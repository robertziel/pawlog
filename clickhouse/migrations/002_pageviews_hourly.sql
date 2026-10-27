CREATE TABLE IF NOT EXISTS pageviews_hourly
(
    site_id    LowCardinality(String),
    hour       DateTime('UTC'),
    path       String,
    views      SimpleAggregateFunction(sum, UInt64),
    engaged_ms SimpleAggregateFunction(sum, UInt64),
    visitors   AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (site_id, hour, path);

-- engagement rows ride along so page detail gets time-on-page without touching raw events
CREATE MATERIALIZED VIEW IF NOT EXISTS pageviews_hourly_mv TO pageviews_hourly AS
SELECT
    site_id,
    toDateTime(toStartOfHour(ts), 'UTC') AS hour,
    path,
    countIf(event = 'pageview') AS views,
    sumIf(toUInt64(engaged_ms), event = 'engagement') AS engaged_ms,
    uniqState(visitor_id) AS visitors
FROM events
WHERE event IN ('pageview', 'engagement')
GROUP BY site_id, hour, path;
