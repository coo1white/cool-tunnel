// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// Codable mirror of `cool_tunnel_server::ct-protocol::subscription`
// — the JSON shape served at
// `GET https://<panel-domain>/api/v1/subscription/<token>`.
//
// Trust model: TLS authenticates the panel domain. The manifest's
// HMAC `signature` is computed with the panel-only `APP_KEY` and
// is not client-verifiable; it exists for server-side auditing.
//
// The panel returns cover-site HTML at HTTP 200 for every error
// path (bad token, expired, rate-limited, missing APP_KEY,
// malformed JSON). Reading `Content-Type` and attempting JSON
// decode is the only honest signal that the token was rejected.
//
// HTTPS-only URL enforcement and the 1 MB body cap live in
// `SubscriptionClient`, not here.

import Foundation

/// One-shot manifest the panel returns for a subscription URL.
public struct SubscriptionManifestV1: Sendable, Codable, Hashable {
    /// Always `1` for this struct. Bump means new manifest version.
    public let version: UInt32
    /// Server domain (display only — match against the URL the user
    /// pasted to detect a hijacked panel returning a foreign server).
    public let server: String
    /// One or more profiles this subscription resolves to. Clients
    /// usually pick the first; the rest are operator-defined
    /// alternates.
    public let profiles: [SubscriptionProfileV1]
    /// Server capabilities the operator has opted into.
    public let capabilities: ServerCapabilitiesV1
    /// Unix timestamp the manifest was issued.
    public let issuedAt: UInt64
    /// Unix timestamp after which clients must re-fetch.
    public let expiresAt: UInt64
    /// Free-form operator note; rendered in the UI when present.
    public let note: String?
    /// HMAC-SHA-256 of the canonical body, hex-encoded. Not
    /// client-verifiable — the panel signs with `APP_KEY` which
    /// the client doesn't hold.
    public let signature: String?

    private enum CodingKeys: String, CodingKey {
        case version, server, profiles, capabilities, note, signature
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

/// One profile entry inside a [`SubscriptionManifestV1`]. Mirrors
/// `cool_tunnel_server::ct-protocol::profile::ProfileV1`.
public struct SubscriptionProfileV1: Sendable, Codable, Hashable {
    /// Upstream proxy hostname.
    public let host: String
    /// Upstream proxy port (typically 443 for the standard
    /// SNI-fronted topology).
    public let port: UInt16
    /// `NaiveProxy` basic-auth username.
    public let username: String
    /// `NaiveProxy` basic-auth password (cleartext).
    public let password: String
    /// Free-form label the operator picked. Optional.
    public let label: String?
}

/// Server-side feature flags the operator opted into. Mirrors
/// `cool_tunnel_server::ct-protocol::subscription::ServerCapabilitiesV1`.
public struct ServerCapabilitiesV1: Sendable, Codable, Hashable {
    /// Anti-tracking features the server is enforcing. Empty array
    /// means none — surface a warning in the UI before the user
    /// connects.
    public let antiTracking: [AntiTrackingFeature]
    /// Always `false` from a real deployment (NaiveProxy is
    /// HTTP/2-only). A `true` value is a strong counterfeit signal.
    public let http3: Bool
    /// Stable identifier for the cover site currently active.
    public let fakeSiteSlug: String?

    private enum CodingKeys: String, CodingKey {
        case antiTracking = "anti_tracking"
        case http3
        case fakeSiteSlug = "fake_site_slug"
    }
}

/// One anti-tracking feature flag.
///
/// Custom `Decodable` (not the auto-derived raw-value init) so a
/// future flag this v1 client doesn't know decodes into
/// [`unknown`] rather than failing the entire array decode and
/// bricking every v1 client on a server-side rollout.
public enum AntiTrackingFeature: Sendable, Codable, Hashable {
    case hideIp
    case hideVia
    case probeResistance
    case dohResolver
    case http3
    /// Forward-compat sink for any flag the server adds in a
    /// future revision.
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "hide_ip": self = .hideIp
        case "hide_via": self = .hideVia
        case "probe_resistance": self = .probeResistance
        case "doh_resolver": self = .dohResolver
        case "http3": self = .http3
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hideIp: try container.encode("hide_ip")
        case .hideVia: try container.encode("hide_via")
        case .probeResistance: try container.encode("probe_resistance")
        case .dohResolver: try container.encode("doh_resolver")
        case .http3: try container.encode("http3")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

// MARK: - Validation

extension SubscriptionManifestV1 {
    /// Maximum manifest age the client accepts (7 days).
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Acceptable forward clock-skew on `issued_at`. Beyond this,
    /// future-dating bypasses the staleness gate (a counterfeit
    /// panel could pair `issued_at = far_future` with
    /// `expires_at = farther_future` for an indefinitely-valid
    /// manifest).
    ///
    /// Typed `UInt64` so `validate(now:)`'s arithmetic runs without
    /// a `Double → UInt64` conversion that would trap on a future
    /// negative or NaN value.
    public static let maxForwardSkew: UInt64 = 60

    /// Maximum manifest validity window (`expires_at - issued_at`),
    /// one year. Without this gate, a counterfeit panel could pair
    /// `issued_at = now()` with `expires_at = u64::MAX`.
    public static let maxValidity: UInt64 = 365 * 24 * 60 * 60

    /// Maximum number of profile entries per manifest.
    /// Defense-in-depth against a hostile panel packing thousands
    /// of profiles into the 1 MB body cap to chew memory.
    public static let maxProfiles: Int = 16

    /// Returns `true` for any host string pointing at the user's
    /// own machine, link-local, or private / non-routable address
    /// space — values a counterfeit panel could use to turn the
    /// user's machine into a closed-loop SSRF source.
    public static func isBlockedHost(_ host: String) -> Bool {
        let normalised = host.trimmingCharacters(in: .whitespaces).lowercased()
        if normalised.isEmpty { return true }
        if normalised == "localhost" { return true }
        if normalised.hasSuffix(".local") || normalised == "local" { return true }
        // Bracketed IPv6 literal (the only IPv6 shape
        // `ServerAddress::parse` accepts).
        if normalised.hasPrefix("[") {
            let stripped = normalised.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if stripped == "::1" || stripped == "::" { return true }
            if stripped.hasPrefix("fe80:") || stripped.hasPrefix("fc")
                || stripped.hasPrefix("fd")
            {
                return true
            }
            return false
        }
        let parts = normalised.split(separator: ".")
        if parts.count == 4, let a = UInt8(parts[0]), let b = UInt8(parts[1]),
            let c = UInt8(parts[2]), UInt8(parts[3]) != nil
        {
            if a == 0 && b == 0 && c == 0 { return true }  // 0.0.0.0
            if a == 10 { return true }  // 10.0.0.0/8
            if a == 127 { return true }  // 127.0.0.0/8
            if a == 169 && b == 254 { return true }  // 169.254.0.0/16
            if a == 172 && (16...31).contains(b) { return true }  // 172.16.0.0/12
            if a == 192 && b == 168 { return true }  // 192.168.0.0/16
        }
        return false
    }

    /// Returns the first profile, or `nil` on an empty profile
    /// list (which a real panel won't produce).
    public var primaryProfile: SubscriptionProfileV1? {
        profiles.first
    }

    /// Validates the manifest against the schema-version,
    /// profile-cardinality, blocked-host, capability-counterfeit,
    /// issued-at, forward-skew, expiry-ordering, validity-window,
    /// expiry, and freshness rules. Throws
    /// [`SubscriptionValidationError`] describing the first
    /// violated rule. `now` is injected for testability.
    public func validate(now: Date = Date()) throws {
        if version != 1 {
            throw SubscriptionValidationError.unsupportedVersion(got: version, expected: 1)
        }
        if profiles.isEmpty {
            throw SubscriptionValidationError.noProfiles
        }
        if profiles.count > Self.maxProfiles {
            throw SubscriptionValidationError.tooManyProfiles(
                got: profiles.count, max: Self.maxProfiles
            )
        }
        for profile in profiles {
            if Self.isBlockedHost(profile.host) {
                throw SubscriptionValidationError.blockedHost(profile.host)
            }
        }
        if capabilities.http3 {
            throw SubscriptionValidationError.counterfeitCapabilities
        }
        // `0` is a schema sentinel; only stub or counterfeit
        // servers emit it. Refuse so a stub manifest can't bypass
        // the freshness check by sentinel.
        if issuedAt == 0 {
            throw SubscriptionValidationError.invalidIssuedAt
        }
        let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
        // Saturating add (not wrapping `&+`): on the
        // `nowSecs > UInt64.max - 60` edge a wrap would produce
        // `skewCeiling ≈ 0` and flag every legitimate `issuedAt`.
        let (sum, overflow) = nowSecs.addingReportingOverflow(Self.maxForwardSkew)
        let skewCeiling = overflow ? UInt64.max : sum
        if issuedAt > skewCeiling {
            throw SubscriptionValidationError.invalidIssuedAt
        }
        if expiresAt < issuedAt {
            throw SubscriptionValidationError.malformedExpiry
        }
        // Same saturating-add discipline as the skew ceiling.
        let (validityCap, validityOverflow) = issuedAt.addingReportingOverflow(Self.maxValidity)
        let maxExpires = validityOverflow ? UInt64.max : validityCap
        if expiresAt > maxExpires {
            throw SubscriptionValidationError.validityTooLong(
                gotSeconds: expiresAt &- issuedAt, maxSeconds: Self.maxValidity
            )
        }
        if expiresAt <= nowSecs {
            throw SubscriptionValidationError.expired(at: expiresAt)
        }
        // Freshness gate — only meaningful when client clock is at
        // or after `issuedAt`; the future-skew guard above already
        // rejected larger drifts.
        if nowSecs > issuedAt {
            let age = TimeInterval(nowSecs - issuedAt)
            if age > Self.maxAge {
                throw SubscriptionValidationError.stale(ageSeconds: age)
            }
        }
    }
}

/// Reasons a manifest fetched from the panel is unusable.
///
/// Routed through `TunnelOrchestrator.translate(_:)` into
/// `SubscriptionImportError` for the UI; conforms to
/// `LocalizedError` so any direct render path also reads cleanly.
public enum SubscriptionValidationError: LocalizedError, Sendable, Equatable {
    /// Manifest's `version` field is not `1`.
    case unsupportedVersion(got: UInt32, expected: UInt32)
    /// Empty `profiles` array.
    case noProfiles
    /// Profile count exceeds [`SubscriptionManifestV1.maxProfiles`].
    case tooManyProfiles(got: Int, max: Int)
    /// `capabilities.http3 == true` (strong counterfeit signal —
    /// real naive is HTTP/2-only).
    case counterfeitCapabilities
    /// `issued_at` is `0` or future-dated beyond clock-skew.
    case invalidIssuedAt
    /// `expires_at < issued_at`.
    case malformedExpiry
    /// `expires_at - issued_at > 1 year`.
    case validityTooLong(gotSeconds: UInt64, maxSeconds: UInt64)
    /// `expires_at` is in the past.
    case expired(at: UInt64)
    /// `now - issued_at > 7 days` — typically a caching proxy.
    case stale(ageSeconds: TimeInterval)
    /// Profile's `host` is loopback / link-local / private (SSRF
    /// risk). Carries the rejected host string for diagnostics.
    case blockedHost(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let got, let expected):
            return "Subscription manifest version is \(got); this app understands \(expected)."
        case .noProfiles:
            return "Subscription manifest contained no profiles."
        case .tooManyProfiles(let got, let max):
            return "Subscription manifest has \(got) profiles; the cap is \(max)."
        case .counterfeitCapabilities:
            return
                "Subscription manifest advertises a capability inconsistent with a real Cool Tunnel server."
        case .invalidIssuedAt:
            return "Subscription manifest's issue timestamp is invalid."
        case .malformedExpiry:
            return "Subscription manifest's expiry precedes its issue time."
        case .validityTooLong(_, let maxSeconds):
            return
                "Subscription manifest claims a validity longer than the \(maxSeconds / (24 * 60 * 60)) day maximum."
        case .expired:
            return "Subscription manifest has expired."
        case .stale(let ageSeconds):
            let days = max(1, Int(ageSeconds / (24 * 60 * 60)))
            return "Subscription manifest is \(days) days old."
        case .blockedHost(let host):
            return "Subscription manifest points at a blocked host (\(host))."
        }
    }
}

// MARK: - Conversion to local Profile

extension SubscriptionManifestV1 {
    /// Builds a local [`Profile`] from the primary subscription
    /// profile. `localPort` is per-machine UI state, not server-
    /// issued. `id` defaults to the upstream `host:port` for a
    /// stable identifier across imports.
    ///
    /// Returns `nil` when [`primaryProfile`] is absent.
    public func toLocalProfile(localPort: String, id: String? = nil) -> Profile? {
        guard let p = primaryProfile else { return nil }
        let profileID = id ?? "\(p.host):\(p.port)"
        return Profile(
            id: profileID,
            server: "\(p.host):\(p.port)",
            username: p.username,
            password: p.password,
            localPort: localPort
        )
    }
}
