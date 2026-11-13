-- Demo dataset for CcinnStarRocks (StarRocks 3.1+): every table model, partitions, a view,
-- a synchronous rollup and an asynchronous materialized view.
-- A cold FE can exceed the default 3 s planner budget on the first statements.
SET new_planner_optimize_timeout = 60000;
CREATE DATABASE IF NOT EXISTS shop;
USE shop;

DROP MATERIALIZED VIEW IF EXISTS mv_city_daily;
DROP VIEW IF EXISTS v_paid_orders;
DROP TABLE IF EXISTS orders FORCE;
DROP TABLE IF EXISTS customers FORCE;
DROP TABLE IF EXISTS daily_metrics FORCE;
DROP TABLE IF EXISTS events_latest FORCE;

CREATE TABLE orders (
    order_id   BIGINT        NOT NULL COMMENT "order identifier",
    order_date DATE          NOT NULL,
    city       VARCHAR(32)   NOT NULL,
    channel    VARCHAR(16),
    status     VARCHAR(16),
    total      DECIMAL(12, 2),
    qty        INT
) DUPLICATE KEY(order_id, order_date)
COMMENT "Orders fact table"
PARTITION BY RANGE(order_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01')),
    PARTITION p202403 VALUES [('2024-03-01'), ('2024-04-01')),
    PARTITION p202404 VALUES [('2024-04-01'), ('2024-05-01')),
    PARTITION p202405 VALUES [('2024-05-01'), ('2024-06-01')),
    PARTITION p202406 VALUES [('2024-06-01'), ('2024-07-01')),
    PARTITION p202407 VALUES [('2024-07-01'), ('2024-08-01')),
    PARTITION p202408 VALUES [('2024-08-01'), ('2024-09-01')),
    PARTITION p202409 VALUES [('2024-09-01'), ('2024-10-01')),
    PARTITION p202410 VALUES [('2024-10-01'), ('2024-11-01')),
    PARTITION p202411 VALUES [('2024-11-01'), ('2024-12-01')),
    PARTITION p202412 VALUES [('2024-12-01'), ('2025-01-01')),
    PARTITION p202501 VALUES [('2025-01-01'), ('2025-02-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");

CREATE TABLE customers (
    customer_id BIGINT NOT NULL,
    name        VARCHAR(64),
    city        VARCHAR(32),
    vip         BOOLEAN,
    joined      DATETIME
) PRIMARY KEY(customer_id)
DISTRIBUTED BY HASH(customer_id) BUCKETS 2
PROPERTIES ("replication_num" = "1");

CREATE TABLE daily_metrics (
    dt   DATE        NOT NULL,
    city VARCHAR(32) NOT NULL,
    pv   BIGINT SUM DEFAULT "0",
    uv   BITMAP BITMAP_UNION
) AGGREGATE KEY(dt, city)
DISTRIBUTED BY HASH(city) BUCKETS 2
PROPERTIES ("replication_num" = "1");

CREATE TABLE events_latest (
    device_id BIGINT NOT NULL,
    last_seen DATETIME,
    state     VARCHAR(16)
) UNIQUE KEY(device_id)
DISTRIBUTED BY HASH(device_id) BUCKETS 2
PROPERTIES ("replication_num" = "1");

INSERT INTO orders
SELECT g,
       date_add('2024-01-01', g % 395),
       CASE g % 5 WHEN 0 THEN 'Kuala Lumpur' WHEN 1 THEN 'Penang' WHEN 2 THEN 'Johor Bahru' WHEN 3 THEN 'Singapore' ELSE 'Ipoh' END,
       CASE g % 3 WHEN 0 THEN 'mobile' ELSE 'web' END,
       CASE g % 4 WHEN 0 THEN 'pending' WHEN 1 THEN 'paid' WHEN 2 THEN 'shipped' ELSE 'delivered' END,
       CAST((g * 17) % 500 + 9.9 AS DECIMAL(12, 2)),
       g % 5 + 1
FROM TABLE(generate_series(1, 20000)) AS t(g);

INSERT INTO customers
SELECT g, concat('Customer ', g),
       CASE g % 5 WHEN 0 THEN 'Kuala Lumpur' WHEN 1 THEN 'Penang' WHEN 2 THEN 'Johor Bahru' WHEN 3 THEN 'Singapore' ELSE 'Ipoh' END,
       g % 9 = 0, date_add('2021-01-01 08:00:00', g)
FROM TABLE(generate_series(1, 500)) AS t(g);

INSERT INTO daily_metrics
SELECT date_add('2024-01-01', g % 60), CASE g % 3 WHEN 0 THEN 'Kuala Lumpur' WHEN 1 THEN 'Penang' ELSE 'Ipoh' END, g % 100, to_bitmap(g)
FROM TABLE(generate_series(1, 3000)) AS t(g);

INSERT INTO events_latest
SELECT g % 200, date_add('2024-06-01 00:00:00', g), CASE g % 2 WHEN 0 THEN 'online' ELSE 'offline' END
FROM TABLE(generate_series(1, 1000)) AS t(g);

CREATE VIEW v_paid_orders COMMENT "Paid orders only" AS
SELECT order_id, order_date, city, total FROM orders WHERE status = 'paid';

CREATE MATERIALIZED VIEW mv_city_daily
COMMENT "Revenue per city and day"
DISTRIBUTED BY HASH(city) BUCKETS 2
REFRESH ASYNC EVERY (INTERVAL 1 DAY)
PROPERTIES ("replication_num" = "1")
AS SELECT order_date, city, SUM(total) AS revenue, COUNT(*) AS orders
   FROM orders GROUP BY order_date, city;

REFRESH MATERIALIZED VIEW mv_city_daily WITH SYNC MODE;

-- Synchronous materialized view (rollup) maintained with the base table.
CREATE MATERIALIZED VIEW mv_orders_by_channel AS
SELECT channel, status, SUM(total), COUNT(order_id) FROM orders GROUP BY channel, status;

CREATE USER IF NOT EXISTS 'ccinn'@'%' IDENTIFIED BY 'ccinn-secret';
GRANT root TO USER 'ccinn'@'%';
