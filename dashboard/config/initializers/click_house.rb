# Missing connection settings fail at boot.
ClickHouse.config do |c|
  c.url = ENV.fetch("CLICKHOUSE_URL")
  c.database = ENV.fetch("CLICKHOUSE_DB")
  c.username = ENV.fetch("CLICKHOUSE_USER")
  c.password = ENV.fetch("CLICKHOUSE_PASSWORD")
  c.logger = Rails.logger
  c.timeout = 30
end

Rails.application.config.after_initialize { Site.all } # validate sites YAML at boot
