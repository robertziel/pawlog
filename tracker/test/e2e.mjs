// Browser test for pawlog.js against a stub collector. Runs in the Playwright image (`make test-tracker`).
import { test, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import { chromium } from "playwright";

const root = new URL("..", import.meta.url).pathname;
const SITE = "http://127.0.0.1:4101", DASH = "http://127.0.0.1:4102", COLLECTOR = "http://127.0.0.1:4103";
let batches = [];

const serve = (port, handler) => new Promise((ok) => http.createServer(handler).listen(port, "127.0.0.1", ok));
const demo = () => fs.readFileSync(root + "demo.html", "utf8").replaceAll("PAWLOG_SRC", COLLECTOR + "/pawlog.js").replaceAll("PAWLOG_DASHBOARD", DASH);
await serve(4101, (req, res) => res.writeHead(200, { "content-type": "text/html" }).end(demo()));
await serve(4102, (req, res) =>
  res.writeHead(200, { "content-type": "text/html" }).end(`<iframe id="f" src="${SITE}/demo.html#pawlog-heatmap" width="1280" height="800"></iframe>`));
await serve(4103, (req, res) => {
  if (req.url == "/pawlog.js") return res.writeHead(200, { "content-type": "application/javascript" }).end(fs.readFileSync(root + "dist/pawlog.js"));
  let body = "";
  req.on("data", (c) => (body += c)).on("end", () => {
    if (req.method == "POST" && req.url == "/e") batches.push(JSON.parse(body));
    res.writeHead(204, { "access-control-allow-origin": req.headers.origin || "*" }).end();
  });
});

const browser = await chromium.launch();
setTimeout(() => { console.error("suite timeout"); process.exit(1); }, 90e3).unref();
after(() => browser.close().then(() => process.exit(0)));
const events = () => batches.flat();
const until = async (pred, ms = 8000) => {
  for (const end = Date.now() + ms; Date.now() < end; await new Promise((r) => setTimeout(r, 100))) if (pred()) return;
  assert.fail("timed out; got " + JSON.stringify(events().map((e) => e.event)));
};
async function open(init) {
  batches = [];
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  if (init) await ctx.addInitScript(init);
  const page = await ctx.newPage();
  await page.goto(SITE + "/demo.html?utm_source=news&utm_medium=email", { referer: "https://www.google.com/" });
  return page;
}
const close = async (page) => { await page.close({ runBeforeUnload: true }); await new Promise((r) => setTimeout(r, 300)); };

test("pageview, clicks, rage, scroll, engagement, SPA nav", async () => {
  const page = await open();
  await page.click("#cta");
  await page.click("[data-track=share]");
  await page.click("nav a:nth-child(3)");
  for (let i = 0; i < 3; i++) await page.click("#footer-link");
  await page.mouse.wheel(0, 5000);
  await page.waitForTimeout(200);
  await page.click("#spa");
  await page.waitForTimeout(100);
  await close(page);
  await until(() => events().filter((e) => e.event == "pageview").length == 2 && events().filter((e) => e.event == "scroll").length == 2);

  const ev = events();
  const pv = ev.filter((e) => e.event == "pageview");
  assert.equal(pv[0].path, "/demo.html");
  assert.equal(pv[0].title, "pawlog demo");
  assert.equal(pv[1].path, "/article/2");
  assert.equal(pv[1].title, "Article 2");
  assert.match(pv[0].session_id, /^[0-9a-f]{16}$/);
  assert.ok(ev.every((e) => e.session_id == pv[0].session_id && e.site_id == "demo" && e.vw == 1280));
  assert.ok(ev.every((e) => e.referrer == "https://www.google.com/" && e.utm_source == "news" && e.utm_medium == "email"));
  assert.ok(pv[0].layout_hash > 0 && !("cid" in pv[0]));

  const clicks = ev.filter((e) => e.event == "click");
  assert.deepEqual(clicks.slice(0, 3).map((c) => c.selector), ["#cta", '[data-track="share"]', "main.layout-article > nav.menu > a.nav-item:nth-of-type(3)"]);
  for (const c of clicks) {
    assert.ok(c.x_rel >= 0 && c.x_rel <= 1 && c.y_rel >= 0 && c.y_rel <= 1, JSON.stringify(c));
    assert.ok(c.page_x_pct > 0 && c.page_x_pct <= 100 && c.page_y > 0 && c.doc_h > 2400);
  }
  const footer = clicks.filter((c) => c.selector == "#footer-link");
  assert.deepEqual(footer.map((c) => c.props?.rage), [undefined, undefined, "1"]);

  const scroll = ev.filter((e) => e.event == "scroll");
  assert.equal(scroll[0].path, "/demo.html");
  assert.ok(scroll[0].scroll_depth >= 99, "depth " + scroll[0].scroll_depth);
  const eng = ev.filter((e) => e.event == "engagement");
  assert.ok(eng.length >= 2 && eng.every((e) => e.engaged_ms > 0));
  assert.ok(batches.every((b) => b.length <= 20));
});

test("flush at 20 events without waiting for the timer", async () => {
  const page = await open();
  await page.evaluate(() => { for (let i = 0; i < 25; i++) analytics.track("t" + i); });
  await until(() => batches.some((b) => b.length == 20), 1000);
  await close(page);
});

test("5s timer flush", async () => {
  const page = await open();
  await until(() => events().some((e) => e.event == "pageview"), 7000);
  await close(page);
});

test("track() and consent toggle", async () => {
  const page = await open();
  await page.click("#custom");
  await page.click("#consent");
  await page.click("#cta");
  await page.click("#revoke");
  await page.click("[data-track=share]");
  await close(page);
  await until(() => events().filter((e) => e.event == "click").length == 5);
  const custom = events().find((e) => e.event == "custom");
  assert.deepEqual(custom.props, { name: "signup", plan: "pro" });
  const byId = (s) => events().filter((e) => e.event == "click" && e.selector == s);
  assert.match(byId("#cta")[0].cid, /^[0-9a-f]{32}$/);
  assert.ok(!("cid" in byId('[data-track="share"]')[0]));
});

for (const [name, init] of [
  ["GPC", () => Object.defineProperty(navigator, "globalPrivacyControl", { get: () => true })],
  ["DNT", () => Object.defineProperty(navigator, "doNotTrack", { get: () => "1" })],
]) {
  test(`${name} disables tracking`, async () => {
    const page = await open(init);
    await page.click("#cta");
    await page.evaluate(() => analytics.track("x"));
    await close(page);
    await new Promise((r) => setTimeout(r, 1000));
    assert.equal(events().length, 0);
  });
}

test("heatmap mode answers rects for the dashboard origin and does not track", async () => {
  batches = [];
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  await page.goto(DASH + "/");
  const frame = page.frameLocator("#f");
  await frame.locator("#cta").waitFor();
  await page.waitForTimeout(300);
  const reply = await page.evaluate(() => new Promise((ok) => {
    addEventListener("message", (e) => e.data?.pawlog == "rects" && ok(e.data));
    document.getElementById("f").contentWindow.postMessage({ pawlog: "rects", sels: ["#cta", "#nope", "!!bad"] }, "*");
  }));
  assert.equal(reply.rects.length, 3);
  assert.ok(reply.rects[0][2] > 0 && reply.rects[0][3] > 0);
  assert.deepEqual(reply.rects.slice(1), [null, null]);
  assert.ok(reply.docH > 2400);
  await page.close();
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(events().length, 0);
});
