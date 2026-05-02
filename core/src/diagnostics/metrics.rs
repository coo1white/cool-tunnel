//! Parser for `curl --write-out` output and a small unit-conversion helper.
//!
//! The Swift app passes a `\n`-delimited list of `key=value` pairs through
//! curl's `--write-out` flag and consumes them as a `[String: String]`
//! dictionary. This module replicates that parser exactly so the two
//! implementations report identical numbers.

use std::collections::HashMap;

/// Splits the captured `--write-out` output into a `key → value` map.
///
/// Behaviour matches the Swift `parseCurlMetrics`:
///
/// - Lines without `=` are skipped.
/// - The first `=` separates key from value; later `=` characters are
///   preserved in the value.
/// - Repeated keys: last occurrence wins.
#[must_use]
pub fn parse_write_out(output: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in output.split('\n') {
        if let Some((key, value)) = line.split_once('=') {
            out.insert(key.to_owned(), value.to_owned());
        }
    }
    out
}

/// Converts a curl-emitted seconds-as-decimal value (e.g. `"0.123456"`) into
/// integer milliseconds.
///
/// Returns `None` when the input is missing or unparseable, so callers can
/// distinguish "no measurement" from "0 ms".
#[must_use]
pub fn secs_to_ms(value: Option<&String>) -> Option<f64> {
    let raw = value?;
    let parsed: f64 = raw.parse().ok()?;
    Some(parsed * 1000.0)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn parses_typical_output() {
        let raw = "http_code=204\n\
                   remote_ip=142.250.190.36\n\
                   time_namelookup=0.001234\n\
                   time_connect=0.045678\n\
                   time_appconnect=0.123456\n\
                   time_starttransfer=0.234567\n\
                   time_total=0.345678\n";
        let m = parse_write_out(raw);
        assert_eq!(m.get("http_code").map(String::as_str), Some("204"));
        assert_eq!(m.get("remote_ip").map(String::as_str), Some("142.250.190.36"));
        let dns_ms = secs_to_ms(m.get("time_namelookup")).unwrap();
        assert!((dns_ms - 1.234).abs() < 0.01);
    }

    #[test]
    fn ignores_lines_without_equals() {
        let m = parse_write_out("not_a_pair\nhttp_code=200\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("http_code").map(String::as_str), Some("200"));
    }

    #[test]
    fn last_occurrence_wins() {
        let m = parse_write_out("http_code=200\nhttp_code=204\n");
        assert_eq!(m.get("http_code").map(String::as_str), Some("204"));
    }

    #[test]
    fn secs_to_ms_handles_missing_input() {
        assert_eq!(secs_to_ms(None), None);
        let bad = "not-a-number".to_owned();
        assert_eq!(secs_to_ms(Some(&bad)), None);
    }

    #[test]
    fn value_may_contain_equals_sign() {
        let m = parse_write_out("token=key=value\n");
        assert_eq!(m.get("token").map(String::as_str), Some("key=value"));
    }
}
