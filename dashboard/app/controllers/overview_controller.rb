class OverviewController < ApplicationController
  def show
    previous = (range.begin - range.count)..(range.begin - 1)
    @current, @previous = totals(range), totals(previous)
    @previous_range = previous
    @series = Analytics.rows("timeseries", **scope(path: ""))
    @pages = Analytics.rows("top_pages", **scope(path: ""))
    @sources = Analytics.rows("sources", **scope)
    @countries = Analytics.rows("breakdown", **scope(dim: "country"))
    @devices = Analytics.rows("breakdown", **scope(dim: "device"))
  end

  private
    def totals(r)
      p = { site: site.id, from: r.begin.iso8601, to: r.end.iso8601 }
      Analytics.row("overview_traffic", **p).merge(Analytics.row("overview_sessions", **p))
    end
end
