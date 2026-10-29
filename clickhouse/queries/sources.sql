SELECT ref_domain, utm_source, utm_medium, utm_campaign,
       uniqCombinedMerge(12)(visits) AS visits, uniqCombinedMerge(12)(visitors) AS visitors, sum(pageviews) AS pageviews
FROM sources_daily
WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY ref_domain, utm_source, utm_medium, utm_campaign
ORDER BY visits DESC
LIMIT 50
