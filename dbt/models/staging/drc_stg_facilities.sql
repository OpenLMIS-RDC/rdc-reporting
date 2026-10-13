{{
  config(
    materialized='view'
  )
}}

-- Supplement to core stg_facilities for referencedata.facilities: only the
-- columns core does not stage. Join on id; take every other facility column
-- from core stg_facilities.
-- Used by: analytics.dim_facility (go_live_date, go_down_date).

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
  from raw.events_openlmis_referencedata_facilities
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  -- Nullable DATE: epoch days (CDC) or ISO string (bootstrap); JSON null
  -- stays NULL instead of falling through to 1970-01-01.
  if(JSONType(after, 'golivedate') = 'Null', null,
    coalesce(
      toDateOrNull(JSONExtractString(after, 'golivedate')),
      toDate(toDate('1970-01-01') + JSONExtractInt(after, 'golivedate'))
    )
  )                                                     as go_live_date,
  if(JSONType(after, 'godowndate') = 'Null', null,
    coalesce(
      toDateOrNull(JSONExtractString(after, 'godowndate')),
      toDate(toDate('1970-01-01') + JSONExtractInt(after, 'godowndate'))
    )
  )                                                     as go_down_date
from ranked
where _rn = 1
  and op != 'd'
