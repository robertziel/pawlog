//! Needs a broker: TEST_KAFKA_BROKERS=host:port (`make test` starts one).
use std::net::SocketAddr;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use collector::{serve, App, Config};
use metrics_exporter_prometheus::PrometheusBuilder;
use rdkafka::admin::{AdminClient, AdminOptions, NewTopic, TopicReplication};
use rdkafka::consumer::{BaseConsumer, Consumer};
use rdkafka::{ClientConfig, Message};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const ORIGIN: &str = "https://site.test";
const CHROME: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

async fn http(addr: SocketAddr, method: &str, path: &str, headers: &[(&str, &str)], body: &str) -> u16 {
    let mut s = TcpStream::connect(addr).await.unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {}\r\n", body.len());
    for (k, v) in headers {
        req += &format!("{k}: {v}\r\n");
    }
    req += "\r\n";
    req += body;
    s.write_all(req.as_bytes()).await.unwrap();
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await.unwrap();
    String::from_utf8_lossy(&buf[9..12]).parse().unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn post_batch_lands_in_topic() {
    let brokers = std::env::var("TEST_KAFKA_BROKERS").expect("TEST_KAFKA_BROKERS");
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64;
    let topic = format!("events_test_{now}");
    let admin: AdminClient<_> = ClientConfig::new().set("bootstrap.servers", &brokers).create().unwrap();
    let r = admin.create_topics(&[NewTopic::new(&topic, 1, TopicReplication::Fixed(1))], &AdminOptions::new()).await.unwrap();
    assert!(r[0].is_ok(), "{r:?}");

    let js = std::env::temp_dir().join("pawlog.js");
    std::fs::write(&js, "/*pawlog*/").unwrap();
    let cfg = Config {
        listen_addr: "127.0.0.1:0".parse().unwrap(),
        brokers: brokers.clone(),
        topic: topic.clone(),
        allowed_origins: vec![ORIGIN.into()],
        queue_max_messages: 1000,
        pawlog_js_path: js.to_string_lossy().into(),
        geoip_db_path: None,
        client_ip_header: Some("x-forwarded-for".try_into().unwrap()),
    };
    let app = App::new(cfg, PrometheusBuilder::new().install_recorder().unwrap()).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(serve(listener, app, std::future::pending()));

    let deadline = Instant::now() + Duration::from_secs(30);
    while http(addr, "GET", "/healthz", &[], "").await != 200 {
        assert!(Instant::now() < deadline, "healthz never 200");
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    let ev = |kind: &str, path: &str| {
        format!(r#"{{"event":"{kind}","ts":{now},"site_id":"s1","session_id":"00000000000000ff","path":"{path}","vw":1280,"referrer":"https://www.google.com/"}}"#)
    };
    let body = format!("[{},{},{}]", ev("pageview", "/a"), ev("click", "/a"), ev("scroll", "/b"));
    let xff = ("X-Forwarded-For", "10.0.0.1, 203.0.113.7");
    let good = [("Origin", ORIGIN), ("User-Agent", CHROME), xff];

    assert_eq!(http(addr, "POST", "/e", &[("Origin", "https://evil.test"), ("User-Agent", CHROME), xff], &body).await, 403);
    assert_eq!(http(addr, "POST", "/e", &[("Origin", ORIGIN), ("User-Agent", "curl/8.5.0"), xff], &body).await, 204);
    assert_eq!(http(addr, "POST", "/e", &good, "[]").await, 400);
    assert_eq!(http(addr, "POST", "/e", &good, &"x".repeat(collector::MAX_BODY + 1)).await, 413);
    assert_eq!(http(addr, "OPTIONS", "/e", &[("Origin", ORIGIN)], "").await, 204);
    assert_eq!(http(addr, "GET", "/pawlog.js", &[], "").await, 200);
    assert_eq!(http(addr, "POST", "/e", &good, &body).await, 204);

    let consumer: BaseConsumer = ClientConfig::new()
        .set("bootstrap.servers", &brokers)
        .set("group.id", &topic)
        .set("auto.offset.reset", "earliest")
        .create()
        .unwrap();
    consumer.subscribe(&[&topic]).unwrap();
    let mut payloads = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    // Poll past the first message so a leaked bot/rejected batch would show up too.
    while Instant::now() < deadline && (payloads.is_empty() || Instant::now() + Duration::from_secs(17) < deadline) {
        if let Some(m) = consumer.poll(Duration::from_millis(500)) {
            payloads.push(String::from_utf8(m.unwrap().payload().unwrap().to_vec()).unwrap());
        }
    }
    assert_eq!(payloads.len(), 1, "{payloads:?}");
    let p = &payloads[0];
    assert!(!p.contains("203.0.113.7") && !p.contains("10.0.0.1"), "raw ip leaked");
    let rows: Vec<serde_json::Value> = p.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(rows.len(), 3);
    assert_eq!(rows.iter().map(|r| r["event"].as_str().unwrap()).collect::<Vec<_>>(), ["pageview", "click", "scroll"]);
    assert_eq!(rows[2]["path"], "/b");
    for r in &rows {
        assert_eq!(r["browser"], "Chrome");
        assert_eq!(r["device"], "desktop");
        assert_eq!(r["vw_bucket"], "desktop");
        assert_eq!(r["ref_domain"], "google.com");
        assert_eq!(r["session_id"], 255);
        assert_eq!(r["site_id"], "s1");
        assert_eq!(r["visitor_id"], rows[0]["visitor_id"]);
        assert_ne!(r["visitor_id"], 0);
    }
}
