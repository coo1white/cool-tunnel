//! `NaiveProxy` JSON config generation.
//!
//! Produces the `config.json` consumed by the bundled `naive` binary.
//! The format matches the file the Swift app currently writes:
//!
//! ```json
//! {
//!   "listen": "socks://127.0.0.1:1080",
//!   "proxy":  "https://user:pass@host:port"
//! }
//! ```

use serde::Serialize;

use crate::config::LOOPBACK_HOST;
use crate::domain::{Credentials, Port, Profile, ServerAddress};

/// JSON config consumed by the bundled `naive` binary.
///
/// Construct one from a [`Profile`] via [`NaiveConfig::from_profile`], then
/// serialize with [`NaiveConfig::to_pretty_json`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NaiveConfig {
    /// `socks://127.0.0.1:<port>`
    pub listen: String,
    /// `https://<user>:<pass>@<server>` with credentials percent-encoded.
    pub proxy: String,
}

impl NaiveConfig {
    /// Builds a config from a validated profile.
    #[must_use]
    pub fn from_profile(profile: &Profile) -> Self {
        Self {
            listen: build_listen_url(profile.local_port()),
            proxy: build_proxy_url(profile.server(), profile.credentials()),
        }
    }

    /// Serializes the config to indented JSON (two-space indent, sorted keys
    /// guaranteed by struct field order).
    ///
    /// # Errors
    ///
    /// Returns the underlying [`serde_json::Error`] on the (effectively
    /// impossible) failure path of writing two `String` fields to JSON.
    pub fn to_pretty_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }
}

fn build_listen_url(port: Port) -> String {
    format!("socks://{LOOPBACK_HOST}:{port}")
}

fn build_proxy_url(server: &ServerAddress, credentials: &Credentials) -> String {
    let encoded = credentials.percent_encoded();
    format!(
        "https://{user}:{pass}@{server}",
        user = encoded.username(),
        pass = encoded.password(),
        server = server,
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::domain::{Password, ProfileId, Username};

    /// Test fixture. Uses an obviously-fake placeholder password —
    /// real credentials must never land in test code, since git
    /// history is forever and search engines do index test fixtures.
    fn sample_profile() -> Profile {
        Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("naive.example.com").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Password::parse("test-password-do-not-use").unwrap(),
            ),
            Port::new(1080).unwrap(),
        )
    }

    #[test]
    fn listen_url_uses_loopback() {
        let cfg = NaiveConfig::from_profile(&sample_profile());
        assert_eq!(cfg.listen, "socks://127.0.0.1:1080");
    }

    #[test]
    fn proxy_url_percent_encodes_credentials() {
        let profile = Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("naive.example.com").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Password::parse("p@ss/word").unwrap(),
            ),
            Port::new(1080).unwrap(),
        );
        let cfg = NaiveConfig::from_profile(&profile);
        assert_eq!(cfg.proxy, "https://alice:p%40ss%2Fword@naive.example.com");
    }

    #[test]
    fn pretty_json_is_well_formed() {
        let cfg = NaiveConfig::from_profile(&sample_profile());
        let json = cfg.to_pretty_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["listen"], "socks://127.0.0.1:1080");
        assert_eq!(
            parsed["proxy"],
            "https://alice:test-password-do-not-use@naive.example.com"
        );
    }

    #[test]
    fn server_with_explicit_port_round_trips() {
        let profile = Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("naive.example.com:8443").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Password::parse("secret").unwrap(),
            ),
            Port::new(1080).unwrap(),
        );
        let cfg = NaiveConfig::from_profile(&profile);
        assert!(cfg.proxy.ends_with("@naive.example.com:8443"));
    }
}
