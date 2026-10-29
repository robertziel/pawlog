# The only views on raw events (events_recent): last 30 minutes.
class RealtimeController < ApplicationController
  def show
    dims = %w[source title country city]
    r = Analytics.parallel(now: -> { Analytics.row("realtime", site: site.id) }, minutes: -> { Analytics.rows("realtime_minutes", site: site.id) },
                           **dims.to_h { |d| [ d.to_sym, -> { Analytics.rows("realtime_breakdown", site: site.id, dim: d) } ] })
    @now, @minutes, @by = r[:now], r[:minutes], dims.index_with { r[_1.to_sym] }
    @by["title"] = @by["title"].select { _1["views"].to_i > 0 } # titles come from pageviews only
  end

  def pages
    @now = Analytics.row("realtime", site: site.id)
    @pages = Analytics.rows("realtime_pages", site: site.id)
  end
end
