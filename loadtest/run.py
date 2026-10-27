#!/usr/bin/env python3
"""Load test against the running compose stack (`make up` first).

usage: run.py [rate:seconds ...]   default: 200:60 2000:120 5000:120
Runs oha per step inside the compose network, samples collector CPU/RAM, Redpanda lag and ClickHouse every 5s,
then waits for ingestion to drain and compares events sent vs rows in ClickHouse.
Host-side by design: it only drives docker.
"""
import json, os, re, subprocess, sys, threading, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "loadtest", "results")
OHA = "ghcr.io/hatoo/oha:1.16.0"
NET = "pawlog_default"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
EVENTS_PER_REQ = 20
CONNS = 100

env = dict(l.split("=", 1) for l in open(os.path.join(ROOT, "deploy", ".env")).read().splitlines() if "=" in l and not l.startswith("#"))
steps = [tuple(map(int, a.split(":"))) for a in (sys.argv[1:] or ["200:60", "2000:120", "5000:120"])]


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout


def cid(service):
    c = sh("docker", "compose", "-f", f"{ROOT}/deploy/docker-compose.yml", "--env-file", f"{ROOT}/deploy/.env", "ps", "-q", service).strip()
    if not c:
        sys.exit(f"{service} is not running; run `make up`")
    return c


CH, RP, COL = cid("clickhouse"), cid("redpanda"), cid("collector")


def ch(sql):
    return sh("docker", "exec", CH, "clickhouse-client", "-u", env["CLICKHOUSE_USER"], "--password", env["CLICKHOUSE_PASSWORD"],
              "-d", env["CLICKHOUSE_DB"], "-q", sql).strip()


def metrics():
    text = urllib.request.urlopen(f"http://{env['COLLECTOR_PUBLISH']}/metrics", timeout=5).read().decode()
    m = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            k, v = line.rsplit(" ", 1)
            m[k] = float(v)
    return m


def hist_p(before, after, q):
    """Upper bucket bound holding quantile q of requests between two scrapes."""
    key = re.compile(r'collector_request_seconds_bucket\{le="([^"]+)"\}')
    b = sorted((float(key.match(k)[1]), after[k] - before.get(k, 0)) for k in after if key.match(k))
    total = b[-1][1]
    return next((le for le, n in b if n >= q * total), float("inf")) if total else None


def to_bytes(s):
    num, unit = re.match(r"([\d.]+)\s*([KMG]?i?B)", s).groups()
    return float(num) * {"B": 1, "KiB": 2**10, "MiB": 2**20, "GiB": 2**30, "KB": 1e3, "MB": 1e6, "GB": 1e9}[unit]


samples, stop = [], threading.Event()


def sampler(label):
    while not stop.is_set():
        t = time.time()
        cpu, mem = sh("docker", "stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", COL).strip().split("|")
        lag = re.search(r"TOTAL-LAG\s+(\d+)", sh("docker", "exec", RP, "rpk", "group", "describe", env["CLICKHOUSE_KAFKA_GROUP"], "-X", "brokers=localhost:9092"))
        rows, fresh_ms = ch("SELECT count(), dateDiff('millisecond', max(received_at), now64(3)) FROM events WHERE received_at > now() - 60").split("\t")
        samples.append({"step": label[0], "t": t, "cpu": float(cpu.rstrip("%")), "mem": to_bytes(mem.split("/")[0].strip()),
                        "lag_msgs": int(lag[1]) if lag else None, "fresh_ms": int(fresh_ms), "rows_60s": int(rows), "count": int(ch("SELECT count() FROM events"))})
        stop.wait(max(0, 5 - (time.time() - t)))


os.makedirs(OUT, exist_ok=True)
base_count = int(ch("SELECT count() FROM events"))
m0 = metrics()
label = ["idle"]
threading.Thread(target=sampler, args=(label,), daemon=True).start()
results = []
for rate, secs in steps:
    body = open(os.path.join(ROOT, "loadtest", "batch20.template.json")).read().replace("__TS__", str(int(time.time() * 1000)))
    open(os.path.join(OUT, "batch.json"), "w").write(body)
    headers = ["-H", f"Origin: {env['ALLOWED_ORIGINS'].split(',')[0]}", "-H", f"User-Agent: {UA}", "-H", "Content-Type: text/plain"]
    if env["CLIENT_IP_HEADER"]:
        headers += ["-H", f"{env['CLIENT_IP_HEADER']}: 203.0.113.9"]
    label[0] = f"{rate}/s"
    print(f"step {rate} req/s for {secs}s ...", flush=True)
    mb, t0 = metrics(), time.time()
    raw = sh("docker", "run", "--rm", "--network", NET, "-v", f"{OUT}:/lt:ro", OHA, "-z", f"{secs}s", "-q", str(rate), "-c", str(CONNS),
             "-m", "POST", *headers, "-D", "/lt/batch.json", "--no-tui", "--output-format", "json", "http://collector:8080/e")
    ma, r = metrics(), json.loads(raw)
    codes = r["statusCodeDistribution"]
    results.append({"rate": rate, "secs": secs, "rps": r["summary"]["requestsPerSec"], "p50_ms": r["latencyPercentiles"]["p50"] * 1e3,
                    "p99_ms": r["latencyPercentiles"]["p99"] * 1e3, "codes": codes, "errors": r["errorDistribution"],
                    "ok": codes.get("204", 0), "collector_p50_le_ms": hist_p(mb, ma, 0.5) * 1e3, "collector_p99_le_ms": hist_p(mb, ma, 0.99) * 1e3,
                    "t0": t0, "t1": time.time()})
    print(f"  rps={results[-1]['rps']:.0f} p99={results[-1]['p99_ms']:.2f}ms codes={codes} errors={r['errorDistribution']}", flush=True)

label[0] = "drain"
sent = sum(s["ok"] for s in results) * EVENTS_PER_REQ
deadline, got = time.time() + 180, 0
while time.time() < deadline:
    got = int(ch("SELECT count() FROM events")) - base_count
    if got >= sent:
        break
    time.sleep(1)
drain_s = time.time() - results[-1]["t1"]
stop.set()
m1 = metrics()
delta = lambda k: m1.get(k, 0) - m0.get(k, 0)

parts = {t: (int(r), int(b)) for t, r, b in (l.split("\t") for l in ch(
    "SELECT table, sum(rows), sum(bytes_on_disk) FROM system.parts WHERE active AND database = currentDatabase() GROUP BY table").splitlines())}
ev_rows, ev_bytes = parts["events"]
rollup_bytes = sum(b for t, (r, b) in parts.items() if t != "events")

print("\n| step | duration | RPS | p50 ms | p99 ms | collector p99 ≤ | non-204 | errors | collector CPU avg/max | RAM max | lag max msgs | freshness max s | CH insert rows/s |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for s in results:
    ss = [x for x in samples if x["step"] == f"{s['rate']}/s"]
    ins = (ss[-1]["count"] - ss[0]["count"]) / (ss[-1]["t"] - ss[0]["t"]) if len(ss) > 1 else 0
    non204 = sum(v for k, v in s["codes"].items() if k != "204")
    print(f"| {s['rate']}/s | {s['secs']}s | {s['rps']:.0f} | {s['p50_ms']:.2f} | {s['p99_ms']:.2f} | {s['collector_p99_le_ms']:g} ms | {non204} | "
          f"{sum(s['errors'].values())} | {sum(x['cpu'] for x in ss) / max(len(ss), 1):.0f}% / {max((x['cpu'] for x in ss), default=0):.0f}% | "
          f"{max((x['mem'] for x in ss), default=0) / 2**20:.0f} MiB | {max((x['lag_msgs'] or 0 for x in ss), default=0)} | "
          f"{max((x['fresh_ms'] for x in ss), default=0) / 1e3:.1f} | {ins:,.0f} |")
print(f"\nsent events {sent:,} · in ClickHouse {got:,} · dropped {sent - got:,} · drain {drain_s:.1f}s after last request")
print(f"collector: delivered ok {delta('collector_delivered_events_total{result=\"ok\"}'):,.0f} · delivery errors {delta('collector_delivered_events_total{result=\"error\"}'):,.0f} · "
      f"queue full {delta('collector_queue_full_total'):,.0f}")
print(f"disk: events {ev_bytes / ev_rows * 1e6 / 2**20:.1f} MiB per 1M events ({ev_rows:,} rows, {ev_bytes / 2**20:.0f} MiB) · rollups total {rollup_bytes / 2**20:.0f} MiB")

gate = next((s for s in results if s["rate"] == 2000), None)
checks = {
    "2k req/s p99 < 10 ms (client)": gate is not None and gate["p99_ms"] < 10,
    "2k req/s p99 < 10 ms (collector)": gate is not None and gate["collector_p99_le_ms"] <= 10,
    "2k req/s sustained (rps >= 1980, all 204)": gate is not None and gate["rps"] >= 1980 and gate["ok"] == sum(gate["codes"].values()) and not gate["errors"],
    "0 dropped events": got == sent,
    "lag < 5 s": max((x["fresh_ms"] for x in samples if x["step"] not in ("idle", "drain")), default=1e9) < 5000 and drain_s < 5,
}
for k, v in checks.items():
    print(f"{'PASS' if v else 'FAIL'} {k}")
json.dump({"steps": results, "samples": samples, "sent": sent, "got": got, "parts": parts, "checks": checks},
          open(os.path.join(OUT, f"load-{int(time.time())}.json"), "w"), indent=1)
sys.exit(0 if all(checks.values()) else 1)
