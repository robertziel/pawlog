SELECT path, argMaxIf(title, ts, event = 'pageview') AS title, uniq(visitor_id) AS active, countIf(event = 'pageview') AS views
FROM events_recent
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 30 MINUTE
GROUP BY path
ORDER BY active DESC, views DESC
LIMIT 50
