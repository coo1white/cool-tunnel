//! Credential redaction for log lines forwarded to the Swift UI.
//!
//! `naive` prints its full proxy URL — including userinfo
//! (`https://user:pass@host:port`) — at startup with default verbosity.
//! Anything we forward verbatim ends up in the live log view, support
//! bundles, and screenshots. This module strips the userinfo segment
//! before the line crosses our boundary.

use std::borrow::Cow;
use std::sync::OnceLock;

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
    // Apply redactors in sequence. Each one borrows when no match is
    // found, so the no-secret common case (vast majority of log
    // lines) allocates zero times.
    let after_url = match userinfo_regex() {
        Some(re) => re.replace_all(line, "${scheme}***:***@"),
        None => Cow::Borrowed(line),
    };
    let after_auth = match auth_header_regex() {
        Some(re) => re.replace_all(&after_url, "${prefix}***"),
        None => after_url.clone(),
    };
    let after_cookie = match cookie_header_regex() {
        Some(re) => re.replace_all(&after_auth, "${prefix}***"),
        None => after_auth.clone(),
    };
    // If nothing changed, return the borrowed input — preserves the
    // zero-allocation fast path for clean lines.
    if after_cookie == line {
        Cow::Borrowed(line)
    } else {
        Cow::Owned(after_cookie.into_owned())
    }
}

/// `scheme://userinfo@` matcher. Schemes are case-insensitive (curl
/// occasionally upper-cases them in error output). The userinfo class
/// `[^@\s/]+` stops at the first `@`, whitespace, or `/` so a path
/// containing `@` cannot be mistaken for credentials.
fn userinfo_regex() -> Option<&'static Regex> {
    static REGEX: OnceLock<Option<Regex>> = OnceLock::new();
    REGEX
        .get_or_init(|| {
            Regex::new(r"(?i)(?P<scheme>(?:https?|socks(?:5h?|4a?)?|ftp|naive)://)[^@\s/]+@").ok()
        })
        .as_ref()
}

/// `Authorization: <scheme> <value>` matcher. The scheme is left
/// intact (Bearer / Basic / Digest tells the user what auth type the
/// upstream wanted); the value is replaced with `***`.
fn auth_header_regex() -> Option<&'static Regex> {
    static REGEX: OnceLock<Option<Regex>> = OnceLock::new();
    REGEX
        .get_or_init(|| {
            // Capture everything up to and including the auth scheme +
            // whitespace; replace just the secret tail.
            Regex::new(r"(?i)(?P<prefix>Authorization:\s*[A-Za-z]+\s+)\S+").ok()
        })
        .as_ref()
}

/// `Cookie: …` matcher. Cookies frequently carry session tokens and
/// CSRF state — replacing the entire value (not just one cookie pair)
/// is the conservative choice for log lines we don't control.
fn cookie_header_regex() -> Option<&'static Regex> {
    static REGEX: OnceLock<Option<Regex>> = OnceLock::new();
    REGEX
        .get_or_init(|| Regex::new(r"(?i)(?P<prefix>(?:Set-)?Cookie:\s*)[^\r\n]+").ok())
        .as_ref()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn redacts_userinfo_in_https_url() {
        let line = "Listening: https://nick:hunter2@naive.example.com:443";
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
            "socks5://nick:hunter2@proxy.example.com:1080",
            "socks5h://nick:hunter2@proxy.example.com:1080",
            "socks4://nick:hunter2@proxy.example.com:1080",
            "socks4a://nick:hunter2@proxy.example.com:1080",
            "socks://nick:hunter2@proxy.example.com:1080",
        ] {
            let out = redact(line);
            assert!(!out.contains("hunter2"), "password leaked: {out}");
            assert!(!out.contains("nick"), "username leaked: {out}");
            assert!(out.contains("***:***@"), "redaction marker missing: {out}");
        }
    }

    /// `naive://` and `ftp://` are also covered — both can show up in
    /// curl error text under unusual configurations.
    #[test]
    fn redacts_naive_and_ftp_schemes() {
        let naive = "naive+https://nick:hunter2@server:443";
        // The "naive+https://" case still has the inner https:// match
        // — ensure the password is gone.
        let out = redact(naive);
        assert!(!out.contains("hunter2"));

        let ftp = "ftp://nick:hunter2@host";
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
}
