-- dim: country | device | browser | os; closed days from session_stats, open days from sessions
WITH (SELECT max(day) FROM session_stats) AS closed
SELECT value, sum(n) AS sessions, uniqCombinedMerge(12)(v) AS visitors
FROM
(
    SELECT value, sessions AS n, visitors AS v
    FROM session_stats
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND least({to:Date}, closed) AND dim = {dim:String}
    UNION ALL
    SELECT value, count(), uniqCombinedState(12)(visitor_id)
    FROM
    (
        SELECT any(visitor_id) AS visitor_id, any({dim:Identifier}) AS value
        FROM sessions
        WHERE site_id = {site:String} AND day BETWEEN greatest({from:Date}, closed + 1) AND {to:Date}
        GROUP BY day, session_id
        HAVING sum(pageviews) > 0
    )
    GROUP BY value
)
GROUP BY value
ORDER BY sessions DESC
LIMIT 50
