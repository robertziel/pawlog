# Reports snapshot
class OverviewController < ApplicationController
  def show
    r = Analytics.parallel(
      current: -> { Analytics.totals(site, range) }, previous: -> { Analytics.totals(site, previous_range) },
      series: -> { Analytics.daily(site, range) }, previous_series: -> { Analytics.daily(site, previous_range) },
      pages: -> { Analytics.rows("top_pages", **scope(path: "")) },
      channels: -> { Analytics.rows("channels", **scope) },
      sources: -> { Analytics.rows("sources", **scope) },
      countries: -> { Analytics.rows("breakdown", **scope(dim: "country")) },
      devices: -> { Analytics.rows("breakdown", **scope(dim: "device")) })
    r.each { |k, v| instance_variable_set("@#{k}", v) }
  end
end
