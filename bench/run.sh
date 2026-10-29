#!/bin/bash
# Storage growth + query latency at a given daily volume. Runs inside a dedicated ClickHouse container (`make bench`).
# env: DAYS, VIEWS (pageviews/day), CLICKHOUSE_HOST/USER/PASSWORD, RETENTION_MS (Kafka topic retention), OUT (results dir)
set -euo pipefail
cd "$(dirname "$0")"
: "${DAYS:?}" "${VIEWS:?}" "${RETENTION_MS:?}" "${OUT:?}"
db=pawlog_bench site=bench
SESSIONS=$(( VIEWS * 2 / 5 ))   # generator averages 2.5 pageviews per session
ch() { clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "$db" "$@"; }
md() { ch --format Markdown -q "$1"; echo; }
now() { date +%s.%N; }
gen() { ch --param_site=$site --param_seed="$1" --param_start="$2" --param_span="$3" --param_sessions="$4" --queries-file generate.sql; }
exec > >(tee "$OUT/report.md") 2>&1

clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -q "DROP DATABASE IF EXISTS $db"
../clickhouse/migrate.sh "$db" kafka >/dev/null

echo "# pawlog benchmark · $VIEWS views/day · $DAYS days · $(date -u +%F)"
echo
echo "## Ingest (INSERT through 7 rollup MVs)"
echo
echo "| day | events | seconds | events/s |"
echo "|---|---|---|---|"
first=$(date -u -d "-$DAYS days" +%F)
for d in $(seq 0 $((DAYS - 1))); do
  day=$(date -u -d "$first +$d days" +%F)
  before=$(ch -q "SELECT count() FROM events"); t0=$(now)
  gen "$d" "$day 00:00:00.000" 86400 "$SESSIONS"
  t1=$(now); after=$(ch -q "SELECT count() FROM events")
  awk -v d="$day" -v n=$((after - before)) -v s="$(echo "$t1 - $t0" | bc)" 'BEGIN { printf "| %s | %d | %.1f | %d |\n", d, n, s, n / s }'
done
# live slice so realtime queries see a last-30-minutes volume matching VIEWS/day
gen 999999 "$(date -u -d '-30 min' '+%F %T').000" 1800 $(( SESSIONS * 1800 / 86400 ))
echo
echo "## Session summaries (refreshable MVs, hourly; first refresh backfills all closed days)"
echo
echo "| view | seconds |"; echo "|---|---|"
for v in session_stats_mv session_pages_mv; do
  t0=$(now); ch -q "SYSTEM REFRESH VIEW $v"; ch -q "SYSTEM WAIT VIEW $v"
  echo "| $v | $(echo "$(now) - $t0" | bc | xargs printf '%.1f') |"
done
echo

sizes() {
  md "SELECT table, formatReadableQuantity(sum(rows)) AS rows, count() AS parts,
        formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed, formatReadableSize(sum(bytes_on_disk)) AS on_disk,
        round(sum(data_uncompressed_bytes) / sum(bytes_on_disk), 1) AS ratio,
        formatReadableSize(sum(bytes_on_disk) / $DAYS) AS per_day,
        formatReadableSize(sum(bytes_on_disk) / $DAYS / ($VIEWS / 1e6)) AS per_day_per_1M_views
      FROM system.parts WHERE active AND database = '$db' GROUP BY table ORDER BY sum(bytes_on_disk) DESC"
}
echo "## Storage as inserted (background merges still running)"; echo; sizes
for t in $(ch -q "SELECT name FROM system.tables WHERE database = '$db' AND engine LIKE '%MergeTree'"); do ch -q "OPTIMIZE TABLE $t FINAL"; done
echo "## Storage after OPTIMIZE FINAL (steady state)"; echo; sizes

ev_day=$(ch -q "SELECT sum(bytes_on_disk) / $DAYS FROM system.parts WHERE active AND database = '$db' AND table = 'events'")
ro_day=$(ch -q "SELECT sum(bytes_on_disk) / $DAYS FROM system.parts WHERE active AND database = '$db' AND table != 'events'")
ev_n=$(ch -q "SELECT count() / $DAYS FROM events WHERE ts < today()")
json=$(ch -q "SELECT avg(length(formatRow('JSONEachRow', *))) FROM (SELECT * FROM events LIMIT 200000)")
ret_days=$(( RETENTION_MS / 86400000 ))
echo "## Growth projection at $VIEWS views/day"
echo
echo "| store | per day | 30 days | 180 days | 1 year | 3 years |"
echo "|---|---|---|---|---|---|"
ch -q "SELECT concat('| events (TTL 180 d) | ', formatReadableSize($ev_day), ' | ', formatReadableSize($ev_day * 30), ' | ', formatReadableSize($ev_day * 180), ' | ', formatReadableSize($ev_day * 180), ' | ', formatReadableSize($ev_day * 180), ' |')"
ch -q "SELECT concat('| rollups (no TTL) | ', formatReadableSize($ro_day), ' | ', formatReadableSize($ro_day * 30), ' | ', formatReadableSize($ro_day * 180), ' | ', formatReadableSize($ro_day * 365), ' | ', formatReadableSize($ro_day * 1095), ' |')"
ch -q "SELECT concat('| Redpanda (retention $ret_days d, uncompressed JSON) | ', formatReadableSize($json * $ev_n), ' | ', formatReadableSize($json * $ev_n * least(30, $ret_days)), ' | ', formatReadableSize($json * $ev_n * least(180, $ret_days)), ' | ', formatReadableSize($json * $ev_n * least(365, $ret_days)), ' | ', formatReadableSize($json * $ev_n * least(1095, $ret_days)), ' |')"
echo
ch -q "SELECT concat('events/day ', formatReadableQuantity($ev_n), ' · events/view ', toString(round($ev_n / $VIEWS, 2)), ' · bytes on disk/event ', toString(round($ev_day / $ev_n, 1)), ' · JSON bytes/event ', toString(round($json)), ' · avg ingest ', toString(round($ev_n / 86400, 1)), ' events/s')"
echo
echo "## events: largest columns"; echo
md "SELECT name, type, formatReadableSize(sum(data_compressed_bytes)) AS on_disk, formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
      round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
    FROM system.columns WHERE database = '$db' AND table = 'events' GROUP BY name, type ORDER BY sum(data_compressed_bytes) DESC LIMIT 15"

# Query latency: every dashboard query, each range, 1 cold (caches dropped) + 5 warm runs, measured from query_log.
top=$(ch -q "SELECT path FROM pageviews_hourly WHERE site_id = '$site' GROUP BY path ORDER BY sum(views) DESC LIMIT 1")
to=$(date -u -d yesterday +%F)
ranges="1 7 28"; [ "$DAYS" -gt 28 ] && ranges="$ranges $DAYS"
run_q() { # name, range, file, extra params
  local q=$1 r=$2 f=$3; shift 3
  ch -q "SYSTEM DROP MARK CACHE"; ch -q "SYSTEM DROP UNCOMPRESSED CACHE"
  for i in 0 1 2 3 4 5; do
    ch --log_comment="bench|$q|$r|$i" --param_site=$site --param_path="$top" --param_vw=desktop --param_layout=0 --param_dim=country "$@" --queries-file "$f" >/dev/null
  done
}
for f in ../clickhouse/queries/*.sql; do
  q=$(basename "$f" .sql)
  case "$q" in realtime*) run_q "$q" 30m "$f"; continue ;; esac
  for r in $ranges; do run_q "$q" "${r}d" "$f" --param_from="$(date -u -d "$to -$((r - 1)) days" +%F)" --param_to="$to"; done
done
ch -q "SYSTEM FLUSH LOGS"
latency="SELECT splitByChar('|', log_comment)[2] AS query, splitByChar('|', log_comment)[3] AS range,
      anyIf(query_duration_ms, splitByChar('|', log_comment)[4] = '0') AS cold_ms,
      quantileExactIf(0.5)(query_duration_ms, splitByChar('|', log_comment)[4] != '0') AS warm_p50_ms,
      maxIf(query_duration_ms, splitByChar('|', log_comment)[4] != '0') AS warm_max_ms,
      formatReadableQuantity(any(read_rows)) AS rows_read, formatReadableSize(any(read_bytes)) AS bytes_read,
      formatReadableSize(max(memory_usage)) AS peak_memory
    FROM system.query_log
    WHERE type = 'QueryFinish' AND log_comment LIKE 'bench|%' AND current_database = '$db'"
echo "## Query latency (path = '$top', ranges end $to)"; echo
md "$latency GROUP BY query, range ORDER BY query, toUInt32OrZero(trimRight(range, 'dm'))"

echo "## Visitor count error: rollup uniqCombined(12) vs exact count over raw events, 28 days"; echo
from28=$(date -u -d "$to -27 days" +%F)
md "SELECT 'site' AS scope, r.v AS rollup, e.v AS exact, round(100 * (r.v - e.v) / e.v, 2) AS error_pct
    FROM (SELECT uniqCombinedMerge(12)(visitors) AS v FROM pageviews_hourly WHERE site_id = '$site' AND toDate(hour) BETWEEN '$from28' AND '$to') r,
         (SELECT uniqExact(visitor_id) AS v FROM events WHERE site_id = '$site' AND event IN ('pageview', 'engagement') AND toDate(ts) BETWEEN '$from28' AND '$to') e
    UNION ALL
    SELECT 'page $top', r.v, e.v, round(100 * (r.v - e.v) / e.v, 2)
    FROM (SELECT uniqCombinedMerge(12)(visitors) AS v FROM pageviews_hourly WHERE site_id = '$site' AND path = '$top' AND toDate(hour) BETWEEN '$from28' AND '$to') r,
         (SELECT uniqExact(visitor_id) AS v FROM events WHERE site_id = '$site' AND event IN ('pageview', 'engagement') AND path = '$top' AND toDate(ts) BETWEEN '$from28' AND '$to') e"

echo "## Dashboard page latency, warm p50: queries run in parallel threads (Analytics.parallel), so a page = its slowest thread"; echo
p50() { ch -q "SELECT quantileExactIf(0.5)(query_duration_ms, splitByChar('|', log_comment)[4] != '0') FROM system.query_log
                WHERE type = 'QueryFinish' AND current_database = '$db' AND log_comment LIKE 'bench|$1|$2|%'"; }
page() { # range, then threads; a+b = queries run one after another in one thread
  local r=$1 worst=0 t q ms; shift
  for t in "$@"; do
    ms=0
    for q in ${t//+/ }; do
      local rr=$r; case "$q" in realtime*) rr=30m ;; esac
      ms=$(( ms + $(p50 "$q" "$rr") ))
    done
    [ "$ms" -gt "$worst" ] && worst=$ms
  done
  echo "$worst"
}
echo "| page | range | ms |"; echo "|---|---|---|"
for r in 7d 28d; do
  echo "| Home | $r | $(page $r overview_traffic+overview_sessions timeseries+sessions_daily realtime realtime_minutes realtime_breakdown breakdown titles channels) |"
  echo "| Reports snapshot | $r | $(page $r overview_traffic+overview_sessions timeseries+sessions_daily top_pages channels sources breakdown) |"
  echo "| Page detail | $r | $(page $r top_pages page_entry_exit timeseries) |"
  echo "| Heatmap | $r | $(page $r layouts click_grid click_elements scroll_map) |"
done
echo "| Realtime overview | 30m | $(page 30m realtime realtime_minutes realtime_breakdown) |"
echo

# Concurrency: the Home page's distinct queries (28 days), mixed, 20 s per level.
from=$(date -u -d "$to -27 days" +%F)
mix="$OUT/home_mix.sql"; : > "$mix"
for q in overview_traffic overview_sessions timeseries sessions_daily breakdown titles channels realtime realtime_minutes realtime_breakdown; do
  sed -e 's/--.*$//' -e "s/{site:String}/'$site'/g" -e "s/{from:Date}/toDate('$from')/g" -e "s/{to:Date}/toDate('$to')/g" \
      -e "s/{path:String}/''/g" -e "s/{dim:Identifier}/country/g" -e "s/{dim:String}/'country'/g" "../clickhouse/queries/$q.sql" | tr '\n' ' ' >> "$mix"; echo >> "$mix"
done
echo "## Concurrency: Home page query mix, 28 days, 20 s per level"; echo
echo "| clients | QPS | p50 ms | p95 ms | p99 ms |"; echo "|---|---|---|---|---|"
for c in 1 4 16 64; do
  clickhouse-benchmark --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "$db" \
    -c "$c" -t 20 < "$mix" > "$OUT/conc-$c.txt" 2>&1 || true # a level that errors is reported as a row below
  errs=$(grep -c 'An error occurred' "$OUT/conc-$c.txt" || true)
  if [ "$errs" -gt 0 ]; then
    echo "| $c | failed: $errs query errors ($(grep -o '([A-Z_][A-Z_]*)' "$OUT/conc-$c.txt" | sort | uniq -c | sort -rn | head -1 | xargs)) | | | |"; continue
  fi
  awk -v c="$c" '/QPS:/ { match($0, /QPS: [0-9.]+/); qps = substr($0, RSTART + 5, RLENGTH - 5) }
                 $1 == "50%" { p50 = $2 } $1 == "95%" { p95 = $2 } $1 == "99%" { p99 = $2 }
                 END { if (!qps) exit 1; printf "| %s | %d | %d | %d | %d |\n", c, qps, p50 * 1000, p95 * 1000, p99 * 1000 }' "$OUT/conc-$c.txt"
done
echo
echo "done $(date -u +%T)"
