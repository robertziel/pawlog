-- the one raw-events query: last 5 minutes
SELECT uniq(visitor_id) AS visitors, countIf(event = 'pageview') AS pageviews
FROM events
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 5 MINUTE
