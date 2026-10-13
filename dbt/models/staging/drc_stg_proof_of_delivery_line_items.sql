{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for fulfillment.proof_of_delivery_line_items.
-- Used by: public.vw_order_flow_product (qte_acceptee, qte_rejetee, nb_lots).

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
  from raw.events_openlmis_fulfillment_proof_of_delivery_line_items
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'proofofdeliveryid')) as proof_of_delivery_id,
  toUUIDOrNull(JSONExtractString(after, 'orderableid')) as orderable_id,
  toUUIDOrNull(JSONExtractString(after, 'lotid'))       as lot_id,
  -- Nullable in source; kept NULL so legacy sum() semantics (qte_acceptee,
  -- qte_rejetee are NULL when no line reports them) carry over.
  if(JSONType(after, 'quantityaccepted') = 'Null', null,
    JSONExtractInt(after, 'quantityaccepted'))          as quantity_accepted,
  if(JSONType(after, 'quantityrejected') = 'Null', null,
    JSONExtractInt(after, 'quantityrejected'))          as quantity_rejected
  -- not exposed (unused by legacy views): notes, vvmstatus, usevvm,
  -- rejectionreasonid, orderableversionnumber
from ranked
where _rn = 1
  and op != 'd'
