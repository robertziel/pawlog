#!/bin/sh
# Rollup correctness + query plans. Runs inside a clickhouse container (see `make test`).
# Every rollup must equal the same aggregate computed from raw events.
set -eu
cd "$(dirname "$0")"
db=pawlog_test
ch() { clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "$db" "$@"; }
clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "DROP DATABASE IF EXISTS $db"
./migrate.sh "$db" kafka >/dev/null
./migrate.sh "$db" kafka >/dev/null # idempotent

# 3 inserts so rollups hold unmerged partial states; 14 days, 2 sites, sessions crossing midnight
for part in 0 1 2; do
ch -q "
INSERT INTO events (ts, received_at, site_id, event, visitor_id, session_id, path, ref_domain, utm_source,
                    country, device, browser, os, vw, vw_bucket, selector, x_rel, y_rel, page_x_pct, page_y,
                    scroll_depth, engaged_ms, layout_hash, props)
SELECT toDateTime64('2026-10-01 00:00:00', 3, 'UTC') + toIntervalMillisecond((n * 37013) % (14 * 86400000)) AS ts,
       ts, ['s1', 's2'][n % 2 + 1], ['pageview', 'click', 'scroll', 'engagement', 'custom'][n % 5 + 1],
       n % 3001, intDiv(n, 7) % 9001, ['/', '/a', '/b', '/c'][n % 4 + 1], ['', 'google.com', 't.co'][n % 3 + 1],
       ['', 'news'][n % 7 % 2 + 1], ['DE', 'FR', 'US'][n % 11 % 3 + 1], ['mobile', 'tablet', 'desktop'][n % 13 % 3 + 1],
       'Chrome', 'Linux', 1280, ['mobile', 'tablet', 'desktop'][n % 3 + 1], ['#a', 'nav > a', ''][n % 17 % 3 + 1],
       (n % 100) / 100, (n % 50) / 50, (n * 7 % 1000) / 10, n * 13 % 5000, n % 101, n % 60000, n % 2,
       if(n % 23 = 0, map('rage', '1'), map())
FROM (SELECT number + $part * 40000 AS n FROM numbers(40000))"
done

fail=0
check() { # name, rollup query, raw query; each returns rows to hash
  a=$(ch -q "SELECT count(), sum(cityHash64(*)) FROM ($2)"); b=$(ch -q "SELECT count(), sum(cityHash64(*)) FROM ($3)")
  if [ "$a" = "$b" ]; then echo "PASS $1 ($(echo "$a" | cut -f1) groups)"; else echo "FAIL $1: rollup=$a raw=$b"; fail=1; fi
}
check pageviews_hourly \
  "SELECT site_id, hour, path, sum(views), sum(engaged_ms), uniqMerge(visitors) FROM pageviews_hourly GROUP BY ALL" \
  "SELECT site_id, toDateTime(toStartOfHour(ts), 'UTC') h, path, countIf(event='pageview'), sumIf(toUInt64(engaged_ms), event='engagement'), uniq(visitor_id) FROM events WHERE event IN ('pageview','engagement') GROUP BY site_id, h, path"
check sources_daily \
  "SELECT site_id, day, ref_domain, utm_source, utm_medium, utm_campaign, sum(pageviews), uniqMerge(visits), uniqMerge(visitors) FROM sources_daily GROUP BY ALL" \
  "SELECT site_id, toDate(ts) d, ref_domain, utm_source, utm_medium, utm_campaign, count(), uniq(session_id), uniq(visitor_id) FROM events WHERE event='pageview' GROUP BY site_id, d, ref_domain, utm_source, utm_medium, utm_campaign"
check sessions \
  "SELECT site_id, day, session_id, min(started_at), max(ended_at), sum(pageviews), argMinMerge(entry_path), argMaxMerge(exit_path) FROM sessions GROUP BY ALL" \
  "SELECT site_id, toDate(ts) d, session_id, min(ts), max(ts), countIf(event='pageview'), argMin(path, ts), argMax(path, ts) FROM events GROUP BY site_id, d, session_id"
check click_grid \
  "SELECT site_id, path, vw_bucket, layout_hash, day, x_pct, y_px, sum(clicks) FROM click_grid GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, layout_hash, toDate(ts) d, toUInt8(least(floor(page_x_pct), 99)) x, intDiv(page_y, 10) * 10 y, count() FROM events WHERE event='click' GROUP BY site_id, path, vw_bucket, layout_hash, d, x, y"
check click_elements \
  "SELECT site_id, path, vw_bucket, day, selector, sum(clicks), sum(rage_clicks), round(avgMerge(x_rel), 4), round(avgMerge(y_rel), 4) FROM click_elements GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, toDate(ts) d, selector, count(), countIf(props['rage']='1'), round(avg(x_rel), 4), round(avg(y_rel), 4) FROM events WHERE event='click' AND selector != '' GROUP BY site_id, path, vw_bucket, d, selector"
check scroll_hist \
  "SELECT site_id, path, vw_bucket, day, depth, sum(pageviews) FROM scroll_hist GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, toDate(ts) d, toUInt8(intDiv(scroll_depth, 10) * 10) b, count() FROM events WHERE event='scroll' GROUP BY site_id, path, vw_bucket, d, b"

# Every dashboard query runs, and its plan uses the primary key.
P="--param_site=s1 --param_from=2026-10-03 --param_to=2026-10-09 --param_path=/b --param_vw=desktop --param_layout=0 --param_dim=country"
for q in queries/*.sql; do
  rows=$(ch $P --queries-file "$q" | wc -l)
  plan=$(ch $P -q "EXPLAIN indexes = 1 $(cat "$q")")
  pk=$(echo "$plan" | sed -n '/^ *PrimaryKey$/,/Granules/p')
  keys=$(echo "$pk" | sed -n '/Keys:/,/Condition/p' | grep -v -e Keys: -e Condition | tr -d ' ' | paste -sd, -)
  gran=$(echo "$pk" | grep -o 'Granules: [0-9]*/[0-9]*' | cut -c11-)
  if [ -z "$keys" ]; then echo "FAIL $(basename "$q"): no primary key use"; fail=1; else
    printf 'PLAN %-18s rows=%-5s granules=%-6s key=%s\n' "$(basename "$q" .sql)" "$rows" "$gran" "$keys"; fi
done
exit $fail
