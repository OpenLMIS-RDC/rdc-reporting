{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.program_orderables.
-- One row per program_orderables.id; every orderable version has its own
-- rows, so consumers pick the version they need (vw_expiry_risk takes
-- active desc, orderable_version_number desc per orderable).
-- Used by: public.vw_expiry_risk (price_per_pack), public.vw_rupture_structures
-- (active program x product perimeter).

with ranked as (
  select
    *,
    row_number() over (
      partition by coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      )
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_program_orderables
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))   as program_id,
  toUUIDOrNull(JSONExtractString(after, 'orderableid')) as orderable_id,
  JSONExtractInt(after, 'orderableversionnumber')       as orderable_version_number,
  JSONExtractBool(after, 'active')                      as active,
  -- numeric(19,2), nullable; arrives as a double (decimal.handling.mode=double).
  -- Kept NULL when unset so vw_expiry_risk's valeur_usd_30j stays NULL, not 0.
  if(JSONType(after, 'priceperpack') = 'Null', null,
    JSONExtractFloat(after, 'priceperpack'))            as price_per_pack
  -- not exposed (unused by legacy views): displayorder, dosesperpatient,
  -- fullsupply, orderabledisplaycategoryid
from ranked
where _rn = 1
  and op != 'd'
