class PagesController < ApplicationController
  def show
    @path = params.require(:path)
    @totals = Analytics.row("top_pages", **scope(path: @path))
    @entry_exit = Analytics.row("page_entry_exit", **scope(path: @path))
    @series = Analytics.rows("timeseries", **scope(path: @path))
  end
end
