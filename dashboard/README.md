# pawlog dashboard

Rails 8 app over the ClickHouse rollups. Runs as the `dashboard` service in `deploy/docker-compose.yml`.

| env | |
|---|---|
| `CLICKHOUSE_URL`, `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | read-only `dashboard` user in compose |
| `CLICKHOUSE_QUERIES_DIR` | `clickhouse/queries` (the only SQL the app runs) |
| `PAWLOG_SITES_FILE` | sites YAML (`deploy/sites.example.yml`) |
| `SECRET_KEY_BASE`, `DASHBOARD_FORCE_SSL`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` | Rails / single admin (seeded on boot) |

Tests: `make test-dashboard` (throwaway ClickHouse built from `clickhouse/migrations`).
