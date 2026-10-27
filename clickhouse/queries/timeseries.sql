-- path = '' for the whole site
SELECT toDate(hour) AS day, sum(views) AS pageviews, uniqMerge(visitors) AS visitors
FROM pageviews_hourly
WHERE site_id = {site:String} AND hour >= {from:Date} AND hour < {to:Date} + 1
  AND ({path:String} = '' OR path = {path:String})
GROUP BY day
ORDER BY day WITH FILL FROM {from:Date} TO {to:Date} + 1
