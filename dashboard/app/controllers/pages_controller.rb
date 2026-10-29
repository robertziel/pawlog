class PagesController < ApplicationController
  def show
    @path = params.require(:path)
    r = Analytics.parallel(totals: -> { Analytics.row("top_pages", **scope(path: @path)) },
                           entry_exit: -> { Analytics.row("page_entry_exit", **scope(path: @path)) },
                           series: -> { Analytics.rows("timeseries", **scope(path: @path)) })
    @totals, @entry_exit, @series = r.values_at(:totals, :entry_exit, :series)
  end
end
