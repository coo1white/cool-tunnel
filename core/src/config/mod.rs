// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Pure functions that turn a validated [`crate::domain::Profile`] into the
//! artifacts `NaiveProxy` and macOS need: a JSON config file and a JavaScript
//! PAC file.

pub mod naive_config;
pub mod pac;

pub use naive_config::NaiveConfig;
pub use pac::{generate_pac, DEFAULT_DIRECT_DOMAINS};

/// IPv4 loopback address used for both the SOCKS listen socket
/// (`naive_config`) and the PAC file's proxy targets (`pac`).
/// Defining it once here prevents the literal from drifting
/// across the two modules.
pub(crate) const LOOPBACK_HOST: &str = "127.0.0.1";
