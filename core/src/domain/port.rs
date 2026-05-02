//! TCP port newtype guaranteeing the inclusive range `1..=65535`.

use std::str::FromStr;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// A TCP port number in the inclusive range `1..=65535`.
///
/// `Port` is constructed via [`Port::new`], `TryFrom<u16>`, or by parsing a
/// string with [`FromStr`]. The zero port (system-allocated) is rejected
/// because the COOL-TUNNEL listener requires a stable, user-chosen port.
///
/// # Examples
///
/// ```
/// use cool_tunnel_core::domain::Port;
///
/// let p = Port::new(1080).expect("1080 is a valid port");
/// assert_eq!(p.get(), 1080);
/// assert!(Port::new(0).is_err());
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub struct Port(u16);

impl Port {
    /// The lowest valid port number.
    pub const MIN: u16 = 1;
    /// The highest valid port number.
    pub const MAX: u16 = u16::MAX;

    /// Constructs a [`Port`] from a `u16`.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidPort`] when `value` is `0`.
    pub const fn new(value: u16) -> Result<Self, InvalidPort> {
        if value == 0 {
            Err(InvalidPort)
        } else {
            Ok(Self(value))
        }
    }

    /// Returns the underlying port number.
    #[must_use]
    pub const fn get(self) -> u16 {
        self.0
    }
}

impl TryFrom<u16> for Port {
    type Error = InvalidPort;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<Port> for u16 {
    fn from(value: Port) -> Self {
        value.0
    }
}

impl std::fmt::Display for Port {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for Port {
    type Err = InvalidPort;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let trimmed = s.trim();
        let value: u16 = trimmed.parse().map_err(|_| InvalidPort)?;
        Self::new(value)
    }
}

/// Returned when a port value is `0` or otherwise out of range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Error)]
#[error("port must be between 1 and 65535")]
pub struct InvalidPort;

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn rejects_zero() {
        assert_eq!(Port::new(0), Err(InvalidPort));
    }

    #[test]
    fn accepts_boundaries() {
        assert_eq!(Port::new(1).unwrap().get(), 1);
        assert_eq!(Port::new(u16::MAX).unwrap().get(), u16::MAX);
    }

    #[test]
    fn parses_from_trimmed_string() {
        assert_eq!("  1080  ".parse::<Port>().unwrap().get(), 1080);
        assert!("0".parse::<Port>().is_err());
        assert!("not-a-port".parse::<Port>().is_err());
        assert!("70000".parse::<Port>().is_err());
    }

    #[test]
    fn serde_roundtrips_as_u16() {
        let p = Port::new(8080).unwrap();
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, "8080");
        let back: Port = serde_json::from_str(&json).unwrap();
        assert_eq!(back, p);
    }

    #[test]
    fn serde_rejects_zero() {
        let err = serde_json::from_str::<Port>("0").unwrap_err();
        assert!(err.to_string().contains("port must be between 1 and 65535"));
    }
}
