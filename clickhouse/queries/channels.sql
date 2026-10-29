SELECT pawlog_channel(ref_domain, utm_source, utm_medium) AS channel,
       uniqMerge(visits) AS sessions, uniqMerge(visitors) AS visitors, sum(pageviews) AS pageviews
FROM sources_daily
WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY channel
ORDER BY sessions DESC
LIMIT 50
