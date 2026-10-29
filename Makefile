REDPANDA_IMAGE := redpandadata/redpanda:v25.2.1
CLICKHOUSE_IMAGE := clickhouse/clickhouse-server:25.8
TEST_CH := pawlog-test-clickhouse
BUN_IMAGE := oven/bun:1.3.14
PLAYWRIGHT_IMAGE := mcr.microsoft.com/playwright:v1.56.1-noble
TEST_RP := pawlog-test-redpanda
DEV := docker run --rm --network container:$(TEST_RP) -v $(CURDIR)/collector:/src \
	-v pawlog-cargo-registry:/usr/local/cargo/registry -v pawlog-collector-target:/src/target \
	-e TEST_KAFKA_BROKERS=127.0.0.1:9092 pawlog-collector-dev

.PHONY: up down e2e load bench test test-collector test-clickhouse test-tracker test-dashboard tracker dashboard-image collector-dev collector-image test-redpanda test-clean

DC := docker compose -f deploy/docker-compose.yml --env-file deploy/.env

up: tracker
	$(DC) up -d --build --wait redpanda clickhouse collector
	$(DC) run --rm migrate
	$(DC) up -d --build --wait dashboard
	$(DC) ps --format 'table {{.Service}}\t{{.Status}}'

e2e: up
	. deploy/.env; docker run --rm --ipc=host --network pawlog_default --add-host e2e.pawlog.local:127.0.0.1 \
		-e COLLECTOR=http://collector:8080 -e CLICKHOUSE=http://clickhouse:8123 -e CH_DB="$$CLICKHOUSE_DB" -e CH_USER=dashboard -e CH_PASSWORD="$$CLICKHOUSE_DASHBOARD_PASSWORD" \
		-e ORIGIN_HOST=e2e.pawlog.local -e DASHBOARD=http://dashboard:3000 -e ADMIN_EMAIL="$$ADMIN_EMAIL" -e ADMIN_PASSWORD="$$ADMIN_PASSWORD" -v $(CURDIR)/tracker:/app -v pawlog-tracker-node-modules:/app/node_modules -w /app $(PLAYWRIGHT_IMAGE) \
		sh -c 'npm install --no-audit --no-fund --silent && node --test test/stack.mjs'

load: up
	python3 loadtest/run.py $(STEPS)

down:
	$(DC) down

collector-dev:
	docker build -q --target dev -t pawlog-collector-dev collector >/dev/null

collector-image:
	docker build -t pawlog-collector collector

test-redpanda:
	docker inspect $(TEST_RP) >/dev/null 2>&1 || docker run -d --rm --name $(TEST_RP) $(REDPANDA_IMAGE) \
		redpanda start --mode dev-container --smp 1 --kafka-addr 127.0.0.1:9092 --advertise-kafka-addr 127.0.0.1:9092 >/dev/null
	until docker exec $(TEST_RP) rpk cluster health 2>/dev/null | grep -q 'Healthy:.*true'; do sleep 1; done

test: test-collector test-clickhouse test-tracker test-dashboard

dashboard-image:
	docker build -q -t pawlog-dashboard dashboard >/dev/null

# Rails tests against a throwaway ClickHouse built from clickhouse/migrations.
test-dashboard: dashboard-image
	-docker rm -f $(TEST_CH) >/dev/null 2>&1
	docker run -d --rm --name $(TEST_CH) -e CLICKHOUSE_PASSWORD=test $(CLICKHOUSE_IMAGE) >/dev/null
	until docker exec $(TEST_CH) clickhouse-client --password test -q 'SELECT 1' >/dev/null 2>&1; do sleep 1; done
	docker run --rm --network container:$(TEST_CH) -v $(CURDIR)/dashboard:/app -v $(CURDIR)/clickhouse:/clickhouse:ro -e RAILS_ENV=test \
		-e CLICKHOUSE_URL=http://127.0.0.1:8123 -e CLICKHOUSE_DB=pawlog_dashboard_test -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD=test \
		-e CLICKHOUSE_QUERIES_DIR=/clickhouse/queries -e CLICKHOUSE_MIGRATIONS_DIR=/clickhouse/migrations -e PAWLOG_SITES_FILE=test/fixtures/files/sites.yml \
		pawlog-dashboard sh -c 'bin/rails db:migrate >/dev/null && bin/rails test'; s=$$?; docker rm -f $(TEST_CH) >/dev/null; exit $$s

tracker:
	docker run --rm -v $(CURDIR)/tracker:/app -w /app $(BUN_IMAGE) ./build.sh

test-tracker: tracker
	docker run --rm --ipc=host -v $(CURDIR)/tracker:/app -v pawlog-tracker-node-modules:/app/node_modules -w /app $(PLAYWRIGHT_IMAGE) \
		sh -c 'npm install --no-audit --no-fund --silent && node --test test/e2e.mjs'

test-collector: collector-dev test-redpanda
	$(DEV) cargo test --release; s=$$?; $(MAKE) -s test-clean; exit $$s

test-clickhouse:
	-docker rm -f $(TEST_CH) >/dev/null 2>&1
	docker run -d --rm --name $(TEST_CH) -e CLICKHOUSE_PASSWORD=test -v $(CURDIR)/clickhouse:/pawlog:ro $(CLICKHOUSE_IMAGE) >/dev/null
	until docker exec $(TEST_CH) clickhouse-client --password test -q 'SELECT 1' >/dev/null 2>&1; do sleep 1; done
	docker exec -e CLICKHOUSE_HOST=localhost -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD=test $(TEST_CH) /pawlog/test.sh; s=$$?; docker rm -f $(TEST_CH) >/dev/null; exit $$s

# Storage growth + query latency at VIEWS pageviews/day for DAYS days, in a throwaway ClickHouse sized like deploy/.env.
DAYS ?= 30
VIEWS ?= 1000000
BENCH_CH := pawlog-bench-clickhouse
bench:
	-docker rm -f $(BENCH_CH) >/dev/null 2>&1
	mkdir -p bench/results
	. deploy/.env; docker run -d --rm --name $(BENCH_CH) --cpus "$$CLICKHOUSE_CPUS" --memory "$$CLICKHOUSE_MEMORY" --ulimit nofile=262144:262144 \
		-e CLICKHOUSE_PASSWORD=bench -v $(CURDIR)/clickhouse:/pawlog/clickhouse:ro -v $(CURDIR)/bench:/pawlog/bench:ro -v $(CURDIR)/bench/results:/results $(CLICKHOUSE_IMAGE) >/dev/null
	until docker exec $(BENCH_CH) clickhouse-client --password bench -q 'SELECT 1' >/dev/null 2>&1; do sleep 1; done
	. deploy/.env; docker exec -e DAYS=$(DAYS) -e VIEWS=$(VIEWS) -e RETENTION_MS="$$KAFKA_RETENTION_MS" -e OUT=/results \
		-e CLICKHOUSE_HOST=localhost -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD=bench $(BENCH_CH) /pawlog/bench/run.sh; \
		s=$$?; docker rm -f $(BENCH_CH) >/dev/null; exit $$s

test-clean:
	-docker rm -f $(TEST_RP) >/dev/null 2>&1
