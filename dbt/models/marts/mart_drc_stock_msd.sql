{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(facility_id, program_id, product_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC stock status by months of stock: one row per facility x program x
-- product with the latest balance, the average monthly consumption over the
-- last 3 months of movements, the months of stock (MSD) and the stock state
-- band (Rupture / Stock dormant / Potentielle rupture / Sous-stock /
-- Satisfaisant / Surstock).
--
-- Replaces: public.vw_stock_msd
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual datasets
-- "ETAT DE STOCK" and "ETAT DE STOCK A DIFFERENTS NIVEAUX" on top of it
-- (identical SQL), collapsed into one mart. Built from repo SQL on
-- origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on UAT.
--
-- Columns: the view columns, verbatim and in view order, then the dataset
-- columns (annee_mois, etat_stock_ordonne and the 1/0 flags). mois is the
-- French month name; legacy used to_char(..., 'TMMonth'), whose language
-- depends on the database lc_time.
--
-- Differences from legacy:
--   - Grain. Legacy took the latest daily row per facility x product
--     (DISTINCT ON facility_id, product_id) and kept whichever program came
--     first, an arbitrary pick when a product is in several programs at a
--     facility. This mart keeps one row per facility x program x product,
--     all on the latest day, with the CMM of that program (the legacy CMM
--     was already per program).
--   - Balance from drc_int_stock_daily_history: OpenLMIS's own balance
--     (design decision D1), not the legacy reasoned-lines running sum.
--   - Decimal rounding, half away from zero as Postgres numeric.
--
-- CMM is unchanged: consumption lines ('Consommation', 'Consumed',
-- 'Sortie de stock') in the 3 months up to the latest occurred date of any
-- line item in the system, divided by 3.
--
-- Verification (reviewer, on UAT, same day as the mart build). Export:
--   \copy (select * from public.vw_stock_msd) to 'stock_msd.csv' csv header
-- load as scratch.legacy_vw_stock_msd, then compare the CMM (independent of
-- the balance change), which must return 0 rows:
--   select facility_id, product_id, program_id, cmm
--   from scratch.legacy_vw_stock_msd
--   except
--   select facility_id, product_id, program_id, cmm
--   from curated.mart_drc_stock_msd;
-- Legacy has one row per facility x product, so rows of products in
-- several programs at one facility show up here only on the mart side.

with bornes as (
  select max(occurred_date) as d_max
  from {{ ref('drc_stg_stock_card_line_items') }}
),

conso as (
  select
    sc.facility_id                                   as facility_id,
    sc.orderable_id                                  as product_id,
    sc.program_id                                    as program_id,
    toDecimal128(sum(li.quantity), 10) / 3           as cmm
  from {{ ref('drc_stg_stock_card_line_items') }} li
  inner join {{ ref('drc_stg_stock_card_line_item_reasons') }} r
    on r.id = li.reason_id
  inner join {{ ref('drc_stg_stock_cards') }} sc
    on sc.id = li.stock_card_id
  cross join bornes b
  -- 'Sortie de stock' is the legacy MSD view's own addition; whether it
  -- stays is the DRC team's call (plan 7c).
  where r.name in {{ drc_consumption_reasons(['Sortie de stock']) }}
    and li.occurred_date > b.d_max - toIntervalMonth(3)
    and li.occurred_date <= b.d_max
  group by sc.facility_id, sc.orderable_id, sc.program_id
),

-- Latest day of every key (every key of the dense series ends yesterday)
sdu as (
  select
    facility_id,
    product_id,
    program_id,
    argMax(stock_on_hand, movement_date) as latest_stock_on_hand,
    max(movement_date)                   as latest_movement_date
  from {{ ref('drc_int_stock_daily_history') }}
  group by facility_id, product_id, program_id
),

msd as (
  select
    s.facility_id as facility_id,
    s.product_id as product_id,
    s.program_id as program_id,
    s.latest_movement_date                                  as date_rapport,
    toYear(s.latest_movement_date)                          as annee,
    toMonth(s.latest_movement_date)                         as mois_num,
    {{ drc_month_name_fr('s.latest_movement_date') }}       as mois,
    fac.geographic_level                             as niveau_organisation,
    fac.geographic_zone_name                         as unite_organisation,
    fac.district_name                                as district,
    fac.region_name                                  as region,
    fac.facility_type_name                           as type_structure,
    fac.facility_name                                as structure,
    p.name                                           as programme,
    o.full_product_name                              as produit,
    o.code                                           as code_produit,
    s.latest_stock_on_hand                                  as quantites_en_fin_de_periode,
    toDecimal128(round(c.cmm, 2), 2)                 as cmm,
    multiIf(
      s.latest_stock_on_hand <= 0,           toDecimal128(0, 2),
      coalesce(c.cmm, 0) = 0,         null,
      least(toDecimal128(round(toDecimal128(s.latest_stock_on_hand, 10) / c.cmm, 2), 2),
            toDecimal128(24, 2))
    )                                                as msd,
    multiIf(
      s.latest_stock_on_hand <= 0,                              'Rupture',
      coalesce(c.cmm, 0) = 0,                            'Stock dormant',
      toDecimal128(s.latest_stock_on_hand, 10) / c.cmm <= 4,    'Potentielle rupture',
      toDecimal128(s.latest_stock_on_hand, 10) / c.cmm <= 7,    'Sous-stock',
      toDecimal128(s.latest_stock_on_hand, 10) / c.cmm <= 15,   'Satisfaisant',
      'Surstock'
    )                                                as etat_stock
  from sdu s
  left join conso c
    on c.facility_id = s.facility_id
    and c.product_id = s.product_id
    and c.program_id = s.program_id
  left join {{ ref('mart_drc_facility_directory') }} fac
    on fac.facility_id = s.facility_id
  left join {{ ref('stg_orderables') }} o
    on o.id = s.product_id
  left join {{ ref('stg_programs') }} p
    on p.id = s.program_id
)

select
  m.*,

  -- "ETAT DE STOCK" / "ETAT DE STOCK A DIFFERENTS NIVEAUX" dataset columns
  formatDateTime(m.date_rapport, '%Y-%m')          as annee_mois,
  case m.etat_stock
    when 'Rupture'             then '1. Rupture (MSD = 0)'
    when 'Potentielle rupture' then '2. Potentielle rupture (MSD <= 4 mois)'
    when 'Sous-stock'          then '3. Sous-stock (MSD 4 a 7 mois)'
    when 'Satisfaisant'        then '4. Satisfaisant (MSD 7 a 15 mois)'
    when 'Surstock'            then '5. Surstock (MSD > 15 mois)'
    when 'Stock dormant'       then '6. Stock dormant (CMM = 0)'
    else '9. ' || coalesce(m.etat_stock, 'Non classe')
  end                                              as etat_stock_ordonne,
  toUInt8(m.etat_stock = 'Rupture')                as est_en_rupture,
  toUInt8(m.etat_stock in ('Rupture', 'Potentielle rupture')) as est_sous_4_mois,
  toUInt8(m.etat_stock = 'Surstock')               as est_en_surstock,
  toUInt8(m.msd is null)                           as est_dormant,
  toUInt8(1)                                       as ligne_suivie
from msd m
