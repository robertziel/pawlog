SELECT count() AS sessions, avg(pv <= 1) AS bounce_rate, avg(duration_s) AS avg_duration_s
FROM
(
    SELECT sum(pageviews) AS pv, dateDiff('millisecond', min(started_at), max(ended_at)) / 1000 AS duration_s
    FROM sessions
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
    GROUP BY day, session_id
    HAVING pv > 0
)
