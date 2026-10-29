# Runs the shared SQL in clickhouse/queries (CLICKHOUSE_QUERIES_DIR). Values travel as ClickHouse HTTP
# query parameters (param_*), never interpolated into SQL.
module Analytics
  DIR = Pathname(ENV.fetch("CLICKHOUSE_QUERIES_DIR"))
  SQL = DIR.glob("*.sql").to_h { [ _1.basename(".sql").to_s, _1.read ] }.freeze # read once; shared by threads

  def self.rows(name, **params)
    sql = SQL.fetch(name)
    resp = ClickHouse.connection.get(body: sql, query: { default_format: "JSON", **params.to_h { |k, v| [ :"param_#{k}", v.to_s ] } })
    ClickHouse::Response::Factory.response(resp, ClickHouse.config).to_a
  end

  def self.row(name, **params) = rows(name, **params).first

  # Runs the given lambdas concurrently (one thread each), returns their results under the same keys.
  # Errors re-raise in the caller. A page's queries are independent, so its latency is the slowest one, not the sum.
  def self.parallel(**calls)
    threads = calls.transform_values { |c| Thread.new { Thread.current.report_on_exception = false; Rails.application.executor.wrap { c.call } } }
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.transform_values(&:value) }
  end

  # Site totals for a range of UTC days. Ratios are nil when there are no sessions (undefined, not 0).
  def self.totals(site, range)
    p = { site: site.id, from: range.begin.iso8601, to: range.end.iso8601 }
    t = row("overview_traffic", **p).merge(row("overview_sessions", **p))
    s = t["sessions"].to_i
    t.merge("views_per_session" => (t["pageviews"].to_f / s if s > 0), "engagement_rate" => (t["engagement_rate"] if s > 0),
            "avg_duration_s" => (t["avg_duration_s"] if s > 0))
  end

  # One row per day: pageviews, visitors, sessions, engagement_rate, views_per_session.
  def self.daily(site, range)
    p = { site: site.id, from: range.begin.iso8601, to: range.end.iso8601 }
    sessions = rows("sessions_daily", **p).index_by { _1["day"].to_s }
    rows("timeseries", **p, path: "").map do |r|
      s = sessions.fetch(r["day"].to_s)
      n = s["sessions"].to_i
      r.merge("sessions" => n, "engagement_rate" => (s["engaged"].to_f / n if n > 0), "views_per_session" => (r["pageviews"].to_f / n if n > 0))
    end
  end
end
