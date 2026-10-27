-- one scroll event per pageview carrying its max depth; depth bucket = floor to 10
CREATE TABLE IF NOT EXISTS scroll_hist
(
    site_id   LowCardinality(String),
    path      String,
    vw_bucket Enum8('mobile' = 1, 'tablet' = 2, 'desktop' = 3),
    day       Date,
    depth     UInt8,
    pageviews SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, path, vw_bucket, day, depth);

CREATE MATERIALIZED VIEW IF NOT EXISTS scroll_hist_mv TO scroll_hist AS
SELECT
    site_id, path, vw_bucket, toDate(ts) AS day,
    toUInt8(intDiv(scroll_depth, 10) * 10) AS depth,
    count() AS pageviews
FROM events
WHERE event = 'scroll'
GROUP BY site_id, path, vw_bucket, day, depth;
