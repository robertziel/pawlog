# Builds a throwaway ClickHouse database from clickhouse/migrations (minus Kafka ingest) and loads known events,
# so dashboard tests exercise the real rollup MVs and the shared query files.
module ClickHouseFixtures
  DAY = "2026-10-01"

  def self.load!
    c, db = ClickHouse.connection, ClickHouse.config.database
    c.execute("DROP DATABASE IF EXISTS #{db}", database: nil)
    c.execute("CREATE DATABASE #{db}", database: nil)
    Dir[File.join(ENV.fetch("CLICKHOUSE_MIGRATIONS_DIR"), "*.sql")].sort.reject { |f| f.include?("kafka") }.each do |f|
      File.read(f).split(/;\s*$/).map(&:strip).reject { |s| s.gsub(/^--.*$/, "").strip.empty? }.each { |s| c.post(s) }
    end
    c.post(events.map(&:to_json).join("\n"), query: { query: "INSERT INTO events FORMAT JSONEachRow" })
    %w[session_stats_mv session_pages_mv].each { |v| c.post("SYSTEM REFRESH VIEW #{v}"); c.post("SYSTEM WAIT VIEW #{v}") }
  end

  def self.events
    t = ->(hms) { "#{DAY} #{hms}.000" }
    a = { site_id: "t1", session_id: 1, visitor_id: 10, ref_domain: "google.com", country: "DE", device: "desktop", vw_bucket: "desktop", layout_hash: 7 }
    b = { site_id: "t1", session_id: 2, visitor_id: 11, country: "FR", device: "mobile", vw_bucket: "mobile" }
    click = { event: "click", path: "/a", selector: "#cta", page_x_pct: 50.5, page_y: 105, x_rel: 0.5, y_rel: 0.25 }
    [
      { **a, event: "pageview", path: "/", title: "Home", ts: t["10:00:00"] },
      { **a, event: "pageview", path: "/a", title: "A", ts: t["10:01:00"] },
      { **a, **click, ts: t["10:01:10"] },
      { **a, **click, ts: t["10:01:20"] },
      { **a, **click, ts: t["10:01:30"] },
      { **a, **click, selector: "nav > a", page_x_pct: 10.2, page_y: 20, props: { rage: "1" }, ts: t["10:01:40"] },
      { **a, event: "scroll", path: "/a", scroll_depth: 80, ts: t["10:01:50"] },
      { **a, event: "engagement", path: "/a", engaged_ms: 30_000, ts: t["10:02:00"] },
      { **b, event: "pageview", path: "/a", title: "A", ts: t["11:00:00"] },
      { **b, event: "scroll", path: "/a", scroll_depth: 30, ts: t["11:00:05"] },
      { site_id: "t2", session_id: 9, visitor_id: 99, event: "pageview", path: "/", vw_bucket: "desktop", ts: t["12:00:00"] },
      { site_id: "t1", session_id: 3, visitor_id: 12, event: "pageview", path: "/live", title: "Live", vw_bucket: "desktop",
        ts: Time.now.utc.strftime("%F %T.%L") }
    ].map { |e| { received_at: e[:ts], **e } }
  end
end
