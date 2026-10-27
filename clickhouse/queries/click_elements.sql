SELECT selector, sum(clicks) AS clicks, sum(rage_clicks) AS rage_clicks,
       avgMerge(x_rel) AS x_rel, avgMerge(y_rel) AS y_rel
FROM click_elements
WHERE site_id = {site:String} AND path = {path:String} AND vw_bucket = {vw:String}
  AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY selector
ORDER BY clicks DESC
LIMIT 50
