class ApplicationController < ActionController::Base
  include Authentication
  allow_browser versions: :modern

  helper_method :site, :range, :scope

  class BadParams < StandardError; end
  rescue_from(Date::Error, BadParams) { |e| render plain: "bad request: #{e.message}", status: :bad_request }

  private
    def site
      @site ||= params[:site].present? ? Site.find(params[:site]) : Site.all.first
    end

    # UTC days, inclusive; defaults to the last 7 days.
    def range
      @range ||= begin
        to = params[:to].present? ? Date.iso8601(params[:to]) : Date.current
        from = params[:from].present? ? Date.iso8601(params[:from]) : to - 6
        raise BadParams, "from is after to" if from > to
        from..to
      end
    end

    # Params for every query, and for links that keep the current site/range.
    def scope(**extra) = { site: site.id, from: range.begin.iso8601, to: range.end.iso8601, **extra }
end
