// Core/Subscription.swift
//
// Codable mirror of `cool_tunnel_server::ct-protocol::subscription`
// — the JSON shape served at
// `GET https://<panel-domain>/api/v1/subscription/<token>`.
//
// Trust model. The manifest body carries an HMAC-SHA-256 `signature`
// computed with the panel's `APP_KEY`. That key never leaves the
// server, so the client physically cannot verify the HMAC. The
// signature exists for server-side auditing — clients trust the
// manifest because TLS authenticates the panel domain (the operator
// configured a valid Let's Encrypt cert through Caddy).
//
// Anti-fingerprinting consequence. Every panel error path —
// rate-limited, expired token, missing APP_KEY, malformed JSON —
// returns the cover-site HTML at HTTP 200. The client cannot
// distinguish "bad token" from "endpoint exists but rejected" on
// status code alone. Reading the response `Content-Type` and
// attempting JSON decode is the only honest signal.
//
// What the client validates:
//   - HTTPS-only URL.
//   - Response decodes as `SubscriptionManifestV1`.
//   - `version == 1`.
//   - `expires_at` is in the future.
//   - `now - issued_at <= 7 days` (freshness guard, matches the
//     server-side comment in `ct-protocol::subscription`).

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
    /// alternates (per-team rotation, hot-spare in another region).
    public let profiles: [SubscriptionProfileV1]
    /// Server capabilities the operator has opted into.
    public let capabilities: ServerCapabilitiesV1
    /// Unix timestamp the manifest was issued.
    public let issuedAt: UInt64
    /// Unix timestamp after which clients must re-fetch.
    public let expiresAt: UInt64
    /// Free-form operator note ("hot-spare server in Tokyo");
    /// rendered in the UI when present.
    public let note: String?
    /// HMAC-SHA-256 of the canonical body with `signature: nil`.
    /// Hex-encoded. Decorative on the client — the panel signs with
    /// `APP_KEY` which the client doesn't have. Surfaced for
    /// completeness so a future protocol revision can move to
    /// asymmetric signing without changing the wire shape.
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
    /// Whether HTTP/3 is advertised. Always `false` from a real
    /// `cool-tunnel-server` deployment (`NaiveProxy` is HTTP/2-only;
    /// advertising true would lead to a recognisable QUIC fallback
    /// pattern). A `true` here is a strong signal the panel is
    /// counterfeit.
    public let http3: Bool
    /// Stable identifier for the cover site currently active.
    /// Surface in UI as "connected via 'minimal-blog'".
    public let fakeSiteSlug: String?

    private enum CodingKeys: String, CodingKey {
        case antiTracking = "anti_tracking"
        case http3
        case fakeSiteSlug = "fake_site_slug"
    }
}

/// One anti-tracking feature flag. Mirrors
/// `cool_tunnel_server::ct-protocol::subscription::AntiTrackingFeature`.
public enum AntiTrackingFeature: String, Sendable, Codable, Hashable {
    case hideIp = "hide_ip"
    case hideVia = "hide_via"
    case probeResistance = "probe_resistance"
    case dohResolver = "doh_resolver"
    case http3
}

// MARK: - Validation

extension SubscriptionManifestV1 {
    /// Maximum manifest age the client accepts. Matches the
    /// 7-day freshness guard documented in
    /// `ct-protocol::subscription::SubscriptionManifestV1`. A
    /// manifest that arrives older than this — typically because a
    /// caching proxy on the user's network is serving a stale copy
    /// — is refused so the user gets fresh credentials and current
    /// capability flags.
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Returns the first profile, or `nil` when the manifest
    /// shipped with an empty profile list (which the panel won't
    /// produce, but a hijacked or stub server might).
    public var primaryProfile: SubscriptionProfileV1? {
        profiles.first
    }

    /// Validates the manifest against the freshness, expiry, and
    /// schema-version rules. Throws [`SubscriptionValidationError`]
    /// describing the first violated rule. `now` is injected so
    /// tests don't depend on wall-clock time.
    public func validate(now: Date = Date()) throws {
        if version != 1 {
            throw SubscriptionValidationError.unsupportedVersion(got: version, expected: 1)
        }
        if profiles.isEmpty {
            throw SubscriptionValidationError.noProfiles
        }
        let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
        if expiresAt <= nowSecs {
            throw SubscriptionValidationError.expired(at: expiresAt)
        }
        // `issuedAt` should never be in the future; clamp the
        // comparison to non-negative so a small clock skew on the
        // client doesn't flip the freshness check upside-down.
        if issuedAt > 0 && nowSecs > issuedAt {
            let age = TimeInterval(nowSecs - issuedAt)
            if age > Self.maxAge {
                throw SubscriptionValidationError.stale(ageSeconds: age)
            }
        }
    }
}

/// Reasons a manifest fetched from the panel is unusable.
public enum SubscriptionValidationError: Error, Sendable, Equatable {
    /// Manifest's `version` field is not `1`. The client only
    /// understands V1 today; a future server might emit V2 alongside
    /// V1 during a migration, but the URL is supposed to negotiate
    /// the version and this client doesn't yet.
    case unsupportedVersion(got: UInt32, expected: UInt32)
    /// Manifest had an empty `profiles` array. A real panel always
    /// emits at least one entry; an empty list is a sign of a stub
    /// or counterfeit server.
    case noProfiles
    /// `expires_at` is in the past — server tells the client to
    /// re-fetch. The user pasted an old cached URL.
    case expired(at: UInt64)
    /// `now - issued_at > 7 days` — almost always a caching proxy on
    /// the user's network serving a stale copy. Re-fetch over a
    /// different network typically resolves it.
    case stale(ageSeconds: TimeInterval)
}

// MARK: - Conversion to local Profile

extension SubscriptionManifestV1 {
    /// Builds a local [`Profile`] from the primary subscription
    /// profile, using `localPort` as the user's chosen SOCKS
    /// listener port (the manifest itself doesn't carry a local
    /// port — that's a per-machine UI choice, not server-issued).
    /// `id` defaults to the upstream `host:port` so a user importing
    /// two subscriptions for the same server gets a stable, unique
    /// identifier without picking one by hand.
    ///
    /// Returns `nil` when [`primaryProfile`] is absent (an empty
    /// `profiles` array on the wire); use [`validate`] to surface a
    /// real error before reaching here.
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
