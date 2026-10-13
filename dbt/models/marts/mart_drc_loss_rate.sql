{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(facility_id, program_id, product_id, date_rapport)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC loss rate: one row per month x facility x program x product with stock
-- movements, with the month's receipts (CREDIT), issues (DEBIT), losses by
-- cause (Peremption / Avarie / Vol ou Disparition), the opening balance of
-- the month, and four loss-rate denominators.
--
-- Replaces: public.vw_taux_perte
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- "Taux de perte" on top of it, collapsed into one mart. Built from repo SQL
-- on origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on
-- UAT.
--
-- Columns: the view columns, verbatim and in view order, then the dataset
-- columns. Added for a testable grain: facility_id (the dataset looked it up
-- by facility name with a scalar subquery; same value unless two facilities
-- share a name, where legacy errors), program_id and product_id. mois is the
-- French month name; legacy used to_char(..., 'TMMonth'), whose language
-- depends on the database lc_time.
--
-- Differences from legacy:
--   - stock_debut is the opening balance of the month's first day in
--     drc_int_stock_daily_history: OpenLMIS's own balance (design decision
--     D1), and available for every month since the key's first movement.
--     Legacy read stock_daily_history, which started on 2026-07-26 at 0, so
--     stock_debut was NULL before August 2026 and 0-based afterwards.
--   - Ratios are Float64 from an exact Decimal division; taux_perte_pct is
--     rounded in Decimal (half away from zero, as Postgres numeric).
--
-- Verification (reviewer, on UAT). Export:
--   \copy (select * from public.vw_taux_perte) to 'taux_perte.csv' csv header
-- load as scratch.legacy_vw_taux_perte. The flows do not depend on the
-- balance, so this must return 0 rows both ways (one month at a time is
-- enough: add "where annee_mois = '<YYYY-MM>'" to both sides):
--   select date_rapport, province, zone_de_sante, aire_de_sante,
--          etablissement_de_sante, type_structure, programme, code, produit,
--          quantite_entrees, quantite_sorties, quantite_perdue,
--          pertes_peremption, pertes_avarie, pertes_vol,
--          round(taux_perte_sur_entrees, 9), round(taux_perte_sur_sorties, 9),
--          taux_perte_pct, annee_mois
--   from scratch.legacy_vw_taux_perte
--   except
--   select <same list> from curated.mart_drc_loss_rate;
-- stock_debut, stock_total_disponible and taux_perte_sur_disponible differ
-- by design.

with mv as (
  select
    assumeNotNull(sc.facility_id)         as facility_id,
    assumeNotNull(sc.orderable_id)        as product_id,
    assumeNotNull(sc.program_id)          as program_id,
    toStartOfMonth(li.occurred_date)      as mois,
    li.quantity                           as quantity,
    r.reason_type                         as reasontype,
    r.name                                as reason
  from {{ ref('drc_stg_stock_card_line_items') }} li
  inner join {{ ref('drc_stg_stock_card_line_item_reasons') }} r
    on r.id = li.reason_id
  inner join {{ ref('drc_stg_stock_cards') }} sc
    on sc.id = li.stock_card_id
  where sc.facility_id is not null
    and sc.orderable_id is not null
    and sc.program_id is not null
),

agg as (
  select
    facility_id,
    product_id,
    program_id,
    mois,
    sumIf(quantity, reasontype = 'CREDIT')                                          as entrees,
    sumIf(quantity, reasontype = 'DEBIT')                                           as sorties_totales,
    sumIf(quantity, reason in ('Peremption', 'Avarie', 'Vol ou Disparition'))        as pertes,
    sumIf(quantity, reason = 'Peremption')                                          as pertes_peremption,
    sumIf(quantity, reason = 'Avarie')                                              as pertes_avarie,
    sumIf(quantity, reason = 'Vol ou Disparition')                                  as pertes_vol
  from mv
  group by facility_id, product_id, program_id, mois
),

opening as (
  select
    facility_id,
    product_id,
    program_id,
    toStartOfMonth(movement_date)            as mois,
    argMin(opening_balance, movement_date)   as stock_debut
  from {{ ref('drc_int_stock_daily_history') }}
  group by facility_id, product_id, program_id, mois
),

perte as (
  select
    a.mois                                           as date_rapport,
    toYear(a.mois)                                   as annee,
    {{ drc_month_name_fr('a.mois') }}                as mois,
    fac.province_name                                as province,
    fac.health_zone_name                             as zone_de_sante,
    fac.health_area_name                             as aire_de_sante,
    fac.facility_name                                as etablissement_de_sante,
    fac.facility_type_name                           as type_structure,
    p.name                                           as programme,
    o.code                                           as code,
    o.full_product_name                              as produit,
    op.stock_debut                                   as stock_debut,
    a.entrees                                        as quantite_entrees,
    a.sorties_totales                                as quantite_sorties,
    a.pertes                                         as quantite_perdue,
    a.pertes_peremption                              as pertes_peremption,
    a.pertes_avarie                                  as pertes_avarie,
    a.pertes_vol                                     as pertes_vol,
    op.stock_debut + a.entrees                       as stock_total_disponible,
    if(a.entrees = 0, null,
      toFloat64(toDecimal128(a.pertes, 20) / a.entrees))         as taux_perte_sur_entrees,
    if(a.sorties_totales = 0, null,
      toFloat64(toDecimal128(a.pertes, 20) / a.sorties_totales)) as taux_perte_sur_sorties,
    if(op.stock_debut + a.entrees = 0, null,
      toFloat64(toDecimal128(a.pertes, 20) / (op.stock_debut + a.entrees))) as taux_perte_sur_disponible,
    if(a.sorties_totales = 0, null,
      toFloat64(round(toDecimal128(100 * a.pertes, 10) / a.sorties_totales, 1))) as taux_perte_pct,
    formatDateTime(a.mois, '%Y-%m')                  as annee_mois,
    a.facility_id                                    as facility_id,
    a.program_id                                     as program_id,
    a.product_id                                     as product_id
  from agg a
  left join opening op
    on op.facility_id = a.facility_id
    and op.product_id = a.product_id
    and op.program_id = a.program_id
    and op.mois = a.mois
  left join {{ ref('mart_drc_facility_directory') }} fac
    on fac.facility_id = a.facility_id
  left join {{ ref('stg_programs') }} p
    on p.id = a.program_id
  left join {{ ref('stg_orderables') }} o
    on o.id = a.product_id
)

select
  t.*,

  -- "Taux de perte" dataset columns
  t.etablissement_de_sante                         as structure,
  t.zone_de_sante                                  as unite_organisation,
  t.quantite_perdue                                as valeur_pertes,
  -- Cause principale de la perte (pour cibler l'action corrective)
  multiIf(
    t.quantite_perdue = 0,                                           '0. Aucune perte',
    t.pertes_peremption >= greatest(t.pertes_avarie, t.pertes_vol),  '1. Péremption',
    t.pertes_avarie >= greatest(t.pertes_peremption, t.pertes_vol),  '2. Avarie / casse',
    t.pertes_vol > 0,                                                '3. Vol / disparition',
    '4. Autre / non ventilé'
  )                                                as cause_principale,
  toUInt8(t.quantite_perdue > 0)                   as a_une_perte,
  toUInt8(1)                                       as ligne_suivie
from perte t
