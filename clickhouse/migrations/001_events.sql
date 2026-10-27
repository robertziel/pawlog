CREATE TABLE IF NOT EXISTS events
(
    ts           DateTime64(3, 'UTC'),
    received_at  DateTime64(3, 'UTC'),
    site_id      LowCardinality(String),
    event        LowCardinality(String),
    visitor_id   UInt64,
    session_id   UInt64,
    path         String,
    title        String,
    referrer     String,
    ref_domain   LowCardinality(String),
    utm_source   LowCardinality(String),
    utm_medium   LowCardinality(String),
    utm_campaign LowCardinality(String),
    country      LowCardinality(String),
    region       LowCardinality(String),
    city         LowCardinality(String),
    browser      LowCardinality(String),
    os           LowCardinality(String),
    device       LowCardinality(String),
    vw           UInt16,
    vw_bucket    Enum8('mobile' = 1, 'tablet' = 2, 'desktop' = 3),
    selector     String,
    x_rel        Float32,
    y_rel        Float32,
    page_x_pct   Float32,
    page_y       UInt32,
    doc_h        UInt32,
    scroll_depth UInt8,
    engaged_ms   UInt32,
    layout_hash  UInt64,
    props        Map(String, String),
    -- time-clustered parts make this prune everything but recent granules for realtime
    INDEX ts_minmax ts TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (site_id, event, path, ts)
TTL toDateTime(ts) + INTERVAL 180 DAY;
