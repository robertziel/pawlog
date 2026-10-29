-- pawlog.js repeats the session's landing referrer/utm on every pageview, so each session has one source
CREATE TABLE IF NOT EXISTS sources_daily
(
    site_id      LowCardinality(String),
    day          Date,
    ref_domain   LowCardinality(String),
    utm_source   LowCardinality(String),
    utm_medium   LowCardinality(String),
    utm_campaign LowCardinality(String),
    pageviews    SimpleAggregateFunction(sum, UInt64),
    visits       AggregateFunction(uniqCombined(12), UInt64),
    visitors     AggregateFunction(uniqCombined(12), UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, day, ref_domain, utm_source, utm_medium, utm_campaign);

CREATE MATERIALIZED VIEW IF NOT EXISTS sources_daily_mv TO sources_daily AS
SELECT
    site_id, toDate(ts) AS day, ref_domain, utm_source, utm_medium, utm_campaign,
    count() AS pageviews,
    uniqCombinedState(12)(session_id) AS visits,
    uniqCombinedState(12)(visitor_id) AS visitors
FROM events
WHERE event = 'pageview'
GROUP BY site_id, day, ref_domain, utm_source, utm_medium, utm_campaign;
