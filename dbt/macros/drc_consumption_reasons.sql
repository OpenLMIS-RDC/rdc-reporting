{#
  Stock card line item reason names counted as consumption, as a SQL list
  for `r.name in {{ drc_consumption_reasons() }}`. The legacy daily function
  matched on names, not on the `consumed` reason tag; kept that way (plan 7c,
  decision 2026-10-15). Shared by the `consumptions` flow in
  drc_int_stock_daily_history and the CMM in mart_drc_stock_msd: to count
  more reasons as consumption, add them here.
#}
{% macro drc_consumption_reasons(extra=[]) -%}
  {%- set names = ['Consumed', 'Consommation'] + extra -%}
  ({% for n in names %}'{{ n }}'{% if not loop.last %}, {% endif %}{% endfor %})
{%- endmacro %}
