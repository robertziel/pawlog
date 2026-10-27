pub mod event;
pub mod salt;

use std::convert::Infallible;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{self, HeaderMap, HeaderName, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::server::graceful::GracefulShutdown;
use metrics::{counter, histogram};
use metrics_exporter_prometheus::PrometheusHandle;
use rdkafka::error::{KafkaError, RDKafkaErrorCode};
use rdkafka::producer::{BaseRecord, DeliveryResult, Producer, ProducerContext, ThreadedProducer};
use rdkafka::{ClientConfig, ClientContext};
use tokio::net::TcpListener;
use tracing::{error, info, warn};

pub const MAX_BODY: usize = 64 * 1024;
const BODY_TIMEOUT: Duration = Duration::from_secs(10);

pub struct Config {
    pub listen_addr: SocketAddr,
    pub brokers: String,
    pub topic: String,
    pub allowed_origins: Vec<String>,
    pub queue_max_messages: u32,
    pub pawlog_js_path: String,
    pub geoip_db_path: Option<String>,
    pub client_ip_header: Option<HeaderName>,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        // Every var must be present; optional features are disabled only by an explicit empty value.
        let var = |k: &str| std::env::var(k).map_err(|_| format!("missing env {k}"));
        let req = |k: &str| var(k).and_then(|v| if v.is_empty() { Err(format!("empty env {k}")) } else { Ok(v) });
        let opt = |k: &str| var(k).map(|v| Some(v).filter(|v| !v.is_empty()));
        let bad = |k: &str, e: &dyn std::fmt::Display| format!("bad env {k}: {e}");
        Ok(Self {
            listen_addr: req("LISTEN_ADDR")?.parse().map_err(|e| bad("LISTEN_ADDR", &e))?,
            brokers: req("KAFKA_BROKERS")?,
            topic: req("KAFKA_TOPIC")?,
            allowed_origins: req("ALLOWED_ORIGINS")?.split(',').map(|s| s.trim().to_owned()).collect(),
            queue_max_messages: req("QUEUE_MAX_MESSAGES")?.parse().map_err(|e| bad("QUEUE_MAX_MESSAGES", &e))?,
            pawlog_js_path: req("PAWLOG_JS_PATH")?,
            geoip_db_path: opt("GEOIP_DB_PATH")?,
            client_ip_header: opt("CLIENT_IP_HEADER")?
                .map(|h| HeaderName::try_from(h).map_err(|e| bad("CLIENT_IP_HEADER", &e)))
                .transpose()?,
        })
    }
}

pub struct DeliveryCtx;
impl ClientContext for DeliveryCtx {}
impl ProducerContext for DeliveryCtx {
    /// Number of events in the message, so failures are counted in events, not batches.
    type DeliveryOpaque = Box<u64>;
    fn delivery(&self, r: &DeliveryResult<'_>, events: Box<u64>) {
        match r {
            Ok(_) => counter!("collector_delivered_events_total", "result" => "ok").increment(*events),
            Err((e, _)) => {
                counter!("collector_delivered_events_total", "result" => "error").increment(*events);
                error!(error = %e, events = *events, "delivery failed");
            }
        }
    }
}

pub struct App {
    cfg: Config,
    producer: ThreadedProducer<DeliveryCtx>,
    salt: salt::DailySalt,
    geo: Option<maxminddb::Reader<Vec<u8>>>,
    pawlog_js: Bytes,
    healthy: AtomicBool,
    metrics: PrometheusHandle,
}

type Resp = Response<Full<Bytes>>;

fn status(s: StatusCode) -> Resp {
    let mut r = Response::new(Full::default());
    *r.status_mut() = s;
    r
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64
}

impl App {
    pub fn new(cfg: Config, metrics: PrometheusHandle) -> Result<Arc<Self>, String> {
        let producer = ClientConfig::new()
            .set("bootstrap.servers", &cfg.brokers)
            .set("linger.ms", "20")
            .set("compression.type", "lz4")
            .set("acks", "all")
            .set("enable.idempotence", "true")
            .set("queue.buffering.max.messages", cfg.queue_max_messages.to_string())
            .create_with_context(DeliveryCtx)
            .map_err(|e| format!("producer: {e}"))?;
        let geo = cfg
            .geoip_db_path
            .as_ref()
            .map(|p| maxminddb::Reader::open_readfile(p).map_err(|e| format!("GEOIP_DB_PATH {p}: {e}")))
            .transpose()?;
        let pawlog_js = std::fs::read(&cfg.pawlog_js_path).map_err(|e| format!("PAWLOG_JS_PATH {}: {e}", cfg.pawlog_js_path))?;
        let app = Arc::new(Self {
            cfg,
            producer,
            salt: salt::DailySalt::default(),
            geo,
            pawlog_js: pawlog_js.into(),
            healthy: AtomicBool::new(false),
            metrics,
        });
        let a = app.clone();
        std::thread::spawn(move || loop {
            a.check_health();
            std::thread::sleep(Duration::from_secs(5));
        });
        Ok(app)
    }

    /// Healthy = broker reachable and our topic has partitions.
    fn check_health(&self) {
        let ok = match self.producer.client().fetch_metadata(Some(&self.cfg.topic), Duration::from_secs(3)) {
            Ok(md) => md.topics().iter().any(|t| t.name() == self.cfg.topic && t.error().is_none() && !t.partitions().is_empty()),
            Err(e) => {
                warn!(error = %e, "metadata fetch failed");
                false
            }
        };
        if self.healthy.swap(ok, Ordering::Relaxed) != ok {
            info!(healthy = ok, "producer health changed");
        }
    }

    pub fn flush(&self) {
        if let Err(e) = self.producer.flush(Duration::from_secs(10)) {
            error!(error = %e, in_flight = self.producer.in_flight_count(), "flush on shutdown failed");
        }
    }

    fn origin(&self, h: &HeaderMap) -> Option<HeaderValue> {
        let o = h.get(header::ORIGIN)?;
        self.cfg.allowed_origins.iter().any(|a| a.as_bytes() == o.as_bytes()).then(|| o.clone())
    }

    fn client_ip(&self, peer: IpAddr, h: &HeaderMap) -> Option<IpAddr> {
        match &self.cfg.client_ip_header {
            // Last hop is the one our own proxy appended; earlier ones are client-controlled.
            Some(name) => h.get(name)?.to_str().ok()?.rsplit(',').next()?.trim().parse().ok(),
            None => Some(peer),
        }
    }

    fn geo(&self, ip: IpAddr) -> event::Geo {
        let Some(r) = &self.geo else { return Default::default() };
        let Ok(Some(c)) = r.lookup::<maxminddb::geoip2::City>(ip) else { return Default::default() };
        let en = |n: Option<std::collections::BTreeMap<&str, &str>>| n.and_then(|n| n.get("en").map(|s| s.to_string())).unwrap_or_default();
        event::Geo {
            country: c.country.and_then(|c| c.iso_code).unwrap_or_default().to_owned(),
            region: en(c.subdivisions.and_then(|s| s.into_iter().next()).and_then(|s| s.names)),
            city: en(c.city.and_then(|c| c.names)),
        }
    }

    async fn collect(&self, peer: IpAddr, req: Request<Incoming>) -> Resp {
        let Some(origin) = self.origin(req.headers()) else { return status(StatusCode::FORBIDDEN) };
        let mut resp = self.collect_inner(peer, req).await;
        resp.headers_mut().insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin);
        resp.headers_mut().insert(header::VARY, HeaderValue::from_static("Origin"));
        resp
    }

    async fn collect_inner(&self, peer: IpAddr, req: Request<Incoming>) -> Resp {
        let reject = |reason: &'static str| {
            counter!("collector_rejected_total", "reason" => reason).increment(1);
            status(StatusCode::BAD_REQUEST)
        };
        let too_big = req
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok()?.parse::<usize>().ok())
            .is_some_and(|n| n > MAX_BODY);
        if too_big {
            return status(StatusCode::PAYLOAD_TOO_LARGE);
        }
        let ua = req.headers().get(header::USER_AGENT).and_then(|v| v.to_str().ok()).unwrap_or("").to_owned();
        let parsed = event::parse_ua(&ua);
        if parsed.bot {
            counter!("collector_bots_dropped_total").increment(1);
            return status(StatusCode::NO_CONTENT);
        }
        let Some(ip) = self.client_ip(peer, req.headers()) else { return reject("client_ip") };
        let body = match tokio::time::timeout(BODY_TIMEOUT, Limited::new(req.into_body(), MAX_BODY).collect()).await {
            Ok(Ok(b)) => b.to_bytes(),
            Ok(Err(e)) if e.downcast_ref::<http_body_util::LengthLimitError>().is_some() => return status(StatusCode::PAYLOAD_TOO_LARGE),
            Ok(Err(_)) => return reject("body"),
            Err(_) => return status(StatusCode::REQUEST_TIMEOUT),
        };
        let now = now_ms();
        let batch = match event::parse_batch(&body, now) {
            Ok(b) => b,
            Err(reason) => return reject(reason),
        };
        let geo = self.geo(ip);
        let ctx = event::Ctx { received_at: now, ip, ua: &ua, parsed: &parsed, geo: &geo, salt: self.salt.get(now) };
        let payload = event::enrich(&batch, &ctx);
        let n = batch.len() as u64;
        let record = BaseRecord::<(), [u8], Box<u64>>::with_opaque_to(&self.cfg.topic, Box::new(n)).payload(&payload);
        match self.producer.send(record) {
            Ok(()) => {
                counter!("collector_events_total").increment(n);
                status(StatusCode::NO_CONTENT)
            }
            Err((KafkaError::MessageProduction(RDKafkaErrorCode::QueueFull), _)) => {
                counter!("collector_queue_full_total").increment(1);
                status(StatusCode::SERVICE_UNAVAILABLE)
            }
            Err((e, _)) => {
                error!(error = %e, "produce failed");
                status(StatusCode::INTERNAL_SERVER_ERROR)
            }
        }
    }

    fn preflight(&self, req: &Request<Incoming>) -> Resp {
        let Some(origin) = self.origin(req.headers()) else { return status(StatusCode::FORBIDDEN) };
        let mut r = status(StatusCode::NO_CONTENT);
        let h = r.headers_mut();
        h.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin);
        h.insert(header::ACCESS_CONTROL_ALLOW_METHODS, HeaderValue::from_static("POST"));
        h.insert(header::ACCESS_CONTROL_ALLOW_HEADERS, HeaderValue::from_static("Content-Type"));
        h.insert(header::ACCESS_CONTROL_MAX_AGE, HeaderValue::from_static("86400"));
        h.insert(header::VARY, HeaderValue::from_static("Origin"));
        r
    }

    fn pawlog_js(&self) -> Resp {
        let mut r = Response::new(Full::new(self.pawlog_js.clone()));
        let h = r.headers_mut();
        h.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/javascript; charset=utf-8"));
        // Unversioned path, so a day of freshness plus a week of background revalidation.
        h.insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=86400, stale-while-revalidate=604800"));
        r
    }

    async fn handle(self: Arc<Self>, peer: IpAddr, req: Request<Incoming>) -> Result<Resp, Infallible> {
        let start = Instant::now();
        let resp = match (req.method(), req.uri().path()) {
            (&Method::POST, "/e") => self.collect(peer, req).await,
            (&Method::OPTIONS, "/e") => self.preflight(&req),
            (&Method::GET, "/pawlog.js") => self.pawlog_js(),
            (&Method::GET, "/healthz") if self.healthy.load(Ordering::Relaxed) => status(StatusCode::OK),
            (&Method::GET, "/healthz") => status(StatusCode::SERVICE_UNAVAILABLE),
            (&Method::GET, "/metrics") => Response::new(Full::new(self.metrics.render().into())),
            _ => status(StatusCode::NOT_FOUND),
        };
        counter!("collector_requests_total", "status" => resp.status().as_u16().to_string()).increment(1);
        histogram!("collector_request_seconds").record(start.elapsed().as_secs_f64());
        Ok(resp)
    }
}

/// Serve until `shutdown` resolves, then drain connections and flush the producer.
pub async fn serve(listener: TcpListener, app: Arc<App>, shutdown: impl Future<Output = ()>) {
    let graceful = GracefulShutdown::new();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            r = listener.accept() => {
                let (stream, peer) = match r {
                    Ok(x) => x,
                    Err(e) => {
                        warn!(error = %e, "accept failed");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    }
                };
                let _ = stream.set_nodelay(true);
                let app = app.clone();
                let svc = service_fn(move |req| app.clone().handle(peer.ip(), req));
                let conn = http1::Builder::new()
                    .timer(TokioTimer::new())
                    .header_read_timeout(Duration::from_secs(10))
                    .serve_connection(TokioIo::new(stream), svc);
                let fut = graceful.watch(conn);
                tokio::spawn(async move { let _ = fut.await; });
            }
            _ = &mut shutdown => break,
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(10), graceful.shutdown()).await;
    app.flush();
}
