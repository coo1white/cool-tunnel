// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Validated upstream proxy server address (host or `host:port`).

use std::str::FromStr;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::port::Port;

/// A validated upstream server address.
///
/// Accepts either a bare hostname (`naive.example.com`) or a hostname with an
/// explicit port (`naive.example.com:8443`). The following are rejected:
///
/// - empty strings,
/// - addresses longer than 253 characters,
/// - addresses containing whitespace,
/// - URL schemes (`https://`), userinfo (`user@`), paths, queries, fragments,
/// - empty host before the `:` separator,
/// - non-numeric or out-of-range port suffixes.
///
/// The check matches the rules implemented in the Swift app's
/// `validatedServerString()`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ServerAddress(String);

impl ServerAddress {
    /// RFC 1035 fully-qualified domain name byte cap. **v0.1.7.13
    /// (R-F#3):** promoted from `const` (private) to `pub const`
    /// so `server_mode::MAX_PAC_DOMAIN_BYTES` can reference it
    /// instead of duplicating the literal `253`. Single source
    /// of truth — a future bump (e.g. for an IDN edge case) only
    /// needs to change this one number.
    pub const MAX_LEN: usize = 253;
    const FORBIDDEN: &'static [&'static str] = &["://", "@", "/", "?", "#"];

    /// Parses and validates a server address.
    ///
    /// Accepts hostnames, IPv4 literals, and bracketed IPv6 literals
    /// (`[2001:db8::1]:443`). Bare IPv6 literals (e.g. `2001:db8::1`)
    /// are rejected because `rfind(':')` would split them at the
    /// last colon and treat `1` as a port — silently misleading the
    /// downstream resolver. Brackets are the unambiguous form.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidServer`] describing the first rule violated.
    pub fn parse(input: &str) -> Result<Self, InvalidServer> {
        let trimmed = input.trim();

        if trimmed.is_empty() {
            return Err(InvalidServer::Empty);
        }
        // RFC 1035 caps fully-qualified domain names at 253 octets. A
        // unicode hostname can pass a `chars().count()` check while
        // exceeding that limit in bytes, so check the byte length here.
        if trimmed.len() > Self::MAX_LEN {
            return Err(InvalidServer::TooLong);
        }
        if trimmed.chars().any(char::is_whitespace) {
            return Err(InvalidServer::ContainsWhitespace);
        }
        for forbidden in Self::FORBIDDEN {
            if trimmed.contains(forbidden) {
                return Err(InvalidServer::ContainsForbidden(forbidden));
            }
        }
        // Bracketed IPv6 form: `[host]:port` or `[host]`. The `]` is
        // the structural separator between host and the optional
        // port suffix; we extract the inner host between the
        // brackets and validate the port (if any) separately.
        if let Some(rest) = trimmed.strip_prefix('[') {
            let Some(end) = rest.find(']') else {
                return Err(InvalidServer::UnclosedBracket);
            };
            let host = &rest[..end];
            if host.is_empty() {
                return Err(InvalidServer::EmptyHost);
            }
            let after = &rest[end + 1..];
            if !after.is_empty() {
                let Some(port_str) = after.strip_prefix(':') else {
                    return Err(InvalidServer::InvalidPort);
                };
                Port::from_str(port_str).map_err(|_| InvalidServer::InvalidPort)?;
            }
            return Ok(Self(trimmed.to_owned()));
        }
        // Bare strings with multiple colons are almost certainly
        // unbracketed IPv6 literals; `rfind(':')` would split them
        // at the wrong place and silently produce a host with an
        // embedded `:` plus a "port" that's actually the last v6
        // group. Refuse and tell the caller to bracket.
        if trimmed.matches(':').count() > 1 {
            return Err(InvalidServer::AmbiguousIPv6);
        }
        if let Some(idx) = trimmed.rfind(':') {
            let host = &trimmed[..idx];
            let port_str = &trimmed[idx + 1..];
            if host.is_empty() {
                return Err(InvalidServer::EmptyHost);
            }
            Port::from_str(port_str).map_err(|_| InvalidServer::InvalidPort)?;
        }

        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the validated address as a string slice.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ServerAddress {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for ServerAddress {
    type Err = InvalidServer;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl TryFrom<String> for ServerAddress {
    type Error = InvalidServer;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<ServerAddress> for String {
    fn from(value: ServerAddress) -> Self {
        value.0
    }
}

/// Reasons a server string failed validation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Error)]
#[non_exhaustive]
pub enum InvalidServer {
    /// The trimmed input was empty.
    #[error("server address must not be empty")]
    Empty,
    /// The address exceeded 253 characters.
    #[error("server address exceeds 253 characters")]
    TooLong,
    /// The address contained whitespace.
    #[error("server address must not contain whitespace")]
    ContainsWhitespace,
    /// The address contained a forbidden substring (scheme, userinfo, path, etc.).
    #[error("server address must not contain {0:?}")]
    ContainsForbidden(&'static str),
    /// The host portion before the trailing `:` was empty.
    #[error("server address has empty host before ':'")]
    EmptyHost,
    /// The port suffix did not parse as a valid [`Port`].
    #[error("server address has invalid port")]
    InvalidPort,
    /// A `[` opened but no matching `]` was found.
    #[error("server address has unclosed '[' for IPv6 literal")]
    UnclosedBracket,
    /// A bare (unbracketed) string contained more than one `:` —
    /// almost certainly an unbracketed IPv6 literal that would be
    /// mis-parsed by `rfind(':')`. Bracket the address as
    /// `[2001:db8::1]:443` to disambiguate.
    #[error("server address looks like an unbracketed IPv6 literal; use brackets, e.g. [2001:db8::1]:443")]
    AmbiguousIPv6,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn accepts_bare_hostname() {
        let addr = ServerAddress::parse("naive.example.com").unwrap();
        assert_eq!(addr.as_str(), "naive.example.com");
    }

    #[test]
    fn accepts_hostname_with_port() {
        let addr = ServerAddress::parse("naive.example.com:8443").unwrap();
        assert_eq!(addr.as_str(), "naive.example.com:8443");
    }

    #[test]
    fn trims_surrounding_whitespace() {
        let addr = ServerAddress::parse("  naive.example.com  ").unwrap();
        assert_eq!(addr.as_str(), "naive.example.com");
    }

    #[test]
    fn rejects_scheme() {
        assert!(matches!(
            ServerAddress::parse("https://naive.example.com"),
            Err(InvalidServer::ContainsForbidden("://"))
        ));
    }

    #[test]
    fn rejects_userinfo() {
        assert!(matches!(
            ServerAddress::parse("user@naive.example.com"),
            Err(InvalidServer::ContainsForbidden("@"))
        ));
    }

    #[test]
    fn rejects_path() {
        assert!(matches!(
            ServerAddress::parse("naive.example.com/path"),
            Err(InvalidServer::ContainsForbidden("/"))
        ));
    }

    #[test]
    fn rejects_internal_whitespace() {
        assert!(matches!(
            ServerAddress::parse("naive example.com"),
            Err(InvalidServer::ContainsWhitespace)
        ));
    }

    #[test]
    fn rejects_empty() {
        assert!(matches!(
            ServerAddress::parse(""),
            Err(InvalidServer::Empty)
        ));
        assert!(matches!(
            ServerAddress::parse("   "),
            Err(InvalidServer::Empty)
        ));
    }

    #[test]
    fn rejects_too_long() {
        let long = "a".repeat(254);
        assert!(matches!(
            ServerAddress::parse(&long),
            Err(InvalidServer::TooLong)
        ));
    }

    #[test]
    fn rejects_invalid_port_suffix() {
        assert!(matches!(
            ServerAddress::parse("naive.example.com:0"),
            Err(InvalidServer::InvalidPort)
        ));
        assert!(matches!(
            ServerAddress::parse("naive.example.com:abc"),
            Err(InvalidServer::InvalidPort)
        ));
    }

    #[test]
    fn rejects_empty_host_before_port() {
        assert!(matches!(
            ServerAddress::parse(":8443"),
            Err(InvalidServer::EmptyHost)
        ));
    }

    #[test]
    fn serde_roundtrips_as_string() {
        let addr = ServerAddress::parse("naive.example.com:8443").unwrap();
        let json = serde_json::to_string(&addr).unwrap();
        assert_eq!(json, "\"naive.example.com:8443\"");
        let back: ServerAddress = serde_json::from_str(&json).unwrap();
        assert_eq!(back, addr);
    }

    #[test]
    fn serde_rejects_invalid() {
        assert!(serde_json::from_str::<ServerAddress>("\"https://x\"").is_err());
    }

    #[test]
    fn accepts_bracketed_ipv6_with_port() {
        let addr = ServerAddress::parse("[2001:db8::1]:443").unwrap();
        assert_eq!(addr.as_str(), "[2001:db8::1]:443");
    }

    #[test]
    fn accepts_bracketed_ipv6_without_port() {
        let addr = ServerAddress::parse("[2001:db8::1]").unwrap();
        assert_eq!(addr.as_str(), "[2001:db8::1]");
    }

    #[test]
    fn accepts_bracketed_ipv6_loopback() {
        let addr = ServerAddress::parse("[::1]:443").unwrap();
        assert_eq!(addr.as_str(), "[::1]:443");
    }

    #[test]
    fn rejects_bare_ipv6_as_ambiguous() {
        assert!(matches!(
            ServerAddress::parse("2001:db8::1"),
            Err(InvalidServer::AmbiguousIPv6)
        ));
    }

    #[test]
    fn rejects_unclosed_bracket() {
        assert!(matches!(
            ServerAddress::parse("[2001:db8::1"),
            Err(InvalidServer::UnclosedBracket)
        ));
    }

    #[test]
    fn rejects_bracketed_with_empty_host() {
        assert!(matches!(
            ServerAddress::parse("[]:443"),
            Err(InvalidServer::EmptyHost)
        ));
    }

    #[test]
    fn rejects_bracketed_with_invalid_port() {
        assert!(matches!(
            ServerAddress::parse("[::1]:99999"),
            Err(InvalidServer::InvalidPort)
        ));
    }

    #[test]
    fn rejects_bracketed_with_junk_after_close_bracket() {
        // `]port` (no `:` separator) is malformed.
        assert!(matches!(
            ServerAddress::parse("[::1]443"),
            Err(InvalidServer::InvalidPort)
        ));
    }

    #[test]
    fn rejects_bracketed_with_empty_port_suffix() {
        // `]:` with no digits after is malformed.
        assert!(matches!(
            ServerAddress::parse("[::1]:"),
            Err(InvalidServer::InvalidPort)
        ));
    }
}
