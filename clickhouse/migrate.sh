#!/bin/sh
# usage: migrate.sh <database> [skip-substring]
# env: CLICKHOUSE_HOST, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD; KAFKA_BROKERS, KAFKA_TOPIC, CLICKHOUSE_KAFKA_GROUP unless kafka is skipped
set -eu
db=$1; skip=${2:-}
ch() { clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" "$@"; }
ch -q "CREATE DATABASE IF NOT EXISTS $db"
for f in "$(dirname "$0")"/migrations/*.sql; do
  if [ -n "$skip" ]; then case "$f" in *"$skip"*) continue ;; esac; fi
  echo "apply $(basename "$f")"
  sql=$(cat "$f")
  case "$sql" in *'${'*)
    sql=$(printf '%s' "$sql" | sed -e "s|\${KAFKA_BROKERS}|$KAFKA_BROKERS|g" -e "s|\${KAFKA_TOPIC}|$KAFKA_TOPIC|g" \
                                   -e "s|\${CLICKHOUSE_KAFKA_GROUP}|$CLICKHOUSE_KAFKA_GROUP|g") ;;
  esac
  printf '%s' "$sql" | ch --database "$db" --multiquery
done
