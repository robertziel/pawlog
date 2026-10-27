// Real browser -> real collector -> Redpanda -> ClickHouse (`make e2e`, stack must be up).
// env: COLLECTOR, CLICKHOUSE, CH_DB, CH_USER, CH_PASSWORD, ORIGIN_HOST (a host in deploy/sites.yml, resolving here), DASHBOARD, ADMIN_EMAIL, ADMIN_PASSWORD
import { test, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import { chromium } from "playwright";

const { COLLECTOR, CLICKHOUSE, CH_DB, CH_USER, CH_PASSWORD, ORIGIN_HOST, DASHBOARD, ADMIN_EMAIL, ADMIN_PASSWORD } = process.env;
assert.ok(COLLECTOR && CLICKHOUSE && CH_DB && CH_USER && CH_PASSWORD && ORIGIN_HOST && DASHBOARD && ADMIN_EMAIL && ADMIN_PASSWORD, "missing env");
const CHROME = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
const page_ = fs.readFileSync(new URL("../demo.html", import.meta.url), "utf8").replaceAll("PAWLOG_SRC", COLLECTOR + "/pawlog.js").replaceAll("PAWLOG_DASHBOARD", DASHBOARD);
const server = http.createServer((q, s) => s.writeHead(200, { "content-type": "text/html" }).end(page_));
await new Promise((ok) => server.listen(80, ok));

const ch = async (sql) => {
  const r = await fetch(`${CLICKHOUSE}/?default_format=JSONEachRow&database=${CH_DB}`, { method: "POST", body: sql, headers: { "X-ClickHouse-User": CH_USER, "X-ClickHouse-Key": CH_PASSWORD } });
  assert.equal(r.status, 200, await r.clone().text());
  return (await r.text()).trim().split("\n").filter(Boolean).map(JSON.parse);
};

// non-2xx responses the collector has served so far, keyed by status
const errors = async () => Object.fromEntries((await (await fetch(COLLECTOR + "/metrics")).text()).split("\n")
  .map((l) => l.match(/^collector_requests_total\{status="(\d+)"\} (\d+)/)).filter((m) => m && !["200", "204"].includes(m[1])).map((m) => [m[1], +m[2]]));

after(() => { server.closeAllConnections(); server.close(); });
test("events from a real page land in ClickHouse and rollups", async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ userAgent: CHROME, viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  const before = await errors();
  await page.goto(`http://${ORIGIN_HOST}/demo.html?utm_source=e2e`, { referer: "https://news.example.org/x" });
  const sid = await page.evaluate(() => JSON.parse(sessionStorage.pawlog_s).id);
  await page.click("#cta");
  await page.click("#custom");
  await page.mouse.wheel(0, 5000);
  await page.waitForTimeout(300);
  await page.click("#spa");
  await page.waitForTimeout(200);
  await page.close({ runBeforeUnload: true });
  await new Promise((r) => setTimeout(r, 500));
  await browser.close();
  assert.deepEqual(await errors(), before, "collector returned non-2xx");

  const session = BigInt("0x" + sid).toString();
  let rows = [];
  for (const end = Date.now() + 20e3; Date.now() < end && rows.length < 5; await new Promise((r) => setTimeout(r, 500)))
    rows = await ch(`SELECT event, count() AS n FROM events WHERE session_id = ${session} GROUP BY event ORDER BY event`);
  const n = Object.fromEntries(rows.map((r) => [r.event, +r.n]));
  assert.deepEqual({ pageview: n.pageview, click: n.click, custom: n.custom, scroll: n.scroll }, { pageview: 2, click: 3, custom: 1, scroll: 2 });
  assert.ok(n.engagement >= 1);

  const [s] = await ch(`SELECT sum(pageviews) AS pv, argMinMerge(entry_path) AS entry, argMaxMerge(exit_path) AS exit, any(ref_domain) AS ref, any(browser) AS browser
                        FROM sessions WHERE session_id = ${session}`);
  assert.deepEqual({ ...s, pv: +s.pv }, { pv: 2, entry: "/demo.html", exit: "/article/2", ref: "news.example.org", browser: "Chrome" });
  const [src] = await ch(`SELECT uniqMerge(visits) AS v FROM sources_daily WHERE site_id = 'demo' AND ref_domain = 'news.example.org' AND utm_source = 'e2e'`);
  assert.ok(+src.v >= 1);
  const [el] = await ch(`SELECT sum(clicks) AS c FROM click_elements WHERE site_id = 'demo' AND selector = '#cta'`);
  assert.ok(+el.c >= 1);
});

test("dashboard heatmap frames the page and draws every mode", async () => {
  const browser = await chromium.launch();
  try {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  await page.goto(DASHBOARD + "/session/new");
  await page.fill("input[name=email_address]", ADMIN_EMAIL);
  await page.fill("input[name=password]", ADMIN_PASSWORD);
  await page.click("input[type=submit]");
  await page.waitForURL(DASHBOARD + "/");
  const site = (await ch(`SELECT site_id FROM events WHERE path = '/demo.html' LIMIT 1`))[0].site_id;
  const today = new Date().toISOString().slice(0, 10);
  fs.mkdirSync("test-results", { recursive: true });
  for (const mode of ["grid", "elements", "scroll"]) {
    await page.goto(`${DASHBOARD}/heatmap?site=${site}&path=/demo.html&vw=desktop&mode=${mode}&from=${today}&to=${today}`);
    await page.waitForFunction(() => document.getElementById("heatmap-status").textContent === "", null, { timeout: 15e3 });
    const painted = await page.evaluate(() => {
      const c = document.querySelector("#heatmap canvas"), d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
      let n = 0;
      for (let i = 3; i < d.length; i += 4) if (d[i]) n++;
      return { n, h: c.height };
    });
    assert.ok(painted.h > 2400 && painted.n > 0, `${mode}: ${JSON.stringify(painted)}`);
    await page.screenshot({ path: `test-results/heatmap-${mode}.png`, fullPage: false });
  }
  } finally { await browser.close(); }
});
