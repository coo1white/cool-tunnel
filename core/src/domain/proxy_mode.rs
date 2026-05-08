// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Active and test proxy modes.

use serde::{Deserialize, Serialize};

/// Active proxy mode driving system-proxy configuration.
///
/// The values map directly onto the macOS `networksetup` operations the
/// Swift app performs:
/// - [`ProxyMode::Stopped`] — no listener, system proxy cleared.
/// - [`ProxyMode::Smart`] — listener up; system proxy points at a PAC URL.
/// - [`ProxyMode::Global`] — listener up; system SOCKS proxy points at the
///   listener.
/// - [`ProxyMode::LocalOnly`] — listener up; system proxy unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ProxyMode {
    /// No listener, system proxy cleared.
    Stopped,
    /// Listener active with PAC-driven smart routing.
    Smart,
    /// Listener active and configured as the global SOCKS proxy.
    Global,
    /// Listener active but not registered with the system proxy settings.
    LocalOnly,
}

impl ProxyMode {
    /// Returns `true` if a SOCKS listener should be running in this mode.
    #[must_use]
    pub const fn requires_listener(self) -> bool {
        !matches!(self, Self::Stopped)
    }
}

// `ProxyMode::title()` and `ProxyTestMode::title()` were removed
// in v2.0.22 — both were orphan UI helpers in a wire-only
// `Deserialize`/`Serialize` enum; the Swift mirror at
// `COOL-TUNNEL/Core/Protocol.swift` carries its own UI strings,
// and no Rust caller ever read them. Reintroduce only if a
// CLI/server-mode UI surface lands here.

/// Mode for diagnostic latency tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ProxyTestMode {
    /// Test through the smart-routing PAC file.
    Smart,
    /// Test as if all traffic is routed through SOCKS.
    Global,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn stopped_does_not_require_listener() {
        assert!(!ProxyMode::Stopped.requires_listener());
    }

    #[test]
    fn other_modes_require_listener() {
        assert!(ProxyMode::Smart.requires_listener());
        assert!(ProxyMode::Global.requires_listener());
        assert!(ProxyMode::LocalOnly.requires_listener());
    }

    #[test]
    fn serializes_in_snake_case() {
        assert_eq!(
            serde_json::to_string(&ProxyMode::LocalOnly).unwrap(),
            "\"local_only\""
        );
        assert_eq!(
            serde_json::to_string(&ProxyMode::Smart).unwrap(),
            "\"smart\""
        );
    }

    #[test]
    fn deserializes_from_snake_case() {
        let mode: ProxyMode = serde_json::from_str("\"local_only\"").unwrap();
        assert_eq!(mode, ProxyMode::LocalOnly);
    }
}
