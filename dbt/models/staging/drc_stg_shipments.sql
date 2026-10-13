{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.shipments.
-- Used by: public.vw_order_flow_product (order -> POD link, date_expedition).

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
  from raw.events_openlmis_fulfillment_shipments
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'orderid'))     as order_id,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'shippeddate')) as shipped_date
  -- not exposed (unused by legacy views): shippedbyid, notes, extradata
from ranked
where _rn = 1
  and op != 'd'
