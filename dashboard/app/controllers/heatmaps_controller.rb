class HeatmapsController < ApplicationController
  BUCKETS = { "mobile" => 375, "tablet" => 820, "desktop" => 1440 }.freeze # iframe width per vw_bucket
  MODES = %w[grid elements scroll].freeze

  def show
    @vw = params.fetch(:vw, "desktop")
    @mode = params.fetch(:mode, "grid")
    raise BadParams, "vw must be one of #{BUCKETS.keys.join(', ')}" unless BUCKETS.key?(@vw)
    raise BadParams, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(@mode)
    @layout = Integer(params.fetch(:layout, "0"), exception: false) or raise BadParams, "layout must be an integer"
    @path = params[:path].presence
    return @pages = Analytics.rows("top_pages", **scope(path: "")) unless @path

    q = scope(path: @path, vw: @vw)
    @layouts = Analytics.rows("layouts", **q)
    @data = {
      grid: Analytics.rows("click_grid", **q, layout: @layout),
      elements: Analytics.rows("click_elements", **q),
      scroll: Analytics.rows("scroll_map", **q)
    }
  end
end
