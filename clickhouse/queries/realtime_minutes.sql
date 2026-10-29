-- active users per minute, 30 bars, oldest first
SELECT toStartOfMinute(ts) AS minute, uniq(visitor_id) AS active
FROM events_recent
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 30 MINUTE
GROUP BY minute
ORDER BY minute WITH FILL FROM toStartOfMinute(now() - INTERVAL 29 MINUTE) TO toStartOfMinute(now()) + 60 STEP 60
