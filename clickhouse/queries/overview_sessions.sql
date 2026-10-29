-- closed days from session_stats, open days (after its last day) from sessions
WITH (SELECT max(day) FROM session_stats) AS closed
SELECT sum(n) AS sessions, sum(e) / sum(n) AS engagement_rate, sum(d) / sum(n) AS avg_duration_s
FROM
(
    SELECT sessions AS n, engaged AS e, duration_s AS d
    FROM session_stats
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND least({to:Date}, closed) AND dim = 'all'
    UNION ALL
    SELECT count(), countIf(pawlog_engaged(pv, duration_s)), sum(duration_s)
    FROM
    (
        SELECT sum(pageviews) AS pv, dateDiff('millisecond', min(started_at), max(ended_at)) / 1000 AS duration_s
        FROM sessions
        WHERE site_id = {site:String} AND day BETWEEN greatest({from:Date}, closed + 1) AND {to:Date}
        GROUP BY day, session_id
        HAVING pv > 0
    )
)
