module ApplicationHelper
  def num(v) = number_with_delimiter(v.to_f.round)
  def pct(v) = "#{(v.to_f * 100).round(1)}%"
  def secs(v) = (s = v.to_f.round) >= 60 ? "#{s / 60}m #{s % 60}s" : "#{s}s"

  # Change vs the previous period; `lower_is_better` flips the colour (bounce rate).
  def delta(cur, prev, lower_is_better: false)
    c, p = cur.to_f, prev.to_f
    return tag.span("n/a", class: "delta") if p.zero?
    d = (c - p) / p
    good = lower_is_better ? d <= 0 : d >= 0
    tag.span("#{d >= 0 ? '+' : ''}#{(d * 100).round(1)}%", class: "delta #{good ? 'up' : 'down'}")
  end

  # Daily bars (pageviews) as inline SVG.
  def bars(series, key: "pageviews")
    vals = series.map { |r| r[key].to_f }
    max = [ vals.max.to_f, 1 ].max
    w = 100.0 / [ vals.size, 1 ].max
    tag.svg(viewBox: "0 0 100 30", preserveAspectRatio: "none", class: "bars", role: "img", "aria-label": "#{key} per day") do
      safe_join(series.each_with_index.map do |r, i|
        h = vals[i] / max * 30
        tag.rect(x: (i * w + w * 0.1).round(3), y: (30 - h).round(3), width: (w * 0.8).round(3), height: h.round(3)) { tag.title("#{r['day']}: #{num(r[key])}") }
      end)
    end
  end
end
