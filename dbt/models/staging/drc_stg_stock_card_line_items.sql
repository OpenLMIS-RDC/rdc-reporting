{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for stockmanagement.stock_card_line_items.
-- quantity is unsigned; the sign comes from the reason's reason_type
-- (CREDIT = +, DEBIT = -). reason_id is null for receive/issue lines that
-- carry a source/destination instead of a reason; the legacy views inner-join
-- the reason and therefore skip those lines.
-- Used by: refresh_daily_stock_history(), fact_expired_risk_snapshot,
-- vw_stock_adjustments (user_id), vw_stock_msd, vw_taux_perte.

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
  from raw.events_openlmis_stockmanagement_stock_card_line_items
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'stockcardid')) as stock_card_id,
  toUUIDOrNull(JSONExtractString(after, 'reasonid'))    as reason_id,
  JSONExtractInt(after, 'quantity')                     as quantity,
  -- Debezium encodes DATE columns as epoch days (int); the bootstrap path
  -- (row_to_json) emits ISO strings. Accept both.
  coalesce(
    toDateOrNull(JSONExtractString(after, 'occurreddate')),
    toDate(toDate('1970-01-01') + JSONExtractInt(after, 'occurreddate'))
  )                                                     as occurred_date,
  toUUIDOrNull(JSONExtractString(after, 'userid'))      as user_id
  -- not exposed (unused by legacy views): processeddate, sourceid,
  -- destinationid, sourcefreetext, destinationfreetext, reasonfreetext,
  -- documentnumber, signature, origineventid, extradata
from ranked
where _rn = 1
  and op != 'd'
