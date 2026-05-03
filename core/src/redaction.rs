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
/// (curl occasionally upper-cases them in error output). The
/// userinfo class `[^@\s/]+` stops at the first `@`, whitespace,
/// or `/` so a path containing `@` cannot be mistaken for
/// credentials.
#[allow(clippy::expect_used)]
static USERINFO_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<scheme>(?:https?|socks(?:5h?|4a?)?|ftp|naive)://)[^@\s/]+@")
        .expect("userinfo redaction regex must compile")
});

/// `Authorization: <scheme> <value>` matcher. The scheme is left
/// intact (Bearer / Basic / Digest tells the user what auth type the
/// upstream wanted); the value is replaced with `***`.
#[allow(clippy::expect_used)]
static AUTH_HEADER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?P<prefix>Authorization:\s*[A-Za-z]+\s+)\S+")
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
    }
}
