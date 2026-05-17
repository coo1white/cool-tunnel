// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
#![forbid(unsafe_code)]
#![warn(missing_docs)]

//! Core engine for the COOL-TUNNEL macOS proxy client.
//!
//! v3.0.0 pivot: the proxy underneath is now sing-box VLESS+Reality,
//! not NaiveProxy. The crate provides the domain types, sing-box
//! config rendering, process supervision, traffic monitoring, and
//! diagnostics that back the Swift UI. It is consumed by the
//! `cool-tunnel-core` binary as a JSON-over-stdio service spawned
//! from the macOS app.
//!
//! # Modules
//!
//! - [`domain`] — value types ([`domain::Port`], [`domain::ServerAddress`],
//!   [`domain::Credentials`] (username + UUID + Reality block),
//!   [`domain::Profile`], [`domain::ProxyMode`]) with validation
//!   enforced at construction.
//! - [`config`] — pure functions that produce the sing-box client
//!   `config.json` from a [`domain::Profile`].
//! - [`protocol`] — request/response/event types that travel over stdin/stdout.
//! - [`error`] — the crate-wide [`error::CoreError`] enum.
//! - [`diagnostics`] — connectivity probes (TLS upstream, SOCKS handshake,
//!   latency) issued through a running proxy.
//! - [`monitor`] — `lsof`-based monitor that watches the supervised
//!   `sing-box` PID for listen-port loss and anomaly conditions.
//! - [`preflight`] — DNS + TCP reachability probe used by the Swift
//!   UI's "Test Connection" button before a full launch.
//! - [`redaction`] — regex pipeline that scrubs URL userinfo,
//!   `Authorization`/`Cookie` headers, bare UUIDs, and Reality
//!   handshake material from sing-box subprocess log lines.
//! - [`supervisor`] — `sing-box` child-process lifecycle manager
//!   (spawn, log drain, graceful stop, natural-death detection).
//! - [`util`] — shared helpers (debouncer for anomaly emit dedup).
//!
//! # Safety
//!
//! The crate forbids `unsafe` code. There is no FFI layer; the Swift app
//! communicates with this engine over a subprocess using newline-delimited
//! JSON.

pub mod config;
pub mod diagnostics;
pub mod domain;
pub mod error;
pub mod monitor;
pub mod preflight;
pub mod protocol;
pub mod redaction;
pub mod supervisor;
pub mod util;

// Re-export the canonical crate-wide error so consumers can write
// `cool_tunnel_core::CoreError` instead of the longer
// `cool_tunnel_core::error::CoreError`. Reduces refactor blast
// radius if `error` ever moves into a parent module.
pub use error::CoreError;
