SELECT ref_domain, utm_source, utm_medium, utm_campaign,
       uniqMerge(visits) AS visits, uniqMerge(visitors) AS visitors, sum(pageviews) AS pageviews
FROM sources_daily
WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY ref_domain, utm_source, utm_medium, utm_campaign
ORDER BY visits DESC
LIMIT 50
