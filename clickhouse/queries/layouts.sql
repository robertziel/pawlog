SELECT layout_hash, sum(clicks) AS clicks
FROM click_grid
WHERE site_id = {site:String} AND path = {path:String} AND vw_bucket = {vw:String}
  AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY layout_hash
ORDER BY clicks DESC
