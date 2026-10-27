-- layout = 0 for all layouts
SELECT x_pct, y_px, sum(clicks) AS clicks
FROM click_grid
WHERE site_id = {site:String} AND path = {path:String} AND vw_bucket = {vw:String}
  AND ({layout:UInt64} = 0 OR layout_hash = {layout:UInt64})
  AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY x_pct, y_px
