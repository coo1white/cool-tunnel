// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Smart-routing PAC file generation.
//!
//! Produces a JavaScript Proxy Auto-Configuration file that returns
//! `"DIRECT"` for loopback, RFC 1918 private IP ranges, and any host matching
//! the user-configured direct-domain list. Everything else is sent through
//! the local SOCKS listener with a `DIRECT` fallback.

use crate::domain::Port;

/// Default direct-domain list used as a fallback when the user has not
/// configured one. Matches the Swift `defaultDirectDomains` constant.
pub const DEFAULT_DIRECT_DOMAINS: &[&str] = &[
    ".cn",
    "baidu.com",
    "bdstatic.com",
    "bilibili.com",
    "douyin.com",
    "jd.com",
    "mi.com",
    "netease.com",
    "qq.com",
    "taobao.com",
    "tmall.com",
    "weibo.com",
    "weixin.qq.com",
    "xiaohongshu.com",
    "youku.com",
    "zhihu.com",
];

/// Generates the PAC file body.
///
/// `direct_domains` are normalised (trimmed, lowercased, empty entries
/// dropped) before being embedded as a JavaScript array. `port` is the
/// SOCKS listener port the smart routing should fall through to.
#[must_use]
pub fn generate_pac(direct_domains: &[String], port: Port) -> String {
    let cleaned = normalise_domains(direct_domains);
    let domains_array = encode_js_string_array(&cleaned);
    let port = port.get();
    // Pull the loopback host through the central `config::LOOPBACK_HOST`
    // constant so the JS template doesn't fossilise its own copy
    // — kept aliased here as `loopback` to keep the format string
    // readable.
    let loopback = crate::config::LOOPBACK_HOST;
    format!(
        "function FindProxyForURL(url, host) {{\n\
         \x20   host = host.toLowerCase();\n\
         \n\
         \x20   if (isPlainHostName(host) ||\n\
         \x20       shExpMatch(host, \"localhost\") ||\n\
         \x20       shExpMatch(host, \"127.*\") ||\n\
         \x20       shExpMatch(host, \"10.*\") ||\n\
         \x20       shExpMatch(host, \"172.16.*\") ||\n\
         \x20       shExpMatch(host, \"172.17.*\") ||\n\
         \x20       shExpMatch(host, \"172.18.*\") ||\n\
         \x20       shExpMatch(host, \"172.19.*\") ||\n\
         \x20       shExpMatch(host, \"172.20.*\") ||\n\
         \x20       shExpMatch(host, \"172.21.*\") ||\n\
         \x20       shExpMatch(host, \"172.22.*\") ||\n\
         \x20       shExpMatch(host, \"172.23.*\") ||\n\
         \x20       shExpMatch(host, \"172.24.*\") ||\n\
         \x20       shExpMatch(host, \"172.25.*\") ||\n\
         \x20       shExpMatch(host, \"172.26.*\") ||\n\
         \x20       shExpMatch(host, \"172.27.*\") ||\n\
         \x20       shExpMatch(host, \"172.28.*\") ||\n\
         \x20       shExpMatch(host, \"172.29.*\") ||\n\
         \x20       shExpMatch(host, \"172.30.*\") ||\n\
         \x20       shExpMatch(host, \"172.31.*\") ||\n\
         \x20       shExpMatch(host, \"192.168.*\")) {{\n\
         \x20       return \"DIRECT\";\n\
         \x20   }}\n\
         \n\
         \x20   var directDomains = {domains_array};\n\
         \n\
         \x20   for (var i = 0; i < directDomains.length; i++) {{\n\
         \x20       var domain = directDomains[i];\n\
         \x20       if (dnsDomainIs(host, domain) || shExpMatch(host, \"*\" + domain)) {{\n\
         \x20           return \"DIRECT\";\n\
         \x20       }}\n\
         \x20   }}\n\
         \n\
         \x20   return \"SOCKS5 {loopback}:{port}; SOCKS {loopback}:{port}; DIRECT\";\n\
         }}"
    )
}

fn normalise_domains(input: &[String]) -> Vec<String> {
    input
        .iter()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

fn encode_js_string_array(values: &[String]) -> String {
    // serde_json produces a strict-JSON array of strings, which is
    // also a valid JavaScript expression — ideal for embedding in
    // PAC content. `serde_json::to_string` over `&[String]` is
    // structurally infallible: `String` has no `Serialize` failure
    // modes (no map keys, no NaN floats).
    //
    // **v0.1.7.12 (SM-7, R4):** previously we defended with
    // `unwrap_or_default()` which silently returned `String::new()`
    // on the unreachable path. If a future refactor swapped
    // `&[String]` for a type that *can* fail to serialize (e.g.
    // a wrapper carrying numeric metadata), the PAC body would
    // become `var directDomains = ;` — invalid JS — emitted to
    // a 200 response with zero diagnostic. `expect()` restores
    // the failure signal: a panic here is safer than emitting
    // malformed JS, and the message names the invariant for
    // whoever is reading the trace.
    #[allow(clippy::expect_used)]
    {
        serde_json::to_string(values)
            .expect("serde_json::to_string over &[String] is structurally infallible")
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn embeds_listener_port() {
        let pac = generate_pac(&[], Port::new(1080).unwrap());
        assert!(pac.contains("SOCKS5 127.0.0.1:1080"));
        assert!(pac.contains("SOCKS 127.0.0.1:1080"));
    }

    #[test]
    fn embeds_normalised_domain_list() {
        let domains = vec![
            "  Baidu.COM  ".to_owned(),
            String::new(),
            "weibo.com".to_owned(),
            "   ".to_owned(),
        ];
        let pac = generate_pac(&domains, Port::new(1080).unwrap());
        assert!(pac.contains("var directDomains = [\"baidu.com\",\"weibo.com\"];"));
    }

    #[test]
    fn empty_domain_list_yields_empty_js_array() {
        let pac = generate_pac(&[], Port::new(1080).unwrap());
        assert!(pac.contains("var directDomains = [];"));
    }

    #[test]
    fn covers_all_172_16_through_31_subnets() {
        let pac = generate_pac(&[], Port::new(1080).unwrap());
        for octet in 16..=31 {
            assert!(
                pac.contains(&format!("172.{octet}.*")),
                "missing 172.{octet}.* in PAC"
            );
        }
    }

    #[test]
    fn includes_loopback_and_local_subnets() {
        let pac = generate_pac(&[], Port::new(1080).unwrap());
        assert!(pac.contains("127.*"));
        assert!(pac.contains("10.*"));
        assert!(pac.contains("192.168.*"));
        assert!(pac.contains("\"localhost\""));
    }

    #[test]
    fn default_direct_domains_match_swift() {
        let count = DEFAULT_DIRECT_DOMAINS.len();
        assert_eq!(count, 16);
        assert!(DEFAULT_DIRECT_DOMAINS.contains(&".cn"));
        assert!(DEFAULT_DIRECT_DOMAINS.contains(&"weixin.qq.com"));
    }
}
