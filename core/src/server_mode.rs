//! Server mode: HTTP API for the future Cool Tunnel admin UI
//! (Filament/PHP server tier).
//!
//! Same `cool-tunnel-core` binary as the client. Launched with
//! `--mode server [--listen ADDR]`. Exposes the *pure* parts of
//! the engine (config + PAC generation, validation) over plain
//! HTTP/1.1 + JSON so any HTTP client — `curl`, the Filament
//! admin UI, a Caddy plugin's sidecar — can reuse the exact
//! logic the macOS app uses without re-implementing it.
//!
//! What the server *does not* do today (intentional for v0.1.5.8):
//!
//!   - It does not spawn `naive` itself. The server-tier proxy is
//!     `forwardproxy@naive` running as a Caddy plugin; the engine
//!     just hands out config text the operator can drop into Caddy.
//!   - It does not authenticate. Run it bound to `127.0.0.1` and
//!     reverse-proxy through Caddy or NGINX with whatever auth you
//!     already use. Adding auth here would force a token-management
//!     decision we want the deployer to own.
//!   - It does not persist. Stateless by design — the deployer's
//!     existing database is the source of truth.
//!
//! Endpoint summary (all return JSON):
//!
//!   GET  /health             → {"status":"ok"}
//!   GET  /version            → {"name":"cool-tunnel-core","version":"X.Y.Z"}
//!   POST /naive/validate     → body: `Profile` JSON; returns `ValidationReport`
//!   POST /naive/config       → body: `Profile` JSON; returns `{"json": "..."}`
//!   POST /naive/pac          → body: `{"direct_domains": […], "port": 1080}`
//!                              returns `{"js": "..."}`

use std::net::SocketAddr;

use axum::extract::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use cool_tunnel_core::config::{generate_pac, NaiveConfig};
use cool_tunnel_core::domain::{Port, Profile};
use cool_tunnel_core::protocol::ValidationReport;
use serde::{Deserialize, Serialize};

/// Default listen address. Loopback-only by design — the user
/// can override with `--listen 0.0.0.0:8080` if they really want
/// to expose the API directly, but the documented deployment is
/// behind a reverse proxy.
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8787";

/// Entry point for server mode. Binds the listener, runs the
/// router until the process is signalled.
///
/// # Errors
///
/// Returns the underlying I/O error if the listener can't bind
/// or if axum's serve loop exits unexpectedly.
pub async fn run(listen: SocketAddr) -> std::io::Result<()> {
    tracing::info!(%listen, "cool-tunnel-core server mode listening");
    let listener = tokio::net::TcpListener::bind(listen).await?;
    let app = router();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
}

/// Wait for SIGINT / SIGTERM. Lets the server drain in-flight
/// requests when the operator kills it.
async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            let _ = sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => tracing::info!("ctrl-c received, draining"),
        () = term => tracing::info!("SIGTERM received, draining"),
    }
}

/// Builds the axum router. Split out so a future test crate could
/// drive it via `tower::ServiceExt::oneshot` without needing a
/// real socket. `Router` is already `#[must_use]`, so callers can't
/// silently drop the routes.
pub fn router() -> Router {
    // Hard cap on JSON body size: 64 KiB is far above any
    // legitimate `Profile` (a few hundred bytes), generous enough
    // for a domain list with a thousand entries, and a tight
    // ceiling against a slowloris / oversized-body attack.
    // Default `Json<T>` extractor cap is 2 MiB which is far
    // larger than anything we actually accept.
    Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/naive/validate", post(naive_validate))
        .route("/naive/config", post(naive_config))
        .route("/naive/pac", post(naive_pac))
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024))
}

// MARK: - Handlers

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

#[derive(Serialize)]
struct VersionResponse {
    name: &'static str,
    version: &'static str,
}

async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        name: "cool-tunnel-core",
        version: env!("CARGO_PKG_VERSION"),
    })
}

/// `POST /naive/validate` — same validation the client mode runs
/// inside `dispatch`. Request body is a `Profile` JSON; response is
/// a `ValidationReport` (`ok: bool`, optional `reason: String`).
///
/// Today the engine's `Profile` deserializer enforces every rule,
/// so a successful deserialize implies a passing validation. We
/// keep the explicit `ValidationReport` shape so the wire format
/// matches the client side and so we can tighten validation later
/// without breaking the API.
async fn naive_validate(Json(_profile): Json<Profile>) -> Json<ValidationReport> {
    Json(ValidationReport {
        ok: true,
        reason: None,
    })
}

#[derive(Serialize)]
struct NaiveConfigResponse {
    json: String,
}

async fn naive_config(Json(profile): Json<Profile>) -> Result<Json<NaiveConfigResponse>, ApiError> {
    let config = NaiveConfig::from_profile(&profile);
    let json = config
        .to_pretty_json()
        .map_err(|err| ApiError::internal(format!("serialize config: {err}")))?;
    Ok(Json(NaiveConfigResponse { json }))
}

#[derive(Deserialize)]
struct NaivePacRequest {
    direct_domains: Vec<String>,
    port: Port,
}

#[derive(Serialize)]
struct NaivePacResponse {
    js: String,
}

async fn naive_pac(Json(body): Json<NaivePacRequest>) -> Json<NaivePacResponse> {
    let js = generate_pac(&body.direct_domains, body.port);
    Json(NaivePacResponse { js })
}

// MARK: - Error type

/// Error envelope for handler code. Each variant maps to a
/// specific HTTP status in `into_response`; future handlers can
/// add their own variants instead of squeezing every failure into
/// 500. `Debug` is derived so handlers can `tracing::error!(?err)`
/// without a re-write.
#[derive(Debug)]
enum ApiError {
    /// HTTP 400 — caller-visible bad input.
    #[allow(dead_code)] // First handler that needs it brings it to life.
    BadRequest(String),
    /// HTTP 500 — server-side failure with an opaque message.
    Internal(String),
}

impl ApiError {
    fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        #[derive(Serialize)]
        struct Body {
            error: String,
        }
        let (status, message) = match self {
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, message),
            Self::Internal(message) => (StatusCode::INTERNAL_SERVER_ERROR, message),
        };
        (status, Json(Body { error: message })).into_response()
    }
}
