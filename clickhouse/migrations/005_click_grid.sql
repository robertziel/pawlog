-- cell = 1% of page width x 10px of page height
CREATE TABLE IF NOT EXISTS click_grid
(
    site_id     LowCardinality(String),
    path        String,
    vw_bucket   Enum8('mobile' = 1, 'tablet' = 2, 'desktop' = 3),
    layout_hash UInt64,
    day         Date,
    x_pct       UInt8,
    y_px        UInt32,
    clicks      SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, path, vw_bucket, layout_hash, day, x_pct, y_px);

CREATE MATERIALIZED VIEW IF NOT EXISTS click_grid_mv TO click_grid AS
SELECT
    site_id, path, vw_bucket, layout_hash, toDate(ts) AS day,
    toUInt8(least(floor(page_x_pct), 99)) AS x_pct,
    intDiv(page_y, 10) * 10 AS y_px,
    count() AS clicks
FROM events
WHERE event = 'click'
GROUP BY site_id, path, vw_bucket, layout_hash, day, x_pct, y_px;
