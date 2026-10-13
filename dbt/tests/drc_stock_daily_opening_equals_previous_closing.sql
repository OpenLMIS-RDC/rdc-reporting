-- Carry-forward check for drc_int_stock_daily_history: every day after a
-- key's first day opens on the previous day's closing balance, and the days
-- of a key are contiguous. Returns the offending rows.

select
  facility_id,
  program_id,
  product_id,
  movement_date,
  opening_balance,
  prev_stock_on_hand,
  prev_movement_date
from (
  select
    facility_id,
    program_id,
    product_id,
    movement_date,
    opening_balance,
    lagInFrame(stock_on_hand) over w      as prev_stock_on_hand,
    lagInFrame(movement_date) over w      as prev_movement_date,
    row_number() over w                   as rn
  from {{ ref('drc_int_stock_daily_history') }}
  window w as (
    partition by facility_id, program_id, product_id
    order by movement_date
    rows between unbounded preceding and current row
  )
)
where rn > 1
  and (
    opening_balance != prev_stock_on_hand
    or movement_date != prev_movement_date + 1
  )
