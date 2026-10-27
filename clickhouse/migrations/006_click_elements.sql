CREATE TABLE IF NOT EXISTS click_elements
(
    site_id     LowCardinality(String),
    path        String,
    vw_bucket   Enum8('mobile' = 1, 'tablet' = 2, 'desktop' = 3),
    day         Date,
    selector    String,
    clicks      SimpleAggregateFunction(sum, UInt64),
    rage_clicks SimpleAggregateFunction(sum, UInt64),
    x_rel       AggregateFunction(avg, Float32),
    y_rel       AggregateFunction(avg, Float32)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, path, vw_bucket, day, selector);

CREATE MATERIALIZED VIEW IF NOT EXISTS click_elements_mv TO click_elements AS
SELECT
    site_id, path, vw_bucket, toDate(ts) AS day, selector,
    count() AS clicks,
    countIf(props['rage'] = '1') AS rage_clicks,
    avgState(x_rel) AS x_rel,
    avgState(y_rel) AS y_rel
FROM events
WHERE event = 'click' AND selector != ''
GROUP BY site_id, path, vw_bucket, day, selector;
