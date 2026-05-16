// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Credential redaction for log lines forwarded to the Swift UI.
//!
//! `naive` prints its full proxy URL — including userinfo — at
//! default verbosity, and forwarded lines reach the live log,
//! support bundles, and screenshots. This module strips userinfo
//! and other credential-shaped fragments before the line crosses
//! our boundary.

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
    Regex::new(r"(?i)(?P<scheme>(?:https?|socks(?:5h?|4a?)?|ftp|naive)://)[^/\s]+@")
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
