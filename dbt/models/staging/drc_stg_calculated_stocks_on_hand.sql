{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for stockmanagement.calculated_stocks_on_hand:
-- OpenLMIS's own closing balance per stock card per occurred date, kept up to
-- date by stockmanagement (physical inventories, reason-less receipts and
-- issues, and backdated entries included). One row per id; deduplication per
-- (stock_card_id, occurred_date) is left to the consumer, since
-- stockmanagement versions without OLMIS-8206 can hold several rows per pair.
-- Used by: drc_int_stock_daily_history (balance source, design decision D1).

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
  from raw.events_openlmis_stockmanagement_calculated_stocks_on_hand
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  toUUIDOrNull(JSONExtractString(after, 'stockcardid')) as stock_card_id,
  JSONExtractInt(after, 'stockonhand')                  as stock_on_hand,
  -- Debezium encodes DATE columns as epoch days (int); the bootstrap path
  -- (row_to_json) emits ISO strings. Accept both.
  coalesce(
    toDateOrNull(JSONExtractString(after, 'occurreddate')),
    toDate(toDate('1970-01-01') + JSONExtractInt(after, 'occurreddate'))
  )                                                     as occurred_date,
  -- TIMESTAMP without time zone: epoch milliseconds from CDC
  -- (time.precision.mode=connect), ISO string from bootstrap. Accept both.
  coalesce(
    parseDateTime64BestEffortOrNull(JSONExtractString(after, 'processeddate'), 3, 'UTC'),
    fromUnixTimestamp64Milli(JSONExtractInt(after, 'processeddate'), 'UTC')
  )                                                     as processed_date
from ranked
where _rn = 1
  and op != 'd'
