-- Sessions split at 00:00 UTC (as Universal Analytics did) so date ranges hit the primary key.
-- bounce = pageviews <= 1, duration = ended_at - started_at; both derived at query time.
CREATE TABLE IF NOT EXISTS sessions
(
    site_id    LowCardinality(String),
    day        Date,
    session_id UInt64,
    visitor_id SimpleAggregateFunction(any, UInt64),
    started_at SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    ended_at   SimpleAggregateFunction(max, DateTime64(3, 'UTC')),
    pageviews  SimpleAggregateFunction(sum, UInt64),
    entry_path AggregateFunction(argMin, String, DateTime64(3, 'UTC')),
    exit_path  AggregateFunction(argMax, String, DateTime64(3, 'UTC')),
    ref_domain SimpleAggregateFunction(any, String),
    country    SimpleAggregateFunction(any, String),
    device     SimpleAggregateFunction(any, String),
    browser    SimpleAggregateFunction(any, String),
    os         SimpleAggregateFunction(any, String)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (site_id, day, session_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS sessions_mv TO sessions AS
SELECT
    site_id, toDate(ts) AS day, session_id,
    any(visitor_id) AS visitor_id,
    min(ts) AS started_at,
    max(ts) AS ended_at,
    countIf(event = 'pageview') AS pageviews,
    argMinState(path, ts) AS entry_path,
    argMaxState(path, ts) AS exit_path,
    any(toString(ref_domain)) AS ref_domain,
    any(toString(country)) AS country,
    any(toString(device)) AS device,
    any(toString(browser)) AS browser,
    any(toString(os)) AS os
FROM events
GROUP BY site_id, day, session_id;
