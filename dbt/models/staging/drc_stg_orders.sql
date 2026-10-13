{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.orders.
-- external_id is the requisition id the order was released from.
-- Used by: public.vw_order_flow_product.

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
  from raw.events_openlmis_fulfillment_orders
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'externalid'))  as external_id,
  JSONExtractString(after, 'ordercode')                 as order_code,
  JSONExtractString(after, 'status')                    as status,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))  as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))   as program_id,
  toUUIDOrNull(JSONExtractString(after, 'processingperiodid')) as processing_period_id,
  JSONExtractBool(after, 'emergency')                   as emergency,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'createddate')) as created_date
  -- not exposed (unused by legacy views): createdbyid, quotedcost,
  -- receivingfacilityid, requestingfacilityid, supplyingfacilityid,
  -- lastupdateddate, lastupdaterid, extradata
from ranked
where _rn = 1
  and op != 'd'
