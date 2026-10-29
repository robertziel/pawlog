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
       intDiv(n, 7) % 9001 % 3001, intDiv(n, 7) % 9001, ['/', '/a', '/b', '/c'][n % 4 + 1], ['', 'google.com', 't.co'][n % 3 + 1],
       ['', 'news'][n % 7 % 2 + 1], ['DE', 'FR', 'US'][intDiv(n, 7) % 9001 % 11 % 3 + 1], ['mobile', 'tablet', 'desktop'][intDiv(n, 7) % 9001 % 13 % 3 + 1],
       'Chrome', 'Linux', 1280, ['mobile', 'tablet', 'desktop'][n % 3 + 1], ['#a', 'nav > a', ''][n % 17 % 3 + 1],
       (n % 100) / 100, (n % 50) / 50, (n * 7 % 1000) / 10, n * 13 % 5000, n % 101, n % 60000, n % 2,
       if(n % 23 = 0, map('rage', '1'), map())
FROM (SELECT number + $part * 40000 AS n FROM numbers(40000))"
done

# refreshable MVs ran at creation on empty tables; refresh now that history exists
for v in session_stats_mv session_pages_mv; do ch -q "SYSTEM REFRESH VIEW $v"; ch -q "SYSTEM WAIT VIEW $v"; done

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
check titles_daily \
  "SELECT site_id, day, title, sum(views), uniqMerge(visitors) FROM titles_daily GROUP BY ALL" \
  "SELECT site_id, toDate(ts) d, title, count(), uniq(visitor_id) FROM events WHERE event='pageview' GROUP BY site_id, d, title"
check click_grid \
  "SELECT site_id, path, vw_bucket, layout_hash, day, x_pct, y_px, sum(clicks) FROM click_grid GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, layout_hash, toDate(ts) d, toUInt8(least(floor(page_x_pct), 99)) x, intDiv(page_y, 10) * 10 y, count() FROM events WHERE event='click' GROUP BY site_id, path, vw_bucket, layout_hash, d, x, y"
check click_elements \
  "SELECT site_id, path, vw_bucket, day, selector, sum(clicks), sum(rage_clicks), round(avgMerge(x_rel), 4), round(avgMerge(y_rel), 4) FROM click_elements GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, toDate(ts) d, selector, count(), countIf(props['rage']='1'), round(avg(x_rel), 4), round(avg(y_rel), 4) FROM events WHERE event='click' AND selector != '' GROUP BY site_id, path, vw_bucket, d, selector"
check scroll_hist \
  "SELECT site_id, path, vw_bucket, day, depth, sum(pageviews) FROM scroll_hist GROUP BY ALL" \
  "SELECT site_id, path, vw_bucket, toDate(ts) d, toUInt8(intDiv(scroll_depth, 10) * 10) b, count() FROM events WHERE event='scroll' GROUP BY site_id, path, vw_bucket, d, b"

raw_sessions="SELECT site_id, toDate(ts) d, session_id, any(visitor_id) v, countIf(event='pageview') pv,
  dateDiff('millisecond', min(ts), max(ts)) / 1000 dur, argMin(path, ts) entry, argMax(path, ts) exit,
  any(country) country, any(device) device, any(browser) browser, any(os) os FROM events GROUP BY site_id, d, session_id"
check session_stats \
  "SELECT site_id, day, dim, value, sessions, engaged, round(duration_s, 3), uniqMerge(visitors) FROM session_stats GROUP BY ALL" \
  "SELECT site_id, d, x.1, x.2, count(), countIf(pawlog_engaged(pv, dur)), round(sum(dur), 3), uniq(v) FROM ($raw_sessions)
   ARRAY JOIN [('all', ''), ('country', toString(country)), ('device', toString(device)), ('browser', toString(browser)), ('os', toString(os))] AS x WHERE pv > 0 GROUP BY site_id, d, x.1, x.2"
check session_pages \
  "SELECT site_id, day, path, entries, exits, bounces FROM session_pages" \
  "SELECT site_id, d, p, countIf(entry = p), countIf(exit = p), countIf(entry = p AND pv <= 1) FROM ($raw_sessions)
   ARRAY JOIN arrayDistinct([entry, exit]) AS p GROUP BY site_id, d, p"

# Queries give the same answer whether days come from session_stats/session_pages or from sessions:
# drop closed days after 10-06 so 10-03..10-09 spans both, then compare with a full rebuild of the result from raw events.
QP="--param_site=s1 --param_from=2026-10-03 --param_to=2026-10-09 --param_path=/b --param_dim=country"
rnd() { awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) $i = sprintf("%.6f", $i) } 1'; }
q() { ch $QP --queries-file "queries/$1.sql" | rnd | md5sum; }
full=$(for n in overview_sessions sessions_daily breakdown page_entry_exit; do q $n; done)
ch -q "ALTER TABLE session_stats DELETE WHERE day > '2026-10-06' SETTINGS mutations_sync = 1"
ch -q "ALTER TABLE session_pages DELETE WHERE day > '2026-10-06' SETTINGS mutations_sync = 1"
split=$(for n in overview_sessions sessions_daily breakdown page_entry_exit; do q $n; done)
if [ "$full" = "$split" ]; then echo "PASS closed/open day split"; else echo "FAIL closed/open day split"; fail=1; fi
raw_overview=$(ch -q "SELECT count(), countIf(pawlog_engaged(pv, dur)) / count(), avg(dur) FROM ($raw_sessions) WHERE site_id = 's1' AND d BETWEEN '2026-10-03' AND '2026-10-09' AND pv > 0" | rnd)
got_overview=$(ch $QP --queries-file queries/overview_sessions.sql | rnd)
if [ "$raw_overview" = "$got_overview" ]; then echo "PASS overview_sessions = raw"; else echo "FAIL overview_sessions: $got_overview raw=$raw_overview"; fail=1; fi

# Channel grouping: (ref_domain, utm_source, utm_medium) -> channel
got=$(ch -q "SELECT arrayStringConcat(arrayMap(t -> pawlog_channel(t.1, t.2, t.3), [
  ('', '', ''), ('google.com', '', ''), ('', 'google', 'cpc'), ('t.co', '', ''), ('', 'facebook', 'paid_social'),
  ('', 'newsletter', 'email'), ('example.org', '', ''), ('', 'partner', 'affiliate'), ('', 'x1', 'banner'), ('', 'foo', 'bar')]), ',')")
want="Direct,Organic Search,Paid Search,Organic Social,Paid Social,Email,Referral,Affiliates,Display,Unassigned"
if [ "$got" = "$want" ]; then echo "PASS pawlog_channel"; else echo "FAIL pawlog_channel: $got"; fail=1; fi

# a few recent events so events_recent (last hour) has parts to plan against
ch -q "INSERT INTO events (ts, received_at, site_id, event, visitor_id, session_id, path) SELECT now64(3) - toIntervalSecond(number), now64(3), 's1', 'pageview', number % 7, number % 3, '/b' FROM numbers(100)"

# Every dashboard query runs, and its plan uses the primary key.
P="--param_site=s1 --param_from=2026-10-03 --param_to=2026-10-09 --param_path=/b --param_vw=desktop --param_layout=0 --param_dim=country"
for q in queries/*.sql; do
  rows=$(ch $P --queries-file "$q" | wc -l)
  plan=$(ch $P -q "EXPLAIN indexes = 1 $(cat "$q")")
  pk=$(echo "$plan" | sed -n '/^ *PrimaryKey$/,/Granules/p')
  keys=$(echo "$pk" | sed -n '/Keys:/,/Condition/p' | grep -v -e Keys: -e Condition | tr -d ' ' | awk '!seen[$0]++' | paste -sd, -)
  gran=$(echo "$pk" | grep -o 'Granules: [0-9]*/[0-9]*' | cut -c11- | paste -sd+ -)
  if [ -z "$keys" ]; then echo "FAIL $(basename "$q"): no primary key use"; fail=1; else
    printf 'PLAN %-18s rows=%-5s granules=%-6s key=%s\n' "$(basename "$q" .sql)" "$rows" "$gran" "$keys"; fi
done
exit $fail
