{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(date_expiration, lot_id)',
    settings={'allow_nullable_key': 1},
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC expiry risk: one row per facility x program x product x lot with stock
-- on hand that is already expired or expires within 90 days, with the
-- 30 / 60 / 90-day quantity buckets and the USD value of the 30-day bucket.
--
-- Replaces: analytics.fact_expired_risk_snapshot and public.vw_expiry_risk
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- ds_expiration on top of them, collapsed into one mart. Built from repo SQL
-- on origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on
-- UAT.
--
-- Columns: the vw_expiry_risk columns, verbatim and in view order, plus
-- program_id (after lot_id): the view groups by program but does not expose
-- it, so without it the grain is not unique. date_expiration stays a Date;
-- ds_expiration turned it into 'YYYY-MM-DD' text with to_char, which Superset
-- renders the same way. horizon_expiration, jours_avant_expiration and the
-- English-named aliases (produit, type_structure, ...) are dataset calculated
-- columns and stay in the dataset (Phase 6).
--
-- As-of date: jours_avant_expiration, categorie_expiration, the buckets and
-- the <= 90-day filter are computed against today() at build time, where
-- legacy used CURRENT_DATE at query time. The mart is current only as of its
-- last build; the Phase 5 Airflow schedule must rebuild it at least daily.
--
-- Port notes, for the reviewer to check against pg_get_viewdef() on UAT:
--   - stock_on_hand is sum(quantity) over every line item of the lot's
--     cards, as in the repo SQL. quantity is unsigned in stockmanagement
--     (the sign comes from the reason or source/destination), so this is
--     total throughput, not a balance. Ported as is to keep the diff exact;
--     if UAT has a signed version, follow UAT.
--   - price: legacy takes one program_orderables row per orderable across
--     all programs (DISTINCT ON orderableid, active desc, version desc), so
--     the price can come from another program than the row's, and ties are
--     arbitrary. Ported as is; ties broken by program_orderables id here.
--   - valeur_usd_30j is rounded in Decimal (half away from zero, as Postgres
--     numeric) and returned as Float64.
--
-- Verification (reviewer, on UAT, same day as the mart build). Export:
--   \copy (select * from public.vw_expiry_risk) to 'expiry_risk.csv' csv header
-- load it into ClickHouse as scratch.legacy_vw_expiry_risk, then both of
-- these must return 0 rows:
--   select facility_id, product_id, lot_id, structure, code_produit,
--          nom_produit, numero_lot, date_expiration, unite_du_produit,
--          stock_on_hand, jours_avant_expiration, categorie_expiration,
--          qte_deja_expiree, qte_expirant_30j, qte_expirant_60j,
--          qte_expirant_90j, valeur_usd_30j, priceperpack, netcontent,
--          programme, niveau_organisationnel, zone_geographique, district,
--          region, type_de_structure, annee, mois, annee_mois
--   from scratch.legacy_vw_expiry_risk
--   except
--   select <same list> from curated.mart_drc_expiry_risk;
--
--   select <same list> from curated.mart_drc_expiry_risk
--   except
--   select <same list> from scratch.legacy_vw_expiry_risk;

with current_lot_balance as (
  select
    sc.facility_id    as facility_id,
    sc.program_id     as program_id,
    sc.orderable_id   as product_id,
    sc.lot_id         as lot_id,
    sum(li.quantity)  as stock_on_hand
  from {{ ref('drc_stg_stock_card_line_items') }} li
  inner join {{ ref('drc_stg_stock_cards') }} sc
    on li.stock_card_id = sc.id
  group by sc.facility_id, sc.program_id, sc.orderable_id, sc.lot_id
  having sum(li.quantity) > 0
),

-- analytics.fact_expired_risk_snapshot
fe as (
  select
    sb.facility_id,
    sb.program_id,
    sb.product_id,
    sb.lot_id,
    l.lot_code                                as lot_code,
    l.expiration_date                         as expiration_date,
    sb.stock_on_hand,
    dateDiff('day', today(), l.expiration_date) as lifetime_days,
    case
      when dateDiff('day', today(), l.expiration_date) < 0    then 'Périmé'
      when dateDiff('day', today(), l.expiration_date) <= 90  then 'Moins de 3 mois'
      when dateDiff('day', today(), l.expiration_date) <= 180 then '3 à 6 mois'
      when dateDiff('day', today(), l.expiration_date) <= 270 then '6 à 9 mois'
      else 'Sain (Plus de 9 mois)'
    end                                       as expiration_category
  from current_lot_balance sb
  inner join {{ ref('drc_stg_lots') }} l
    on sb.lot_id = l.id
  where dateDiff('day', today(), l.expiration_date) <= 270
),

price as (
  select
    orderable_id,
    price_per_pack as priceperpack
  from (
    select
      orderable_id,
      price_per_pack,
      row_number() over (
        partition by orderable_id
        order by active desc, orderable_version_number desc, id
      ) as _rn
    from {{ ref('drc_stg_program_orderables') }}
  )
  where _rn = 1
),

-- core stg_orderables is already the latest version per id
packsize as (
  select
    id          as orderable_id,
    net_content as netcontent
  from {{ ref('stg_orderables') }}
),

bucketed as (
  select
    fe.*,
    if(fe.lifetime_days < 0, fe.stock_on_hand, 0)                            as qte_deja_expiree,
    if(fe.lifetime_days >= 0 and fe.lifetime_days <= 30, fe.stock_on_hand, 0) as qte_expirant_30j,
    if(fe.lifetime_days >= 0 and fe.lifetime_days <= 60, fe.stock_on_hand, 0) as qte_expirant_60j,
    if(fe.lifetime_days >= 0 and fe.lifetime_days <= 90, fe.stock_on_hand, 0) as qte_expirant_90j
  from fe
  where fe.lifetime_days <= 90
)

select
  b.facility_id                  as facility_id,
  b.product_id                   as product_id,
  b.lot_id                       as lot_id,
  b.program_id                   as program_id,
  df.facility_name               as structure,
  dp.code                        as code_produit,
  dp.full_product_name           as nom_produit,
  b.lot_code                     as numero_lot,
  b.expiration_date              as date_expiration,
  dp.description                 as unite_du_produit,
  b.stock_on_hand                as stock_on_hand,
  b.lifetime_days                as jours_avant_expiration,
  b.expiration_category          as categorie_expiration,
  b.qte_deja_expiree             as qte_deja_expiree,
  b.qte_expirant_30j             as qte_expirant_30j,
  b.qte_expirant_60j             as qte_expirant_60j,
  b.qte_expirant_90j             as qte_expirant_90j,
  toFloat64(round(
    toDecimal128(b.qte_expirant_30j, 0)
      * toDecimal128(pr.priceperpack, 6)
      / nullIf(ps.netcontent, 0),
    2))                          as valeur_usd_30j,
  pr.priceperpack                as priceperpack,
  ps.netcontent                  as netcontent,
  dpr.name                       as programme,
  df.geographic_level            as niveau_organisationnel,
  df.geographic_zone_name        as zone_geographique,
  df.district_name               as district,
  df.region_name                 as region,
  df.facility_type_name          as type_de_structure,
  toYear(b.expiration_date)      as annee,
  toMonth(b.expiration_date)     as mois,
  formatDateTime(b.expiration_date, '%Y-%m') as annee_mois
from bucketed b
left join {{ ref('stg_orderables') }} dp
  on dp.id = b.product_id
left join {{ ref('mart_drc_facility_directory') }} df
  on df.facility_id = b.facility_id
left join {{ ref('stg_programs') }} dpr
  on dpr.id = b.program_id
left join price pr
  on pr.orderable_id = b.product_id
left join packsize ps
  on ps.orderable_id = b.product_id
