-- events_recent (last hour of raw events), last 30 minutes
SELECT uniq(visitor_id) AS active_30m, uniqIf(visitor_id, ts > now64(3) - INTERVAL 5 MINUTE) AS active_5m,
       countIf(event = 'pageview') AS views
FROM events_recent
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 30 MINUTE
