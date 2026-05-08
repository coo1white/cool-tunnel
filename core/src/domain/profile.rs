// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Aggregate proxy profile combining server, credentials, and local port.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::credentials::{Credentials, InvalidCredentials, Password, Username};
use super::port::{InvalidPort, Port};
use super::server::{InvalidServer, ServerAddress};

/// Stable identifier for a [`Profile`].
///
/// The string is opaque — the engine never interprets its contents — but it
/// must remain stable across edits so the Swift UI can correlate updates.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProfileId(String);

impl ProfileId {
    /// Wraps a string identifier.
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    /// Returns the identifier as a string slice.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ProfileId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Validated proxy profile.
///
/// A `Profile` cannot exist in an invalid state: every field has been
/// validated by the corresponding domain type. Construct one via
/// [`Profile::new`] from already-validated components, or by deserializing
/// the wire format ([`RawProfile`]) — the latter runs validation
/// automatically through `serde(try_from)`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawProfile", into = "RawProfile")]
pub struct Profile {
    id: ProfileId,
    server: ServerAddress,
    credentials: Credentials,
    local_port: Port,
}

impl Profile {
    /// Constructs a profile from already-validated components.
    #[must_use]
    pub const fn new(
        id: ProfileId,
        server: ServerAddress,
        credentials: Credentials,
        local_port: Port,
    ) -> Self {
        Self {
            id,
            server,
            credentials,
            local_port,
        }
    }

    /// Returns the profile identifier.
    #[must_use]
    pub const fn id(&self) -> &ProfileId {
        &self.id
    }

    /// Returns the upstream server address.
    #[must_use]
    pub const fn server(&self) -> &ServerAddress {
        &self.server
    }

    /// Returns the proxy credentials.
    #[must_use]
    pub const fn credentials(&self) -> &Credentials {
        &self.credentials
    }

    /// Returns the local SOCKS listener port.
    #[must_use]
    pub const fn local_port(&self) -> Port {
        self.local_port
    }
}

/// Wire-format representation matching the Swift `ProxyProfile` JSON shape.
///
/// Each field is a `String`, so the structure can be deserialized even when
/// values are invalid; validation is run during the conversion to [`Profile`].
///
/// `Debug` is **manually implemented** to redact `username` and
/// `password`. The auto-derived `Debug` would print cleartext —
/// no current call site formats a `RawProfile`, but the
/// type *is* the wire shape, and a future
/// `tracing::warn!(?raw, "deserialize failed")` site (the
/// natural place to log a deserialize error) would silently
/// dump cleartext credentials at info level into the engine's
/// stderr stream → forwarded to `os_log` by the Swift
/// `engineStderrLogger` → support bundle. Eliminate the
/// foot-gun pre-emptively. Mirrors the redaction discipline
/// already on `Username`, `Password`, and `EncodedCredentials`
/// in `core/src/domain/credentials.rs`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawProfile {
    /// Stable identifier.
    pub id: String,
    /// Server address (`host` or `host:port`).
    pub server: String,
    /// Proxy username.
    pub username: String,
    /// Proxy password.
    pub password: String,
    /// Local SOCKS listener port (decimal string).
    #[serde(rename = "localPort")]
    pub local_port: String,
}

impl std::fmt::Debug for RawProfile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RawProfile")
            .field("id", &self.id)
            .field("server", &self.server)
            .field("username", &"***")
            .field("password", &"***")
            .field("local_port", &self.local_port)
            .finish()
    }
}

impl TryFrom<RawProfile> for Profile {
    type Error = ValidationError;

    fn try_from(raw: RawProfile) -> Result<Self, Self::Error> {
        let id = ProfileId::new(raw.id);
        let server = ServerAddress::parse(&raw.server)?;
        let username = Username::parse(&raw.username)?;
        let password = Password::parse(&raw.password)?;
        let credentials = Credentials::new(username, password);
        let local_port: Port = raw.local_port.parse()?;
        Ok(Self::new(id, server, credentials, local_port))
    }
}

impl From<Profile> for RawProfile {
    fn from(profile: Profile) -> Self {
        Self {
            id: String::from(profile.id),
            server: profile.server.into(),
            username: profile.credentials.username.into(),
            password: profile.credentials.password.into(),
            local_port: profile.local_port.get().to_string(),
        }
    }
}

impl From<ProfileId> for String {
    fn from(value: ProfileId) -> Self {
        value.0
    }
}

/// Aggregate validation error returned when constructing a [`Profile`].
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum ValidationError {
    /// The local port failed validation.
    #[error(transparent)]
    Port(#[from] InvalidPort),
    /// The server address failed validation.
    #[error(transparent)]
    Server(#[from] InvalidServer),
    /// The credentials failed validation.
    #[error(transparent)]
    Credentials(#[from] InvalidCredentials),
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    fn raw_ok() -> RawProfile {
        RawProfile {
            id: "default".to_owned(),
            server: "naive.example.com".to_owned(),
            username: "alice".to_owned(),
            password: "secret".to_owned(),
            local_port: "1080".to_owned(),
        }
    }

    #[test]
    fn deserializes_validated_profile() {
        let json = serde_json::json!({
            "id": "default",
            "server": "naive.example.com",
            "username": "alice",
            "password": "secret",
            "localPort": "1080"
        });
        let profile: Profile = serde_json::from_value(json).unwrap();
        assert_eq!(profile.id().as_str(), "default");
        assert_eq!(profile.server().as_str(), "naive.example.com");
        assert_eq!(profile.local_port().get(), 1080);
    }

    #[test]
    fn rejects_invalid_server_during_deserialization() {
        let mut raw = raw_ok();
        raw.server = "https://naive.example.com".to_owned();
        let json = serde_json::to_value(&raw).unwrap();
        let err = serde_json::from_value::<Profile>(json).unwrap_err();
        assert!(err.to_string().contains("server address must not contain"));
    }

    #[test]
    fn rejects_zero_port() {
        let mut raw = raw_ok();
        raw.local_port = "0".to_owned();
        let err = Profile::try_from(raw).unwrap_err();
        assert!(matches!(err, ValidationError::Port(_)));
    }

    #[test]
    fn rejects_empty_credentials() {
        let mut raw = raw_ok();
        raw.password = "   ".to_owned();
        let err = Profile::try_from(raw).unwrap_err();
        assert!(matches!(
            err,
            ValidationError::Credentials(InvalidCredentials::EmptyPassword)
        ));
    }

    #[test]
    fn roundtrip_to_raw_and_back() {
        let raw = raw_ok();
        let profile = Profile::try_from(raw.clone()).unwrap();
        let back: RawProfile = profile.into();
        assert_eq!(back, raw);
    }
}
