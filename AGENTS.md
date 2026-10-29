# AGENTS.md

Guidance for coding agents (and humans) working in this repository.

## What this is

**pawlog**: self-hosted, privacy-first web analytics with heatmaps.
`pawlog.js` (browser) → `collector` (Rust/hyper) → Redpanda topic → ClickHouse (Kafka engine → MV → `events` + rollup MVs) → `dashboard` (Rails 8, reads rollups).

## Commands (everything runs in Docker; the host only needs docker, make, python3)

```bash
cp deploy/.env.example deploy/.env      # then edit; every var is required
make up          # build + start the stack, apply ClickHouse migrations (idempotent)
make test        # collector (unit + Redpanda integration), ClickHouse rollups, tracker (Playwright), dashboard
make e2e         # real browser -> collector -> Redpanda -> ClickHouse, against the running stack
make load        # oha ramp 200 -> 2000 -> 5000 req/s; STEPS="200:10 2000:10" for a short run
make bench       # 1M views/day for 30 days: storage growth, query latency, concurrency; DAYS=90 VIEWS=200000 to vary
make down
```

## Rules

- **A deployment is configuration, never code.** No host, IP, domain, port, origin, site or sizing in code, compose,
  tests or examples. Wiring and secrets are env (`deploy/.env`, documented in `deploy/.env.example`, `${VAR:?}` in
  compose). What a deployment *is* (its sites) is YAML (`dashboard/config/sites.yml`, from `sites.example.yml`).
  Real per-deployment files are gitignored; only `*.example*` files are committed. One place per value.
- **No fallbacks.** Missing or invalid config fails loudly at startup. If a source is unavailable, return an error or
  an empty state that says what is missing, never a substitute value. An explicitly empty value
  (e.g. `GEOIP_DB_PATH=`) disables an optional feature; it is the operator's choice, not a default.
- **Privacy.** Never store or log a raw IP. `visitor_id` = sha256(ip, ua, site, daily salt) truncated to u64, with the
  salt random per UTC day and held only in memory. `cid` (cookie id) exists only after `analytics.consent(true)`.
  DNT/GPC = no tracking.
- **Dashboards read rollups only.** The single exception is realtime (`realtime*.sql`: last 30 min from `events_recent`, a 1-hour copy of raw `events`). Session stats for closed days come from `session_stats`/`session_pages` (refreshable MVs); open days from `sessions`.
  Dashboard SQL lives in `clickhouse/queries/*.sql` (one source, parameterized; `make test` EXPLAINs each).
- **Migrations** are numbered, idempotent (`IF NOT EXISTS`) and applied in order by `clickhouse/migrate.sh`.
  The Kafka ingest is last so rollup MVs exist before rows flow.
- Keep dependencies minimal and justify each new crate or gem in one line. `pawlog.js` stays under 4 KB gzip
  (enforced by `tracker/build.sh`).
