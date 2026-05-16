// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Pure functions that turn a validated [`crate::domain::Profile`] into the
//! sing-box `config.json` consumed by the bundled `sing-box` binary.
//!
//! v3.0.0 pivot: the v2.x PAC file generator is gone. Sing-box routes
//! traffic via its own `route.rules` block, which the client config
//! shape includes by default — no separate Swift-rendered PAC URL is
//! needed.

pub mod singbox_config;

pub use singbox_config::SingboxConfig;

/// IPv4 loopback address used for the SOCKS listen socket. Defined
/// once so any future tweak (e.g. shifting to `::1` for IPv6
/// loopback) is a single-line change.
pub(crate) const LOOPBACK_HOST: &str = "127.0.0.1";
