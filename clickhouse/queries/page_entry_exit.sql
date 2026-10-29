-- closed days from session_pages, open days from sessions
WITH (SELECT max(day) FROM session_pages) AS closed
SELECT sum(en) AS entries, sum(ex) AS exits, sum(b) AS bounces
FROM
(
    SELECT entries AS en, exits AS ex, bounces AS b
    FROM session_pages
    WHERE site_id = {site:String} AND path = {path:String} AND day BETWEEN {from:Date} AND least({to:Date}, closed)
    UNION ALL
    SELECT countIf(entry = {path:String}), countIf(exit = {path:String}), countIf(entry = {path:String} AND pv <= 1)
    FROM
    (
        SELECT argMinMerge(entry_path) AS entry, argMaxMerge(exit_path) AS exit, sum(pageviews) AS pv
        FROM sessions
        WHERE site_id = {site:String} AND day BETWEEN greatest({from:Date}, closed + 1) AND {to:Date}
        GROUP BY day, session_id
    )
)
