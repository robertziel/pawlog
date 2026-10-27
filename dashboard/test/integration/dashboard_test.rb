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

  test "overview totals, comparison and breakdowns come from rollups" do
    get root_path(day)
    assert_response :success
    assert_equal %w[2 3 2 50.0% 1m\ 3s], %w[visitors pageviews sessions bounce_rate avg_duration_s].map { kpi(_1) }
    assert_select %([data-kpi="pageviews"] .delta), "n/a" # previous day is empty
    assert_select "td", text: "/a"
    assert_select "td", text: "google.com"
    assert_select "td", text: "DE"
    assert_select "td", text: "mobile"
  end

  test "site filter" do
    get root_path(day.merge(site: "t2"))
    assert_equal %w[1 1], %w[visitors pageviews].map { kpi(_1) }
  end

  test "page detail" do
    get page_path(day.merge(path: "/a"))
    assert_response :success
    assert_equal %w[2 2 15s 1 2 1], %w[pageviews visitors avg_engaged entries exits bounces].map { kpi(_1) }
  end

  test "realtime reads the last 5 minutes" do
    get realtime_path(site: "t1")
    assert_equal %w[1 1], %w[visitors pageviews].map { kpi(_1) }
    assert_select "td", text: "/live"
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
