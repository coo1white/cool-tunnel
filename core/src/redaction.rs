// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Credential redaction for log lines forwarded to the Swift UI.
//!
//! v3.0.0 surface area:
//! - `sing-box` prints the resolved outbound block (UUID, Reality
//!   public_key, short_id) at startup. This module strips those
//!   before forwarding to the UI.
//! - Forward-compat with v2.x: legacy `Authorization: Basic …`
//!   headers and `scheme://user:pass@host` userinfo are still
//!   redacted so support bundles from mixed-version sessions stay
//!   safe.
//!
//! Patterns are independent — a line carrying both a userinfo URL
//! and a bare UUID will have both redacted.

use std::borrow::Cow;
use std::sync::LazyLock;

use regex::Regex;

/// Returns a copy of `line` with credential-bearing patterns
/// replaced:
///
/// - `scheme://userinfo@host` → `scheme://***:***@host`
/// - `Authorization: <type> <value>` → `Authorization: <type> ***`
/// - `Cookie: …` → `Cookie: ***`
/// - JSON / k=v credential fields → redacted value
/// - query-string `?token=…` / `&api_key=…` → redacted value
///
/// Borrows on no match; allocates only on substitution.
#[must_use]
pub fn redact(line: &str) -> Cow<'_, str> {
    // Sequential Cow reassignment: passthrough when no match,
    // owned only on substitution. Keeps the zero-allocation fast
    // path for clean lines.
    let mut current = Cow::Borrowed(line);
    if let Cow::Owned(s) = USERINFO_REGEX.replace_all(&current, "${scheme}***:***@") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = AUTH_HEADER_REGEX.replace_all(&current, "${prefix}***") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = COOKIE_HEADER_REGEX.replace_all(&current, "${prefix}***") {
        current = Cow::Owned(s);
    }
    // Strict-JSON-quoted pass runs FIRST. The bare-token matcher
    // below stops at the first space/comma/quote, which would
    // leak the tail of any password with embedded whitespace
    // (e.g. `Tr0ub4dor 3 cat-pic`).
    if let Cow::Owned(s) = JSON_KV_QUOTED_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    // Query-string pass runs BEFORE the bare k=v rule below: the
    // bare matcher's value class doesn't include `&`, so a URL
    // like `?token=abc&user=alice&page=2` would otherwise have
    // its non-credential params clobbered.
    if let Cow::Owned(s) = QUERY_STRING_CRED_REGEX.replace_all(&current, "${prefix}***") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = JSON_KV_CRED_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = AUTH_HEADER_REGEX.replace_all(&current, "${prefix}***") {
        // Re-run after the JSON pass in case a header-shaped
        // credential coexists with a JSON dump on the same line.
        current = Cow::Owned(s);
    }
    // v3.0.0 Reality / VLESS patterns. The JSON-quoted form runs
    // first (same rationale as the v2.x password pass) so a value
    // with embedded punctuation is fully redacted.
    if let Cow::Owned(s) = REALITY_QUOTED_KV_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = REALITY_BARE_KV_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    // Bare-UUID pass runs LAST so we don't accidentally clobber the
    // tail of a quoted Reality `public_key` value (which is base64url
    // and never matches the UUID shape). The hyphenated form is the
    // only one sing-box emits and the only one VLESS accepts.
    if let Cow::Owned(s) = UUID_REGEX.replace_all(&current, "<uuid-redacted>") {
        current = Cow::Owned(s);
    }
    current
}

// `LazyLock` panics on regex-compile failure (fail-loud is correct
// for a security control — the previous `OnceLock<Option<Regex>>`
// silently degraded to passthrough, leaking credentials).
// `expect` is allowed despite the crate-wide deny because the
// `redaction_regexes_compile` test catches any bad edit at
// `cargo test` time.

/// `scheme://userinfo@` matcher. Schemes are case-insensitive
/// (curl occasionally upper-cases them in error output).
///
/// Userinfo class is `[^/\s]+` (greedy up to path-or-whitespace,
/// then literal `@`) so a password containing `@` like
/// `user:p@ssword@host` is fully redacted. The greedy form
/// backtracks to the last `@` before the path-or-whitespace
/// boundary.
#[allow(clippy::expect_used)]
static USERINFO_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<scheme>(?:https?|socks(?:5h?|4a?)?|ftp|naive|vless)://)[^/\s]+@")
        .expect("userinfo redaction regex must compile")
});

/// `[Proxy-]Authorization: <scheme> <value>` matcher. The scheme
/// is left intact (Bearer / Basic / Digest is useful diagnostic);
/// the value is replaced with `***`.
#[allow(clippy::expect_used)]
static AUTH_HEADER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<prefix>(?:Proxy-)?Authorization:\s*[A-Za-z]+\s+)\S+")
        .expect("Authorization redaction regex must compile")
});

/// `[Set-]Cookie: …` matcher. Replaces the entire value (not just
/// one cookie pair) because cookies frequently carry session
/// tokens and CSRF state.
#[allow(clippy::expect_used)]
static COOKIE_HEADER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<prefix>(?:Set-)?Cookie:\s*)[^\r\n]+")
        .expect("Cookie redaction regex must compile")
});

/// Strict-JSON-quoted-value matcher. Value `(?:[^"\\]|\\.)*`
/// consumes any non-`"` character or escape pair, terminating
/// only at the literal closing quote — so a password with
/// embedded spaces / commas / punctuation is fully redacted
/// instead of leaking past the first delimiter.
#[allow(clippy::expect_used)]
static JSON_KV_QUOTED_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?ix)
        (?P<prefix>
            "(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token)"
            \s* : \s*
            "
        )
        (?:[^"\\]|\\.)*
        (?P<suffix>")
        "#,
    )
    .expect("JSON KV quoted-value credential redaction regex must compile")
});

/// Bare-token `key=value` / `key: value` matcher. Runs AFTER
/// `JSON_KV_QUOTED_REGEX` (which handles the quoted case);
/// bare-token formats are space-delimited by definition so the
/// embedded-space leak doesn't apply.
///
/// Covers `password`, `passwd`, `secret`, `token`, `api_key`,
/// `apikey`, `access_token`, `refresh_token`.
#[allow(clippy::expect_used)]
static JSON_KV_CRED_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    // `&` and `#` are in the value terminator set so a URL like
    // `?token=abc&user=alice#frag` doesn't have the bare matcher
    // eat past the `&`/`#` and clobber subsequent params (or
    // re-match the `token=***` left by QUERY_STRING_CRED_REGEX).
    Regex::new(
        r#"(?ix)
        (?P<prefix>
            "?(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token)"?
            \s* [:=] \s*
            "?
        )
        [^"\s,&\x23}\r\n]+
        (?P<suffix>"?)
        "#,
    )
    .expect("JSON KV credential redaction regex must compile")
});

/// Query-string credential matcher (`?token=…`, `&api_key=…`,
/// etc.). Value runs from `=` to the next `&` / whitespace /
/// fragment `#`. Distinct from `JSON_KV_CRED_REGEX` because URL
/// queries use `&` as the value terminator.
#[allow(clippy::expect_used)]
static QUERY_STRING_CRED_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    // Single-line form (not `(?x)`) — the value class contains a
    // literal `#` that extended-mode would treat as a comment.
    Regex::new(
        r"(?i)(?P<prefix>[?&](?:token|api[_-]?key|access[_-]?token|refresh[_-]?token|session|auth|password|secret)=)[^&\s#]+",
    )
    .expect("query-string credential redaction regex must compile")
});

/// Bare-UUID matcher. RFC 4122 hyphenated, lowercase or uppercase.
/// sing-box emits the VLESS user_id verbatim in the startup
/// "outbound resolved" log line; redacting at this layer keeps
/// support bundles safe even if the higher-level JSON KV passes
/// miss a future field name.
///
/// Replacement string is a literal `<uuid-redacted>` rather than
/// `***` so the post-redaction line still looks structurally like
/// a UUID would have lived there — easier to spot in support
/// bundles than a generic asterisk run.
#[allow(clippy::expect_used)]
static UUID_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
        .expect("UUID redaction regex must compile")
});

/// Strict-JSON-quoted-value matcher for Reality fields:
/// `"public_key": "<base64url>"` and `"short_id": "<hex>"`. Same
/// strategy as `JSON_KV_QUOTED_REGEX` so embedded punctuation in a
/// future short_id formatting doesn't leak past the comma.
///
/// Also covers a future `"uuid": "<value>"` field name so a
/// rendered config blob can't smuggle an unredacted UUID past the
/// bare-UUID matcher below (the bare matcher catches the value
/// already, but the quoted matcher additionally hides the field
/// name's existence by replacing the value with `***` rather than
/// the longer `<uuid-redacted>` literal).
#[allow(clippy::expect_used)]
static REALITY_QUOTED_KV_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?ix)
        (?P<prefix>
            "(?:public[_-]?key|short[_-]?id|uuid|reality[_-]?private[_-]?key)"
            \s* : \s*
            "
        )
        (?:[^"\\]|\\.)*
        (?P<suffix>")
        "#,
    )
    .expect("Reality JSON KV redaction regex must compile")
});

/// Bare-token `key=value` / `key: value` matcher for Reality fields.
/// Covers `public_key`, `short_id`, `uuid`, `reality_private_key`.
/// Value class mirrors `JSON_KV_CRED_REGEX` (terminates at
/// `&`/`#`/comma/quote) so URL-shaped contexts don't bleed past
/// the intended segment.
#[allow(clippy::expect_used)]
static REALITY_BARE_KV_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?ix)
        (?P<prefix>
            "?(?:public[_-]?key|short[_-]?id|uuid|reality[_-]?private[_-]?key)"?
            \s* [:=] \s*
            "?
        )
        [^"\s,&\x23}\r\n]+
        (?P<suffix>"?)
        "#,
    )
    .expect("Reality bare KV redaction regex must compile")
});

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn redacts_userinfo_in_https_url() {
        let line = "Listening: https://alice:hunter2@naive.example.com:443";
        assert_eq!(
            redact(line),
            "Listening: https://***:***@naive.example.com:443"
        );
    }

    #[test]
    fn redacts_userinfo_in_http_url() {
        let line = "proxy = http://user:pwd@host";
        assert_eq!(redact(line), "proxy = http://***:***@host");
    }

    #[test]
    fn redacts_username_only_userinfo() {
        let line = "http://just-user@host";
        assert_eq!(redact(line), "http://***:***@host");
    }

    #[test]
    fn passes_through_clean_url() {
        let line = "GET https://example.com/path";
        let out = redact(line);
        assert_eq!(out, line);
        assert!(matches!(out, Cow::Borrowed(_)));
    }

    #[test]
    fn handles_multiple_urls_in_one_line() {
        let line = "from https://a:b@x to http://c:d@y";
        assert_eq!(redact(line), "from https://***:***@x to http://***:***@y");
    }

    #[test]
    fn redacts_socks_variants() {
        for line in [
            "socks5://alice:hunter2@proxy.example.com:1080",
            "socks5h://alice:hunter2@proxy.example.com:1080",
            "socks4://alice:hunter2@proxy.example.com:1080",
            "socks4a://alice:hunter2@proxy.example.com:1080",
            "socks://alice:hunter2@proxy.example.com:1080",
        ] {
            let out = redact(line);
            assert!(!out.contains("hunter2"), "password leaked: {out}");
            assert!(!out.contains("alice"), "username leaked: {out}");
            assert!(out.contains("***:***@"), "redaction marker missing: {out}");
        }
    }

    #[test]
    fn redacts_naive_and_ftp_schemes() {
        let naive = "naive+https://alice:hunter2@server:443";
        // The inner `https://` is the matched scheme here.
        let out = redact(naive);
        assert!(!out.contains("hunter2"));

        let ftp = "ftp://alice:hunter2@host";
        let out = redact(ftp);
        assert!(!out.contains("hunter2"), "ftp password leaked: {out}");
    }

    #[test]
    fn redacts_vless_scheme_userinfo() {
        let line = "vless://alice:550e8400-e29b-41d4-a716-446655440000@proxy.example.com:443";
        let out = redact(line);
        assert!(!out.contains("alice"), "username leaked: {out}");
        assert!(
            !out.contains("550e8400-e29b-41d4-a716-446655440000"),
            "uuid leaked: {out}"
        );
        assert_eq!(out, "vless://***:***@proxy.example.com:443");
    }

    #[test]
    fn redacts_authorization_header() {
        let line = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig";
        let out = redact(line);
        assert_eq!(out, "Authorization: Bearer ***");
    }

    #[test]
    fn redacts_proxy_authorization_header() {
        let line = "Proxy-Authorization: Basic bmljazpodW50ZXIy";
        let out = redact(line);
        assert!(out.ends_with("***"), "expected trailing ***: {out}");
        assert!(!out.contains("bmljazpodW50ZXIy"), "payload leaked: {out}");
        assert!(
            out.starts_with("Proxy-Authorization:"),
            "header rewritten: {out}"
        );
    }

    #[test]
    fn redacts_proxy_authorization_with_whitespace_and_case() {
        for line in [
            "  proxy-authorization:   Bearer eyJhbGc...",
            "Proxy-Authorization:Basic abcdef==", // no space after colon
            "PROXY-AUTHORIZATION: Digest nonce=...",
        ] {
            let out = redact(line);
            assert!(
                !out.contains("eyJhbGc") && !out.contains("abcdef") && !out.contains("nonce"),
                "credentials leaked: {out}"
            );
        }
    }

    #[test]
    fn redacts_basic_authorization_header() {
        let line = "  Authorization:   Basic bmljazpodW50ZXIy";
        let out = redact(line);
        assert!(out.ends_with("***"), "expected trailing ***: {out}");
        assert!(!out.contains("bmljazpodW50ZXIy"), "payload leaked: {out}");
    }

    #[test]
    fn redacts_cookie_and_set_cookie_headers() {
        for line in [
            "Cookie: session=abc123; csrf=def456",
            "Set-Cookie: session=abc123; HttpOnly; Secure",
        ] {
            let out = redact(line);
            assert!(!out.contains("abc123"), "session token leaked: {out}");
            assert!(out.contains("***"), "redaction marker missing: {out}");
        }
    }

    #[test]
    fn does_not_cross_path_separator() {
        // `@` after the path must NOT match.
        let line = "https://example.com/owner@repo";
        assert_eq!(redact(line), line);
    }

    /// Bare `user@host` outside a URL is probably email / git;
    /// false positives there would hurt log readability with no
    /// security payoff.
    #[test]
    fn does_not_match_at_outside_url() {
        let line = "user@host (not a URL)";
        assert_eq!(redact(line), line);
    }

    #[test]
    fn empty_line_is_safe() {
        assert_eq!(redact(""), "");
    }

    /// Force-touches every `LazyLock` so a bad regex edit fails
    /// `cargo test` instead of becoming a runtime panic.
    #[test]
    fn redaction_regexes_compile() {
        let _ = USERINFO_REGEX.replace_all("", "");
        let _ = AUTH_HEADER_REGEX.replace_all("", "");
        let _ = COOKIE_HEADER_REGEX.replace_all("", "");
        let _ = JSON_KV_QUOTED_REGEX.replace_all("", "");
        let _ = JSON_KV_CRED_REGEX.replace_all("", "");
        let _ = QUERY_STRING_CRED_REGEX.replace_all("", "");
        let _ = UUID_REGEX.replace_all("", "");
        let _ = REALITY_QUOTED_KV_REGEX.replace_all("", "");
        let _ = REALITY_BARE_KV_REGEX.replace_all("", "");
    }

    // MARK: - v3.0.0 Reality / UUID patterns

    #[test]
    fn redacts_bare_uuid() {
        let line = "outbound resolved uuid=11111111-2222-3333-4444-555555555555 ok";
        let out = redact(line);
        assert!(
            !out.contains("11111111-2222-3333-4444-555555555555"),
            "uuid leaked: {out}"
        );
        // The bare-KV regex catches the value first and replaces
        // with `***`; the bare-UUID matcher would otherwise replace
        // with `<uuid-redacted>`. Either is acceptable — we only
        // assert nothing leaks.
    }

    #[test]
    fn redacts_quoted_uuid_in_json() {
        let line = r#"{"users":[{"uuid":"11111111-2222-3333-4444-555555555555","name":"alice"}]}"#;
        let out = redact(line);
        assert!(
            !out.contains("11111111-2222-3333-4444-555555555555"),
            "uuid leaked: {out}"
        );
        assert!(out.contains(r#""uuid":"***""#), "shape wrong: {out}");
        assert!(
            out.contains(r#""name":"alice""#),
            "non-cred field clobbered: {out}"
        );
    }

    #[test]
    fn redacts_quoted_reality_public_key() {
        let line = r#"{"reality":{"public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"01ab"}}"#;
        let out = redact(line);
        assert!(
            !out.contains("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "public_key leaked: {out}"
        );
        assert!(!out.contains("01ab"), "short_id leaked: {out}");
        assert!(
            out.contains(r#""public_key":"***""#),
            "public_key shape wrong: {out}"
        );
        assert!(
            out.contains(r#""short_id":"***""#),
            "short_id shape wrong: {out}"
        );
    }

    #[test]
    fn redacts_bare_reality_kv() {
        let line = "config public_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA short_id=01ab";
        let out = redact(line);
        assert!(
            !out.contains("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "public_key leaked: {out}"
        );
        assert!(!out.contains("01ab"), "short_id leaked: {out}");
    }

    /// Non-credential plain text containing only hex but not the
    /// UUID shape (wrong dash positions) must pass through.
    #[test]
    fn does_not_match_non_uuid_hex_string() {
        let line = "see also commit abc12345 for the fix";
        let out = redact(line);
        assert_eq!(out, line);
    }

    #[test]
    fn redacts_uuid_inside_log_sentence() {
        let line =
            "[info] vless-out connecting with uuid 11111111-2222-3333-4444-555555555555 to host";
        let out = redact(line);
        assert!(
            !out.contains("11111111-2222-3333-4444-555555555555"),
            "uuid leaked: {out}"
        );
    }

    /// Two UUIDs on one line each redact independently.
    #[test]
    fn redacts_two_uuids_independently() {
        let line =
            "old=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee new=11111111-2222-3333-4444-555555555555";
        let out = redact(line);
        assert!(!out.contains("aaaaaaaa-bbbb"), "old uuid leaked: {out}");
        assert!(!out.contains("11111111-2222"), "new uuid leaked: {out}");
    }

    /// Strict-JSON quoted value with embedded space must be
    /// redacted in full.
    #[test]
    fn redacts_quoted_password_with_embedded_space() {
        let line = r#"config error: {"password":"Tr0ub4dor 3 cat-pic","other":"ok"}"#;
        let out = redact(line);
        assert!(!out.contains("Tr0ub4dor"), "password head leaked: {out}");
        assert!(!out.contains("cat-pic"), "password tail leaked: {out}");
        assert!(
            out.contains(r#""password":"***""#),
            "redaction shape wrong: {out}"
        );
        assert!(
            out.contains(r#""other":"ok""#),
            "non-credential field clobbered: {out}"
        );
    }

    #[test]
    fn redacts_quoted_password_with_embedded_comma() {
        let line = r#"{"password":"foo,bar","u":"v"}"#;
        let out = redact(line);
        assert!(!out.contains("foo,bar"), "password leaked: {out}");
        assert!(
            out.contains(r#""password":"***""#),
            "redaction shape wrong: {out}"
        );
        assert!(
            out.contains(r#""u":"v""#),
            "non-credential field clobbered: {out}"
        );
    }

    /// Quoted value containing escape pair `\"` must redact in full.
    #[test]
    fn redacts_quoted_password_with_escaped_quote() {
        let line = r#"{"password":"a\"b"}"#;
        let out = redact(line);
        assert!(!out.contains("a\\\"b"), "password leaked: {out}");
        assert!(
            out.contains(r#""password":"***""#),
            "redaction shape wrong: {out}"
        );
    }

    #[test]
    fn redacts_bare_password_assignment() {
        for line in ["password=hunter2", "password: hunter2", "PASSWORD=hunter2"] {
            let out = redact(line);
            assert!(!out.contains("hunter2"), "bare value leaked: {out}");
            assert!(out.contains("***"), "redaction marker missing: {out}");
        }
    }

    /// Userinfo with embedded `@` redacts in full.
    #[test]
    fn redacts_userinfo_with_embedded_at_sign() {
        let line = "https://user:p@ssword@host.example.com/path";
        let out = redact(line);
        assert!(!out.contains("p@ssword"), "password leaked: {out}");
        assert!(
            out.starts_with("https://***:***@host.example.com"),
            "redaction shape wrong: {out}"
        );
    }

    /// Two URLs on one line each redact independently — the greedy
    /// class is bounded by `\s`, not `@`.
    #[test]
    fn redacts_two_urls_with_at_signs_independently() {
        let line = "from https://a:b@host1 to https://c:d@host2";
        let out = redact(line);
        assert!(!out.contains("a:b"), "first creds leaked: {out}");
        assert!(!out.contains("c:d"), "second creds leaked: {out}");
        assert!(
            out == "from https://***:***@host1 to https://***:***@host2",
            "redaction shape wrong: {out}"
        );
    }

    // MARK: - Query-string credentials

    #[test]
    fn redacts_query_string_token() {
        let line = "fetching https://panel.example.com/path?token=secretvalue123";
        let out = redact(line);
        assert!(!out.contains("secretvalue123"), "token leaked: {out}");
        assert!(out.contains("?token=***"), "shape wrong: {out}");
    }

    /// Each value runs only to the next `&`; non-credential params
    /// after survive.
    #[test]
    fn redacts_query_string_token_followed_by_other_params() {
        let line = "https://x.com/p?token=abc&user=alice&page=2";
        let out = redact(line);
        assert!(!out.contains("abc"), "token leaked: {out}");
        assert!(
            out.contains("user=alice"),
            "non-cred param clobbered: {out}"
        );
        assert!(out.contains("page=2"), "non-cred param clobbered: {out}");
    }

    #[test]
    fn redacts_every_query_string_credential_shape() {
        for line in [
            "https://x.com/p?api_key=xyz",
            "https://x.com/p?session=def",
            "https://x.com/p?auth=ghi",
            "https://x.com/p?password=jkl",
            "https://x.com/p?secret=mno",
            "https://x.com/p?refresh_token=pqr",
        ] {
            let out = redact(line);
            assert!(
                !out.contains("xyz")
                    && !out.contains("def")
                    && !out.contains("ghi")
                    && !out.contains("jkl")
                    && !out.contains("mno")
                    && !out.contains("pqr"),
                "credential leaked: {out}"
            );
        }
    }

    #[test]
    fn passes_through_non_credential_query_params() {
        let line = "https://x.com/p?page=2&sort=asc";
        let out = redact(line);
        assert_eq!(out, line);
        assert!(matches!(out, Cow::Borrowed(_)));
    }

    /// Redaction stops at the URL fragment separator `#`.
    #[test]
    fn redacts_query_string_token_with_fragment() {
        let line = "https://x.com/p?token=abc#anchor";
        let out = redact(line);
        assert!(!out.contains("abc"), "token leaked: {out}");
        assert!(out.contains("#anchor"), "fragment lost: {out}");
    }
}
