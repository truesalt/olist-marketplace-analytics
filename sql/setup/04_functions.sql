/* ============================================================================
   File        : 04_functions.sql
   Purpose     : Reusable scalar functions so the same business rule (delay bucket,
                 region, city cleaning, config lookup) is coded once, not copy-pasted.
   Business Q  : setup
   SQL concepts: stored functions, DELIMITER, DETERMINISTIC / NO SQL / READS SQL DATA,
                 DECLARE, IF, CASE, WHILE loop, nested REPLACE, LOWER/TRIM/LOCATE,
                 scalar subquery
   Output      : fn_delay_bucket(INT), fn_region(CHAR(2)), fn_strip_accents(VARCHAR),
                 fn_cfg(VARCHAR)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/04_functions.sql
   Note        : creating functions while binary logging is on needs
                 log_bin_trust_function_creators = 1 (set once by `make db-user`).
   ========================================================================== */

USE olist;

-- The function bodies below contain accented literals ('ã', 'ç', ...). SET NAMES makes sure the
-- server reads this file as UTF-8 even if the client's locale defaults to latin1.
SET NAMES utf8mb4;

DROP FUNCTION IF EXISTS fn_delay_bucket;
DROP FUNCTION IF EXISTS fn_region;
DROP FUNCTION IF EXISTS fn_strip_accents;
DROP FUNCTION IF EXISTS fn_cfg;

-- DELIMITER is a mysql-client command: it lets the ';' inside a function body pass
-- through, and '$$' ends each CREATE statement instead.
DELIMITER $$

-- ---------------------------------------------------------------------------
-- 1. fn_delay_bucket: delay_days (delivered - estimated) -> labelled bucket.
--    Numeric prefixes ("1." .. "5.") make the labels sort correctly in Power BI.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_delay_bucket(delay INT)
RETURNS VARCHAR(20)
DETERMINISTIC
NO SQL
COMMENT 'Bucket delay_days: Early 7+ / On time / Late 1-3 / Late 4-7 / Late 8+ / Not delivered'
BEGIN
  RETURN CASE
    WHEN delay IS NULL THEN 'Not delivered'    -- no valid delivery, so no delay to measure
    WHEN delay <= -7   THEN '1. Early 7+ d'
    WHEN delay <= 0    THEN '2. On time'       -- -6 .. 0 days
    WHEN delay <= 3    THEN '3. Late 1-3 d'
    WHEN delay <= 7    THEN '4. Late 4-7 d'
    ELSE                    '5. Late 8+ d'
  END;
END$$

-- ---------------------------------------------------------------------------
-- 2. fn_region: Brazilian state code -> one of the 5 official macro-regions.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_region(state CHAR(2))
RETURNS VARCHAR(15)
DETERMINISTIC
NO SQL
COMMENT 'Brazilian state (UF) -> macro-region'
BEGIN
  RETURN CASE
    WHEN state IN ('AC','AP','AM','PA','RO','RR','TO')           THEN 'North'
    WHEN state IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE') THEN 'Northeast'
    WHEN state IN ('DF','GO','MT','MS')                          THEN 'Center-West'
    WHEN state IN ('ES','MG','RJ','SP')                          THEN 'Southeast'
    WHEN state IN ('PR','RS','SC')                               THEN 'South'
    ELSE 'Unknown'
  END;
END$$

-- ---------------------------------------------------------------------------
-- 3. fn_strip_accents: normalise free-text city names so 'São Paulo', 'SAO PAULO'
--    and 'sao  paulo' all become 'sao paulo'. LOWER runs first, so only lowercase
--    accented letters need replacing. REPLACE matches exact characters (it ignores
--    the accent-insensitive collation), so each accented letter is mapped explicitly.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_strip_accents(s VARCHAR(255))
RETURNS VARCHAR(255)
DETERMINISTIC
NO SQL
COMMENT 'lower + trim + remove Portuguese accents + apostrophe/hyphen -> space + collapse spaces'
BEGIN
  DECLARE v VARCHAR(255);
  IF s IS NULL THEN
    RETURN NULL;
  END IF;

  SET v = LOWER(TRIM(s));
  SET v = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(v, 'á', 'a'), 'à', 'a'), 'â', 'a'), 'ã', 'a'), 'ä', 'a');
  SET v = REPLACE(REPLACE(REPLACE(REPLACE(v, 'é', 'e'), 'è', 'e'), 'ê', 'e'), 'ë', 'e');
  SET v = REPLACE(REPLACE(REPLACE(REPLACE(v, 'í', 'i'), 'ì', 'i'), 'î', 'i'), 'ï', 'i');
  SET v = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(v, 'ó', 'o'), 'ò', 'o'), 'ô', 'o'), 'õ', 'o'), 'ö', 'o');
  SET v = REPLACE(REPLACE(REPLACE(REPLACE(v, 'ú', 'u'), 'ù', 'u'), 'û', 'u'), 'ü', 'u');
  SET v = REPLACE(REPLACE(v, 'ç', 'c'), 'ñ', 'n');
  SET v = REPLACE(REPLACE(v, '''', ' '), '-', ' ');   -- d'oeste -> d oeste, mogi-mirim -> mogi mirim

  -- Collapse runs of spaces: one REPLACE pass turns 3 spaces into 2, so loop until none left.
  WHILE LOCATE('  ', v) > 0 DO
    SET v = REPLACE(v, '  ', ' ');
  END WHILE;

  RETURN TRIM(v);
END$$

-- ---------------------------------------------------------------------------
-- 4. fn_cfg: read one parameter from cfg_params (analysis window, thresholds).
--    Declared DETERMINISTIC because the value is fixed for the duration of a run;
--    READS SQL DATA because it queries a table.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_cfg(p_name VARCHAR(50))
RETURNS VARCHAR(50)
DETERMINISTIC
READS SQL DATA
COMMENT 'Lookup in cfg_params, e.g. fn_cfg(''window_start'')'
BEGIN
  RETURN (SELECT param_value FROM cfg_params WHERE param_name = p_name);
END$$

DELIMITER ;

-- Smoke tests: one row per function, expected value in the comment.
SELECT
  fn_delay_bucket(-10)                    AS early,        -- '1. Early 7+ d'
  fn_delay_bucket(0)                      AS on_time,      -- '2. On time'
  fn_delay_bucket(5)                      AS late_4_7,     -- '4. Late 4-7 d'
  fn_delay_bucket(NULL)                   AS not_delivered,
  fn_region('BA')                         AS region_ba,    -- 'Northeast'
  fn_strip_accents('  São-Paulo  D''Oeste ') AS city_clean, -- 'sao paulo d oeste'
  fn_cfg('window_end')                    AS window_end;   -- '2018-08-31'
