-- per day: sessions and engaged sessions; closed days from session_stats, open days from sessions
WITH (SELECT max(day) FROM session_stats) AS closed
SELECT day, sum(n) AS sessions, sum(e) AS engaged
FROM
(
    SELECT day, sessions AS n, engaged AS e
    FROM session_stats
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND least({to:Date}, closed) AND dim = 'all'
    UNION ALL
    SELECT day, count(), countIf(pawlog_engaged(pv, duration_s))
    FROM
    (
        SELECT day, sum(pageviews) AS pv, dateDiff('millisecond', min(started_at), max(ended_at)) / 1000 AS duration_s
        FROM sessions
        WHERE site_id = {site:String} AND day BETWEEN greatest({from:Date}, closed + 1) AND {to:Date}
        GROUP BY day, session_id
        HAVING pv > 0
    )
    GROUP BY day
)
GROUP BY day
ORDER BY day WITH FILL FROM {from:Date} TO {to:Date} + 1
