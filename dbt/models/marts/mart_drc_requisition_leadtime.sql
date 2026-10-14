{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(req_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC requisition lead time: one row per requisition with the first date it
-- reached each status, the interval measures in days, and the labels, flags
-- and dimensions of the "Suivi des réquisitions" dataset.
--
-- Replaces: analytics.fact_requisition_leadtime
-- (OlmisCreateAnalyticSchemaStatements.sql, section 3.6) and the virtual
-- dataset "Suivi des réquisitions" on top of it, collapsed into one mart.
-- The "Suivi des réquisitions – étapes" dataset is an unpivot of this grain
-- (six steps per requisition) and stays a dataset over this mart (Phase 6);
-- every date it reads is here. Built from repo SQL on origin/PowerBI and the
-- 2026-08-21 export, not from pg_get_viewdef() on UAT.
--
-- Columns: the fact columns first, verbatim and in legacy order, then the
-- dataset columns. The dataset renamed some fact columns (statut_code,
-- delai_*_j in French); both names are kept so the fact and the dataset can
-- each be diffed as they were. Left out, because they read now() and belong
-- in the Superset dataset as calculated columns (Phase 6), not in a table
-- frozen at build time:
--   anciennete_sans_mouvement_j  = if(date_released is null,
--     round(dateDiff('second', date_last_change, now()) / 86400.0, 1), null)
--   mois_nom (dataset calculated column, French month name from mois)
--
-- Differences from legacy:
--   - Status-change createddate is a timestamptz cast to timestamp in the
--     Postgres session time zone; here it is a DateTime in the ClickHouse
--     server time zone. Equal when both are UTC.
--   - Delays are Float64 days; legacy returns numeric. Compare with a
--     tolerance of 1e-9.
--
-- Verification (reviewer, on UAT). Export the legacy side:
--   \copy (select frl.*, <dataset select list without frl.*> from
--     analytics.fact_requisition_leadtime frl ...) to 'leadtime.csv' csv header
-- or, for the fact alone:
--   \copy (select * from analytics.fact_requisition_leadtime) to 'fact_leadtime.csv' csv header
-- load it into ClickHouse as scratch.legacy_fact_requisition_leadtime, then
-- both of these must return 0 rows (delays rounded to absorb float noise):
--   select req_id, facility_id, program_id, processing_period_id,
--          req_status_current, emergency_status, date_initiated,
--          date_submitted, date_authorized, date_in_approval, date_approved,
--          date_released, date_rejected, date_last_change,
--          round(delai_initiated_to_submitted_j, 6),
--          round(delai_submitted_to_authorized_j, 6),
--          round(delai_authorized_to_approved_j, 6),
--          round(delai_approved_to_released_j, 6),
--          round(delai_total_initiated_to_released_j, 6), month_initiated
--   from scratch.legacy_fact_requisition_leadtime
--   except
--   select <same list> from curated.mart_drc_requisition_leadtime;
--
--   select <same list> from curated.mart_drc_requisition_leadtime
--   except
--   select <same list> from scratch.legacy_fact_requisition_leadtime;
-- Then the same with the dataset columns against the dataset SQL output
-- (numero_requisition .. periode).

with sc as (
  select
    requisition_id,
    minIf(created_date, status = 'INITIATED')   as date_initiated,
    minIf(created_date, status = 'SUBMITTED')   as date_submitted,
    minIf(created_date, status = 'AUTHORIZED')  as date_authorized,
    minIf(created_date, status = 'IN_APPROVAL') as date_in_approval,
    minIf(created_date, status = 'APPROVED')    as date_approved,
    minIf(created_date, status = 'RELEASED')    as date_released,
    minIf(created_date, status = 'REJECTED')    as date_rejected,
    max(created_date)                           as date_last_change
  from {{ ref('stg_status_changes') }}
  group by requisition_id
),

-- Facility key renamed: joined on a second facility_id, frl.* would come
-- out as `frl.facility_id`.
df as (
  select
    facility_id as df_facility_id,
    geographic_level,
    geographic_zone_name,
    facility_type_name,
    facility_name
  from {{ ref('mart_drc_facility_directory') }}
),

frl as (
  select
    r.id                   as req_id,
    r.facility_id          as facility_id,
    r.program_id           as program_id,
    r.processing_period_id as processing_period_id,
    r.status               as req_status_current,
    r.emergency            as emergency_status,
    -- Jalons
    sc.date_initiated,
    sc.date_submitted,
    sc.date_authorized,
    sc.date_in_approval,
    sc.date_approved,
    sc.date_released,
    sc.date_rejected,
    sc.date_last_change,
    -- Délais en jours
    dateDiff('second', sc.date_initiated,  sc.date_submitted)  / 86400.0 as delai_initiated_to_submitted_j,
    dateDiff('second', sc.date_submitted,  sc.date_authorized) / 86400.0 as delai_submitted_to_authorized_j,
    dateDiff('second', sc.date_authorized, sc.date_approved)   / 86400.0 as delai_authorized_to_approved_j,
    dateDiff('second', sc.date_approved,   sc.date_released)   / 86400.0 as delai_approved_to_released_j,
    dateDiff('second', sc.date_initiated,  sc.date_released)   / 86400.0 as delai_total_initiated_to_released_j,
    toStartOfMonth(sc.date_initiated)                                    as month_initiated
  from {{ ref('stg_requisitions') }} r
  left join sc
    on sc.requisition_id = r.id
)

select
  frl.*,

  -- "Suivi des réquisitions" dataset columns
  'REQ-' || upper(coalesce(dpr.code, 'NA'))
    || '-' || formatDateTime(dpp.start_date, '%Y%m')
    || '-' || upper(substring(toString(frl.req_id), 1, 8)) as numero_requisition,

  frl.req_status_current as statut_code,
  case frl.req_status_current
    when 'INITIATED'              then '1 - Initiée'
    when 'SUBMITTED'              then '2 - Soumise'
    when 'AUTHORIZED'             then '3 - Autorisée'
    when 'IN_APPROVAL'            then '4 - En cours d''approbation'
    when 'APPROVED'               then '5 - Approuvée'
    when 'RELEASED'               then '6 - Libérée (convertie en commande)'
    when 'RELEASED_WITHOUT_ORDER' then '7 - Libérée sans commande'
    when 'REJECTED'               then '8 - Rejetée'
    when 'SKIPPED'                then '9 - Ignorée'
    else coalesce(frl.req_status_current, 'Inconnu')
  end as statut_requisition,
  if(frl.emergency_status, 'Urgence', 'Régulière') as type_requisition,

  1                                       as nb_initiee,
  if(frl.date_submitted   is not null, 1, 0) as nb_soumise,
  if(frl.date_authorized  is not null, 1, 0) as nb_autorisee,
  if(frl.date_in_approval is not null, 1, 0) as nb_en_approbation,
  if(frl.date_approved    is not null, 1, 0) as nb_approuvee,
  if(frl.date_released    is not null, 1, 0) as nb_liberee,

  frl.delai_initiated_to_submitted_j      as delai_initiation_a_soumission_j,
  frl.delai_submitted_to_authorized_j     as delai_soumission_a_autorisation_j,
  frl.delai_authorized_to_approved_j      as delai_autorisation_a_approbation_j,
  frl.delai_approved_to_released_j        as delai_approbation_a_liberation_j,
  frl.delai_total_initiated_to_released_j as delai_total_j,

  -- anciennete_sans_mouvement_j: dataset calculated column, see header

  case
    when frl.delai_total_initiated_to_released_j is null then '5. Non libérée'
    when frl.delai_total_initiated_to_released_j <= 2  then '1. 2 jours ou moins'
    when frl.delai_total_initiated_to_released_j <= 5  then '2. 3 à 5 jours'
    when frl.delai_total_initiated_to_released_j <= 10 then '3. 6 à 10 jours'
    else '4. Plus de 10 jours'
  end as tranche_celerite,

  df.geographic_level     as niveau_organisationnel,
  df.geographic_zone_name as zone_geographique,
  df.facility_type_name   as type_de_structure,
  df.facility_name        as structure,
  dpr.name                as programme,
  toYear(dpp.start_date)  as annee,
  toMonth(dpp.start_date) as mois,
  dpp.name                as periode
from frl
left join df
  on df.df_facility_id = frl.facility_id
left join {{ ref('stg_programs') }} dpr
  on dpr.id = frl.program_id
left join {{ ref('stg_processing_periods') }} dpp
  on dpp.id = frl.processing_period_id
