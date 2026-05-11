// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Credential redaction for log lines forwarded to the Swift UI.
//!
//! `naive` prints its full proxy URL — including userinfo
//! (`https://user:pass@host:port`) — at startup with default verbosity.
//! Anything we forward verbatim ends up in the live log view, support
//! bundles, and screenshots. This module strips the userinfo segment
//! before the line crosses our boundary.

use std::borrow::Cow;
use std::sync::LazyLock;

use regex::Regex;

/// Returns a copy of `line` with credential-bearing patterns replaced
/// by their redacted equivalents:
///
/// - `scheme://userinfo@host` → `scheme://***:***@host` for any
///   `http`, `https`, `socks`, `socks4`, `socks5`, `ftp`, `naive` URL
/// - `Authorization: <type> <value>` → `Authorization: <type> ***`
/// - `Cookie: …` → `Cookie: ***` (whole value redacted; cookies often
///   carry session tokens that we don't want to leak by accident)
///
/// Borrows when no pattern matches, allocates only when a substitution
/// is needed. Applied to every line streamed from the `naive`
/// subprocess and to every curl-stderr blob forwarded to the UI.
#[must_use]
pub fn redact(line: &str) -> Cow<'_, str> {
    // Each step takes a Cow and returns a Cow — passthrough when no
    // match, owned only on substitution. Sequential reassignment
    // keeps the zero-allocation fast path for clean lines without
    // the previous `Option<Regex>` + `.clone()` dance that allocated
    // even when no redaction was needed.
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
    // **Diag-F#1 (v0.1.7.17):** JSON / k=v credential fields.
    // `naive` config-load errors dump partial JSON like
    // `"password":"..."`; curl -v emits `password: hunter2`.
    // Without this, both forms reach the UI verbatim.
    //
    // **M6 (v2.0.38):** the strict-JSON-quoted-string pass runs
    // FIRST. The bare-token pass that historically handled both
    // forms stops at the first space, comma, or quote in the
    // value, which leaks the tail of any password with embedded
    // whitespace or punctuation (the realistic case: human-typed
    // passwords like "Tr0ub4dor 3 cat-pic"). Two passes —
    // strict-quoted first, then bare for the remaining
    // k=v / k: v shapes — keep the bare-token fast path while
    // closing the embedded-space leak for the JSON shape that
    // naive actually emits.
    if let Cow::Owned(s) = JSON_KV_QUOTED_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = JSON_KV_CRED_REGEX.replace_all(&current, "${prefix}***${suffix}") {
        current = Cow::Owned(s);
    }
    if let Cow::Owned(s) = AUTH_HEADER_REGEX.replace_all(&current, "${prefix}***") {
        // Re-run after JSON pass in case a header-shaped credential
        // appears in a log line that also contains a JSON dump.
        current = Cow::Owned(s);
    }
    current
}

// `LazyLock` (Rust 1.80+) panics on first use if the regex fails
// to compile, which the supervisor's `kill_on_drop` reaps into a
// fail-fast restart. The previous `OnceLock<Option<Regex>>`
// silently degraded to a passthrough on compile failure —
// credentials would then leak. Fail-loud is the right LTSC
// posture for a security control. The
// `redaction_regexes_compile` test below catches any bad edit
// at `cargo test` time before it can ship.
//
// `expect` is used in spite of the crate-wide `expect_used =
// "deny"` lint because the compile-time test acts as the safety
// net the lint usually provides, and panic is the correct
// response to a constant regex that won't compile.

/// `scheme://userinfo@` matcher. Schemes are case-insensitive
/// (curl occasionally upper-cases them in error output).
///
/// **L2 (v2.0.38):** the userinfo class is `[^/\s]+`, greedy-up-to-
/// path-or-whitespace, with a literal `@` after. The previous class
/// `[^@\s/]+` stopped at the *first* `@`, so a password containing
/// an `@` (`user:p@ssword@host`) was only partially redacted —
/// `user:p` got `***:***@` but `ssword@host` reached the log
/// verbatim. The greedy form backtracks to the last `@` before the
/// path-or-whitespace boundary, redacting the full userinfo run.
/// Trade-off: a URL fragment like `https://x.com#a@b` now matches
/// and redacts to `https://***:***@b`, but that shape doesn't
/// appear in the `naive` / curl log surface this module guards.
#[allow(clippy::expect_used)]
static USERINFO_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<scheme>(?:https?|socks(?:5h?|4a?)?|ftp|naive)://)[^/\s]+@")
        .expect("userinfo redaction regex must compile")
});

/// `Authorization: <scheme> <value>` matcher. The scheme is left
/// intact (Bearer / Basic / Digest tells the user what auth type the
/// upstream wanted); the value is replaced with `***`.
///
/// **v0.1.7.10:** also matches `Proxy-Authorization:`. `naive` and
/// curl emit this header verbatim on upstream-proxy failure, and
/// the previous regex required the bare `Authorization:` prefix
/// — letting `Proxy-Authorization: Basic <b64>` slip through and
/// undoing every other credential-hygiene effort. Single regex
/// covers both via the optional `Proxy-` prefix.
#[allow(clippy::expect_used)]
static AUTH_HEADER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<prefix>(?:Proxy-)?Authorization:\s*[A-Za-z]+\s+)\S+")
        .expect("Authorization redaction regex must compile")
});

/// `Cookie: …` matcher. Cookies frequently carry session tokens and
/// CSRF state — replacing the entire value (not just one cookie pair)
/// is the conservative choice for log lines we don't control.
#[allow(clippy::expect_used)]
static COOKIE_HEADER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<prefix>(?:Set-)?Cookie:\s*)[^\r\n]+")
        .expect("Cookie redaction regex must compile")
});

/// **M6 (v2.0.38):** strict-JSON-quoted-value matcher. Runs first,
/// before the bare-token matcher below. The value `(?:[^"\\]|\\.)*`
/// consumes any non-`"` character or any escaped pair, terminating
/// only at the literal closing quote — so a password with embedded
/// spaces, commas, or punctuation is fully redacted instead of
/// leaking everything past the first delimiter. The previous
/// single-regex design used `[^"\s,}\r\n]+` for both quoted and
/// bare values; the realistic case (operator picks
/// `Tr0ub4dor 3 cat-pic` and `naive` emits a JSON dump on a
/// config-load error) was leaking everything from the first space
/// onwards.
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

/// **Diag-F#1 (v0.1.7.17):** matches credential-bearing JSON
/// fields and `key=value` / `key: value` plain text dumps.
/// Covers `password`, `passwd`, `secret`, `token`, `api_key`,
/// `apikey`, `access_token`, `refresh_token` — case-insensitive,
/// optional surrounding quotes on the key, optional surrounding
/// quotes on the value. The trailing-quote `suffix` capture
/// preserves the closing quote on JSON so the redacted output
/// remains parse-able.
///
/// **M6 (v2.0.38):** this matcher now runs **after**
/// `JSON_KV_QUOTED_REGEX`, which handles the strict-JSON case
/// (the leak surface for human-typed passwords with spaces). This
/// remaining matcher exclusively handles the bare-token shapes
/// (`password=hunter2`, `password: hunter2`) which never had the
/// embedded-space problem because those formats are
/// space-delimited by definition.
#[allow(clippy::expect_used)]
static JSON_KV_CRED_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?ix)
        (?P<prefix>
            "?(?:password|passwd|secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token)"?
            \s* [:=] \s*
            "?
        )
        [^"\s,}\r\n]+
        (?P<suffix>"?)
        "#,
    )
    .expect("JSON KV credential redaction regex must compile")
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

    /// SOCKS variants must be redacted too — naive's error output and
    /// curl's proxy diagnostics both spell SOCKS URLs explicitly.
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

    /// `naive://` and `ftp://` are also covered — both can show up in
    /// curl error text under unusual configurations.
    #[test]
    fn redacts_naive_and_ftp_schemes() {
        let naive = "naive+https://alice:hunter2@server:443";
        // The "naive+https://" case still has the inner https:// match
        // — ensure the password is gone.
        let out = redact(naive);
        assert!(!out.contains("hunter2"));

        let ftp = "ftp://alice:hunter2@host";
        let out = redact(ftp);
        assert!(!out.contains("hunter2"), "ftp password leaked: {out}");
    }

    /// Authorization headers must hide the secret while keeping the
    /// scheme name visible (so the user can still tell whether the
    /// proxy expected Bearer / Basic / Digest).
    #[test]
    fn redacts_authorization_header() {
        let line = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig";
        let out = redact(line);
        assert_eq!(out, "Authorization: Bearer ***");
    }

    /// `Proxy-Authorization` (the upstream-proxy auth header) must
    /// be redacted with the same posture as `Authorization`.
    /// Regression test for v0.1.7.10's Ru-A2 fix — pre-fix the
    /// regex required the literal `Authorization:` prefix and let
    /// `Proxy-Authorization: Basic <b64>` slip through verbatim.
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

    /// Mixed case + leading whitespace — matches the form curl
    /// emits in `-v` output.
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

    /// Basic auth is base64-encoded `user:pass` — must never reach
    /// the log line in cleartext OR base64.
    #[test]
    fn redacts_basic_authorization_header() {
        let line = "  Authorization:   Basic bmljazpodW50ZXIy";
        let out = redact(line);
        // Whitespace between scheme and value is preserved; payload
        // is masked.
        assert!(out.ends_with("***"), "expected trailing ***: {out}");
        assert!(!out.contains("bmljazpodW50ZXIy"), "payload leaked: {out}");
    }

    /// Cookies often carry session tokens — redact the whole value.
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
        // Pathological: `@` after the path. The regex must not capture it.
        let line = "https://example.com/owner@repo";
        assert_eq!(redact(line), line);
    }

    /// Bare `user@host` outside a URL is *probably* an email or git
    /// reference; we deliberately don't redact those because false
    /// positives would damage log readability without any security
    /// payoff (no password adjacent).
    #[test]
    fn does_not_match_at_outside_url() {
        let line = "user@host (not a URL)";
        assert_eq!(redact(line), line);
    }

    #[test]
    fn empty_line_is_safe() {
        assert_eq!(redact(""), "");
    }

    /// Force-touch every `LazyLock` so a future regex edit that
    /// doesn't compile fails `cargo test` instead of shipping and
    /// turning credential redaction into a runtime panic. Belt-
    /// and-braces alongside the `LazyLock`'s own `expect`.
    #[test]
    fn redaction_regexes_compile() {
        // The asserts force initialisation; we don't care about the
        // match result, only that `replace_all` does not panic.
        let _ = USERINFO_REGEX.replace_all("", "");
        let _ = AUTH_HEADER_REGEX.replace_all("", "");
        let _ = COOKIE_HEADER_REGEX.replace_all("", "");
        let _ = JSON_KV_QUOTED_REGEX.replace_all("", "");
        let _ = JSON_KV_CRED_REGEX.replace_all("", "");
    }

    /// **M6 regression test.** Strict-JSON quoted value with an
    /// embedded space must be redacted in full. Previously the
    /// single-regex design stopped the value match at the first
    /// space, leaving the rest of the password in the log line.
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

    /// **M6 regression test.** Same shape with embedded comma.
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

    /// **M6 regression test.** Quoted value containing an escaped
    /// quote (`\"`) must be redacted including the escape pair.
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

    /// **M6 sanity.** Existing bare-token path still works for the
    /// `k=v` and `k: v` shapes the previous single-regex handled.
    #[test]
    fn redacts_bare_password_assignment() {
        for line in ["password=hunter2", "password: hunter2", "PASSWORD=hunter2"] {
            let out = redact(line);
            assert!(!out.contains("hunter2"), "bare value leaked: {out}");
            assert!(out.contains("***"), "redaction marker missing: {out}");
        }
    }

    /// **L2 regression test.** Userinfo containing an embedded `@`
    /// is fully redacted; the previous `[^@\s/]+@` stopped at the
    /// first `@` and leaked the password tail.
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

    /// **L2 sanity.** Two URLs on one line each redact independently
    /// — the greedy class is bounded by `\s`, not `@`, so the
    /// second URL's userinfo is matched as its own run.
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
}
