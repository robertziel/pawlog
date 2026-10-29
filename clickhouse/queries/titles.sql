SELECT title, sum(views) AS views, uniqCombinedMerge(12)(visitors) AS visitors
FROM titles_daily
WHERE site_id = {site:String} AND day BETWEEN {from:Date} AND {to:Date}
GROUP BY title
ORDER BY views DESC
LIMIT 50
