// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Server mode: HTTP API for the future Cool Tunnel admin UI
//! (Filament/PHP server tier).
//!
//! Same `cool-tunnel-core` binary as the client. Launched with
//! `--mode server [--listen ADDR] [--allow-public]`. Exposes the
//! *pure* parts of the engine (config + PAC generation, validation)
//! over plain HTTP/1.1 + JSON so any HTTP client — `curl`, the
//! Filament admin UI, a Caddy plugin's sidecar — can reuse the
//! exact logic the macOS app uses without re-implementing it.
//!
//! What the server *does not* do today (intentional through v0.1.7.x):
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
//! ## v0.1.7.11 Rule-Maker hardening
//!
//! The four changes in this revision come from the Fifth audit
//! cycle (Rule Maker rubric, R1 fail-secure / R2 boundary
//! enforcement / R3 latency / R4 no theatre):
//!
//! - **SM-9 (R2):** the loopback-only deployment posture is now
//!   *enforced*, not just documented. [`run`] refuses to bind a
//!   non-loopback address unless the caller explicitly passed
//!   `allow_public = true` (set by `--allow-public` on the CLI).
//!   Previously a `--listen 0.0.0.0:8787` typo silently exposed an
//!   unauthenticated engine; now it errors out with a message that
//!   tells the operator exactly what the flag is for.
//! - **SM-1 (R1, R2):** every JSON handler now scrubs
//!   [`JsonRejection`] before it reaches the wire. axum's default
//!   400 body includes the verbatim serde error, which describes
//!   internal field names and the engine's domain validation rules
//!   (e.g. `"server: contains forbidden ':/​/'"`). The handlers now
//!   intercept the rejection, log it via `tracing::warn!` server-
//!   side, and return a stable opaque envelope.
//! - **SM-2 (R1):** [`ApiError`] variants carry no payload. The
//!   wire body is a stable string per status; cause-of-failure
//!   detail goes to `tracing::error!` only. The previous
//!   `Internal(String)` field structurally invited callers to
//!   interpolate `serde_json::Error` (which embeds line/column/
//!   field info) — removing the field forces logging-only.
//! - **SM-3 (R4, R2):** [`naive_validate`] now actually validates
//!   and reports the result in the response shape it advertised.
//!   Previously the handler dropped the deserialized profile with
//!   `_` and unconditionally returned `ok:true`; the only failure
//!   path produced a 400 from the extractor, making the `ok:false`
//!   branch of `ValidationReport` unreachable by any well-behaved
//!   caller. The handler now accepts a raw `serde_json::Value`,
//!   runs the `Profile` deserializer itself, and returns a real
//!   `{ok:false, reason:"invalid profile"}` on failure with the
//!   detailed cause logged server-side.
//!
//! ## Endpoint summary (all return JSON)
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
//! `Password::expose_secret`, and a "let's log the failing body
//! for debug" PR would silently leak credentials to whatever the
//! tracing subscriber writes to (today: stderr; tomorrow: a file
//! the deployer pipes off-host). When you need diagnostic detail,
//! log the *cause* (a `serde_json::Error`'s `Display` is fine, it
//! only references field paths — never values) but never the
//! payload itself.

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

/// Default listen address. Loopback-only by design — see [`run`]
/// for the public-bind acknowledgement requirement (SM-9).
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8787";

/// Entry point for server mode. Binds the listener, runs the
/// router until the process is signalled.
///
/// # Errors
///
/// - [`std::io::ErrorKind::PermissionDenied`] if `listen` is a
///   non-loopback address and `allow_public` is `false`. The
///   operator must explicitly opt in via `--allow-public` on the
///   CLI to bind anything reachable from the network — this server
///   has no auth and the documented deployment is behind a reverse
///   proxy.
/// - The underlying I/O error if the listener can't bind or if
///   axum's serve loop exits unexpectedly.
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
        // Operator opted in. Surface the choice prominently in
        // the log so post-incident review can see when the gate
        // was bypassed and by whom (process owner is in the
        // tracing default fields).
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
    //
    // **SM-10 (R3):** `ConcurrencyLimitLayer` caps the total
    // number of in-flight requests across all routes at 64.
    // This is far above any legitimate UI workload (a Filament
    // admin UI with one operator clicking through a config
    // form) and bounds the worst-case for a slow-loris client
    // dripping bytes into a 64 KiB body — the connection still
    // has to wait, but the server can't be made to hold more
    // than 64 simultaneously. Combined with hyper's default
    // keepalive timeout, the resource exhaustion path is
    // capped without needing the `tower::timeout::TimeoutLayer`
    // boilerplate (which introduces a non-Infallible error
    // type and requires `HandleErrorLayer` plumbing). A proper
    // body-read timeout is deferred to a later cycle.
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
/// reports the outcome in the [`ValidationReport`] shape the
/// endpoint advertises.
///
/// **SM-3 (R4, R2):** previously the handler took `Json<Profile>`
/// and dropped the value (`_profile`); deserialize failures became
/// 400s from the axum extractor, so `ok:false` was structurally
/// unreachable. Now the handler accepts any JSON value, runs the
/// deserializer itself, and surfaces both branches:
///
///   - `Ok(_)`  → `{"ok":true,"reason":null}`
///   - `Err(e)` → `{"ok":false,"reason":"invalid profile"}`
///     with `e` logged at warn level server-side.
///
/// The wire `reason` is intentionally generic. An unauthenticated
/// caller cannot use it to enumerate the engine's validation rules
/// (which would help craft bypass attempts in a future hardened
/// deployment); a deployer debugging their own stack reads the
/// detail from the engine logs.
async fn naive_validate(
    body: Result<Json<serde_json::Value>, JsonRejection>,
) -> Json<ValidationReport> {
    let value = match body {
        Ok(Json(v)) => v,
        Err(rejection) => {
            // Body wasn't JSON, exceeded the size cap, or the
            // Content-Type was wrong. Return the structured
            // `ok:false` rather than a 400 — that keeps the
            // contract shape consistent for callers and aligns
            // with the rest of the validation handler's path.
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

/// **SM-4 (R2, R3):** caps on the PAC request shape. The 64 KiB
/// router-wide body limit is the outer ceiling, but inside that
/// envelope a single request could still carry ~16k single-char
/// domain entries — each becomes a `to_lowercase()` allocation in
/// `normalise_domains`, then a `serde_json::to_string` pass in
/// `encode_js_string_array`, then is embedded in a `format!` —
/// pushing PAC generation past the R3 ≤10 ms target on a busy
/// worker. With these caps the total work per request is
/// bounded well under 10 ms (1024 entries × 253 bytes ≈ 256 KiB
/// of string data, processed linearly).
const MAX_PAC_DOMAINS: usize = 1024;
/// RFC 1035 hostname maximum byte length. PAC entries are
/// matched as suffixes (`dnsDomainIs(host, domain)`) so anything
/// longer than a real hostname is wasted — and provides an
/// inflation vector in `format!`.
///
/// **v0.1.7.13 (R-F#3):** delegates to
/// [`ServerAddress::MAX_LEN`] so the RFC limit lives in exactly
/// one place. The `domain` crate's `ServerAddress::parse` already
/// enforces the same number against the `Profile`'s `server`
/// field; pinning both call sites to the same constant
/// eliminates drift if the limit is ever revised.
const MAX_PAC_DOMAIN_BYTES: usize = ServerAddress::MAX_LEN;

async fn naive_pac(
    body: Result<Json<NaivePacRequest>, JsonRejection>,
) -> Result<Json<NaivePacResponse>, ApiError> {
    let Json(request) = body.map_err(|err| ApiError::from_json_rejection(&err))?;
    // SM-4 caps. Enforced at the handler boundary rather than in
    // the deserializer because `Vec<String>` has no native serde
    // attribute for max-items / max-byte-len; a custom
    // `deserialize_with` would have to duplicate the type. Inline
    // is clearer.
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
    // **SM-6 (R3) — resolved by SM-4.** With the caps above,
    // the synchronous `generate_pac` cost is bounded under
    // 10 ms on a current-gen worker; no `spawn_blocking` is
    // needed. (The audit explicitly warned against
    // `spawn_blocking`-without-cap, which would just move the
    // unbounded work elsewhere.)
    let js = generate_pac(&request.direct_domains, request.port);
    Ok(Json(NaivePacResponse { js }))
}

// MARK: - Error type

/// Error envelope for handler code. **Both variants intentionally
/// carry no payload** — see SM-2 in the file header.
///
/// The wire body is a stable opaque string per HTTP status; any
/// detail belongs in `tracing` server-side, not in the response.
/// `Debug` is preserved so handlers can `tracing::error!(?err)`.
#[derive(Debug)]
enum ApiError {
    /// HTTP 400 — caller-visible bad input. Wire body:
    /// `{"error":"bad request"}`.
    BadRequest,
    /// HTTP 500 — server-side failure. Wire body:
    /// `{"error":"internal error"}`. The cause goes to
    /// `tracing::error!` only.
    Internal,
}

impl ApiError {
    /// Helper for handlers shaped as
    /// `Result<Json<T>, JsonRejection>`: log the underlying serde
    /// error server-side, surface only the opaque envelope to the
    /// wire. SM-1's scrub happens here.
    ///
    /// Takes `&JsonRejection` rather than consuming it: the body
    /// only needs `Display` (`%err`) for logging, and pass-by-ref
    /// keeps clippy's `needless_pass_by_value` happy. Call sites
    /// hand a reference: `body.map_err(|e| ApiError::from_json_rejection(&e))`.
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
