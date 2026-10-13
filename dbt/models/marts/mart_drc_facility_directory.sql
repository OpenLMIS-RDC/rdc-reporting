{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(facility_name, facility_id)',
    query_settings={'join_use_nulls': 1}
  )
}}

-- DRC facility dimension: one row per facility with the district / region /
-- country rungs, facility type and operator, and the DRC province (PROV),
-- health zone (ZS) and health area (AS) names.
--
-- Replaces: analytics.dim_facility (OlmisCreateAnalyticSchemaStatements.sql,
-- section 2.1). Columns and order are the legacy ones, verbatim. Built from
-- repo SQL on origin/PowerBI, not from pg_get_viewdef() on UAT.
--
-- Built from core staging rather than core mart_facility_directory: the core
-- mart has no region/country rungs, type id/code, operator or level, so it
-- would add a join without removing one.
--
-- join_use_nulls: unmatched left joins yield NULL as in Postgres, not ''
-- or the zero UUID, so the diff against the legacy view is exact.
--
-- Geo hierarchy: the legacy WITH RECURSIVE walk from each zone up to the
-- root is unrolled into geo_depth fixed self-joins: the zone itself plus up
-- to 5 ancestors. DRC is country > PROV > ZS > AS and only rungs up to PROV
-- are read, so 6 leaves headroom; a deeper tree would leave the names NULL.
--
-- Verification (reviewer, on UAT). Export the legacy side:
--   \copy (select * from analytics.dim_facility) to 'dim_facility.csv' csv header
-- load it into ClickHouse as scratch.legacy_dim_facility (same column names,
-- empty CSV fields as NULL), then both of these must return 0 rows:
--   select * from scratch.legacy_dim_facility
--   except
--   select * from curated.mart_drc_facility_directory;
--
--   select * from curated.mart_drc_facility_directory
--   except
--   select * from scratch.legacy_dim_facility;
-- Postgres exports booleans as t/f and the mart stores them as UInt8:
-- load the three boolean columns as Bool so the two sides compare equal.

{% set geo_depth = 6 %}

with geo_ancestors as (
  -- One row per (start zone, zone on its path to the root), the start zone
  -- included: the legacy geo_hierarchy CTE.
  {% for depth in range(geo_depth) %}
  select
    z0.id                 as start_zone_id,
    z{{ depth }}.name     as zone_name,
    z{{ depth }}.level_id as level_id
  from {{ ref('stg_geographic_zones') }} z0
  {% for step in range(1, depth + 1) %}
  inner join {{ ref('stg_geographic_zones') }} z{{ step }}
    on z{{ step }}.id = z{{ step - 1 }}.parent_id
  {% endfor %}
  {% if not loop.last %}
  union all
  {% endif %}
  {% endfor %}
),

geo_mapped as (
  select
    ga.start_zone_id,
    max(if(gl.code = 'PROV', ga.zone_name, null)) as province_name,
    max(if(gl.code = 'ZS',   ga.zone_name, null)) as health_zone_name,
    max(if(gl.code = 'AS',   ga.zone_name, null)) as health_area_name
  from geo_ancestors ga
  inner join {{ ref('drc_stg_geographic_levels') }} gl
    on ga.level_id = gl.id
  group by ga.start_zone_id
)

select
  f.id                  as facility_id,
  f.code                as facility_code,
  f.name                as facility_name,
  f.active              as facility_active_status,
  f.enabled             as facility_enabled_status,
  f.openlmis_accessible as openlmis_accessible,
  fd.go_live_date       as go_live_date,
  fd.go_down_date       as go_down_date,
  dgz.id                as district_id,
  dgz.code              as district_code,
  dgz.name              as district_name,
  rgz.id                as region_id,
  rgz.code              as region_code,
  rgz.name              as region_name,
  cgz.id                as country_id,
  cgz.code              as country_code,
  cgz.name              as country_name,
  ft.id                 as facility_type_id,
  ft.code               as facility_type_code,
  ft.name               as facility_type_name,
  fo.id                 as facility_operator_id,
  fo.code               as facility_operator_code,
  fo.name               as facility_operator_name,
  dgz.name              as geographic_zone_name,
  gl.name               as geographic_level,
  m.province_name,
  m.health_zone_name,
  m.health_area_name
from {{ ref('stg_facilities') }} f
left join {{ ref('drc_stg_facilities') }} fd
  on fd.id = f.id
left join {{ ref('stg_geographic_zones') }} dgz
  on dgz.id = f.geographic_zone_id
left join {{ ref('stg_geographic_zones') }} rgz
  on rgz.id = dgz.parent_id
left join {{ ref('stg_geographic_zones') }} cgz
  on cgz.id = rgz.parent_id
left join {{ ref('stg_facility_types') }} ft
  on ft.id = f.type_id
left join {{ ref('drc_stg_facility_operators') }} fo
  on fo.id = f.operated_by_id
left join {{ ref('drc_stg_geographic_levels') }} gl
  on gl.id = dgz.level_id
left join geo_mapped m
  on m.start_zone_id = f.geographic_zone_id
