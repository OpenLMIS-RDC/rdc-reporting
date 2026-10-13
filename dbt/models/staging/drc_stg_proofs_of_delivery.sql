{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.proofs_of_delivery.
-- Used by: public.vw_order_flow_product (date_reception).

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
  from raw.events_openlmis_fulfillment_proofs_of_delivery
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'shipmentid'))  as shipment_id,
  -- Nullable DATE: epoch days (CDC) or ISO string (bootstrap); JSON null
  -- stays NULL instead of falling through to 1970-01-01.
  if(JSONType(after, 'receiveddate') = 'Null', null,
    coalesce(
      toDateOrNull(JSONExtractString(after, 'receiveddate')),
      toDate(toDate('1970-01-01') + JSONExtractInt(after, 'receiveddate'))
    )
  )                                                     as received_date
  -- not exposed (unused by legacy views): status, deliveredby, receivedby
from ranked
where _rn = 1
  and op != 'd'
