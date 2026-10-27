-- dim: country | device | browser | os
SELECT value, count() AS sessions, uniq(visitor_id) AS visitors
FROM
(
    SELECT any(visitor_id) AS visitor_id, any({dim:Identifier}) AS value
    FROM sessions
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
    GROUP BY day, session_id
    HAVING sum(pageviews) > 0
)
GROUP BY value
ORDER BY sessions DESC
LIMIT 50
