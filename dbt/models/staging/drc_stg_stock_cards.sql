{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for stockmanagement.stock_cards.
-- One card per facility x program x orderable x lot (lot_id null when unlotted).
-- Used by: refresh_daily_stock_history() perimeter, fact_expired_risk_snapshot,
-- vw_stock_adjustments, vw_stock_msd, vw_taux_perte.

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
  from raw.events_openlmis_stockmanagement_stock_cards
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))  as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))   as program_id,
  toUUIDOrNull(JSONExtractString(after, 'orderableid')) as orderable_id,
  toUUIDOrNull(JSONExtractString(after, 'lotid'))       as lot_id
  -- not exposed (unused by legacy views): origineventid, isshowed, isactive
from ranked
where _rn = 1
  and op != 'd'
