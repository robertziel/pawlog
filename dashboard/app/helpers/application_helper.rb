module ApplicationHelper
  def num(v) = number_with_delimiter(v.to_f.round)
  def pct(v) = "#{(v.to_f * 100).round(1)}%"
  def secs(v) = (s = v.to_f.round) >= 60 ? "#{s / 60}m #{s % 60}s" : "#{s}s"
  def ratio(v) = v.to_f.round(2).to_s.delete_suffix(".0")
  # Ratios are nil when undefined (no sessions); shown as n/a, never as 0.
  def fmt(kind, v) = v.nil? ? "n/a" : send(kind, v)

  # Current path with some query params replaced (dropdown links keep everything else).
  def here(**over) = "#{request.path}?#{request.query_parameters.merge(over.stringify_keys).to_query}"

  def range_label
    days = range.count
    range.end == Date.current && ApplicationController::RANGE_PRESETS.include?(days) ? "Last #{days} days" : "#{range.begin.strftime('%-d %b %Y')} – #{range.end.strftime('%-d %b %Y')}"
  end

  # Change vs the previous period.
  def delta(cur, prev)
    return tag.span("n/a", class: "delta") if cur.nil? || prev.nil? || prev.to_f.zero?
    d = (cur.to_f - prev.to_f) / prev.to_f
    tag.span("#{d >= 0 ? '↑' : '↓'} #{(d.abs * 100).round(1)}%", class: "delta #{d >= 0 ? 'up' : 'down'}")
  end

  # Vertical bars as inline SVG; `label` names each bar in its tooltip.
  def bars(series, key:, label:, aria:)
    vals = series.map { |r| r[key].to_f }
    max = [ vals.max.to_f, 1 ].max
    w = 100.0 / [ vals.size, 1 ].max
    tag.svg(viewBox: "0 0 100 30", preserveAspectRatio: "none", class: "bars", role: "img", "aria-label": aria) do
      safe_join(series.each_with_index.map do |r, i|
        h = vals[i] / max * 30
        tag.rect(x: (i * w + w * 0.15).round(3), y: (30 - h).round(3), width: (w * 0.7).round(3), height: h.round(3)) { tag.title("#{label.call(r)}: #{num(r[key])}") }
      end)
    end
  end

  # Daily line, current period solid vs previous period dashed; nil values leave a gap.
  def line_chart(series, previous, key:, kind:, label:, width: 640)
    w, h, top, bottom, left = width.to_f, 220.0, 10.0, 190.0, 20.0
    right = w - 50
    vals = (series + previous).filter_map { _1[key]&.to_f }
    step = nice_step([ vals.max.to_f, kind == :pct ? 0.04 : 4 ].max / 4)
    max = step * 4.0
    x = ->(i) { series.size > 1 ? left + i * (right - left) / (series.size - 1) : (left + right) / 2 }
    y = ->(v) { bottom - v / max * (bottom - top) }
    line = ->(rows, cls) do
      rows.each_with_index.slice_when { |a, b| a[0][key].nil? != b[0][key].nil? }.reject { _1[0][0][key].nil? }.map do |seg|
        pts = seg.map { |r, i| [ x[i].round(1), y[r[key].to_f].round(1) ] }
        pts.one? ? tag.circle(cx: pts[0][0], cy: pts[0][1], r: 3, class: cls) : tag.polyline(points: pts.map { _1.join(",") }.join(" "), class: cls)
      end
    end
    ticks = (0..4).map do |t|
      v = step * t
      tag.line(x1: left, x2: right, y1: y[v], y2: y[v], class: "grid") + tag.text(fmt(kind == :num ? :ratio : kind, v), x: right + 8, y: y[v] + 4, class: "tick")
    end
    every = [ (series.size / 5.0).ceil, 1 ].max
    xlabels = series.each_with_index.select { |_, i| (i % every).zero? }.map do |r, i|
      tag.text(r["day"].to_date.strftime("%d %b"), x: x[i], y: h - 8, class: "tick", "text-anchor": "middle")
    end
    points = series.each_with_index.map do |r, i|
      p = previous[i]
      tip = "#{r['day']}: #{fmt(kind, r[key])}#{" · #{p['day']}: #{fmt(kind, p[key])}" if p}"
      tag.rect(x: x[i] - (right - left) / series.size / 2, y: top, width: (right - left) / series.size, height: bottom - top, class: "hit") { tag.title(tip) }
    end
    tag.svg(viewBox: "0 0 #{w} #{h}", class: "line-chart", role: "img", "aria-label": label) do
      safe_join(ticks + xlabels + line[previous, "prev"] + line[series, "cur"] + points)
    end
  end

  private
    def nice_step(raw)
      mag = 10**Math.log10(raw).floor
      [ 1, 2, 2.5, 5, 10 ].map { _1 * mag }.find { _1 >= raw }
    end
end
