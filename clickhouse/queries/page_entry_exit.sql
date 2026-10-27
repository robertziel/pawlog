SELECT countIf(entry = {path:String}) AS entries,
       countIf(exit = {path:String}) AS exits,
       countIf(entry = {path:String} AND pv <= 1) AS bounces
FROM
(
    SELECT argMinMerge(entry_path) AS entry, argMaxMerge(exit_path) AS exit, sum(pageviews) AS pv
    FROM sessions
    WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
    GROUP BY day, session_id
)
