{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(line_item_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC stock adjustments: one row per stock card line item whose reason is in
-- the ADJUSTMENT category (consumption, receipts and the beginning-balance
-- corrections excluded), with the signed quantity, the reason, the user who
-- entered it, and the facility / program dimensions.
--
-- Replaces: public.vw_stock_adjustments
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- ds_ajustement on top of it, collapsed into one mart. Built from repo SQL on
-- origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on UAT.
--
-- Columns: the view columns, verbatim and in view order, plus facility_id
-- (last): ds_ajustement looked it up by facility name with a scalar subquery
-- on dim_facility; here it is the stock card's facility_id. Same value unless
-- two facilities share a name, where legacy errors. mois_nom is a dataset
-- calculated column and stays in the dataset (Phase 6). The "who adjusted"
-- columns are kept (plan decision 2).
--
-- Differences from legacy:
--   - A reason or user name that is NULL in Postgres arrives as '' through
--     JSONExtractString. utilisateur_ayant_ajuste is unaffected (legacy
--     coalesces to ''); raison_ajustement and login_utilisateur show '' where
--     legacy shows NULL for a matched row with a NULL name. login_utilisateur
--     is still NULL when no user matches.
--
-- Verification (reviewer, on UAT). Export the legacy side:
--   \copy (select * from public.vw_stock_adjustments) to 'stock_adjustments.csv' csv header
-- load it into ClickHouse as scratch.legacy_vw_stock_adjustments, then both
-- of these must return 0 rows (add "where annee_mois = '<YYYY-MM>'" to both
-- sides to diff one month):
--   select line_item_id, structure, code_produit, nom_produit, numero_lot,
--          unite_de_dispensation, quantite_ajustee, raison_ajustement,
--          utilisateur_ayant_ajuste, login_utilisateur, sens_ajustement,
--          reasontype, quantite_absolue, date_ajustement, programme,
--          niveau_organisationnel, zone_geographique, district, region,
--          type_de_structure, annee, mois, annee_mois
--   from scratch.legacy_vw_stock_adjustments
--   except
--   select <same list> from curated.mart_drc_stock_adjustments;
--
--   select <same list> from curated.mart_drc_stock_adjustments
--   except
--   select <same list> from scratch.legacy_vw_stock_adjustments;

select
  li.id                                                   as line_item_id,
  df.facility_name                                        as structure,
  dp.code                                                 as code_produit,
  dp.full_product_name                                    as nom_produit,
  kl.lot_code                                             as numero_lot,
  dp.description                                          as unite_de_dispensation,
  if(r.reason_type = 'CREDIT', li.quantity, -li.quantity) as quantite_ajustee,
  r.name                                                  as raison_ajustement,
  trimBoth(coalesce(du.first_name, '') || ' ' || coalesce(du.last_name, ''))
                                                          as utilisateur_ayant_ajuste,
  du.username                                             as login_utilisateur,
  if(r.reason_type = 'CREDIT', 'Positif', 'Négatif')      as sens_ajustement,
  r.reason_type                                           as reasontype,
  li.quantity                                             as quantite_absolue,
  li.occurred_date                                        as date_ajustement,
  dpr.name                                                as programme,
  df.geographic_level                                     as niveau_organisationnel,
  df.geographic_zone_name                                 as zone_geographique,
  df.district_name                                        as district,
  df.region_name                                          as region,
  df.facility_type_name                                   as type_de_structure,
  toYear(li.occurred_date)                                as annee,
  toMonth(li.occurred_date)                               as mois,
  formatDateTime(li.occurred_date, '%Y-%m')               as annee_mois,
  sc.facility_id                                          as facility_id
from {{ ref('drc_stg_stock_card_line_items') }} li
inner join {{ ref('drc_stg_stock_card_line_item_reasons') }} r
  on r.id = li.reason_id
inner join {{ ref('drc_stg_stock_cards') }} sc
  on sc.id = li.stock_card_id
left join {{ ref('stg_orderables') }} dp
  on dp.id = sc.orderable_id
left join {{ ref('drc_stg_lots') }} kl
  on kl.id = sc.lot_id
left join {{ ref('mart_drc_facility_directory') }} df
  on df.facility_id = sc.facility_id
left join {{ ref('stg_programs') }} dpr
  on dpr.id = sc.program_id
left join {{ ref('drc_stg_users') }} du
  on du.id = li.user_id
where r.reason_category = 'ADJUSTMENT'
  and r.name not in (
    'Consommation', 'Consumed', 'Receipts',
    'Beginning Balance Excess', 'Beginning Balance Insufficiency'
  )
