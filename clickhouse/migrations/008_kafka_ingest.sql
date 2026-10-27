-- Last on purpose: rollup MVs must exist before rows start flowing.
-- ${...} values are filled from env by migrate.sh.
CREATE TABLE IF NOT EXISTS events_queue AS events
ENGINE = Kafka
SETTINGS
    kafka_broker_list = '${KAFKA_BROKERS}',
    kafka_topic_list = '${KAFKA_TOPIC}',
    kafka_group_name = '${CLICKHOUSE_KAFKA_GROUP}',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 2,
    kafka_skip_broken_messages = 100,
    kafka_flush_interval_ms = 1000; -- default 7.5s flush would break the <5s lag target

CREATE MATERIALIZED VIEW IF NOT EXISTS events_mv TO events AS
SELECT * FROM events_queue;
