-- dim: source | country | city | device | title | path; last 30 minutes
WITH pawlog_source(utm_source, ref_domain) AS source
SELECT toString({dim:Identifier}) AS value, uniq(visitor_id) AS active, countIf(event = 'pageview') AS views
FROM events_recent
WHERE site_id = {site:String} AND ts > now64(3) - INTERVAL 30 MINUTE
GROUP BY value
ORDER BY active DESC, views DESC
LIMIT 50
