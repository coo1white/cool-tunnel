// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Server mode: HTTP API for the Cool Tunnel admin UI.
//!
//! Same `cool-tunnel-core` binary as the client. Launched with
//! `--mode server [--listen ADDR] [--allow-public]`. Exposes the
//! *pure* parts of the engine (config + PAC generation,
//! validation) over plain HTTP/1.1 + JSON.
//!
//! Intentionally does NOT:
//!   - spawn `naive` (the server-tier proxy is `forwardproxy@naive`
//!     under Caddy; the engine just hands out config text);
//!   - authenticate (run on `127.0.0.1`, reverse-proxy through
//!     Caddy/NGINX with whatever auth you already have);
//!   - persist (stateless — the deployer's DB is the source of
//!     truth).
//!
//! ## Endpoints (all return JSON)
//!
//!   GET  /health             → `{"status":"ok"}`
//!   GET  /version            → `{"name":"cool-tunnel-core","version":"X.Y.Z"}`
//!   POST /naive/validate     → body: any JSON; returns `ValidationReport`
//!   POST /naive/config       → body: `Profile` JSON; returns `{"json":"..."}`
//!   POST /naive/pac          → body: `{"direct_domains":[…],"port":1080}`
//!                              returns `{"js":"..."}`
//!
//! ## Logging policy (do not violate)
//!
//! Handlers MUST NOT log the request body, the resolved `Profile`,
//! or the contents of `ApiError::*` payloads. `Profile` carries
//! `Password::expose_secret`. Log the *cause* (a
//! `serde_json::Error`'s `Display` references field paths, not
//! values) but never the payload itself.

use std::net::SocketAddr;

use axum::extract::rejection::JsonRejection;
use axum::extract::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use cool_tunnel_core::config::{generate_pac, NaiveConfig};
use cool_tunnel_core::domain::{Port, Profile, ServerAddress};
use cool_tunnel_core::protocol::ValidationReport;
use serde::{Deserialize, Serialize};

/// Default listen address. Loopback-only by design.
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8787";

/// Entry point for server mode. Binds the listener, runs the
/// router until the process is signalled.
///
/// # Errors
///
/// - [`std::io::ErrorKind::PermissionDenied`] if `listen` is a
///   non-loopback address and `allow_public` is `false`. This
///   server has no auth and the documented deployment is behind
///   a reverse proxy.
/// - I/O error if the listener can't bind.
pub async fn run(listen: SocketAddr, allow_public: bool) -> std::io::Result<()> {
    if !listen.ip().is_loopback() && !allow_public {
        let msg = format!(
            "refusing to bind non-loopback address {listen}: this server has no auth. \
             Pass --allow-public to confirm a reverse proxy with auth is in front of it."
        );
        tracing::error!("{msg}");
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            msg,
        ));
    }
    if !listen.ip().is_loopback() {
        // Operator opted in — surface the choice prominently
        // for post-incident review.
        tracing::warn!(
            %listen,
            "binding non-loopback address with --allow-public — \
             ensure a reverse proxy with auth is in front of this binary"
        );
    }
    tracing::info!(%listen, "cool-tunnel-core server mode listening");
    let listener = tokio::net::TcpListener::bind(listen).await?;
    let app = router();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
}

/// Waits for SIGINT / SIGTERM so the server can drain in-flight
/// requests on shutdown.
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

/// Builds the axum router.
pub fn router() -> Router {
    // 64 KiB body cap: tight ceiling against slowloris / oversize
    // bodies (default `Json<T>` cap is 2 MiB).
    //
    // `ConcurrencyLimitLayer(64)` caps total in-flight requests.
    // Bounds the slowloris-via-many-connections path without the
    // `tower::timeout::TimeoutLayer` boilerplate. A proper
    // body-read timeout is deferred.
    Router::new()
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/naive/validate", post(naive_validate))
        .route("/naive/config", post(naive_config))
        .route("/naive/pac", post(naive_pac))
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024))
        .layer(tower::limit::ConcurrencyLimitLayer::new(64))
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

/// `POST /naive/validate` — runs the `Profile` deserializer and
/// reports the outcome.
///
///   - `Ok(_)`  → `{"ok":true,"reason":null}`
///   - `Err(e)` → `{"ok":false,"reason":"invalid profile"}` with
///     `e` logged at warn level server-side.
///
/// The wire `reason` is intentionally generic so an unauthenticated
/// caller cannot enumerate the engine's validation rules.
async fn naive_validate(
    body: Result<Json<serde_json::Value>, JsonRejection>,
) -> Json<ValidationReport> {
    let value = match body {
        Ok(Json(v)) => v,
        Err(rejection) => {
            // Return structured `ok:false` rather than a 400 so
            // the contract shape stays consistent.
            tracing::warn!(error = %rejection, "naive_validate: rejected body envelope");
            return Json(ValidationReport {
                ok: false,
                reason: Some("invalid request body".to_owned()),
            });
        }
    };
    match serde_json::from_value::<Profile>(value) {
        Ok(_profile) => Json(ValidationReport {
            ok: true,
            reason: None,
        }),
        Err(err) => {
            tracing::warn!(error = %err, "naive_validate: profile rejected");
            Json(ValidationReport {
                ok: false,
                reason: Some("invalid profile".to_owned()),
            })
        }
    }
}

#[derive(Serialize)]
struct NaiveConfigResponse {
    json: String,
}

async fn naive_config(
    body: Result<Json<Profile>, JsonRejection>,
) -> Result<Json<NaiveConfigResponse>, ApiError> {
    let Json(profile) = body.map_err(|err| ApiError::from_json_rejection(&err))?;
    let config = NaiveConfig::from_profile(&profile);
    let json = config.to_pretty_json().map_err(|err| {
        tracing::error!(error = %err, "naive_config: serialize failed");
        ApiError::Internal
    })?;
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

/// Cap on `direct_domains` per request. Without this a 64 KiB
/// body could carry ~16k single-char entries, each forcing a
/// `to_lowercase()` allocation plus `serde_json::to_string` plus
/// `format!`. 1024 keeps total work well under 10 ms.
const MAX_PAC_DOMAINS: usize = 1024;
/// RFC 1035 hostname byte limit. Delegates to
/// [`ServerAddress::MAX_LEN`] so both PAC entries and a
/// `Profile.server` validate against one constant.
const MAX_PAC_DOMAIN_BYTES: usize = ServerAddress::MAX_LEN;

async fn naive_pac(
    body: Result<Json<NaivePacRequest>, JsonRejection>,
) -> Result<Json<NaivePacResponse>, ApiError> {
    let Json(request) = body.map_err(|err| ApiError::from_json_rejection(&err))?;
    // Inline caps — `Vec<String>` has no native serde attribute
    // for max-items / max-byte-len, and a custom `deserialize_with`
    // would have to duplicate the type.
    if request.direct_domains.len() > MAX_PAC_DOMAINS {
        tracing::warn!(
            count = request.direct_domains.len(),
            cap = MAX_PAC_DOMAINS,
            "naive_pac: direct_domains over cap"
        );
        return Err(ApiError::BadRequest);
    }
    if let Some(too_long) = request
        .direct_domains
        .iter()
        .find(|d| d.len() > MAX_PAC_DOMAIN_BYTES)
    {
        tracing::warn!(
            len = too_long.len(),
            cap = MAX_PAC_DOMAIN_BYTES,
            "naive_pac: domain entry over per-entry byte cap"
        );
        return Err(ApiError::BadRequest);
    }
    // With the caps above, synchronous `generate_pac` runs under
    // 10 ms — no `spawn_blocking` needed.
    let js = generate_pac(&request.direct_domains, request.port);
    Ok(Json(NaivePacResponse { js }))
}

// MARK: - Error type

/// Error envelope for handler code. Variants carry no payload —
/// the wire body is a stable opaque string per HTTP status; any
/// detail belongs in `tracing` server-side, not in the response.
#[derive(Debug)]
enum ApiError {
    /// HTTP 400 — `{"error":"bad request"}`.
    BadRequest,
    /// HTTP 500 — `{"error":"internal error"}`.
    Internal,
}

impl ApiError {
    /// Logs the serde rejection server-side and surfaces only the
    /// opaque envelope to the wire.
    fn from_json_rejection(err: &JsonRejection) -> Self {
        tracing::warn!(error = %err, "scrubbed JsonRejection at handler boundary");
        Self::BadRequest
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        #[derive(Serialize)]
        struct Body {
            error: &'static str,
        }
        let (status, error) = match self {
            Self::BadRequest => (StatusCode::BAD_REQUEST, "bad request"),
            Self::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
        };
        (status, Json(Body { error })).into_response()
    }
}
