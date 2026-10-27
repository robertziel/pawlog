# The one view on raw events: last 5 minutes.
class RealtimeController < ApplicationController
  def show
    @now = Analytics.row("realtime", site: site.id)
    @pages = Analytics.rows("realtime_pages", site: site.id)
  end
end
