{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.status_changes (order status
-- history; landed as kafka_order_status_changes in the legacy stack). Named
-- after the legacy landing table so it is not confused with core
-- stg_status_changes, which is requisition.status_changes.
-- No legacy view reads it; it is in CDC scope for order-flow milestones.

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
  from raw.events_openlmis_fulfillment_status_changes
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'orderid'))     as order_id,
  JSONExtractString(after, 'status')                    as status,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'createddate')) as created_date
  -- not exposed: authorid
from ranked
where _rn = 1
  and op != 'd'
