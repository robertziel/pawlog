-- Realistic synthetic traffic, one row per event, shaped like pawlog.js + collector output.
-- params: site, seed, start (DateTime64), span (seconds), sessions
-- ~2.5 pageviews/session (geometric), ~3.5 events/pageview (engagement 85%, scroll 85%, clicks mean 0.8, custom 3%),
-- 5000 paths (log-uniform ~ Zipf), diurnal curve peaking ~14:00 UTC, GA-like source/device/country mix.
INSERT INTO events (ts, received_at, site_id, event, visitor_id, session_id, path, title, referrer, ref_domain,
                    utm_source, utm_medium, utm_campaign, country, region, city, browser, os, device, vw, vw_bucket,
                    selector, x_rel, y_rel, page_x_pct, page_y, doc_h, scroll_depth, engaged_ms, layout_hash, props)
SELECT
    ts, ts + toIntervalMillisecond(20 + eh % 300), {site:String}, ev, visitor_id, session_id, path,
    if(ev = 'pageview', title, ''), referrer, replaceRegexpOne(domain(referrer), '^www\\.', ''),
    utm_source, utm_medium, utm_campaign, country, region, city, browser, os, device, vw,
    multiIf(vw < 768, 'mobile', vw < 1024, 'tablet', 'desktop'),
    if(ev = 'click', selector, ''),
    if(ev = 'click', (eh % 1000) / 1000, 0), if(ev = 'click', (intDiv(eh, 1000) % 1000) / 1000, 0),
    if(ev = 'click', (intDiv(eh, 1000000) % 1000) / 10, 0),
    if(ev = 'click', toUInt32(doc_h * pow((intDiv(eh, 1000000000) % 1000) / 1000, 2)), 0),
    if(ev IN ('click', 'scroll'), doc_h, 0),
    if(ev = 'scroll', depth, 0), if(ev = 'engagement', engaged_ms, 0), layout_hash,
    multiIf(ev = 'click' AND eh % 100 = 0, map('rage', '1'),
            ev = 'custom', map('name', 'signup', 'plan', ['free', 'pro', 'team'][eh % 3 + 1]), map())
FROM
(
    SELECT *,
        ev, j, cityHash64(pvh, j) AS eh,
        multiIf(ev = 'pageview', pv_ts,
                ev = 'click', pv_ts + toIntervalMillisecond(j * 4000 + eh % 3000),
                ev = 'custom', pv_ts + toIntervalSecond(10),
                pv_ts + toIntervalMillisecond(greatest(engaged_ms, 5000))) AS ts,
        multiIf(eh % 25 < 5, ['#cta', '#signup', '#search', '#menu', '#buy'][eh % 25 + 1],
                concat('main.layout > section:nth-of-type(', toString(eh % 5 + 1), ') > a.link:nth-of-type(', toString(intDiv(eh % 25, 5)), ')')) AS selector
    FROM
    (
        SELECT *,
            cityHash64(h, i) AS pvh,
            toUInt32(exp((pvh % 1000000) / 1000000 * log(5000))) - 1 AS pid,
            if(pid = 0, '/', concat(['/blog/', '/docs/', '/products/', '/news/'][pid % 4 + 1], 'item-', toString(pid))) AS path,
            if(pid = 0, 'Home · Example', concat(['Blog', 'Docs', 'Products', 'News'][pid % 4 + 1], ' · Item ', toString(pid), ' · Example')) AS title,
            cityHash64(pid % 4, device) % 4294967296 AS layout_hash,
            1500 + cityHash64(pid) % 6000 AS doc_h,
            toUInt32(least(1800000, -log(greatest((intDiv(pvh, 1000000) % 1000000) / 1000000, 1e-9)) * 40000)) AS engaged_ms,
            toUInt8(least(100, 100 * sqrt((intDiv(pvh, 1000) % 1000) / 1000))) AS depth,
            start_ts + toIntervalSecond(i * 45 + pvh % 30) AS pv_ts,
            arrayConcat(['pageview'],
                        if(pvh % 100 < 85, ['engagement'], []),
                        if(intDiv(pvh, 100) % 100 < 85, ['scroll'], []),
                        arrayMap(x -> 'click', range([0, 0, 0, 0, 1, 1, 1, 1, 2, 2][intDiv(pvh, 10000) % 10 + 1])),
                        if(intDiv(pvh, 100000) % 100 >= 97, ['custom'], [])) AS evs
        FROM
        (
            SELECT
                number AS s,
                cityHash64({seed:UInt64}, number) AS h,
                cityHash64('v', {seed:UInt64}, number % toUInt64(ceil({sessions:UInt64} * 0.8))) AS visitor_id,
                cityHash64('s', {seed:UInt64}, number) AS session_id,
                1 + toUInt32(least(29, floor(log(greatest((h % 1000003) / 1000003, 1e-9)) / log(0.6)))) AS pvs,
                -- inverse of a density peaking at u = 0.6 of the span
                (cityHash64(h, 2) % 1000000) / 1000000 AS u,
                u - 0.12 * sin(2 * pi() * (u - 0.6)) AS t0,
                {start:DateTime64(3)} + toIntervalMillisecond(toUInt64(({span:UInt32} * 1000) * (t0 - floor(t0)))) AS start_ts,
                intDiv(h, 7) % 1000 AS src,
                multiIf(src < 400, '', src < 700, 'https://www.google.com/', src < 730, 'https://www.bing.com/', src < 750, 'https://duckduckgo.com/',
                        src < 800, ['https://t.co/', 'https://www.facebook.com/', 'https://www.reddit.com/r/webdev/', 'https://www.linkedin.com/'][src % 4 + 1],
                        src < 900, concat('https://site', toString(toUInt32(exp((intDiv(h, 11) % 10000) / 10000 * log(2000)))), '.example/post-', toString(intDiv(h, 13) % 500)),
                        src < 950, '', src < 980, 'https://www.google.com/', 'https://t.co/') AS referrer,
                multiIf(src < 900, '', src < 950, 'newsletter', src < 980, 'google', 'twitter') AS utm_source,
                multiIf(src < 900, '', src < 950, 'email', src < 980, 'cpc', 'social') AS utm_medium,
                multiIf(src < 900, '', src < 950, concat('weekly-', toString(h % 52)), src < 980, ['brand', 'generic'][h % 2 + 1], 'launch') AS utm_campaign,
                ['US', 'DE', 'GB', 'IN', 'FR', 'CA', 'PL', 'NL', 'BR', 'ES', 'IT', 'AU', 'JP', 'SE', 'CH', 'UA', 'MX', 'TR', 'BE', 'AT',
                 'CZ', 'RO', 'PT', 'GR', 'DK', 'NO', 'FI', 'IE', 'ID', 'KR'][toUInt32(exp((intDiv(h, 17) % 10000) / 10000 * log(30))) ] AS country,
                concat(country, '-', toString(intDiv(h, 19) % 12)) AS region,
                concat(country, ' City ', toString(toUInt32(exp((intDiv(h, 23) % 10000) / 10000 * log(300))))) AS city,
                intDiv(h, 29) % 100 AS dr,
                multiIf(dr < 45, 'desktop', dr < 95, 'mobile', 'tablet') AS device,
                multiIf(device = 'desktop', ['Windows', 'Windows', 'Windows', 'Mac OSX', 'Mac OSX', 'Linux'][h % 6 + 1],
                        device = 'mobile', ['Android', 'Android', 'Android', 'iPhone', 'iPhone'][h % 5 + 1],
                        ['iPad', 'iPad', 'Android'][h % 3 + 1]) AS os,
                multiIf(os IN ('iPhone', 'iPad'), ['Safari', 'Safari', 'Safari', 'Chrome'][intDiv(h, 31) % 4 + 1],
                        os = 'Mac OSX', ['Safari', 'Chrome', 'Chrome', 'Firefox'][intDiv(h, 31) % 4 + 1],
                        ['Chrome', 'Chrome', 'Chrome', 'Chrome', 'Edge', 'Firefox', 'Samsung Browser', 'Opera'][intDiv(h, 31) % 8 + 1]) AS browser,
                toUInt16(multiIf(device = 'desktop', [1280, 1366, 1440, 1536, 1920][intDiv(h, 37) % 5 + 1],
                                 device = 'mobile', [360, 375, 390, 393, 412, 414][intDiv(h, 37) % 6 + 1],
                                 [768, 810, 820, 834][intDiv(h, 37) % 4 + 1])) AS vw
            FROM numbers({sessions:UInt64})
        )
        ARRAY JOIN range(pvs) AS i
    )
    ARRAY JOIN evs AS ev, arrayEnumerate(evs) AS j
)
WHERE ts <= now64(3)
