// Heatmap viewer: frames the page with #pawlog-heatmap, asks its pawlog.js for document size and element rects
// (postMessage, answered only for this dashboard's origin), then draws the click grid, elements or scroll map.
(() => {
  const root = document.getElementById("heatmap");
  if (!root) return;
  const { url, origin, mode, width } = root.dataset;
  const data = JSON.parse(document.getElementById("heatmap-data").textContent);
  const frame = root.querySelector("iframe"), canvas = root.querySelector("canvas");
  const status = document.getElementById("heatmap-status");
  frame.style.width = width + "px";

  let tries = 0, timer = 0;
  const ask = () => {
    if (++tries > 20) {
      clearInterval(timer);
      status.textContent = `no answer from pawlog.js at ${origin} — its script tag needs data-dashboard="${location.origin}"`;
      return;
    }
    frame.contentWindow.postMessage({ pawlog: "rects", sels: data.elements.map((e) => e.selector) }, origin);
  };
  addEventListener("message", (e) => {
    if (e.origin !== origin || e.data?.pawlog !== "rects") return;
    clearInterval(timer);
    status.textContent = "";
    draw(e.data);
  });
  frame.addEventListener("load", () => { ask(); timer = setInterval(ask, 500); });
  frame.src = url + "#pawlog-heatmap";

  function draw({ rects, docH, docW }) {
    frame.style.height = docH + "px";
    Object.assign(canvas, { width: docW, height: docH });
    Object.assign(canvas.style, { width: docW + "px", height: docH + "px" });
    const g = canvas.getContext("2d");
    g.font = "12px system-ui, sans-serif";
    const label = (text, x, y) => {
      const w = g.measureText(text).width + 8;
      g.fillStyle = "rgba(0,0,0,.75)"; g.fillRect(x, y - 14, w, 18);
      g.fillStyle = "#fff"; g.fillText(text, x + 4, y);
    };

    if (mode === "grid") {
      const max = data.grid.reduce((m, c) => Math.max(m, +c.clicks), 1), cw = docW / 100;
      for (const c of data.grid) {
        const a = Math.sqrt(+c.clicks / max);
        g.fillStyle = `hsla(${(1 - a) * 240}, 100%, 50%, ${0.2 + a * 0.6})`;
        g.fillRect(+c.x_pct * cw, +c.y_px, cw, 10);
      }
    } else if (mode === "elements") {
      const max = data.elements.reduce((m, e) => Math.max(m, +e.clicks), 1);
      data.elements.forEach((e, i) => {
        const r = rects[i];
        if (!r) return; // selector no longer on the page
        const [x, y, w, h] = r, a = +e.clicks / max;
        g.fillStyle = `rgba(255, 80, 0, ${0.15 + a * 0.45})`; g.fillRect(x, y, w, h);
        g.strokeStyle = "#ff5000"; g.strokeRect(x, y, w, h);
        g.fillStyle = "#000"; g.beginPath(); g.arc(x + +e.x_rel * w, y + +e.y_rel * h, 4, 0, 7); g.fill();
        label(`${e.clicks}${+e.rage_clicks ? ` · ${e.rage_clicks} rage` : ""}`, x, y);
      });
    } else {
      // every 10% band, shaded by the share of pageviews whose max depth reached it
      const total = data.scroll.reduce((t, s) => t + +s.n, 0);
      for (let d = 0; total && d < 100; d += 10) {
        const frac = data.scroll.reduce((t, s) => t + (+s.depth >= d ? +s.n : 0), 0) / total;
        const y0 = (d / 100) * docH;
        g.fillStyle = `rgba(0, 0, 0, ${(1 - frac) * 0.7})`;
        g.fillRect(0, y0, docW, docH / 10);
        label(`${d}% · ${Math.round(frac * 100)}% reached`, 8, y0 + 16);
      }
    }
  }
})();
