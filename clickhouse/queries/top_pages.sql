SELECT path, sum(views) AS pageviews, uniqMerge(visitors) AS visitors,
       sum(engaged_ms) / greatest(sum(views), 1) AS avg_engaged_ms
FROM pageviews_hourly
WHERE site_id = {site:String} AND hour >= {from:Date} AND hour < {to:Date} + 1
  AND ({path:String} = '' OR path = {path:String})
GROUP BY path
ORDER BY pageviews DESC
LIMIT 50
