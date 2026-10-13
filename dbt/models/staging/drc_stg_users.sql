{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.users.
-- Kept only for the "who adjusted" columns on ds_ajustement (plan decision 2):
-- public.vw_stock_adjustments reads username, first_name, last_name via
-- analytics.dim_user. Contact details (email, phonenumber) and the other
-- dim_user columns are deliberately not exposed.

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
  from raw.events_openlmis_referencedata_users
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  JSONExtractString(after, 'username')                  as username,
  JSONExtractString(after, 'firstname')                 as first_name,
  JSONExtractString(after, 'lastname')                  as last_name
from ranked
where _rn = 1
  and op != 'd'
