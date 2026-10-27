use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::net::IpAddr;

pub const MAX_EVENTS: usize = 50;
const MAX_PAST_MS: i64 = 24 * 3_600_000;
const MAX_FUTURE_MS: i64 = 5 * 60_000;

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Pageview,
    Click,
    Scroll,
    Engagement,
    Custom,
}

/// One event as sent by pawlog.js. Everything server-derived is absent on purpose.
#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct In {
    pub event: Kind,
    pub ts: i64,
    pub site_id: String,
    /// 16 hex chars (64-bit, JS can't carry u64 as a number)
    pub session_id: String,
    /// Consent-gated cookie id; absent = cookieless
    #[serde(default)]
    pub cid: Option<String>,
    pub path: String,
    pub vw: u16,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub referrer: String,
    #[serde(default)]
    pub utm_source: String,
    #[serde(default)]
    pub utm_medium: String,
    #[serde(default)]
    pub utm_campaign: String,
    #[serde(default)]
    pub selector: String,
    #[serde(default)]
    pub x_rel: f32,
    #[serde(default)]
    pub y_rel: f32,
    #[serde(default)]
    pub page_x_pct: f32,
    #[serde(default)]
    pub page_y: u32,
    #[serde(default)]
    pub doc_h: u32,
    #[serde(default)]
    pub scroll_depth: u8,
    #[serde(default)]
    pub engaged_ms: u32,
    #[serde(default)]
    pub layout_hash: u64,
    #[serde(default)]
    pub props: HashMap<String, String>,
}

/// Parse + validate a request body. `Err` is the metrics reason label.
pub fn parse_batch(body: &[u8], now_ms: i64) -> Result<Vec<In>, &'static str> {
    let mut batch: Vec<In> = serde_json::from_slice(body).map_err(|_| "json")?;
    if batch.is_empty() || batch.len() > MAX_EVENTS {
        return Err("count");
    }
    for e in &mut batch {
        if e.ts < now_ms - MAX_PAST_MS || e.ts > now_ms + MAX_FUTURE_MS {
            return Err("ts");
        }
        e.ts = e.ts.min(now_ms);
        validate(e)?;
    }
    Ok(batch)
}

fn validate(e: &In) -> Result<(), &'static str> {
    let len = |s: &str, max: usize| s.len() <= max;
    let ok = !e.site_id.is_empty()
        && len(&e.site_id, 64)
        && e.session_id.len() == 16
        && u64::from_str_radix(&e.session_id, 16).is_ok()
        && e.cid.as_deref().is_none_or(|c| !c.is_empty() && len(c, 128))
        && e.path.starts_with('/')
        && len(&e.path, 2048)
        && e.vw > 0
        && len(&e.title, 512)
        && len(&e.referrer, 2048)
        && len(&e.utm_source, 256)
        && len(&e.utm_medium, 256)
        && len(&e.utm_campaign, 256)
        && len(&e.selector, 512)
        && (0.0..=1.0).contains(&e.x_rel)
        && (0.0..=1.0).contains(&e.y_rel)
        && (0.0..=100.0).contains(&e.page_x_pct)
        && e.scroll_depth <= 100
        && e.props.len() <= 32
        && e.props.iter().all(|(k, v)| !k.is_empty() && len(k, 64) && len(v, 512));
    if ok { Ok(()) } else { Err("field") }
}

pub struct Ua {
    pub browser: String,
    pub os: String,
    pub device: &'static str,
    pub bot: bool,
}

const BOT_MARKERS: &[&str] = &[
    "bot", "crawl", "spider", "slurp", "headless", "phantomjs", "puppeteer", "playwright",
    "selenium", "lighthouse", "curl/", "wget/", "python-requests", "python-urllib", "aiohttp",
    "go-http-client", "java/", "okhttp", "axios/", "node-fetch", "scrapy", "httpclient",
    "facebookexternalhit",
];

pub fn parse_ua(ua: &str) -> Ua {
    let r = woothee::parser::Parser::new().parse(ua);
    let lower = ua.to_ascii_lowercase();
    let bot = ua.is_empty()
        || r.as_ref().is_some_and(|r| r.category == "crawler")
        || BOT_MARKERS.iter().any(|m| lower.contains(m));
    let known = |s: &str| if s == woothee::woothee::VALUE_UNKNOWN { String::new() } else { s.to_owned() };
    let tablet = ua.contains("iPad") || ua.contains("Tablet") || (ua.contains("Android") && !ua.contains("Mobile"));
    let device = match r.as_ref().map(|r| r.category) {
        Some("smartphone" | "mobilephone") if tablet => "tablet",
        Some("smartphone" | "mobilephone") => "mobile",
        Some("pc") => "desktop",
        _ => "",
    };
    Ua {
        browser: r.as_ref().map_or_else(String::new, |r| known(r.name)),
        os: r.as_ref().map_or_else(String::new, |r| known(r.os)),
        device,
        bot,
    }
}

#[derive(Default)]
pub struct Geo {
    pub country: String,
    pub region: String,
    pub city: String,
}

/// Per-request context shared by every event in the batch.
pub struct Ctx<'a> {
    pub received_at: i64,
    pub ip: IpAddr,
    pub ua: &'a str,
    pub parsed: &'a Ua,
    pub geo: &'a Geo,
    pub salt: [u8; 32],
}

/// sha256(ip, ua, site_id, daily_salt) truncated to the UInt64 visitor_id column.
pub fn ip_hash(ip: IpAddr, ua: &str, site_id: &str, salt: &[u8; 32]) -> u64 {
    let mut h = Sha256::new();
    for part in [ip.to_string().as_bytes(), ua.as_bytes(), site_id.as_bytes()] {
        h.update(part);
        h.update([0]);
    }
    h.update(salt);
    first_u64(h.finalize().as_slice())
}

fn cid_hash(cid: &str) -> u64 {
    first_u64(Sha256::digest(cid.as_bytes()).as_slice())
}

fn first_u64(d: &[u8]) -> u64 {
    u64::from_be_bytes(d[..8].try_into().unwrap())
}

pub fn vw_bucket(vw: u16) -> &'static str {
    match vw {
        0..768 => "mobile",
        768..1024 => "tablet",
        _ => "desktop",
    }
}

pub fn ref_domain(referrer: &str) -> String {
    let Some((_, rest)) = referrer.split_once("://") else { return String::new() };
    let host = rest.split(['/', '?', '#', ':']).next().unwrap_or("").to_ascii_lowercase();
    host.strip_prefix("www.").map(str::to_owned).unwrap_or(host)
}

/// Unix ms -> ClickHouse DateTime64(3) text, UTC.
pub fn fmt_ms(ms: i64) -> String {
    let (days, rem) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    // Howard Hinnant's civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (m <= 2) as i64;
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}.{:03}",
        rem / 3_600_000, rem / 60_000 % 60, rem / 1000 % 60, rem % 1000
    )
}

#[derive(Serialize)]
struct Out<'a> {
    ts: String,
    received_at: &'a str,
    site_id: &'a str,
    event: Kind,
    visitor_id: u64,
    session_id: u64,
    path: &'a str,
    title: &'a str,
    referrer: &'a str,
    ref_domain: String,
    utm_source: &'a str,
    utm_medium: &'a str,
    utm_campaign: &'a str,
    country: &'a str,
    region: &'a str,
    city: &'a str,
    browser: &'a str,
    os: &'a str,
    device: &'a str,
    vw: u16,
    vw_bucket: &'static str,
    selector: &'a str,
    x_rel: f32,
    y_rel: f32,
    page_x_pct: f32,
    page_y: u32,
    doc_h: u32,
    scroll_depth: u8,
    engaged_ms: u32,
    layout_hash: u64,
    props: &'a HashMap<String, String>,
}

/// Enriched JSONEachRow payload: one line per event.
pub fn enrich(batch: &[In], c: &Ctx) -> Vec<u8> {
    let received_at = fmt_ms(c.received_at);
    let mut buf = Vec::with_capacity(batch.len() * 512);
    for e in batch {
        let visitor_id = match &e.cid {
            Some(cid) => cid_hash(cid),
            None => ip_hash(c.ip, c.ua, &e.site_id, &c.salt),
        };
        let row = Out {
            ts: fmt_ms(e.ts),
            received_at: &received_at,
            site_id: &e.site_id,
            event: e.event,
            visitor_id,
            session_id: u64::from_str_radix(&e.session_id, 16).unwrap(), // validated
            path: &e.path,
            title: &e.title,
            referrer: &e.referrer,
            ref_domain: ref_domain(&e.referrer),
            utm_source: &e.utm_source,
            utm_medium: &e.utm_medium,
            utm_campaign: &e.utm_campaign,
            country: &c.geo.country,
            region: &c.geo.region,
            city: &c.geo.city,
            browser: &c.parsed.browser,
            os: &c.parsed.os,
            device: c.parsed.device,
            vw: e.vw,
            vw_bucket: vw_bucket(e.vw),
            selector: &e.selector,
            x_rel: e.x_rel,
            y_rel: e.y_rel,
            page_x_pct: e.page_x_pct,
            page_y: e.page_y,
            doc_h: e.doc_h,
            scroll_depth: e.scroll_depth,
            engaged_ms: e.engaged_ms,
            layout_hash: e.layout_hash,
            props: &e.props,
        };
        serde_json::to_writer(&mut buf, &row).unwrap();
        buf.push(b'\n');
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_793_000_000_000;
    const CHROME: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
    const IPHONE: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";
    const IPAD: &str = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";

    fn ev(extra: &str) -> String {
        format!(r#"{{"event":"pageview","ts":{NOW},"site_id":"s1","session_id":"00000000000000ff","path":"/a","vw":1280{extra}}}"#)
    }
    fn batch(items: &[String]) -> Vec<u8> {
        format!("[{}]", items.join(",")).into_bytes()
    }

    #[test]
    fn accepts_valid() {
        let b = parse_batch(&batch(&[ev("")]), NOW).unwrap();
        assert_eq!(b[0].event, Kind::Pageview);
    }

    #[test]
    fn rejects_bad_input() {
        let cases: &[(Vec<u8>, &str)] = &[
            (b"{nope".to_vec(), "json"),
            (b"[]".to_vec(), "count"),
            (batch(&vec![ev(""); 51]), "count"),
            (batch(&[ev("").replace("pageview", "purchase")]), "json"),
            (batch(&[ev(r#","bogus":1"#)]), "json"),
            (batch(&[ev("").replace(&NOW.to_string(), &(NOW - MAX_PAST_MS - 1).to_string())]), "ts"),
            (batch(&[ev("").replace(&NOW.to_string(), &(NOW + MAX_FUTURE_MS + 1).to_string())]), "ts"),
            (batch(&[ev("").replace("00000000000000ff", "xyz")]), "field"),
            (batch(&[ev("").replace(r#""/a""#, r#""a""#)]), "field"),
            (batch(&[ev(r#","x_rel":1.5"#)]), "field"),
            (batch(&[ev(r#","scroll_depth":101"#)]), "field"),
        ];
        for (body, reason) in cases {
            assert_eq!(parse_batch(body, NOW).err(), Some(*reason), "{}", String::from_utf8_lossy(body));
        }
    }

    #[test]
    fn clamps_small_future_skew() {
        let b = parse_batch(&batch(&[ev("").replace(&NOW.to_string(), &(NOW + 60_000).to_string())]), NOW).unwrap();
        assert_eq!(b[0].ts, NOW);
    }

    #[test]
    fn ua_and_device() {
        let c = parse_ua(CHROME);
        assert_eq!((c.browser.as_str(), c.os.as_str(), c.device, c.bot), ("Chrome", "Windows 10", "desktop", false));
        assert_eq!(parse_ua(IPHONE).device, "mobile");
        assert_eq!(parse_ua(IPAD).device, "tablet");
    }

    #[test]
    fn bot_filter() {
        for ua in [
            "",
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/130.0.0.0 Safari/537.36",
            "curl/8.5.0",
            "python-requests/2.32",
        ] {
            assert!(parse_ua(ua).bot, "{ua}");
        }
        assert!(!parse_ua(CHROME).bot && !parse_ua(IPHONE).bot);
    }

    #[test]
    fn ip_hash_changes_with_salt_rotation() {
        let salt = crate::salt::DailySalt::default();
        let ip: IpAddr = "203.0.113.7".parse().unwrap();
        let day = NOW - NOW.rem_euclid(crate::salt::DAY_MS);
        let a = ip_hash(ip, CHROME, "s1", &salt.get(day));
        assert_eq!(a, ip_hash(ip, CHROME, "s1", &salt.get(day + 3_600_000)));
        assert_ne!(a, ip_hash(ip, CHROME, "s1", &salt.get(day + crate::salt::DAY_MS)));
        assert_ne!(a, ip_hash(ip, CHROME, "s2", &salt.get(day)));
    }

    #[test]
    fn enrich_rows() {
        let b = parse_batch(
            &batch(&[
                ev(r#","referrer":"https://www.Google.com/search?q=x""#).replace(r#""vw":1280"#, r#""vw":500"#),
                ev(r#","cid":"abc""#),
            ]),
            NOW,
        )
        .unwrap();
        let ua = parse_ua(CHROME);
        let geo = Geo { country: "DE".into(), ..Default::default() };
        let ctx = Ctx { received_at: NOW, ip: "203.0.113.7".parse().unwrap(), ua: CHROME, parsed: &ua, geo: &geo, salt: [7; 32] };
        let out = String::from_utf8(enrich(&b, &ctx)).unwrap();
        assert!(!out.contains("203.0.113.7"));
        let rows: Vec<serde_json::Value> = out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["ref_domain"], "google.com");
        assert_eq!(rows[0]["vw_bucket"], "mobile");
        assert_eq!(rows[0]["session_id"], 255);
        assert_eq!(rows[0]["country"], "DE");
        assert_eq!(rows[0]["browser"], "Chrome");
        assert_eq!(rows[0]["visitor_id"], ip_hash(ctx.ip, CHROME, "s1", &[7; 32]));
        assert_eq!(rows[1]["visitor_id"], cid_hash("abc"));
        assert_eq!(rows[0]["ts"], fmt_ms(NOW));
    }

    #[test]
    fn fmt_ms_utc() {
        assert_eq!(fmt_ms(0), "1970-01-01 00:00:00.000");
        assert_eq!(fmt_ms(951_782_400_123), "2000-02-29 00:00:00.123");
        assert_eq!(fmt_ms(1_793_000_000_000), "2026-10-26 07:33:20.000");
    }
}
