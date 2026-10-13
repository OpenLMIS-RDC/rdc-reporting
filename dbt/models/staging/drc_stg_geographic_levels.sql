{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.geographic_levels.
-- Supplies the level code (PROV / ZS / AS) that core stg_geographic_zones
-- does not carry. Used by: analytics.dim_facility (geo_mapped, geographic_level).
-- level_number is not read by the legacy views; it is exposed so the Phase 3
-- hierarchy walk can size its self-joins to the levels actually present.

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
  from raw.events_openlmis_referencedata_geographic_levels
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  JSONExtractString(after, 'code')                      as code,
  JSONExtractString(after, 'name')                      as name,
  JSONExtractInt(after, 'levelnumber')                  as level_number
from ranked
where _rn = 1
  and op != 'd'
