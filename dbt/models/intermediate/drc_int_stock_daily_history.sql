{{
  config(
    materialized='table',
    engine='MergeTree()',
    partition_by='toYYYYMM(movement_date)',
    order_by='(facility_id, program_id, product_id, movement_date)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC daily stock series: one row per day x facility x program x product,
-- from each key's first stock movement (not before drc_snapshot_start_date)
-- to yesterday, with the opening and closing balance, the day's flows by
-- category, and the stockout flag.
--
-- Replaces: analytics.stock_daily_history and the plpgsql
-- analytics.refresh_daily_stock_history() that filled it one day per night
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql, repo SQL on
-- origin/PowerBI). Design and decisions: docs/daily-snapshot-design.md.
-- Columns are the legacy table's, verbatim and in order.
--
-- Stateless: every day is computed from the full source history on every
-- build, never from this table's previous contents. A full rebuild is the
-- backfill; backdated entries are picked up on the next build; no day opens
-- at an artificial 0 (legacy seeding artifact, migration doc Part G #1).
--
-- Balance (decision D1 = B): stock_on_hand is OpenLMIS's own closing
-- balance from stockmanagement.calculated_stocks_on_hand, taking for each
-- stock card the latest row on or before the day (ASOF join) and summing
-- the key's cards (one per lot). Unlike legacy it reflects physical
-- inventories and receipts / issues without a reason.
--
-- Flows: receipts, consumptions, losses, net_transfers and net_adjustments
-- keep the legacy reason-name rules verbatim (reasoned lines only).
-- net_variation is stock_on_hand - opening_balance (decision D2), so
-- opening + variation = closing still holds; legacy summed the reasoned
-- lines instead. The gap between net_variation and the flows is movement
-- without a reason.
--
-- yesterday = today in var('drc_snapshot_timezone') minus one day (D3; UTC
-- by default, as the legacy cron). Today is never included.
--
-- Verification against legacy (reviewer, on UAT): see the design note,
-- section 8. Per key and day, the flows must match the legacy table except
-- for lines processed after the legacy run for their day:
--   select movement_date, facility_id, program_id, product_id, receipts,
--          consumptions, losses, net_transfers, net_adjustments
--   from scratch.legacy_stock_daily_history
--   except
--   select <same list> from curated.drc_int_stock_daily_history
--   where movement_date between '2026-07-26' and '<last legacy day>';
-- and the balance on the latest day must equal OpenLMIS's stock card
-- summary for a sample of cards.

{% set start_date = var('drc_snapshot_start_date', '2024-01-01') %}
{% set tz = var('drc_snapshot_timezone', 'UTC') %}

with cards as (
  select
    id                          as stock_card_id,
    assumeNotNull(facility_id)  as facility_id,
    assumeNotNull(program_id)   as program_id,
    assumeNotNull(orderable_id) as product_id
  from {{ ref('drc_stg_stock_cards') }}
  where facility_id is not null
    and program_id is not null
    and orderable_id is not null
),

-- One balance per card and date: the row processed last (several rows per
-- pair are possible on stockmanagement versions without OLMIS-8206).
card_balances as (
  select
    assumeNotNull(stock_card_id)                     as stock_card_id,
    occurred_date,
    argMax(stock_on_hand, (processed_date, id))      as stock_on_hand
  from {{ ref('drc_stg_calculated_stocks_on_hand') }}
  where stock_card_id is not null
  group by stock_card_id, occurred_date
),

bounds as (
  select toDate(now('{{ tz }}')) - 1 as yesterday
),

-- Perimeter (legacy step 1): every facility x program x product with a
-- stock card. The series of a key starts on its first balance date, but not
-- before the start date. Keys whose cards have no balance yet get no rows.
key_ranges as (
  select
    c.facility_id as facility_id,
    c.program_id  as program_id,
    c.product_id  as product_id,
    greatest(min(cb.occurred_date), toDate('{{ start_date }}')) as from_day
  from cards c
  inner join card_balances cb
    on cb.stock_card_id = c.stock_card_id
  group by c.facility_id, c.program_id, c.product_id
),

-- One row per card and day, from the day before the key's first day (to
-- seed opening_balance) to yesterday.
card_days as (
  select
    c.stock_card_id as stock_card_id,
    c.facility_id   as facility_id,
    c.program_id    as program_id,
    c.product_id    as product_id,
    kr.from_day     as from_day,
    arrayJoin(
      arrayMap(
        i -> toDate(kr.from_day - 1 + i),
        range(toUInt32(dateDiff('day', kr.from_day, b.yesterday) + 2))
      )
    ) as movement_date
  from cards c
  inner join key_ranges kr
    on kr.facility_id = c.facility_id
    and kr.program_id = c.program_id
    and kr.product_id = c.product_id
  cross join bounds b
  where kr.from_day <= b.yesterday
),

-- Carry-forward (legacy step 3): the latest stored balance on or before the
-- day, per card, summed over the key's cards. No row yet means no stock.
key_balances as (
  select
    cd.facility_id                     as facility_id,
    cd.program_id                      as program_id,
    cd.product_id                      as product_id,
    cd.from_day                        as from_day,
    cd.movement_date                   as movement_date,
    coalesce(sum(cb.stock_on_hand), 0) as stock_on_hand
  from card_days cd
  asof left join card_balances cb
    on cb.stock_card_id = cd.stock_card_id
    and cd.movement_date >= cb.occurred_date
  group by cd.facility_id, cd.program_id, cd.product_id, cd.from_day,
    cd.movement_date
),

with_opening as (
  select
    *,
    lagInFrame(stock_on_hand, 1, 0) over (
      partition by facility_id, program_id, product_id
      order by movement_date
      rows between 1 preceding and current row
    ) as opening_balance
  from key_balances
),

-- The day's movements (legacy step 2), reason-name rules copied verbatim.
daily_movements as (
  select
    c.facility_id    as facility_id,
    c.program_id     as program_id,
    c.product_id     as product_id,
    li.occurred_date as movement_date,
    sum(if(r.name in ('Receipts'), li.quantity, 0))                     as receipts,
    sum(if(r.name in {{ drc_consumption_reasons() }}, li.quantity, 0)) as consumptions,
    sum(if(
      r.reason_type = 'DEBIT'
        and r.reason_category = 'ADJUSTMENT'
        and r.name in ('Peremption', 'Avarie', 'Vol ou Disparition'),
      li.quantity, 0))                                                   as losses,
    sum(if(
      r.name in ('Transfer In', 'Transfert Entrant', 'Retour de Service',
                 'Transfert Sortant', 'Retour au Fournisseur',
                 'Donation Sortante', 'Donation Recue'),
      if(r.reason_type = 'CREDIT', li.quantity, -li.quantity), 0))       as net_transfers,
    sum(if(
      r.name not in ('Correction (+)', 'Correction (-)',
                     'Ajustement Inventaire (+)', 'Ajustement Inventaire (-)',
                     'Beginning Balance Excess', 'Beginning Balance Insufficiency',
                     'Unpacked From Kit', 'Unpack Kit'),
      if(r.reason_type = 'CREDIT', li.quantity, -li.quantity), 0))       as net_adjustments
  from {{ ref('drc_stg_stock_card_line_items') }} li
  inner join {{ ref('drc_stg_stock_card_line_item_reasons') }} r
    on r.id = li.reason_id
  inner join cards c
    on c.stock_card_id = li.stock_card_id
  group by c.facility_id, c.program_id, c.product_id, li.occurred_date
)

select
  w.movement_date                                  as movement_date,
  w.facility_id                                    as facility_id,
  w.program_id                                     as program_id,
  w.product_id                                     as product_id,
  w.opening_balance                                as opening_balance,
  coalesce(dm.receipts, 0)                         as receipts,
  coalesce(dm.consumptions, 0)                     as consumptions,
  coalesce(dm.losses, 0)                           as losses,
  coalesce(dm.net_transfers, 0)                    as net_transfers,
  coalesce(dm.net_adjustments, 0)                  as net_adjustments,
  w.stock_on_hand - w.opening_balance              as net_variation,
  w.stock_on_hand                                  as stock_on_hand,
  toUInt8(w.stock_on_hand <= 0)                    as stockout_days,
  now()                                            as updated_at
from with_opening w
left join daily_movements dm
  on dm.facility_id = w.facility_id
  and dm.program_id = w.program_id
  and dm.product_id = w.product_id
  and dm.movement_date = w.movement_date
-- drop the seeding day before the key's first day
where w.movement_date >= w.from_day
