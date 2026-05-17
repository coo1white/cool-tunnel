// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! VLESS account credentials and Reality handshake parameters.
//!
//! v3.0.0 pivot: NaiveProxy's `Authorization: Basic <user:pass>` is
//! gone. Sing-box VLESS authenticates with a UUID (RFC 4122) and
//! the Reality transport layers an X25519 public key + dest-SNI
//! over TLS to keep the handshake indistinguishable from a real
//! visit to the cover site.
//!
//! Every value type here validates at construction and redacts in
//! `Debug` / `Display`. The Swift app already treats UUIDs as
//! account-grade secrets (panic loggers, support bundles, etc.)
//! and the Reality public_key + short_id are equally credential-
//! shaped for the rendered config blob.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// A non-empty, whitespace-trimmed VLESS account name.
///
/// Carried through to sing-box's `users[].name` field; sing-box does
/// not authenticate on the name (UUID does that), but it appears in
/// server logs so we keep the panel's `alphaDash` + max-64 rule so
/// the client and server agree on which names are admissible.
///
/// `Debug` and `Display` redact the contents — account names are
/// not as sensitive as UUIDs but they identify a user; leaking one
/// via `info!("user: {u}")` aids correlation attacks.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Username(String);

/// Maximum username length, mirroring the Laravel panel's
/// `TextInput::make('username')->maxLength(64)` validation rule
/// in `panel/app/Filament/Resources/ProxyAccountResource.php`.
/// Aligns local validation with server-side so a username the
/// panel rejects with HTTP 422 also fails locally before the engine
/// ever hits the wire.
pub const USERNAME_MAX_LEN: usize = 64;

/// Canonical RFC 4122 UUID length: `8-4-4-4-12` hex digits plus
/// four dashes = 36 characters. We accept only the lowercase
/// hyphenated form sing-box emits, matching the `cool-tunnel-server`
/// `singbox-core` keygen output.
pub const UUID_LEN: usize = 36;

/// Maximum byte length of a Reality `short_id`. The wire field is
/// an even-length hex string (0–16 chars) per the sing-box server
/// validator. We accept up to 16 chars here to mirror that.
pub const REALITY_SHORT_ID_MAX_LEN: usize = 16;

/// Length of the decoded Reality public key (X25519, 32 bytes).
/// The wire form is base64url; the constructor decodes and verifies
/// the length so a typo cannot smuggle a wrong-shaped key into the
/// rendered config.
pub const REALITY_PUBLIC_KEY_DECODED_LEN: usize = 32;

impl Username {
    /// Parses and validates a username.
    ///
    /// Mirrors the Laravel panel's `alphaDash` + `maxLength(64)`
    /// rules: ASCII letters, digits, dash, underscore.
    ///
    /// # Errors
    ///
    /// - [`InvalidCredentials::EmptyUsername`] if trimmed input
    ///   is empty.
    /// - [`InvalidCredentials::UsernameTooLong`] if the trimmed
    ///   input exceeds [`USERNAME_MAX_LEN`].
    /// - [`InvalidCredentials::IllegalUsernameChar`] if the
    ///   trimmed input contains a non-`alphaDash` character.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyUsername);
        }
        if trimmed.len() > USERNAME_MAX_LEN {
            return Err(InvalidCredentials::UsernameTooLong {
                max: USERNAME_MAX_LEN,
                got: trimmed.len(),
            });
        }
        if let Some(bad) = trimmed.chars().find(|c| !is_alpha_dash(*c)) {
            return Err(InvalidCredentials::IllegalUsernameChar(bad));
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the username as a string slice. Sensitive — callers
    /// must not log it.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for Username {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Username").field(&"***").finish()
    }
}

impl std::fmt::Display for Username {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
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

/// A validated RFC 4122 UUID used as the VLESS user_id.
///
/// `Debug` and `Display` redact the contents. Plaintext is
/// reachable only via [`Uuid::expose_secret`]. The UUID is the
/// sole auth credential for sing-box VLESS — leakage is account
/// takeover.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Uuid(String);

impl Uuid {
    /// Parses and validates an RFC 4122 UUID string in lowercase
    /// hyphenated form (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
    ///
    /// # Errors
    ///
    /// - [`InvalidCredentials::EmptyUuid`] when trimmed input is empty.
    /// - [`InvalidCredentials::MalformedUuid`] when the input is the
    ///   wrong length, has dashes in the wrong position, or contains
    ///   a non-hex digit.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyUuid);
        }
        if trimmed.len() != UUID_LEN {
            return Err(InvalidCredentials::MalformedUuid);
        }
        // Position-checked dashes plus hex-only nibbles. Avoids
        // pulling in a regex (we already have one redactor regex,
        // but the parse hot path runs once per profile decode).
        let bytes = trimmed.as_bytes();
        for (idx, &b) in bytes.iter().enumerate() {
            let want_dash = matches!(idx, 8 | 13 | 18 | 23);
            if want_dash {
                if b != b'-' {
                    return Err(InvalidCredentials::MalformedUuid);
                }
            } else if !b.is_ascii_hexdigit() {
                return Err(InvalidCredentials::MalformedUuid);
            }
        }
        Ok(Self(trimmed.to_ascii_lowercase()))
    }

    /// Returns the plaintext UUID.
    ///
    /// Sensitive. Callers must not log or persist unencrypted.
    #[must_use]
    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for Uuid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Uuid").field(&"***").finish()
    }
}

impl TryFrom<String> for Uuid {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<Uuid> for String {
    fn from(value: Uuid) -> Self {
        value.0
    }
}

/// Reality transport parameters paired with the server's keypair.
///
/// `public_key` and `short_id` are credential-shaped — leakage
/// allows an attacker to author config bundles that present as
/// this server. `Debug` redacts both.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "RawReality", into = "RawReality")]
pub struct Reality {
    public_key: RealityPublicKey,
    dest_host: RealityDestHost,
    short_id: RealityShortId,
}

impl Reality {
    /// Constructs a Reality block from already-validated parts.
    #[must_use]
    pub const fn new(
        public_key: RealityPublicKey,
        dest_host: RealityDestHost,
        short_id: RealityShortId,
    ) -> Self {
        Self {
            public_key,
            dest_host,
            short_id,
        }
    }

    /// Returns the X25519 public key (base64url).
    #[must_use]
    pub fn public_key(&self) -> &RealityPublicKey {
        &self.public_key
    }

    /// Returns the cover-site FQDN used as Reality SNI.
    #[must_use]
    pub fn dest_host(&self) -> &RealityDestHost {
        &self.dest_host
    }

    /// Returns the Reality short_id (possibly empty).
    #[must_use]
    pub fn short_id(&self) -> &RealityShortId {
        &self.short_id
    }
}

impl std::fmt::Debug for Reality {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Reality")
            .field("public_key", &"***")
            .field("dest_host", &self.dest_host)
            .field("short_id", &"***")
            .finish()
    }
}

/// Wire-format representation of [`Reality`]. Each field is a
/// `String` so `serde_json::from_value` can deserialize even when
/// values are invalid; validation runs in the conversion to
/// [`Reality`].
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RawReality {
    /// X25519 public key, base64url (32 bytes after decode).
    pub public_key: String,
    /// Cover-site FQDN (e.g. `www.microsoft.com`).
    pub dest_host: String,
    /// Reality short_id (hex, even length, 0–16 chars; `""` means
    /// no challenge — the server-side `singbox-core` config emits
    /// this default).
    pub short_id: String,
}

impl std::fmt::Debug for RawReality {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RawReality")
            .field("public_key", &"***")
            .field("dest_host", &self.dest_host)
            .field("short_id", &"***")
            .finish()
    }
}

impl TryFrom<RawReality> for Reality {
    type Error = InvalidCredentials;

    fn try_from(raw: RawReality) -> Result<Self, Self::Error> {
        let public_key = RealityPublicKey::parse(&raw.public_key)?;
        let dest_host = RealityDestHost::parse(&raw.dest_host)?;
        let short_id = RealityShortId::parse(&raw.short_id)?;
        Ok(Self::new(public_key, dest_host, short_id))
    }
}

impl From<Reality> for RawReality {
    fn from(value: Reality) -> Self {
        Self {
            public_key: value.public_key.into(),
            dest_host: value.dest_host.into(),
            short_id: value.short_id.into(),
        }
    }
}

/// Base64url-encoded Reality X25519 public key.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RealityPublicKey(String);

impl RealityPublicKey {
    /// Parses a base64url-encoded X25519 public key.
    ///
    /// Accepts both padded and unpadded base64url; verifies the
    /// decoded length is exactly [`REALITY_PUBLIC_KEY_DECODED_LEN`]
    /// (32 bytes). The crate has no base64 dependency, so this
    /// implements the decode inline — RFC 4648 base64url alphabet
    /// (`A–Z a–z 0–9 - _`).
    ///
    /// # Errors
    ///
    /// - [`InvalidCredentials::EmptyRealityPublicKey`] when trimmed
    ///   input is empty.
    /// - [`InvalidCredentials::MalformedRealityPublicKey`] when the
    ///   alphabet, padding, or decoded length is wrong.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyRealityPublicKey);
        }
        let decoded =
            decode_base64url(trimmed).ok_or(InvalidCredentials::MalformedRealityPublicKey)?;
        if decoded.len() != REALITY_PUBLIC_KEY_DECODED_LEN {
            return Err(InvalidCredentials::MalformedRealityPublicKey);
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the wire-form (base64url) public key string.
    ///
    /// Sensitive. Callers must not log it.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for RealityPublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("RealityPublicKey").field(&"***").finish()
    }
}

impl TryFrom<String> for RealityPublicKey {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<RealityPublicKey> for String {
    fn from(value: RealityPublicKey) -> Self {
        value.0
    }
}

/// Validated Reality `dest_host` (cover-site FQDN).
///
/// Reuses the same RFC 1035-derived rules as
/// [`super::ServerAddress`] but rejects scheme / port / userinfo /
/// path — the dest_host is always a bare hostname, sing-box adds
/// `:443` itself.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RealityDestHost(String);

impl RealityDestHost {
    /// RFC 1035 cap, same byte limit as `ServerAddress::MAX_LEN`.
    pub const MAX_LEN: usize = 253;
    /// Forbidden substrings — same set as `ServerAddress`, plus `:`
    /// because a dest_host with an embedded port would confuse the
    /// sing-box config writer.
    const FORBIDDEN: &'static [&'static str] = &["://", "@", "/", "?", "#", ":"];

    /// Parses and validates a Reality dest_host.
    ///
    /// # Errors
    ///
    /// - [`InvalidCredentials::EmptyRealityDestHost`] when empty.
    /// - [`InvalidCredentials::MalformedRealityDestHost`] for any
    ///   other shape error (too long, whitespace, forbidden
    ///   substring).
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(InvalidCredentials::EmptyRealityDestHost);
        }
        if trimmed.len() > Self::MAX_LEN {
            return Err(InvalidCredentials::MalformedRealityDestHost);
        }
        if trimmed.chars().any(char::is_whitespace) {
            return Err(InvalidCredentials::MalformedRealityDestHost);
        }
        for forbidden in Self::FORBIDDEN {
            if trimmed.contains(forbidden) {
                return Err(InvalidCredentials::MalformedRealityDestHost);
            }
        }
        Ok(Self(trimmed.to_owned()))
    }

    /// Returns the dest_host string.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for RealityDestHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::fmt::Debug for RealityDestHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("RealityDestHost").field(&self.0).finish()
    }
}

impl TryFrom<String> for RealityDestHost {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<RealityDestHost> for String {
    fn from(value: RealityDestHost) -> Self {
        value.0
    }
}

/// Validated Reality short_id. Empty string is the conventional
/// "no challenge" value the server accepts.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RealityShortId(String);

impl RealityShortId {
    /// Parses a Reality short_id.
    ///
    /// Accepts empty string (the no-challenge default). Non-empty
    /// values must be even-length hex digits, 2–16 chars.
    ///
    /// # Errors
    ///
    /// [`InvalidCredentials::MalformedRealityShortId`] on length /
    /// alphabet violation.
    pub fn parse(input: &str) -> Result<Self, InvalidCredentials> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Ok(Self(String::new()));
        }
        if trimmed.len() > REALITY_SHORT_ID_MAX_LEN {
            return Err(InvalidCredentials::MalformedRealityShortId);
        }
        // `usize::is_multiple_of` is Rust 1.84+; the crate's MSRV
        // (`rust-version` in Cargo.toml) is 1.80. Stay portable
        // with the explicit modulo form.
        if trimmed.len() % 2 != 0 {
            return Err(InvalidCredentials::MalformedRealityShortId);
        }
        if !trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(InvalidCredentials::MalformedRealityShortId);
        }
        Ok(Self(trimmed.to_ascii_lowercase()))
    }

    /// Returns the short_id (possibly empty).
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for RealityShortId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("RealityShortId").field(&"***").finish()
    }
}

impl TryFrom<String> for RealityShortId {
    type Error = InvalidCredentials;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value)
    }
}

impl From<RealityShortId> for String {
    fn from(value: RealityShortId) -> Self {
        value.0
    }
}

/// VLESS account credentials (sing-box client side).
///
/// Username is the human-readable label; `uuid` is the actual auth
/// credential; `reality` carries the transport-layer secret material
/// needed to render a sing-box config.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Credentials {
    /// Account name.
    pub username: Username,
    /// VLESS user_id (RFC 4122 UUID).
    pub uuid: Uuid,
    /// Reality handshake parameters.
    pub reality: Reality,
}

impl Credentials {
    /// Constructs credentials from already-validated parts.
    #[must_use]
    pub const fn new(username: Username, uuid: Uuid, reality: Reality) -> Self {
        Self {
            username,
            uuid,
            reality,
        }
    }
}

/// Reasons a credential bundle failed validation.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Error)]
#[non_exhaustive]
pub enum InvalidCredentials {
    /// The trimmed username was empty.
    #[error("username must not be empty")]
    EmptyUsername,
    /// Username contained a non-`alphaDash` character (matches the
    /// Laravel panel's rule). The contained `char` is the first
    /// offending character so the UI can show "username can't
    /// contain '@'", not just "invalid".
    #[error("username may only contain letters, digits, '-', or '_'")]
    IllegalUsernameChar(char),
    /// Username exceeded the 64-char Laravel cap. Reported with
    /// both `max` and `got` so the UI can render "username too long
    /// (got 80, max 64)".
    #[error("username too long (got {got}, max {max})")]
    UsernameTooLong {
        /// Configured cap.
        max: usize,
        /// Length that overflowed it.
        got: usize,
    },
    /// The trimmed UUID was empty.
    #[error("uuid must not be empty")]
    EmptyUuid,
    /// The UUID was malformed (wrong length, bad dashes, or
    /// non-hex digit).
    #[error("uuid must be an RFC 4122 hyphenated UUID")]
    MalformedUuid,
    /// The Reality `public_key` field was empty.
    #[error("reality.public_key must not be empty")]
    EmptyRealityPublicKey,
    /// The Reality public key did not decode to 32 base64url bytes.
    #[error("reality.public_key must be 32-byte base64url-encoded X25519")]
    MalformedRealityPublicKey,
    /// The Reality `dest_host` field was empty.
    #[error("reality.dest_host must not be empty")]
    EmptyRealityDestHost,
    /// The Reality dest_host violated the bare-hostname rules.
    #[error("reality.dest_host must be a bare FQDN with no scheme, port, or path")]
    MalformedRealityDestHost,
    /// The Reality short_id violated the hex / length rules.
    #[error("reality.short_id must be empty or even-length hex (0..=16 chars)")]
    MalformedRealityShortId,
}

/// Laravel's `alphaDash` rule: ASCII letters, digits, dash, underscore.
const fn is_alpha_dash(c: char) -> bool {
    matches!(
        c,
        'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_'
    )
}

/// Decodes a base64url-encoded string (with or without `=` padding)
/// into raw bytes. Returns `None` on alphabet violation or
/// inconsistent padding. Inline implementation to keep the crate
/// dep tree the same as v2.x.
fn decode_base64url(input: &str) -> Option<Vec<u8>> {
    let bytes = input.as_bytes();
    // Strip trailing `=` padding (0..=2 chars). Anything beyond
    // that is malformed.
    let mut pad = 0_usize;
    while pad < 2 && bytes.len().saturating_sub(pad) > 0 && bytes[bytes.len() - pad - 1] == b'=' {
        pad += 1;
    }
    let core = &bytes[..bytes.len() - pad];
    if core.contains(&b'=') {
        return None;
    }
    let len = core.len();
    let rem = len % 4;
    if rem == 1 {
        return None;
    }

    let mut out = Vec::with_capacity(len * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &b in core {
        let value = base64url_value(b)?;
        buf = (buf << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xff) as u8);
        }
    }
    Some(out)
}

const fn base64url_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'-' => Some(62),
        b'_' => Some(63),
        _ => None,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    /// Test fixture: any well-formed UUID string. Deliberately
    /// non-real so `git grep` never finds a usable account
    /// credential.
    const VALID_UUID: &str = "11111111-2222-3333-4444-555555555555";

    /// Test fixture: 32 zero-bytes base64url-encoded =
    /// "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA". The pub
    /// key shape is what matters for the parser test; cryptographic
    /// quality is irrelevant here.
    const VALID_REALITY_PUB: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    #[test]
    fn rejects_empty_username() {
        assert_eq!(
            Username::parse("   "),
            Err(InvalidCredentials::EmptyUsername)
        );
    }

    #[test]
    fn rejects_non_alphadash_username() {
        assert!(matches!(
            Username::parse("alice@bad"),
            Err(InvalidCredentials::IllegalUsernameChar('@'))
        ));
        assert!(matches!(
            Username::parse("alice:bad"),
            Err(InvalidCredentials::IllegalUsernameChar(':'))
        ));
    }

    #[test]
    fn accepts_alphadash_username() {
        assert!(Username::parse("alice_bob").is_ok());
        assert!(Username::parse("alice-bob").is_ok());
        assert!(Username::parse("Alice123").is_ok());
    }

    #[test]
    fn enforces_username_max_length() {
        let ok = "a".repeat(USERNAME_MAX_LEN);
        assert!(Username::parse(&ok).is_ok());
        let too_long = "a".repeat(USERNAME_MAX_LEN + 1);
        assert!(matches!(
            Username::parse(&too_long),
            Err(InvalidCredentials::UsernameTooLong {
                max: USERNAME_MAX_LEN,
                got
            }) if got == USERNAME_MAX_LEN + 1
        ));
    }

    #[test]
    fn uuid_round_trips() {
        let u = Uuid::parse(VALID_UUID).unwrap();
        assert_eq!(u.expose_secret(), VALID_UUID);
    }

    #[test]
    fn uuid_lowercases_input() {
        let u = Uuid::parse("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE").unwrap();
        assert_eq!(u.expose_secret(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    }

    #[test]
    fn uuid_rejects_empty() {
        assert_eq!(Uuid::parse("   "), Err(InvalidCredentials::EmptyUuid));
    }

    #[test]
    fn uuid_rejects_wrong_length() {
        assert_eq!(Uuid::parse("1234"), Err(InvalidCredentials::MalformedUuid));
    }

    #[test]
    fn uuid_rejects_misplaced_dash() {
        assert_eq!(
            Uuid::parse("11111111+2222-3333-4444-555555555555"),
            Err(InvalidCredentials::MalformedUuid)
        );
    }

    #[test]
    fn uuid_rejects_non_hex() {
        assert_eq!(
            Uuid::parse("zzzzzzzz-2222-3333-4444-555555555555"),
            Err(InvalidCredentials::MalformedUuid)
        );
    }

    #[test]
    fn uuid_debug_redacts() {
        let u = Uuid::parse(VALID_UUID).unwrap();
        assert_eq!(format!("{u:?}"), "Uuid(\"***\")");
    }

    #[test]
    fn reality_public_key_round_trips() {
        let k = RealityPublicKey::parse(VALID_REALITY_PUB).unwrap();
        assert_eq!(k.as_str(), VALID_REALITY_PUB);
    }

    #[test]
    fn reality_public_key_accepts_padded() {
        // Base64url with `=` padding is also accepted.
        let padded = format!("{VALID_REALITY_PUB}=");
        let k = RealityPublicKey::parse(&padded).unwrap();
        assert_eq!(k.as_str(), padded);
    }

    #[test]
    fn reality_public_key_rejects_empty() {
        assert_eq!(
            RealityPublicKey::parse(""),
            Err(InvalidCredentials::EmptyRealityPublicKey)
        );
    }

    #[test]
    fn reality_public_key_rejects_wrong_decoded_length() {
        // "AAAA" decodes to 3 bytes (one base64 quad = 3 bytes).
        assert_eq!(
            RealityPublicKey::parse("AAAA"),
            Err(InvalidCredentials::MalformedRealityPublicKey)
        );
    }

    #[test]
    fn reality_public_key_rejects_bad_alphabet() {
        // `/` is base64 standard but not base64url.
        assert_eq!(
            RealityPublicKey::parse("AAA/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            Err(InvalidCredentials::MalformedRealityPublicKey)
        );
    }

    #[test]
    fn reality_dest_host_round_trips() {
        let h = RealityDestHost::parse("www.microsoft.com").unwrap();
        assert_eq!(h.as_str(), "www.microsoft.com");
    }

    #[test]
    fn reality_dest_host_rejects_port() {
        assert_eq!(
            RealityDestHost::parse("www.microsoft.com:443"),
            Err(InvalidCredentials::MalformedRealityDestHost)
        );
    }

    #[test]
    fn reality_dest_host_rejects_scheme() {
        assert_eq!(
            RealityDestHost::parse("https://www.microsoft.com"),
            Err(InvalidCredentials::MalformedRealityDestHost)
        );
    }

    #[test]
    fn reality_short_id_empty_ok() {
        let s = RealityShortId::parse("").unwrap();
        assert_eq!(s.as_str(), "");
    }

    #[test]
    fn reality_short_id_hex_round_trips() {
        let s = RealityShortId::parse("01ab").unwrap();
        assert_eq!(s.as_str(), "01ab");
    }

    #[test]
    fn reality_short_id_rejects_odd_length() {
        assert_eq!(
            RealityShortId::parse("abc"),
            Err(InvalidCredentials::MalformedRealityShortId)
        );
    }

    #[test]
    fn reality_short_id_rejects_non_hex() {
        assert_eq!(
            RealityShortId::parse("zzzz"),
            Err(InvalidCredentials::MalformedRealityShortId)
        );
    }

    #[test]
    fn reality_short_id_rejects_too_long() {
        assert_eq!(
            RealityShortId::parse(&"a".repeat(REALITY_SHORT_ID_MAX_LEN + 2)),
            Err(InvalidCredentials::MalformedRealityShortId)
        );
    }

    #[test]
    fn reality_debug_redacts_keys() {
        let reality = Reality::new(
            RealityPublicKey::parse(VALID_REALITY_PUB).unwrap(),
            RealityDestHost::parse("www.microsoft.com").unwrap(),
            RealityShortId::parse("01ab").unwrap(),
        );
        let dump = format!("{reality:?}");
        assert!(
            !dump.contains(VALID_REALITY_PUB),
            "public_key leaked: {dump}"
        );
        assert!(!dump.contains("01ab"), "short_id leaked: {dump}");
        assert!(dump.contains("www.microsoft.com"), "dest_host kept: {dump}");
    }

    #[test]
    fn credentials_debug_redacts_secrets() {
        let creds = Credentials::new(
            Username::parse("alice").unwrap(),
            Uuid::parse(VALID_UUID).unwrap(),
            Reality::new(
                RealityPublicKey::parse(VALID_REALITY_PUB).unwrap(),
                RealityDestHost::parse("www.microsoft.com").unwrap(),
                RealityShortId::parse("01ab").unwrap(),
            ),
        );
        let dump = format!("{creds:?}");
        assert!(!dump.contains("alice"), "username leaked: {dump}");
        assert!(!dump.contains(VALID_UUID), "uuid leaked: {dump}");
        assert!(
            !dump.contains(VALID_REALITY_PUB),
            "public_key leaked: {dump}"
        );
    }

    #[test]
    fn decode_base64url_handles_padding() {
        assert_eq!(decode_base64url("AAAA"), Some(vec![0, 0, 0]));
        assert_eq!(decode_base64url("AAA="), Some(vec![0, 0]));
        assert_eq!(decode_base64url("AA=="), Some(vec![0]));
    }

    #[test]
    fn decode_base64url_rejects_bad_alphabet() {
        assert_eq!(decode_base64url("AA+A"), None);
        assert_eq!(decode_base64url("AA/A"), None);
    }

    #[test]
    fn raw_reality_round_trips() {
        let raw = RawReality {
            public_key: VALID_REALITY_PUB.to_owned(),
            dest_host: "www.microsoft.com".to_owned(),
            short_id: "01ab".to_owned(),
        };
        let reality = Reality::try_from(raw.clone()).unwrap();
        let back: RawReality = reality.into();
        assert_eq!(back.public_key, raw.public_key);
        assert_eq!(back.dest_host, raw.dest_host);
        assert_eq!(back.short_id, raw.short_id);
    }
}
