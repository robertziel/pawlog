-- Per-day session stats for closed days, so dashboards don't regroup ~400k sessions/day at query time.
-- A day is closed two days later: the collector accepts timestamps up to 24 h old.
-- Queries read closed days here (day <= max(day)) and the open days from `sessions`.
CREATE TABLE IF NOT EXISTS session_stats
(
    site_id    LowCardinality(String),
    day        Date,
    dim        LowCardinality(String), -- all | country | device | browser | os
    value      String,
    sessions   UInt64,
    engaged    UInt64,
    duration_s Float64,
    visitors   AggregateFunction(uniq, UInt64)
)
ENGINE = MergeTree
ORDER BY (site_id, day, dim, value);

CREATE TABLE IF NOT EXISTS session_pages
(
    site_id LowCardinality(String),
    day     Date,
    path    String,
    entries UInt64,
    exits   UInt64,
    bounces UInt64
)
ENGINE = MergeTree
ORDER BY (site_id, day, path);

-- APPEND + "day > max(day)": each closed day is computed once; the first refresh backfills history.
CREATE MATERIALIZED VIEW IF NOT EXISTS session_stats_mv REFRESH EVERY 1 HOUR APPEND TO session_stats AS
SELECT site_id, day, d.1 AS dim, d.2 AS value,
       count() AS sessions, countIf(pawlog_engaged(pv, dur)) AS engaged, sum(dur) AS duration_s,
       uniqState(visitor_id) AS visitors
FROM
(
    SELECT site_id, day, any(visitor_id) AS visitor_id, sum(pageviews) AS pv,
           dateDiff('millisecond', min(started_at), max(ended_at)) / 1000 AS dur,
           any(country) AS country, any(device) AS device, any(browser) AS browser, any(os) AS os
    FROM sessions
    WHERE day > (SELECT max(day) FROM session_stats) AND day <= today() - 2
    GROUP BY site_id, day, session_id
    HAVING pv > 0
)
ARRAY JOIN [('all', ''), ('country', country), ('device', device), ('browser', browser), ('os', os)] AS d
GROUP BY site_id, day, dim, value;

CREATE MATERIALIZED VIEW IF NOT EXISTS session_pages_mv REFRESH EVERY 1 HOUR APPEND TO session_pages AS
SELECT site_id, day, p.1 AS path, sum(p.2) AS entries, sum(p.3) AS exits, sum(p.4) AS bounces
FROM
(
    SELECT site_id, day, argMinMerge(entry_path) AS entry, argMaxMerge(exit_path) AS exit, sum(pageviews) AS pv
    FROM sessions
    WHERE day > (SELECT max(day) FROM session_pages) AND day <= today() - 2
    GROUP BY site_id, day, session_id
)
ARRAY JOIN if(entry = exit, [(entry, 1, 1, toUInt8(pv <= 1))], [(entry, 1, 0, toUInt8(pv <= 1)), (exit, 0, 1, 0)]) AS p
GROUP BY site_id, day, path;
