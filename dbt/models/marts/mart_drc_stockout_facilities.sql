{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(facility_id, program_id, product_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC stockouts by facility: one row per product x facility x program the
-- facility is expected to manage (active program product x active supported
-- program), with the latest stock on hand and 1/0 flags for stockout, no
-- data and confirmed stockout.
--
-- Replaces: public.vw_rupture_structures
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- Ruptures_stock on top of it, collapsed into one mart. Built from repo SQL
-- on origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on
-- UAT.
--
-- Columns: the view columns, verbatim and in view order, then the dataset
-- columns. The dataset renamed en_rupture to a_une_rupture; both are kept.
--
-- Differences from legacy:
--   - stock_on_hand: legacy joined the perimeter to the latest daily row per
--     facility x product (DISTINCT ON, program ignored), which picked one
--     program arbitrarily when a product is in several programs at a
--     facility. Here it is the sum of the latest balances over the
--     facility's programs for that product: the same join keys, made
--     deterministic. Identical whenever the product is in one program.
--   - Balance from drc_int_stock_daily_history: OpenLMIS's own balance
--     (design decision D1).
--
-- Verification (reviewer, on UAT). Export:
--   \copy (select * from public.vw_rupture_structures) to 'rupture.csv' csv header
-- load as scratch.legacy_vw_rupture_structures. The perimeter does not
-- depend on the balance, so this must return 0 rows both ways:
--   select product_id, facility_id, program_id, code_produit, produit,
--          programme, structure, niveau_organisation, unite_organisation,
--          district, region, type_structure, sans_donnee
--   from scratch.legacy_vw_rupture_structures
--   except
--   select <same list> from curated.mart_drc_stockout_facilities;
-- stock_on_hand, en_rupture and stockout_confirme differ by design.

with prod_prog as (
  select distinct
    assumeNotNull(orderable_id) as product_id,
    assumeNotNull(program_id)   as program_id
  from {{ ref('drc_stg_program_orderables') }}
  where active
    and orderable_id is not null
    and program_id is not null
),

prog_fac as (
  select distinct
    assumeNotNull(program_id)  as program_id,
    assumeNotNull(facility_id) as facility_id
  from {{ ref('stg_supported_programs') }}
  where active
    and program_id is not null
    and facility_id is not null
),

soh as (
  select
    facility_id,
    product_id,
    sum(stock_on_hand) as stock_on_hand
  from (
    select
      facility_id,
      product_id,
      program_id,
      argMax(stock_on_hand, movement_date) as stock_on_hand
    from {{ ref('drc_int_stock_daily_history') }}
    group by facility_id, product_id, program_id
  )
  group by facility_id, product_id
),

base as (
  select
    pp.product_id  as product_id,
    pp.program_id  as program_id,
    pf.facility_id as facility_id
  from prod_prog pp
  inner join prog_fac pf
    on pf.program_id = pp.program_id
)

select
  b.product_id                                     as product_id,
  b.facility_id                                    as facility_id,
  b.program_id                                     as program_id,
  o.code                                           as code_produit,
  o.full_product_name                              as produit,
  p.name                                           as programme,
  fac.facility_name                                as structure,
  fac.geographic_level                             as niveau_organisation,
  fac.geographic_zone_name                         as unite_organisation,
  fac.district_name                                as district,
  fac.region_name                                  as region,
  fac.facility_type_name                           as type_structure,
  s.stock_on_hand                                  as stock_on_hand,
  toUInt8(1)                                       as structure_existante,
  toUInt8(coalesce(s.stock_on_hand, 0) <= 0)       as en_rupture,
  toUInt8(s.facility_id is null)                   as sans_donnee,
  toUInt8(coalesce(s.stock_on_hand <= 0, 0))       as stockout_confirme,

  -- Ruptures_stock dataset columns
  toUInt8(coalesce(s.stock_on_hand, 0) <= 0)       as a_une_rupture,
  toUInt8(not (coalesce(s.stock_on_hand, 0) <= 0)) as stock_disponible_ok,
  multiIf(
    s.facility_id is null,       '3. Pas de données',
    s.stock_on_hand <= 0,        '2. Rupture confirmée',
    '1. Stock disponible'
  )                                                as statut_disponibilite
from base b
left join soh s
  on s.facility_id = b.facility_id
  and s.product_id = b.product_id
left join {{ ref('mart_drc_facility_directory') }} fac
  on fac.facility_id = b.facility_id
left join {{ ref('stg_orderables') }} o
  on o.id = b.product_id
left join {{ ref('stg_programs') }} p
  on p.id = b.program_id
