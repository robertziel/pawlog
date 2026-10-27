# Runs the shared SQL in clickhouse/queries (CLICKHOUSE_QUERIES_DIR). Values travel as ClickHouse HTTP
# query parameters (param_*), never interpolated into SQL.
module Analytics
  DIR = Pathname(ENV.fetch("CLICKHOUSE_QUERIES_DIR"))

  def self.rows(name, **params)
    sql = (@sql ||= {})[name] ||= DIR.join("#{name}.sql").read
    resp = ClickHouse.connection.get(body: sql, query: { default_format: "JSON", **params.to_h { |k, v| [ :"param_#{k}", v.to_s ] } })
    ClickHouse::Response::Factory.response(resp, ClickHouse.config).to_a
  end

  def self.row(name, **params) = rows(name, **params).first
end
