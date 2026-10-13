{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for stockmanagement.stock_card_line_item_reasons.
-- The legacy views match reasons by name (French and English, e.g.
-- 'Consommation' / 'Consumed', 'Peremption', 'Avarie') and by
-- reason_category / reason_type.

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
  from raw.events_openlmis_stockmanagement_stock_card_line_item_reasons
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                as id,
  JSONExtractString(after, 'name')                      as name,
  JSONExtractString(after, 'reasoncategory')            as reason_category,
  JSONExtractString(after, 'reasontype')                as reason_type
  -- not exposed (unused by legacy views): description, isfreetextallowed
from ranked
where _rn = 1
  and op != 'd'
