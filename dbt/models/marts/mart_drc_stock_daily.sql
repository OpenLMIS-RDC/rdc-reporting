{{
  config(
    materialized='table',
    engine='MergeTree()',
    partition_by='toYYYYMM(movement_date)',
    order_by='(facility_id, program_id, product_id, movement_date)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC daily stock: one row per day x facility x program x product with the
-- opening and closing balance, the day's flows, the CMM of the previous
-- month, the months of stock and the stock status, and the labels and 1/0
-- flags of the daily report datasets. Feeds "Suivi journalier des stocks".
--
-- Replaces: analytics.stock_daily_history / analytics.fact_stock_daily
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual datasets
-- "Rapport de stock journalier - RDC" and "Rapport stock journalier" on top
-- of them, collapsed into one mart. Built from repo SQL on origin/PowerBI and
-- the 2026-08-21 export, not from pg_get_viewdef() on UAT. The series itself
-- is drc_int_stock_daily_history (design: docs/daily-snapshot-design.md).
--
-- Columns: the legacy table columns first, verbatim and in order, then the
-- union of both datasets' columns. Where the datasets named the same value
-- differently, both names are kept (stock_recu / receptions, consommations /
-- consommation, code_produit / code). mois is the French month name for both
-- (the second dataset used to_char(..., 'TMMonth'), language set by lc_time).
-- periode ('J-1' / 'Autres jours') reads CURRENT_DATE and stays a dataset
-- calculated column (Phase 6): the "Période = J-1" native filter needs it.
--
-- Differences from legacy:
--   - Balances are OpenLMIS's and history starts at each key's first
--     movement (design decisions D1, D4): no seeding artifact.
--   - CMM (cmm_m_1) comes from mart_drc_stock_monthly.amc_3m joined on
--     facility, program and product (D6). Legacy joined on facility and
--     product only and took max() over programs. With full history the CMM
--     is now available (legacy: NULL on every row, Part G #2).
--   - No 2-year window (fact_stock_daily cut the table to 2 years); filter
--     on movement_date in the dataset if needed. jours_en_rupture therefore
--     counts stockout days over the whole series, not the last 2 years.
--   - est_dernier_jour compares with the latest day in the mart, as legacy
--     max(...) over () did over the whole dataset; that is yesterday.
--
-- Verification (reviewer, on UAT): diff the flows as described in
-- drc_int_stock_daily_history; the status columns depend on balance and CMM
-- and differ by design.

with daily as (
  select *
  from {{ ref('drc_int_stock_daily_history') }}
),

cmm as (
  select
    facility_id,
    program_id,
    product_id,
    month_date,
    amc_3m
  from {{ ref('mart_drc_stock_monthly') }}
),

with_cmm as (
  select
    d.movement_date    as movement_date,
    d.facility_id      as facility_id,
    d.program_id       as program_id,
    d.product_id       as product_id,
    d.opening_balance  as opening_balance,
    d.receipts         as receipts,
    d.consumptions     as consumptions,
    d.losses           as losses,
    d.net_transfers    as net_transfers,
    d.net_adjustments  as net_adjustments,
    d.net_variation    as net_variation,
    d.stock_on_hand    as stock_on_hand,
    d.stockout_days    as stockout_days,
    d.updated_at       as updated_at,
    -- CMM de référence : mois précédent, à défaut mois courant
    coalesce(mprev.amc_3m, mcur.amc_3m, toDecimal128(0, 2)) as cmm_ref
  from daily d
  left join cmm mprev
    on mprev.facility_id = d.facility_id
    and mprev.program_id = d.program_id
    and mprev.product_id = d.product_id
    and mprev.month_date = toStartOfMonth(d.movement_date) - toIntervalMonth(1)
  left join cmm mcur
    on mcur.facility_id = d.facility_id
    and mcur.program_id = d.program_id
    and mcur.product_id = d.product_id
    and mcur.month_date = toStartOfMonth(d.movement_date)
)

select
  -- analytics.stock_daily_history columns
  w.movement_date as movement_date,
  w.facility_id as facility_id,
  w.program_id as program_id,
  w.product_id as product_id,
  w.opening_balance as opening_balance,
  w.receipts as receipts,
  w.consumptions as consumptions,
  w.losses as losses,
  w.net_transfers as net_transfers,
  w.net_adjustments as net_adjustments,
  w.net_variation as net_variation,
  w.stock_on_hand as stock_on_hand,
  w.stockout_days as stockout_days,
  w.updated_at as updated_at,

  -- daily report dataset columns
  w.movement_date                                 as date_rapport,
  formatDateTime(w.movement_date, '%d/%m/%Y')     as date_rapport_fr,
  toYear(w.movement_date)                         as annee,
  toMonth(w.movement_date)                        as mois_num,
  {{ drc_month_name_fr('w.movement_date') }}      as mois,
  toDayOfMonth(w.movement_date)                   as jour,
  formatDateTime(w.movement_date, '%Y-%m')        as annee_mois,
  fac.geographic_level                            as niveau_organisation,
  fac.geographic_zone_name                        as unite_organisation,
  fac.province_name                               as province,
  fac.health_zone_name                            as zone_de_sante,
  fac.facility_type_name                          as type_structure,
  fac.facility_name                               as structure,
  p.name                                          as programme,
  o.code                                          as code_produit,
  o.code                                          as code,
  o.full_product_name                             as produit,
  w.opening_balance                               as stock_ouverture,
  w.receipts                                      as stock_recu,
  w.receipts                                      as receptions,
  w.losses                                        as pertes,
  w.consumptions                                  as consommations,
  w.consumptions                                  as consommation,
  w.net_adjustments                               as ajustements,
  w.net_transfers                                 as transferts_nets,
  w.stock_on_hand                                 as stock_disponible,
  w.cmm_ref                                       as cmm_m_1,
  -- MSD : NULL quand la CMM n'est pas exploitable
  if(w.cmm_ref > 0,
    toDecimal128(round(toDecimal128(w.stock_on_hand, 10) / w.cmm_ref, 2), 2),
    null)                                         as msd,
  -- Statut : la rupture est qualifiée même sans CMM
  multiIf(
    w.stock_on_hand <= 0,                          '1. Rupture',
    w.cmm_ref = 0,                                 '4. Stock présent - CMM indisponible',
    toDecimal128(w.stock_on_hand, 10) / w.cmm_ref < 1,  '2. Risque de rupture',
    toDecimal128(w.stock_on_hand, 10) / w.cmm_ref <= 3, '3. Satisfaisant',
    '6. Surstock'
  )                                               as statut,
  toUInt8(w.movement_date = max(w.movement_date) over ()) as est_dernier_jour,
  toUInt8(w.stock_on_hand <= 0)                   as est_en_rupture,
  toUInt8(w.cmm_ref > 0)                          as cmm_exploitable,
  toUInt8(w.receipts + w.consumptions + w.losses + w.net_adjustments
    + w.net_transfers != 0)                       as a_mouvement,
  toUInt8(1)                                      as ligne_suivie,
  -- Stockout days of the key over the whole series
  countIf(w.stock_on_hand <= 0) over (
    partition by w.facility_id, w.program_id, w.product_id
  )                                               as jours_en_rupture
from with_cmm w
left join {{ ref('mart_drc_facility_directory') }} fac
  on fac.facility_id = w.facility_id
left join {{ ref('stg_orderables') }} o
  on o.id = w.product_id
left join {{ ref('stg_programs') }} p
  on p.id = w.program_id
