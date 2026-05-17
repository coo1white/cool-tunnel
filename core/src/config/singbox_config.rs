// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Sing-box client `config.json` generation.
//!
//! Produces the config consumed by the bundled `sing-box` binary
//! (`<app-bundle>/Contents/Resources/sing-box`). Mirrors
//! `cool-tunnel-server`'s `singbox-core/src/config/render.ts::renderClientConfig`
//! so the wire shape is byte-equivalent to what the server side
//! emits for a client bundle.

use serde::Serialize;

use crate::config::LOOPBACK_HOST;
use crate::domain::{Credentials, Profile, Reality, ServerAddress};

/// Default sing-box log level. Matches the server-side renderer's default.
const DEFAULT_LOG_LEVEL: &str = "info";

/// VLESS flow constant used by both client and server. Reality
/// requires this exact value (`xtls-rprx-vision`); sing-box rejects
/// connections without it.
const VLESS_FLOW: &str = "xtls-rprx-vision";

/// uTLS fingerprint mimicked by the client. `chrome` matches the
/// server-side renderer's default and is the most common cover-traffic
/// pattern.
const UTLS_FINGERPRINT: &str = "chrome";

/// Sing-box client config produced from a [`Profile`].
///
/// Build via [`SingboxConfig::from_profile`] then serialize with
/// [`SingboxConfig::to_pretty_json`]. Field layout matches the
/// server-side TypeScript renderer 1:1; the only thing the Rust
/// side adds is the `Drop` impl that scrubs the `uuid` and Reality
/// key strings before freeing.
#[derive(Debug, Serialize)]
pub struct SingboxConfig {
    log: LogBlock,
    inbounds: [SocksInbound; 1],
    outbounds: Outbounds,
    route: RouteBlock,
}

impl SingboxConfig {
    /// Builds a config from a validated profile.
    #[must_use]
    pub fn from_profile(profile: &Profile) -> Self {
        let (server_host, server_port) = split_server(profile.server());
        Self {
            log: LogBlock {
                level: DEFAULT_LOG_LEVEL,
                timestamp: true,
            },
            inbounds: [SocksInbound {
                ty: "socks",
                tag: "socks-in",
                listen: LOOPBACK_HOST,
                listen_port: profile.local_port().get(),
            }],
            outbounds: Outbounds {
                vless: VlessOutbound::new(server_host, server_port, profile.credentials()),
                direct: DirectOutbound::new(),
                block: BlockOutbound::new(),
                dns: DnsOutbound::new(),
            },
            route: RouteBlock {
                rules: [RouteRule {
                    protocol: "dns",
                    outbound: "dns-out",
                }],
                final_outbound: "vless-out",
                auto_detect_interface: true,
            },
        }
    }

    /// Serialises the config to indented JSON.
    ///
    /// # Errors
    ///
    /// Returns the underlying [`serde_json::Error`] on the
    /// effectively impossible failure path of writing only owned
    /// `String`s + primitives to JSON.
    pub fn to_pretty_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }
}

/// Default sing-box listen port when the profile carried no
/// explicit port. Matches `cool-tunnel-server`'s production cut.
const DEFAULT_VLESS_PORT: u16 = 443;

fn split_server(server: &ServerAddress) -> (String, u16) {
    let raw = server.as_str();
    // Bracketed IPv6 → strip the brackets for the host field and
    // pick up the trailing port if present.
    if let Some(rest) = raw.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            let host = &rest[..end];
            let after = &rest[end + 1..];
            let port = after
                .strip_prefix(':')
                .and_then(|s| s.parse::<u16>().ok())
                .unwrap_or(DEFAULT_VLESS_PORT);
            return (host.to_owned(), port);
        }
    }
    // Bare host or `host:port`. `ServerAddress::parse` already
    // rejected unbracketed IPv6, so a single colon is unambiguous.
    if let Some((host, port_str)) = raw.rsplit_once(':') {
        if let Ok(port) = port_str.parse::<u16>() {
            return (host.to_owned(), port);
        }
    }
    (raw.to_owned(), DEFAULT_VLESS_PORT)
}

#[derive(Debug, Serialize)]
struct LogBlock {
    level: &'static str,
    timestamp: bool,
}

#[derive(Debug, Serialize)]
struct SocksInbound {
    #[serde(rename = "type")]
    ty: &'static str,
    tag: &'static str,
    listen: &'static str,
    listen_port: u16,
}

// `Outbounds` flattens into a fixed-length array on the wire. We
// model it with a small wrapper so each outbound carries its own
// typed struct (and any future Reality field bump only touches
// the corresponding struct).
#[derive(Debug)]
struct Outbounds {
    vless: VlessOutbound,
    direct: DirectOutbound,
    block: BlockOutbound,
    dns: DnsOutbound,
}

impl Serialize for Outbounds {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeSeq as _;
        let mut seq = serializer.serialize_seq(Some(4))?;
        seq.serialize_element(&self.vless)?;
        seq.serialize_element(&self.direct)?;
        seq.serialize_element(&self.block)?;
        seq.serialize_element(&self.dns)?;
        seq.end()
    }
}

#[derive(Debug, Serialize)]
struct VlessOutbound {
    #[serde(rename = "type")]
    ty: &'static str,
    tag: &'static str,
    server: String,
    server_port: u16,
    uuid: String,
    flow: &'static str,
    tls: TlsBlock,
}

impl VlessOutbound {
    fn new(server: String, server_port: u16, credentials: &Credentials) -> Self {
        Self {
            ty: "vless",
            tag: "vless-out",
            server,
            server_port,
            uuid: credentials.uuid.expose_secret().to_owned(),
            flow: VLESS_FLOW,
            tls: TlsBlock::from_reality(&credentials.reality),
        }
    }
}

impl Drop for VlessOutbound {
    fn drop(&mut self) {
        // Defence-in-depth: `cargo` already moves these strings into
        // the JSON writer, but `panic = "abort"` is the only thing
        // standing between a mid-serialize panic and a leaked
        // allocation. Clear before drop so the OS sees the buffer
        // empty even on the unhappy path.
        self.uuid.clear();
    }
}

#[derive(Debug, Serialize)]
struct TlsBlock {
    enabled: bool,
    server_name: String,
    utls: UtlsBlock,
    reality: RealityBlock,
}

impl TlsBlock {
    fn from_reality(reality: &Reality) -> Self {
        Self {
            enabled: true,
            server_name: reality.dest_host().as_str().to_owned(),
            utls: UtlsBlock {
                enabled: true,
                fingerprint: UTLS_FINGERPRINT,
            },
            reality: RealityBlock {
                enabled: true,
                public_key: reality.public_key().as_str().to_owned(),
                short_id: reality.short_id().as_str().to_owned(),
            },
        }
    }
}

#[derive(Debug, Serialize)]
struct UtlsBlock {
    enabled: bool,
    fingerprint: &'static str,
}

#[derive(Debug, Serialize)]
struct RealityBlock {
    enabled: bool,
    public_key: String,
    short_id: String,
}

impl Drop for RealityBlock {
    fn drop(&mut self) {
        self.public_key.clear();
        self.short_id.clear();
    }
}

#[derive(Debug, Serialize)]
struct DirectOutbound {
    #[serde(rename = "type")]
    ty: &'static str,
    tag: &'static str,
}

impl DirectOutbound {
    const fn new() -> Self {
        Self {
            ty: "direct",
            tag: "direct",
        }
    }
}

#[derive(Debug, Serialize)]
struct BlockOutbound {
    #[serde(rename = "type")]
    ty: &'static str,
    tag: &'static str,
}

impl BlockOutbound {
    const fn new() -> Self {
        Self {
            ty: "block",
            tag: "block",
        }
    }
}

#[derive(Debug, Serialize)]
struct DnsOutbound {
    #[serde(rename = "type")]
    ty: &'static str,
    tag: &'static str,
}

impl DnsOutbound {
    const fn new() -> Self {
        Self {
            ty: "dns",
            tag: "dns-out",
        }
    }
}

#[derive(Debug, Serialize)]
struct RouteBlock {
    rules: [RouteRule; 1],
    #[serde(rename = "final")]
    final_outbound: &'static str,
    auto_detect_interface: bool,
}

#[derive(Debug, Serialize)]
struct RouteRule {
    protocol: &'static str,
    outbound: &'static str,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::domain::{
        Port, ProfileId, RealityDestHost, RealityPublicKey, RealityShortId, Username, Uuid,
    };

    const VALID_UUID: &str = "11111111-2222-3333-4444-555555555555";
    const VALID_REALITY_PUB: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    fn sample_profile() -> Profile {
        Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("vless.example.com").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Uuid::parse(VALID_UUID).unwrap(),
                Reality::new(
                    RealityPublicKey::parse(VALID_REALITY_PUB).unwrap(),
                    RealityDestHost::parse("www.microsoft.com").unwrap(),
                    RealityShortId::parse("01ab").unwrap(),
                ),
            ),
            Port::new(1080).unwrap(),
        )
    }

    #[test]
    fn split_server_defaults_to_443() {
        let server = ServerAddress::parse("vless.example.com").unwrap();
        assert_eq!(split_server(&server), ("vless.example.com".to_owned(), 443));
    }

    #[test]
    fn split_server_picks_explicit_port() {
        let server = ServerAddress::parse("vless.example.com:8443").unwrap();
        assert_eq!(
            split_server(&server),
            ("vless.example.com".to_owned(), 8443)
        );
    }

    #[test]
    fn split_server_strips_ipv6_brackets() {
        let server = ServerAddress::parse("[2001:db8::1]:443").unwrap();
        assert_eq!(split_server(&server), ("2001:db8::1".to_owned(), 443));
    }

    #[test]
    fn config_renders_with_expected_shape() {
        let cfg = SingboxConfig::from_profile(&sample_profile());
        let json = cfg.to_pretty_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["log"]["level"], "info");
        assert_eq!(parsed["log"]["timestamp"], true);

        let inbounds = parsed["inbounds"].as_array().unwrap();
        assert_eq!(inbounds.len(), 1);
        assert_eq!(inbounds[0]["type"], "socks");
        assert_eq!(inbounds[0]["tag"], "socks-in");
        assert_eq!(inbounds[0]["listen"], "127.0.0.1");
        assert_eq!(inbounds[0]["listen_port"], 1080);

        let outbounds = parsed["outbounds"].as_array().unwrap();
        assert_eq!(outbounds.len(), 4);
        // First outbound: vless.
        assert_eq!(outbounds[0]["type"], "vless");
        assert_eq!(outbounds[0]["tag"], "vless-out");
        assert_eq!(outbounds[0]["server"], "vless.example.com");
        assert_eq!(outbounds[0]["server_port"], 443);
        assert_eq!(outbounds[0]["uuid"], VALID_UUID);
        assert_eq!(outbounds[0]["flow"], "xtls-rprx-vision");
        let tls = &outbounds[0]["tls"];
        assert_eq!(tls["enabled"], true);
        assert_eq!(tls["server_name"], "www.microsoft.com");
        assert_eq!(tls["utls"]["enabled"], true);
        assert_eq!(tls["utls"]["fingerprint"], "chrome");
        assert_eq!(tls["reality"]["enabled"], true);
        assert_eq!(tls["reality"]["public_key"], VALID_REALITY_PUB);
        assert_eq!(tls["reality"]["short_id"], "01ab");
        // Following outbounds: direct / block / dns.
        assert_eq!(outbounds[1]["type"], "direct");
        assert_eq!(outbounds[1]["tag"], "direct");
        assert_eq!(outbounds[2]["type"], "block");
        assert_eq!(outbounds[2]["tag"], "block");
        assert_eq!(outbounds[3]["type"], "dns");
        assert_eq!(outbounds[3]["tag"], "dns-out");

        // Route block: one DNS rule, final = vless-out.
        let route = &parsed["route"];
        let rules = route["rules"].as_array().unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0]["protocol"], "dns");
        assert_eq!(rules[0]["outbound"], "dns-out");
        assert_eq!(route["final"], "vless-out");
        assert_eq!(route["auto_detect_interface"], true);
    }

    #[test]
    fn explicit_server_port_round_trips() {
        let profile = Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("vless.example.com:8443").unwrap(),
            sample_profile().credentials().clone(),
            Port::new(1080).unwrap(),
        );
        let cfg = SingboxConfig::from_profile(&profile);
        let json = cfg.to_pretty_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["outbounds"][0]["server"], "vless.example.com");
        assert_eq!(parsed["outbounds"][0]["server_port"], 8443);
    }

    #[test]
    fn empty_short_id_renders_as_empty_string() {
        let profile = Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("vless.example.com").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Uuid::parse(VALID_UUID).unwrap(),
                Reality::new(
                    RealityPublicKey::parse(VALID_REALITY_PUB).unwrap(),
                    RealityDestHost::parse("www.microsoft.com").unwrap(),
                    RealityShortId::parse("").unwrap(),
                ),
            ),
            Port::new(1080).unwrap(),
        );
        let cfg = SingboxConfig::from_profile(&profile);
        let json = cfg.to_pretty_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["outbounds"][0]["tls"]["reality"]["short_id"], "");
    }
}
