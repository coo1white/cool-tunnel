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

/// Returns a copy of `line` with any `scheme://userinfo@` prefix replaced
/// by `scheme://***:***@`.
///
/// Borrows when the line contains no userinfo, allocates only when it does.
#[must_use]
pub fn redact(line: &str) -> Cow<'_, str> {
    match credential_regex() {
        Some(re) => re.replace_all(line, "${scheme}***:***@"),
        // Regex compilation failed at startup — fail open rather than drop
        // logs entirely. This branch is unreachable in practice; the
        // pattern is a compile-time constant.
        None => Cow::Borrowed(line),
    }
}

fn credential_regex() -> Option<&'static Regex> {
    static REGEX: OnceLock<Option<Regex>> = OnceLock::new();
    REGEX
        .get_or_init(|| {
            // `[^@\s/]+` matches the userinfo segment up to (but not
            // including) the `@` separator. Excluding `/` prevents the
            // pattern from gobbling a path that happens to contain `@`.
            Regex::new(r"(?P<scheme>https?://)[^@\s/]+@").ok()
        })
        .as_ref()
}

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
    fn does_not_match_at_outside_url() {
        let line = "user@host (not a URL)";
        assert_eq!(redact(line), line);
    }

    #[test]
    fn does_not_match_other_schemes() {
        // We deliberately scope to http(s); proxy URLs in this app never
        // use other schemes. Out of scope traffic stays unmodified.
        let line = "ftp://user:pass@host";
        assert_eq!(redact(line), line);
    }

    #[test]
    fn does_not_cross_path_separator() {
        // Pathological: `@` after the path. The regex must not capture it.
        let line = "https://example.com/owner@repo";
        assert_eq!(redact(line), line);
    }

    #[test]
    fn empty_line_is_safe() {
        assert_eq!(redact(""), "");
    }
}
