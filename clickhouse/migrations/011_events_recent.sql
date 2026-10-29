-- Last hour of raw events, ordered by time, for the realtime views. `events` is ordered by path, and once
-- merges build day-sized parts its ts index can't skip anything; this table keeps realtime reads ~30 min of rows.
CREATE TABLE IF NOT EXISTS events_recent
(
    ts         DateTime64(3, 'UTC'),
    site_id    LowCardinality(String),
    event      LowCardinality(String),
    visitor_id UInt64,
    path       String,
    title      String,
    ref_domain LowCardinality(String),
    utm_source LowCardinality(String),
    country    LowCardinality(String),
    city       LowCardinality(String),
    device     LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toStartOfHour(ts)
ORDER BY (site_id, ts)
TTL toDateTime(ts) + INTERVAL 1 HOUR
SETTINGS ttl_only_drop_parts = 1, merge_with_ttl_timeout = 600;

CREATE MATERIALIZED VIEW IF NOT EXISTS events_recent_mv TO events_recent AS
SELECT ts, site_id, event, visitor_id, path, title, ref_domain, utm_source, country, city, device
FROM events
WHERE ts > now64(3) - INTERVAL 1 HOUR;
