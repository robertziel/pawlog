-- pageviews per max-depth bucket; the viewer turns these into "% reached" bands
SELECT depth, sum(pageviews) AS n
FROM scroll_hist
WHERE site_id = {site:String} AND path = {path:String} AND vw_bucket = {vw:String}
  AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY depth
ORDER BY depth
