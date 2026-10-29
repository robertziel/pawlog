CREATE TABLE IF NOT EXISTS titles_daily
(
    site_id  LowCardinality(String),
    day      Date,
    title    String,
    views    SimpleAggregateFunction(sum, UInt64),
    visitors AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, day, title);

CREATE MATERIALIZED VIEW IF NOT EXISTS titles_daily_mv TO titles_daily AS
SELECT site_id, toDate(ts) AS day, title, count() AS views, uniqState(visitor_id) AS visitors
FROM events
WHERE event = 'pageview'
GROUP BY site_id, day, title;
