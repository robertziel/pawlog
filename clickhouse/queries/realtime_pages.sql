SELECT path, uniq(visitor_id) AS visitors, countIf(event = 'pageview') AS pageviews
FROM events
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 5 MINUTE
GROUP BY path
ORDER BY visitors DESC
LIMIT 50
