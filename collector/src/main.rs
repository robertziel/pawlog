use collector::{serve, App, Config};
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder};
use tokio::net::TcpListener;
use tokio::signal::unix::{signal, SignalKind};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(EnvFilter::try_from_default_env().expect("RUST_LOG must be set"))
        .init();
    let die = |e: String| -> ! {
        tracing::error!(error = %e, "startup failed");
        std::process::exit(1)
    };
    let cfg = Config::from_env().unwrap_or_else(|e| die(e));
    let addr = cfg.listen_addr;
    // Buckets (not the default summary) so a load test can diff counts per step.
    let buckets = [0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.5];
    let metrics = PrometheusBuilder::new()
        .set_buckets_for_metric(Matcher::Full("collector_request_seconds".into()), &buckets)
        .and_then(|b| b.install_recorder())
        .unwrap_or_else(|e| die(e.to_string()));
    let app = App::new(cfg, metrics).unwrap_or_else(|e| die(e));
    let listener = TcpListener::bind(addr).await.unwrap_or_else(|e| die(format!("bind {addr}: {e}")));
    tracing::info!(%addr, "listening");
    let mut term = signal(SignalKind::terminate()).unwrap();
    serve(listener, app, async move {
        tokio::select! { _ = term.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
        tracing::info!("shutting down");
    })
    .await;
}
