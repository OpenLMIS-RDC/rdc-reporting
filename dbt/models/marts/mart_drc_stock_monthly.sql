{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(facility_id, program_id, product_id, month_date)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC monthly stock: one row per month x facility x program x product with
-- the month's flows, opening / average / closing balance, stockout and
-- observed days, adjusted consumption, the 3-month AMC and the months of
-- stock, plus the labels and stockout severity of the RUPTURE PAR PRODUIT
-- dataset.
--
-- Replaces: analytics.fact_stock_monthly
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- "RUPTURE PAR PRODUIT" on top of it, collapsed into one mart. Built from
-- repo SQL on origin/PowerBI and the 2026-08-21 export, not from
-- pg_get_viewdef() on UAT. The daily datasets' CMM (cmm_m_1) reads amc_3m
-- from here; see mart_drc_stock_daily.
--
-- Columns: the fact_stock_monthly columns first, verbatim and in legacy order
-- (select * of monthly_base, then amc_3m, msd_3m, movement_date), then the
-- dataset columns. The dataset renamed some fact columns (stock_ouverture,
-- consommation, cmm_3m, ...); both names are kept. mois is the French month
-- name; legacy used to_char(..., 'TMMonth'), whose language depends on the
-- database lc_time.
--
-- Differences from legacy:
--   - Built on drc_int_stock_daily_history, so the balances are OpenLMIS's
--     (design decision D1) and history goes back to each key's first
--     movement. Legacy aggregated a series that started on 2026-07-26 at 0,
--     so amc_3m was NULL for every month until three full months had passed.
--   - No 2-year window: legacy cut fact_stock_monthly to the last 2 years,
--     which also dropped the AMC inputs of the oldest months.
--   - RUPTURE PAR PRODUIT deduplicated exact duplicate rows of the legacy
--     view with max(); this mart has none (unique-tested grain).
--   - Decimal rounding, half away from zero as Postgres numeric.
--
-- Verification (reviewer, on UAT): the month_date / key / flow columns must
-- match fact_stock_monthly for months fully covered by the legacy series
-- (2026-08 onwards) except where the daily flows differ (late entries);
-- balances and AMC differ by design (see the design note, section 8):
--   select month_date, facility_id, program_id, product_id, receipts,
--          consumptions, losses, net_transfers, net_adjustments,
--          stockout_days, active_days
--   from scratch.legacy_fact_stock_monthly where month_date >= '2026-08-01'
--   except
--   select <same list> from curated.mart_drc_stock_monthly
--   where month_date >= '2026-08-01';

with monthly_aggregated as (
  select
    toStartOfMonth(movement_date)                                   as month_date,
    facility_id,
    program_id,
    product_id,
    sum(receipts)                                                   as receipts,
    sum(consumptions)                                               as consumptions,
    sum(losses)                                                     as losses,
    sum(net_transfers)                                              as net_transfers,
    sum(net_adjustments)                                            as net_adjustments,
    -- Stock au 1er du mois / stock de clôture du mois
    argMin(opening_balance, movement_date)                          as opening_balance,
    toDecimal128(round(sum(toDecimal128(stock_on_hand, 10)) / count(), 2), 2) as average_stock,
    argMax(stock_on_hand, movement_date)                            as closing_balance,
    toInt64(sum(stockout_days))                                     as stockout_days,
    toInt64(count())                                                as active_days
  from {{ ref('drc_int_stock_daily_history') }}
  group by month_date, facility_id, program_id, product_id
),

monthly_base as (
  select
    *,
    -- Consommation ajustée (si le produit a connu des ruptures)
    if(active_days > stockout_days and active_days > 0,
      toDecimal128(round(
        toDecimal128(consumptions, 10) / (active_days - stockout_days) * active_days,
        2), 2),
      toDecimal128(0, 2)) as adjusted_consumption
  from monthly_aggregated
),

-- AMC: average adjusted consumption over the 3 strictly preceding months.
-- Computed as a Decimal sum / count (avg() returns Float64, which rounds
-- half to even); an empty frame (the key's first month) gives NULL, as in
-- Postgres.
with_amc as (
  select
    *,
    sum(toDecimal128(adjusted_consumption, 10)) over w3
      / greatest(count() over w3, 1)                      as amc_raw,
    count() over w3                                       as amc_months
  from monthly_base
  window w3 as (
    partition by facility_id, program_id, product_id
    order by month_date
    rows between 3 preceding and 1 preceding
  )
),

fact as (
  select
    month_date,
    facility_id,
    program_id,
    product_id,
    receipts,
    consumptions,
    losses,
    net_transfers,
    net_adjustments,
    opening_balance,
    average_stock,
    closing_balance,
    stockout_days,
    active_days,
    adjusted_consumption,
    if(amc_months = 0, null, toDecimal128(round(amc_raw, 2), 2)) as amc_3m,
    -- MSD : 0 si rupture, NULL si stock dormant (stock sans consommation)
    multiIf(
      amc_months > 0 and amc_raw > 0,
        toDecimal128(round(toDecimal128(closing_balance, 10) / amc_raw, 2), 2),
      closing_balance > 0, null,
      toDecimal128(0, 2)
    )                                                            as msd_3m,
    month_date                                                   as movement_date
  from with_amc
)

select
  f.month_date             as month_date,
  f.facility_id            as facility_id,
  f.program_id             as program_id,
  f.product_id             as product_id,
  f.receipts               as receipts,
  f.consumptions           as consumptions,
  f.losses                 as losses,
  f.net_transfers          as net_transfers,
  f.net_adjustments        as net_adjustments,
  f.opening_balance        as opening_balance,
  f.average_stock          as average_stock,
  f.closing_balance        as closing_balance,
  f.stockout_days          as stockout_days,
  f.active_days            as active_days,
  f.adjusted_consumption   as adjusted_consumption,
  f.amc_3m                 as amc_3m,
  f.msd_3m                 as msd_3m,
  f.movement_date          as movement_date,

  -- "RUPTURE PAR PRODUIT" dataset columns
  f.month_date                                as date_rapport,
  toYear(f.month_date)                        as annee,
  {{ drc_month_name_fr('f.month_date') }}     as mois,
  formatDateTime(f.month_date, '%Y-%m')       as annee_mois,
  fac.geographic_level                        as niveau_organisation,
  fac.geographic_zone_name                    as unite_organisation,
  fac.province_name                           as province,
  fac.health_zone_name                        as zone_de_sante,
  fac.facility_type_name                      as type_structure,
  fac.facility_name                           as structure,
  p.name                                      as programme,
  o.code                                      as code,
  o.full_product_name                         as produit,
  f.stockout_days                             as nombre_de_jours_de_rupture,
  f.active_days                               as nombre_de_jours_observes,
  greatest(f.active_days - f.stockout_days, 0) as nombre_de_jours_disponibles,
  f.opening_balance                           as stock_ouverture,
  f.closing_balance                           as stock_fin_periode,
  f.consumptions                              as consommation,
  f.amc_3m                                    as cmm_3m,
  -- msd_3m: same column as the fact's, already above
  multiIf(
    f.active_days = 0,                         '4. Non observé',
    f.stockout_days >= f.active_days,          '1. Rupture totale (100 %)',
    f.stockout_days / f.active_days >= 0.5,    '2. Rupture majeure (50-99 %)',
    f.stockout_days > 0,                       '3. Rupture partielle (< 50 %)',
    '0. Aucune rupture'
  )                                           as severite_rupture,
  toUInt8(f.stockout_days > 0)                as a_connu_une_rupture,
  toUInt8(1)                                  as ligne_suivie
from fact f
left join {{ ref('mart_drc_facility_directory') }} fac
  on fac.facility_id = f.facility_id
left join {{ ref('stg_orderables') }} o
  on o.id = f.product_id
left join {{ ref('stg_programs') }} p
  on p.id = f.program_id
