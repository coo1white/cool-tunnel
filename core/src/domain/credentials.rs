//! Username, password, and the percent-encoder used to embed them in URLs.
//!
//! The encoder matches Swift's `CharacterSet.urlUserAllowed` minus
//! `:@/?#[]`, so the wire output is byte-identical to the Swift app.

use std::fmt::Write as _;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// A non-empty, whitespace-trimmed proxy username.
///
/// `Debug` and `Display` redact the contents to match [`Password`].
/// Usernames are less sensitive than passwords, but they are still
/// account identifiers — leaking them via a stray `info!("user: {u}")`
/// or panic message would aid credential stuffing. The plaintext is
/// reachable only via [`Username::as_str`], which callers must treat
/// as sensitive (do not log, do not include in errors that cross the
/// process boundary).
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Username(String);

impl Username {
    /// Parses and validates a username.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidCredentials::EmptyUsername`] if the trimmed input is empty.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyUsername);
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the username as a string slice. Sensitive — callers
    /// must not log it or persist it unencrypted outside the audited
    /// `Credentials` -> `EncodedCredentials` -> `naive config.json`
    /// path that always lands behind 0600 file permissions.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for Username {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Match Password: never reveal plaintext through Debug. A
        // panic that captures Credentials, a tracing macro that
        // formats the struct with `{:?}`, or a test snapshot would
        // otherwise expose the username.
        f.debug_tuple("Username").field(&"***").finish()
    }
}

impl std::fmt::Display for Username {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Display is intentionally redacted for the same reason as
        // Debug. URL embedding goes through `percent_encoded()` which
        // calls `as_str()` directly, so the plaintext path is the
        // explicit one — implicit `format!("{}", username)` cannot
        // accidentally leak.
        f.write_str("***")
    }
}

impl TryFrom<String> for Username {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<Username> for String {
    fn from(value: Username) -> Self {
        value.0
    }
}

/// A non-empty, whitespace-trimmed proxy password.
///
/// `Debug` and `Display` redact the contents. The plaintext is reachable only
/// via [`Password::expose_secret`] — callers that invoke it must treat the
/// returned string as sensitive (do not log, do not serialize unencrypted).
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Password(String);

impl Password {
    /// Parses and validates a password.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidCredentials::EmptyPassword`] if the trimmed input is empty.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyPassword);
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the plaintext password.
    ///
    /// The result is sensitive. Callers must not log it or persist it
    /// unencrypted. The verbose name is intentional, modelled after the
    /// `secrecy` crate's `ExposeSecret` trait.
    #[must_use]
    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for Password {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Password").field(&"***").finish()
    }
}

impl TryFrom<String> for Password {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<Password> for String {
    fn from(value: Password) -> Self {
        value.0
    }
}

/// Username and password presented to the upstream proxy.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Credentials {
    /// Account name.
    pub username: Username,
    /// Secret.
    pub password: Password,
}

impl Credentials {
    /// Constructs a credential pair from already-validated parts.
    #[must_use]
    pub const fn new(username: Username, password: Password) -> Self {
        Self { username, password }
    }

    /// Returns a percent-encoded copy of these credentials, suitable for
    /// embedding in a URL's userinfo segment.
    #[must_use]
    pub fn percent_encoded(&self) -> EncodedCredentials {
        EncodedCredentials {
            username: percent_encode_userinfo(self.username.as_str()),
            password: percent_encode_userinfo(self.password.expose_secret()),
        }
    }
}

/// Percent-encoded credential pair, ready for URL embedding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedCredentials {
    /// Percent-encoded username.
    pub username: String,
    /// Percent-encoded password.
    pub password: String,
}

/// Reasons a credential pair failed validation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Error)]
#[non_exhaustive]
pub enum InvalidCredentials {
    /// The trimmed username was empty.
    #[error("username must not be empty")]
    EmptyUsername,
    /// The trimmed password was empty.
    #[error("password must not be empty")]
    EmptyPassword,
}

/// Percent-encodes a string against the URL userinfo character set used by
/// Swift (`CharacterSet.urlUserAllowed` minus `:@/?#[]`).
fn percent_encode_userinfo(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        if is_unreserved_or_subdelim(byte) {
            out.push(char::from(byte));
        } else {
            // Writing to a String is infallible, so the result is always Ok.
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

const fn is_unreserved_or_subdelim(byte: u8) -> bool {
    matches!(
        byte,
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
        | b'-' | b'.' | b'_' | b'~'
        | b'!' | b'$' | b'&' | b'\'' | b'(' | b')'
        | b'*' | b'+' | b',' | b';' | b'='
    )
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_username() {
        assert_eq!(
            Username::parse("   "),
            Err(InvalidCredentials::EmptyUsername)
        );
    }

    #[test]
    fn rejects_empty_password() {
        assert_eq!(Password::parse(""), Err(InvalidCredentials::EmptyPassword));
    }

    #[test]
    fn password_debug_redacts() {
        let p = Password::parse("hunter2").unwrap();
        assert_eq!(format!("{p:?}"), "Password(\"***\")");
    }

    /// `Username::Debug` must redact the plaintext exactly like
    /// `Password`. The original implementation forwarded `&self.0` to
    /// `debug_tuple` which leaked the username on every panic /
    /// tracing dump that captured a `Credentials` struct.
    #[test]
    fn username_debug_redacts() {
        let u = Username::parse("nick").unwrap();
        assert_eq!(format!("{u:?}"), "Username(\"***\")");
    }

    /// `Username::Display` must redact too — the `{}` formatter would
    /// otherwise put the plaintext into any log line the caller forgot
    /// to special-case.
    #[test]
    fn username_display_redacts() {
        let u = Username::parse("nick").unwrap();
        assert_eq!(format!("{u}"), "***");
    }

    /// Round-trip the full `Credentials` struct through `{:?}` to
    /// guarantee neither field leaks even when both appear together.
    #[test]
    fn credentials_debug_redacts_both_fields() {
        let c = Credentials::new(
            Username::parse("nick").unwrap(),
            Password::parse("hunter2").unwrap(),
        );
        let dump = format!("{c:?}");
        assert!(!dump.contains("nick"), "username leaked via Debug: {dump}");
        assert!(
            !dump.contains("hunter2"),
            "password leaked via Debug: {dump}"
        );
    }

    #[test]
    fn password_expose_secret_returns_plaintext() {
        let p = Password::parse("hunter2").unwrap();
        assert_eq!(p.expose_secret(), "hunter2");
    }

    #[test]
    fn percent_encoding_preserves_unreserved() {
        assert_eq!(percent_encode_userinfo("nick"), "nick");
        assert_eq!(percent_encode_userinfo("a-b.c_d~e"), "a-b.c_d~e");
        assert_eq!(percent_encode_userinfo("0123456789"), "0123456789");
    }

    #[test]
    fn percent_encoding_escapes_reserved() {
        assert_eq!(percent_encode_userinfo("a:b"), "a%3Ab");
        assert_eq!(percent_encode_userinfo("a@b"), "a%40b");
        assert_eq!(percent_encode_userinfo("a/b"), "a%2Fb");
        assert_eq!(percent_encode_userinfo("a?b"), "a%3Fb");
        assert_eq!(percent_encode_userinfo("a#b"), "a%23b");
        assert_eq!(percent_encode_userinfo("a[b]"), "a%5Bb%5D");
    }

    #[test]
    fn percent_encoding_handles_non_ascii_utf8() {
        // "é" is U+00E9, encoded as bytes C3 A9.
        assert_eq!(percent_encode_userinfo("é"), "%C3%A9");
    }

    #[test]
    fn credentials_percent_encoded_pair() {
        let creds = Credentials::new(
            Username::parse("nick").unwrap(),
            Password::parse("p@ss/word").unwrap(),
        );
        let encoded = creds.percent_encoded();
        assert_eq!(encoded.username, "nick");
        assert_eq!(encoded.password, "p%40ss%2Fword");
    }
}
