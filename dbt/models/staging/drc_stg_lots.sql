{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.lots.
-- Used by: analytics.fact_expired_risk_snapshot, public.vw_stock_adjustments
-- (lot_code, expiration_date).

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
  from raw.events_openlmis_referencedata_lots
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  JSONExtractString(after, 'lotcode')                   as lot_code,
  -- Nullable DATE: epoch days (CDC) or ISO string (bootstrap); JSON null
  -- stays NULL instead of falling through to 1970-01-01.
  if(JSONType(after, 'expirationdate') = 'Null', null,
    coalesce(
      toDateOrNull(JSONExtractString(after, 'expirationdate')),
      toDate(toDate('1970-01-01') + JSONExtractInt(after, 'expirationdate'))
    )
  )                                                     as expiration_date
  -- not exposed (unused by legacy views): manufacturedate, tradeitemid, active
from ranked
where _rn = 1
  and op != 'd'
