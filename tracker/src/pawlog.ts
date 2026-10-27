// pawlog.js — <script defer src="https://<collector>/pawlog.js" data-site="s1" data-layout="main" data-dashboard="https://dash.example"></script>
type Ev = Record<string, unknown>;
type Session = { id: string; last: number; ref: string; utm: [string, string, string] };

const w = window, d = document, n = navigator as Navigator & { globalPrivacyControl?: boolean };
const script = d.currentScript as HTMLScriptElement;
const site = script.dataset.site;
const endpoint = new URL("/e", script.src).href;
const SKEY = "pawlog_s", CKEY = "pawlog_cid", IDLE = 30 * 60e3;
const noop = () => {};
const api: { track: (name: string, props?: Record<string, unknown>) => void; consent: (on: boolean) => void } = { track: noop, consent: noop };
(w as any).analytics = api;

const hex = (words: number) =>
  Array.from(crypto.getRandomValues(new Uint32Array(words)), (x) => x.toString(16).padStart(8, "0")).join("");
const bucket = () => (innerWidth < 768 ? "mobile" : innerWidth < 1024 ? "tablet" : "desktop");
const docH = () => d.documentElement.scrollHeight;

// Element rects for the dashboard heatmap; page is framed with #pawlog-heatmap and never tracks.
if (location.hash == "#pawlog-heatmap") {
  addEventListener("message", (e) => {
    if (e.origin !== script.dataset.dashboard || e.data?.pawlog != "rects") return;
    const rects = (e.data.sels as string[]).map((s) => {
      let el: Element | null = null;
      try { el = d.querySelector(s); } catch {}
      const r = el?.getBoundingClientRect();
      return r ? [r.left + scrollX, r.top + scrollY, r.width, r.height] : null;
    });
    (e.source as Window).postMessage({ pawlog: "rects", rects, docH: docH(), docW: d.documentElement.scrollWidth }, e.origin);
  });
} else if (!site) {
  console.error("pawlog: data-site missing");
} else if (n.doNotTrack == "1" || n.globalPrivacyControl) {
  // DNT/GPC: no tracking at all; the API stays callable as no-ops.
} else {
  start(site);
}

function start(site: string) {
  let store: Storage;
  try { store = sessionStorage; store.getItem(SKEY); } catch { return console.warn("pawlog: sessionStorage unavailable, not tracking"); }

  const session = (): Session => {
    const now = Date.now();
    let s: Session | null = JSON.parse(store.getItem(SKEY) || "null");
    if (!s || now - s.last > IDLE) {
      const ref = d.referrer && new URL(d.referrer).origin != location.origin ? d.referrer.slice(0, 2048) : "";
      const q = new URLSearchParams(location.search), u = (k: string) => (q.get(k) || "").slice(0, 256);
      s = { id: hex(2), last: now, ref, utm: [u("utm_source"), u("utm_medium"), u("utm_campaign")] };
    }
    s.last = now;
    store.setItem(SKEY, JSON.stringify(s));
    return s;
  };

  const cookie = () => d.cookie.match(/(?:^|; )pawlog_cid=([0-9a-f]+)/)?.[1];
  const setCookie = (v: string, age: number) => (d.cookie = `${CKEY}=${v}; Max-Age=${age}; Path=/; SameSite=Lax${location.protocol == "https:" ? "; Secure" : ""}`);

  const layoutHash = () => {
    const el = script.dataset.layout && d.querySelector(script.dataset.layout);
    if (!el) return 0; // 0 = no layout container configured/found
    let h = 0x811c9dc5; // FNV-1a 32
    for (const c of el.className + "|" + bucket()) h = Math.imul(h ^ c.charCodeAt(0), 0x01000193);
    return h >>> 0;
  };

  let q: Ev[] = [], path = location.pathname; // path of the current view, not of location after pushState
  const flush = () => {
    while (q.length) {
      const body = JSON.stringify(q.splice(0, 20));
      if (!n.sendBeacon?.(endpoint, body)) fetch(endpoint, { method: "POST", body, keepalive: true, credentials: "omit" }).catch(noop);
    }
  };
  const send = (event: string, f: Ev = {}) => {
    const s = session(), cid = cookie();
    q.push({
      event, ts: Date.now(), site_id: site, session_id: s.id, path: path.slice(0, 2048), vw: innerWidth,
      referrer: s.ref, utm_source: s.utm[0], utm_medium: s.utm[1], utm_campaign: s.utm[2],
      layout_hash: layoutHash(), ...(cid && { cid }), ...f,
    });
    if (q.length >= 20) flush();
  };
  setInterval(flush, 5e3);

  // Per-pageview state
  let depth = 0, scrollSent = false, engaged = 0, visibleSince = d.visibilityState == "visible" ? Date.now() : 0;
  const onScroll = () => { depth = Math.max(depth, Math.min(100, Math.round(((scrollY + innerHeight) / docH()) * 100))); };
  const endView = () => {
    if (visibleSince) engaged += Date.now() - visibleSince, visibleSince = 0;
    if (engaged) send("engagement", { engaged_ms: engaged }), engaged = 0;
    if (!scrollSent) send("scroll", { scroll_depth: depth, doc_h: docH() }), scrollSent = true;
  };
  const pageview = () => {
    path = location.pathname;
    depth = 0, scrollSent = false, engaged = 0, visibleSince = d.visibilityState == "visible" ? Date.now() : 0;
    onScroll();
    send("pageview", { title: d.title.slice(0, 512) });
  };

  addEventListener("scroll", onScroll, { passive: true });
  d.addEventListener("visibilitychange", () => {
    if (d.visibilityState == "hidden") endView(), flush();
    else visibleSince = Date.now();
  });
  addEventListener("pagehide", () => { endView(); flush(); });

  // Hash-only changes fire popstate too; a pageview needs a new pathname.
  const nav = () => {
    if (location.pathname == path) return;
    endView();
    setTimeout(pageview); // let the SPA update the title first
  };
  const push = history.pushState;
  history.pushState = function (...a: Parameters<History["pushState"]>) {
    push.apply(this, a);
    nav();
  };
  addEventListener("popstate", nav);

  let rageEl: Element | null = null, rageTimes: number[] = [];
  d.addEventListener("click", (e) => {
    const el = (e.target as Element).closest?.("a,button,[data-track]");
    if (!el) return;
    const r = el.getBoundingClientRect(), now = Date.now();
    rageTimes = el == rageEl ? rageTimes.filter((t) => now - t < 1e3) : [];
    rageEl = el, rageTimes.push(now);
    const clamp = (v: number, max: number) => Math.min(max, Math.max(0, v));
    send("click", {
      selector: selector(el),
      x_rel: clamp(r.width ? (e.clientX - r.left) / r.width : 0, 1),
      y_rel: clamp(r.height ? (e.clientY - r.top) / r.height : 0, 1),
      page_x_pct: clamp((e.pageX / d.documentElement.scrollWidth) * 100, 100),
      page_y: Math.round(e.pageY), doc_h: docH(),
      ...(rageTimes.length >= 3 && { props: { rage: "1" } }),
    });
  }, true);

  api.track = (name, props = {}) =>
    send("custom", { props: Object.fromEntries([["name", name], ...Object.entries(props).map(([k, v]) => [k, String(v)])]) });
  api.consent = (on) => (on ? cookie() || setCookie(hex(4), 31536e3) : setCookie("", 0));

  pageview();
}

// Stable selector: data-track, then id, then a short class path; nth-of-type only when still ambiguous.
function selector(el: Element): string {
  const t = (el as HTMLElement).dataset.track;
  if (t) return `[data-track="${CSS.escape(t)}"]`;
  if (el.id) return "#" + CSS.escape(el.id);
  const parts: string[] = [];
  for (let e: Element | null = el; e && e != d.body && parts.length < 4; e = e.parentElement) {
    if (e.id) { parts.unshift("#" + CSS.escape(e.id)); break; }
    parts.unshift(e.tagName.toLowerCase() + Array.from(e.classList).slice(0, 2).map((c) => "." + CSS.escape(c)).join(""));
  }
  let s = parts.join(" > ");
  if (d.querySelectorAll(s).length > 1) {
    const sib = Array.from(el.parentElement!.children).filter((c) => c.tagName == el.tagName);
    s += `:nth-of-type(${sib.indexOf(el) + 1})`;
  }
  return s.slice(0, 512);
}
