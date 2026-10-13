{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(order_line_item_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC order flow per product: one row per order line item, following the
-- chain requisition -> order -> shipment -> proof of delivery, with the
-- requested / approved / ordered / delivered / accepted / rejected
-- quantities and the satisfaction, reception and rejection rates.
--
-- Replaces: public.vw_order_flow_product
-- (OlmisCreateAnalyticAggregateSchemaStatements.sql) and the virtual dataset
-- ds_commandes on top of it, collapsed into one mart. Built from repo SQL on
-- origin/PowerBI and the 2026-08-21 export, not from pg_get_viewdef() on UAT.
--
-- Columns: the view columns, verbatim and in view order, plus:
--   - order_line_item_id (first): row id, not in the view, added so the
--     grain is testable.
--   - facility_id (last): ds_commandes looked it up by facility name with a
--     scalar subquery on dim_facility; here it is the order's facility_id.
--     Same value unless two facilities share a name, where legacy errors.
-- statut_commande carries the ds_commandes value, which relabels the view's
-- 'Échec de transfert' as 'Commande échouée'. type_commande and mois_nom are
-- dataset calculated columns and stay in the dataset (Phase 6).
--
-- Differences from legacy:
--   - qte_demandee / qte_approuvee come from core stg_requisition_line_items,
--     which extracts requestedquantity / approvedquantity with JSONExtractInt:
--     a NULL source value reads as 0. Legacy sum() over NULLs gives NULL, so
--     lines not yet approved show 0 here where legacy shows NULL. Sums are
--     unchanged; averages and IS NULL filters are not.
--   - Rates are rounded in Decimal (half away from zero, as Postgres numeric)
--     and returned as Float64.
--   - Order and shipment timestamps: legacy casts to timestamptz in the
--     session time zone; here DateTime in the ClickHouse server time zone.
--
-- Verification (reviewer, on UAT). Export the legacy side:
--   \copy (select * from public.vw_order_flow_product) to 'order_flow.csv' csv header
-- load it into ClickHouse as scratch.legacy_vw_order_flow_product, then both
-- of these must return 0 rows (one processing period at a time is enough:
-- add "where periode = '<name>'" to both sides):
--   select requisition_id, order_id, numero_commande, periode, order_status,
--          if(statut_commande = 'Échec de transfert', 'Commande échouée', statut_commande),
--          orderable_id, code_produit, nom_du_produit, unite_du_produit,
--          coalesce(qte_demandee, 0), coalesce(qte_approuvee, 0),
--          qte_commandee, qte_livree, qte_acceptee, qte_rejetee, nb_lots,
--          taux_satisfaction_pct, taux_reception_pct, taux_rejet_pct,
--          incoherence_qte, date_commande, date_expedition, date_reception,
--          niveau_organisationnel, zone_geographique, type_de_structure,
--          structure, programme, annee, mois, urgence
--   from scratch.legacy_vw_order_flow_product
--   except
--   select <same list, without the two wrappers> from curated.mart_drc_order_flow;
--
--   select <same list> from curated.mart_drc_order_flow
--   except
--   select <same list, with the wrappers> from scratch.legacy_vw_order_flow_product;

with rli as (
  select
    requisition_id,
    orderable_id,
    sum(requested_quantity) as qte_demandee,
    sum(approved_quantity)  as qte_approuvee
  from {{ ref('stg_requisition_line_items') }}
  group by requisition_id, orderable_id
),

pod_prod as (
  select
    s.order_id,
    pol.orderable_id,
    sum(pol.quantity_accepted)   as qte_acceptee,
    sum(pol.quantity_rejected)   as qte_rejetee,
    count(distinct pol.lot_id)   as nb_lots
  from {{ ref('drc_stg_proof_of_delivery_line_items') }} pol
  inner join {{ ref('drc_stg_proofs_of_delivery') }} pod
    on pod.id = pol.proof_of_delivery_id
  inner join {{ ref('drc_stg_shipments') }} s
    on s.id = pod.shipment_id
  group by s.order_id, pol.orderable_id
),

ord as (
  select
    o.id                   as order_id,
    o.external_id          as ext,
    o.order_code           as ordercode,
    o.status               as order_status,
    o.facility_id          as facilityid,
    o.program_id           as programid,
    o.processing_period_id as processingperiodid,
    o.emergency            as emergency,
    min(o.created_date)    as date_commande,
    min(s.shipped_date)    as date_expedition,
    max(pod.received_date) as date_reception
  from {{ ref('drc_stg_orders') }} o
  left join {{ ref('drc_stg_shipments') }} s
    on s.order_id = o.id
  left join {{ ref('drc_stg_proofs_of_delivery') }} pod
    on pod.shipment_id = s.id
  group by o.id, o.external_id, o.order_code, o.status, o.facility_id,
    o.program_id, o.processing_period_id, o.emergency
),

joined as (
  select
    oli.id                                                as order_line_item_id,
    ord.ext                                               as requisition_id,
    ord.order_id                                          as order_id,
    ord.ordercode                                         as numero_commande,
    dpp.name                                              as periode,
    ord.order_status                                      as order_status,
    case ord.order_status
      when 'ORDERED'         then 'Commandée'
      when 'FULFILLING'      then 'En préparation'
      when 'SHIPPED'         then 'Expédiée'
      when 'RECEIVED'        then 'Reçue'
      -- ds_commandes relabels the view's 'Échec de transfert'
      when 'TRANSFER_FAILED' then 'Commande échouée'
      else ord.order_status
    end                                                   as statut_commande,
    oli.orderable_id                                      as orderable_id,
    dp.code                                               as code_produit,
    dp.full_product_name                                  as nom_du_produit,
    dp.description                                        as unite_du_produit,
    rli.qte_demandee                                      as qte_demandee,
    rli.qte_approuvee                                     as qte_approuvee,
    oli.ordered_quantity                                  as qte_commandee,
    coalesce(pp.qte_acceptee, 0) + coalesce(pp.qte_rejetee, 0) as qte_livree,
    pp.qte_acceptee                                       as qte_acceptee,
    pp.qte_rejetee                                        as qte_rejetee,
    pp.nb_lots                                            as nb_lots,
    ord.date_commande                                     as date_commande,
    ord.date_expedition                                   as date_expedition,
    ord.date_reception                                    as date_reception,
    df.geographic_level                                   as niveau_organisationnel,
    df.geographic_zone_name                               as zone_geographique,
    df.facility_type_name                                 as type_de_structure,
    df.facility_name                                      as structure,
    dpr.name                                              as programme,
    toYear(dpp.start_date)                                as annee,
    toMonth(dpp.start_date)                               as mois,
    ord.emergency                                         as urgence,
    ord.facilityid                                        as facility_id
  from {{ ref('drc_stg_order_line_items') }} oli
  inner join ord
    on ord.order_id = oli.order_id
  left join rli
    on rli.requisition_id = ord.ext
    and rli.orderable_id = oli.orderable_id
  left join pod_prod pp
    on pp.order_id = oli.order_id
    and pp.orderable_id = oli.orderable_id
  left join {{ ref('stg_orderables') }} dp
    on dp.id = oli.orderable_id
  left join {{ ref('mart_drc_facility_directory') }} df
    on df.facility_id = ord.facilityid
  left join {{ ref('stg_programs') }} dpr
    on dpr.id = ord.programid
  left join {{ ref('stg_processing_periods') }} dpp
    on dpp.id = ord.processingperiodid
)

select
  order_line_item_id,
  requisition_id,
  order_id,
  numero_commande,
  periode,
  order_status,
  statut_commande,
  orderable_id,
  code_produit,
  nom_du_produit,
  unite_du_produit,
  qte_demandee,
  qte_approuvee,
  qte_commandee,
  qte_livree,
  qte_acceptee,
  qte_rejetee,
  nb_lots,
  if(qte_commandee > 0,
    toFloat64(least(
      round(toDecimal128(100 * qte_livree, 10) / qte_commandee, 1),
      toDecimal128(100, 10)
    )),
    null)                                                 as taux_satisfaction_pct,
  if(qte_commandee > 0,
    toFloat64(least(
      round(toDecimal128(100 * coalesce(qte_acceptee, 0), 10) / qte_commandee, 1),
      toDecimal128(100, 10)
    )),
    null)                                                 as taux_reception_pct,
  if(qte_livree > 0,
    toFloat64(round(toDecimal128(100 * coalesce(qte_rejetee, 0), 10) / qte_livree, 1)),
    null)                                                 as taux_rejet_pct,
  coalesce(qte_acceptee, 0) > qte_commandee               as incoherence_qte,
  date_commande,
  date_expedition,
  date_reception,
  niveau_organisationnel,
  zone_geographique,
  type_de_structure,
  structure,
  programme,
  annee,
  mois,
  urgence,
  facility_id
from joined
