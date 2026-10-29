require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:one)) }

  def kpi(name) = css_select(%([data-kpi="#{name}"] .value)).first.text.strip
  def day = { site: "t1", from: ClickHouseFixtures::DAY, to: ClickHouseFixtures::DAY }

  test "requires login" do
    sign_out
    get root_path
    assert_redirected_to new_session_path
  end

  def card(name) = css_select(%([data-card="#{name}"] td)).map { _1.text.strip }

  test "home: KPI tabs vs previous period, line chart, realtime card, top-N cards" do
    get root_path(day)
    assert_response :success
    assert_equal [ "3", "2", "50.0%", "1.5" ], %w[pageviews visitors engagement_rate views_per_session].map { kpi(_1) }
    assert_select %([data-kpi="pageviews"] .delta), "n/a" # previous day is empty
    assert_select %(.tab.on[data-kpi="pageviews"])
    assert_select ".line-chart .cur", 1
    assert_select ".line-chart .prev", 1
    assert_equal "1", kpi("active_30m")
    assert_select ".rt-card .bars rect", 30
    assert_equal %w[DE 1 FR 1], card("value").each_slice(2).sort.flatten
    assert_equal %w[A 2 Home 1], card("title")
    assert_equal [ "Direct", "1", "Organic Search", "1" ], card("channel").each_slice(2).sort.flatten

    get root_path(day.merge(metric: "engagement_rate"))
    assert_select %(.tab.on[data-kpi="engagement_rate"])
    get root_path(day.merge(metric: "bounce"))
    assert_response :bad_request
  end

  test "default range is the last 28 days" do
    get root_path(site: "t1")
    assert_select ".range summary", /Last 28 days/
  end

  test "reports snapshot totals, comparison and breakdowns come from rollups" do
    get reports_path(day)
    assert_response :success
    assert_equal [ "3", "2", "2", "50.0%", "1.5", "1m 3s" ], %w[pageviews visitors sessions engagement_rate views_per_session avg_duration_s].map { kpi(_1) }
    assert_select %([data-kpi="pageviews"] .delta), "n/a"
    %w[/a google.com DE mobile Organic\ Search].each { assert_select "td", text: _1 }
  end

  test "site filter" do
    get reports_path(day.merge(site: "t2"))
    assert_equal %w[1 1], %w[visitors pageviews].map { kpi(_1) }
  end

  test "page detail" do
    get page_path(day.merge(path: "/a"))
    assert_response :success
    assert_equal %w[2 2 15s 1 2 1], %w[pageviews visitors avg_engaged entries exits bounces].map { kpi(_1) }
  end

  test "realtime overview reads the last 30 minutes" do
    get realtime_path(site: "t1")
    assert_equal %w[1 1], %w[active_30m active_5m].map { kpi(_1) }
    assert_select ".bars rect", 30
    assert_equal [ "(direct)", "1" ], card("value").first(2)
    assert_select %([data-card="value"] td), text: "Live"
  end

  test "realtime pages" do
    get realtime_pages_path(site: "t1")
    assert_equal %w[1 1], %w[active_30m views].map { kpi(_1) }
    assert_select "td", text: "/live"
    assert_select "td", text: "Live"
  end

  test "heatmap data for path, bucket and layout" do
    get heatmap_path(day.merge(path: "/a", vw: "desktop", layout: 7))
    assert_response :success
    data = JSON.parse(css_select("#heatmap-data").first.text)
    assert_equal [ [ 10, 20, 1 ], [ 50, 100, 3 ] ], data["grid"].map { |c| [ c["x_pct"], c["y_px"], c["clicks"] ].map(&:to_i) }.sort
    assert_equal({ "#cta" => 3, "nav > a" => 1 }, data["elements"].to_h { [ _1["selector"], _1["clicks"].to_i ] })
    assert_equal 1, data["elements"].find { _1["selector"] == "nav > a" }["rage_clicks"].to_i
    assert_equal [ [ 80, 1 ] ], data["scroll"].map { [ _1["depth"].to_i, _1["n"].to_i ] }
    assert_select "#heatmap[data-url='https://t1.test/a'][data-origin='https://t1.test'][data-width='1440']"
    assert_select "select#layout option[value='7']"

    get heatmap_path(day.merge(path: "/a", vw: "mobile"))
    assert_equal [ [ 30, 1 ] ], JSON.parse(css_select("#heatmap-data").first.text)["scroll"].map { [ _1["depth"].to_i, _1["n"].to_i ] }
  end

  test "bad params are 400, not a substitute" do
    get heatmap_path(day.merge(path: "/a", vw: "watch"))
    assert_response :bad_request
    get root_path(site: "t1", from: "2026-10-05", to: "2026-10-01")
    assert_response :bad_request
  end
end
