{#
  French month name of a Date / DateTime expression ('Janvier' .. 'Décembre').
  Used for the legacy "mois" text columns, which Postgres produced with
  to_char(..., 'TMMonth') or an explicit French array.
#}
{% macro drc_month_name_fr(date_expr) -%}
  arrayElement(
    ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin', 'Juillet',
     'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'],
    toMonth({{ date_expr }})
  )
{%- endmacro %}
