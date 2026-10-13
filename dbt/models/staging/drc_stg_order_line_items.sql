{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.order_line_items.
-- Used by: public.vw_order_flow_product (grain of the view).

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
  from raw.events_openlmis_fulfillment_order_line_items
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'orderid'))     as order_id,
  toUUIDOrNull(JSONExtractString(after, 'orderableid')) as orderable_id,
  JSONExtractInt(after, 'orderedquantity')              as ordered_quantity
  -- not exposed (unused by legacy views): orderableversionnumber, extradata
from ranked
where _rn = 1
  and op != 'd'
