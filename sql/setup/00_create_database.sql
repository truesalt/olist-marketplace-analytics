/* ============================================================================
   File        : 00_create_database.sql
   Purpose     : Create the `olist` database and the cfg_params table that every
                 later script reads its analysis window and thresholds from.
   Business Q  : setup
   SQL concepts: CREATE DATABASE (charset/collation), CREATE TABLE, PRIMARY KEY,
                 INSERT ... VALUES (multi-row)
   Output      : database olist; table cfg_params(param_name, param_value, description)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p < sql/setup/00_create_database.sql
                 (or `make db`)
   ========================================================================== */

-- utf8mb4 stores every Unicode character (Portuguese accents, emoji in reviews).
-- utf8mb4_0900_ai_ci = accent-insensitive + case-insensitive comparisons,
-- so 'São Paulo' = 'sao paulo' in WHERE / GROUP BY (MySQL's answer to ILIKE/unaccent).
CREATE DATABASE IF NOT EXISTS olist
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE olist;

-- Central parameter table: analysis files read these values instead of hard-coding
-- dates/thresholds, so changing the window here changes every result consistently.
DROP TABLE IF EXISTS cfg_params;
CREATE TABLE cfg_params (
  param_name  VARCHAR(50)  PRIMARY KEY,
  param_value VARCHAR(50)  NOT NULL,
  description VARCHAR(255)
) COMMENT = 'Analysis parameters read by fn_cfg() and every analysis script';

INSERT INTO cfg_params (param_name, param_value, description) VALUES
  ('window_start',        '2017-01-01', 'Analysis window start (edges of data are sparse)'),
  ('window_end',          '2018-08-31', 'Analysis window end'),
  ('repeat_horizon_days', '180',        'Days after first order to count a repeat purchase'),
  ('low_review_max',      '2',          'Review score <= this is "low"'),
  ('min_orders_seller',   '30',         'Min delivered orders for seller-level ranking'),
  ('min_orders_lane',     '100',        'Min delivered orders for lane-level ranking');

SELECT param_name, param_value, description
FROM cfg_params
ORDER BY param_name;
