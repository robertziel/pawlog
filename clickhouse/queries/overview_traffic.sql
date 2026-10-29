SELECT sum(views) AS pageviews, uniqCombinedMerge(12)(visitors) AS visitors
FROM pageviews_hourly
WHERE site_id = {site:String} AND hour >= {from:Date} AND hour < {to:Date} + 1
