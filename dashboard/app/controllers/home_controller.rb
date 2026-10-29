class HomeController < ApplicationController
  METRICS = { "pageviews" => "Views", "visitors" => "Active users", "engagement_rate" => "Engagement rate", "views_per_session" => "Views per session" }.freeze

  def show
    @metric = params.fetch(:metric, "pageviews")
    raise BadParams, "metric must be one of #{METRICS.keys.join(', ')}" unless METRICS.key?(@metric)
    r = Analytics.parallel(
      current: -> { Analytics.totals(site, range) }, previous: -> { Analytics.totals(site, previous_range) },
      series: -> { Analytics.daily(site, range) }, previous_series: -> { Analytics.daily(site, previous_range) },
      realtime: -> { Analytics.row("realtime", site: site.id) },
      minutes: -> { Analytics.rows("realtime_minutes", site: site.id) },
      cities: -> { Analytics.rows("realtime_breakdown", site: site.id, dim: "city") },
      countries: -> { Analytics.rows("breakdown", **scope(dim: "country")) },
      titles: -> { Analytics.rows("titles", **scope) },
      channels: -> { Analytics.rows("channels", **scope) })
    r.each { |k, v| instance_variable_set("@#{k}", v) }
  end
end
