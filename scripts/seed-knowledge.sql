-- kb_demo: an ADX-style schema for knowledge tests (relationships StarRocks does not enforce).
-- dsp / app / publisher dimensions, an AGG hourly report with a declared foreign key, and a view joining them.
CREATE DATABASE IF NOT EXISTS kb_demo;
USE kb_demo;

CREATE TABLE IF NOT EXISTS dsp (
  id BIGINT NOT NULL COMMENT "DSP id",
  name VARCHAR(64) COMMENT "DSP name"
) PRIMARY KEY (id) COMMENT "Demand-side platforms"
DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");

CREATE TABLE IF NOT EXISTS publisher (
  id BIGINT NOT NULL,
  name VARCHAR(64)
) PRIMARY KEY (id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");

CREATE TABLE IF NOT EXISTS app (
  id BIGINT NOT NULL,
  publisher_id BIGINT NOT NULL COMMENT "Owning publisher",
  name VARCHAR(64)
) PRIMARY KEY (id) COMMENT "Apps (inventory)" DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES ("replication_num" = "1");

CREATE TABLE IF NOT EXISTS report_adx_hour (
  dt DATE NOT NULL,
  hour TINYINT NOT NULL,
  dsp_id BIGINT NOT NULL COMMENT "DSP, 0 = house ads",
  app_id BIGINT NOT NULL,
  dsp_request BIGINT SUM DEFAULT "0" COMMENT "Requests sent to the DSP",
  dsp_fill BIGINT SUM DEFAULT "0" COMMENT "Requests the DSP filled"
) AGGREGATE KEY (dt, hour, dsp_id, app_id) COMMENT "ADX 小时报表"
PARTITION BY RANGE (dt) (START ("2026-11-01") END ("2026-12-01") EVERY (INTERVAL 1 DAY))
DISTRIBUTED BY HASH(dsp_id) BUCKETS 1
PROPERTIES ("replication_num" = "1", "foreign_key_constraints" = "(app_id) REFERENCES app(id)");

INSERT INTO dsp VALUES (0, 'house'), (1, 'alpha'), (2, 'beta');
INSERT INTO publisher VALUES (10, 'news'), (11, 'games');
INSERT INTO app VALUES (100, 10, 'reader'), (101, 11, 'puzzle');
INSERT INTO report_adx_hour VALUES ('2026-11-18', 1, 1, 100, 1000, 700), ('2026-11-18', 2, 2, 101, 500, 100), ('2026-11-19', 1, 0, 100, 200, 200);

CREATE VIEW IF NOT EXISTS v_dsp_report AS
SELECT r.dt, d.name AS dsp_name, SUM(r.dsp_request) AS requests, SUM(r.dsp_fill) AS fills
FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id
GROUP BY r.dt, d.name;
