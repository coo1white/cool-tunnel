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
// What the client validates (in `validate(now:)`):
//   - `version == 1`.
//   - `profiles` is non-empty AND ≤ 16 entries (defensive cap).
//   - `capabilities.http3 == false` (a `true` value is a strong
//     counterfeit signal — see schema commentary).
//   - `issued_at != 0` (the schema sentinel; only stub or
//     counterfeit servers emit zero).
//   - `issued_at <= now + 60 s` (forward clock-skew tolerance;
//     larger drifts would let a counterfeit pair `issued_at =
//     far_future` with `expires_at = farther_future` to bypass
//     the staleness gate).
//   - `expires_at >= issued_at` (rejects malformed manifests
//     where expiry precedes issuance).
//   - `expires_at - issued_at <= 1 year` (caps the validity
//     window so an attacker can't pair `issued_at = now()` with
//     `expires_at = u64::MAX`).
//   - `expires_at > now` (manifest hasn't expired).
//   - `now - issued_at <= 7 days` (freshness guard, matches the
//     server-side comment in `ct-protocol::subscription`).
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
///
/// Custom `Decodable` (instead of the auto-derived `String` raw-value
/// init) so a manifest carrying a future flag this v1 client doesn't
/// know about decodes into [`AntiTrackingFeature.unknown`] rather
/// than failing the entire `[AntiTrackingFeature]` array decode.
/// Without that, a server-side rollout adding `case x = "future_flag"`
/// would brick every v1 client with a misleading
/// `malformedManifest → tokenInvalid` UI banner.
public enum AntiTrackingFeature: Sendable, Codable, Hashable {
    case hideIp
    case hideVia
    case probeResistance
    case dohResolver
    case http3
    /// Forward-compat sink for any flag the server adds in a
    /// future revision. Carrying the raw string lets the UI
    /// surface "unknown protection: <name>" rather than silently
    /// drop it.
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
    /// Maximum manifest age the client accepts. Matches the
    /// 7-day freshness guard documented in
    /// `ct-protocol::subscription::SubscriptionManifestV1`. A
    /// manifest that arrives older than this — typically because a
    /// caching proxy on the user's network is serving a stale copy
    /// — is refused so the user gets fresh credentials and current
    /// capability flags.
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Acceptable forward clock-skew on `issued_at` (60 seconds).
    /// A manifest stamped at most this far ahead of the client
    /// clock is accepted as freshly-issued; anything beyond is
    /// refused because future-dating bypasses the staleness gate
    /// (a counterfeit panel could pair `issued_at = far_future`
    /// with `expires_at = farther_future` to produce an
    /// indefinitely-valid manifest).
    ///
    /// Typed `UInt64` (not `TimeInterval`) so the arithmetic at
    /// `validate(now:)` runs without a `Double → UInt64`
    /// conversion that would trap on a future negative or NaN
    /// value — defensive code shouldn't itself be a crash
    /// vector.
    public static let maxForwardSkew: UInt64 = 60

    /// Maximum manifest validity window (`expires_at - issued_at`).
    /// One year — well beyond any legitimate LTSC subscription
    /// renewal cadence. Without this gate, a counterfeit panel
    /// could pair `issued_at = now()` with `expires_at = u64::MAX`
    /// and the manifest would pass every other check, valid until
    /// year 5.84×10¹¹ AD.
    public static let maxValidity: UInt64 = 365 * 24 * 60 * 60

    /// Maximum number of profile entries inside a single manifest.
    /// Real subscriptions emit one or a small handful; the cap is
    /// defense-in-depth against a hostile panel packing thousands
    /// of profiles into the 1 MB body cap to chew memory.
    public static let maxProfiles: Int = 16

    /// Returns the first profile, or `nil` when the manifest
    /// shipped with an empty profile list (which the panel won't
    /// produce, but a hijacked or stub server might).
    public var primaryProfile: SubscriptionProfileV1? {
        profiles.first
    }

    /// Validates the manifest against the schema-version,
    /// profile-cardinality, capability-counterfeit,
    /// issued-at-sentinel, forward-skew, expiry-ordering,
    /// validity-window, expiry, and freshness rules — in that
    /// order. Throws [`SubscriptionValidationError`] describing
    /// the first violated rule. `now` is injected so tests don't
    /// depend on wall-clock time. See the file-header comment for
    /// the full list and rationale per rule.
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
        // `capabilities.http3 == true` is documented in the schema
        // as "always false from a real cool-tunnel-server
        // deployment" — naive is HTTP/2-only, advertising HTTP/3
        // would produce a recognisable QUIC fallback pattern. A
        // `true` value here is a strong counterfeit signal.
        if capabilities.http3 {
            throw SubscriptionValidationError.counterfeitCapabilities
        }
        // `issued_at` must be a real Unix timestamp. A real panel
        // stamps `now()` at emission; the only source of `0` is a
        // schema fixture or a counterfeit/stub server. Refuse
        // outright so a stub manifest can't bypass the freshness
        // check by sentinel.
        if issuedAt == 0 {
            throw SubscriptionValidationError.invalidIssuedAt
        }
        let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
        // Future-dated `issued_at` beyond clock-skew tolerance is
        // refused. Without this guard, a counterfeit panel could
        // pair `issued_at = now + 365 days` with a far-future
        // `expires_at` and produce an indefinitely-valid manifest
        // — every staleness check would trip the `now > issuedAt`
        // gate and silently skip the age comparison. The 60 s
        // window matches the panel's documented NTP discipline.
        //
        // Saturating add (not `&+`): wrapping defensive arithmetic
        // is the wrong shape — on the `nowSecs > UInt64.max - 60`
        // edge, a wrap would produce `skewCeiling ≈ 0` and
        // *every* legitimate `issuedAt` would be flagged. The
        // saturating form pins to `UInt64.max` instead, which
        // correctly accepts any plausible `issuedAt` near the
        // edge. (Year 5.84×10¹¹ AD problem: not ours.)
        let (sum, overflow) = nowSecs.addingReportingOverflow(Self.maxForwardSkew)
        let skewCeiling = overflow ? UInt64.max : sum
        if issuedAt > skewCeiling {
            throw SubscriptionValidationError.invalidIssuedAt
        }
        // Malformed manifest where expiry precedes issuance. A
        // real panel always emits `expires_at = issued_at + ttl`,
        // so this can only be a stub or transcription error.
        if expiresAt < issuedAt {
            throw SubscriptionValidationError.malformedExpiry
        }
        // Bound the validity window so an attacker can't pair a
        // legitimate-looking `issued_at` with `expires_at =
        // u64::MAX` and produce an indefinitely-valid manifest.
        // Same saturating-add discipline as the skew ceiling
        // above.
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
        // Freshness gate. Only meaningful when the client clock
        // is at or after `issuedAt`; the future-skew guard above
        // already rejected larger drifts, so this branch fires
        // only on legitimate forward time.
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
/// `SubscriptionImportError` for the UI, but conforms to
/// `LocalizedError` so any direct render path also reads cleanly.
public enum SubscriptionValidationError: LocalizedError, Sendable, Equatable {
    /// Manifest's `version` field is not `1`. The client only
    /// understands V1 today; a future server might emit V2 alongside
    /// V1 during a migration, but the URL is supposed to negotiate
    /// the version and this client doesn't yet.
    case unsupportedVersion(got: UInt32, expected: UInt32)
    /// Manifest had an empty `profiles` array. A real panel always
    /// emits at least one entry; an empty list is a sign of a stub
    /// or counterfeit server.
    case noProfiles
    /// Manifest carried more than [`SubscriptionManifestV1.maxProfiles`]
    /// entries. A hostile panel packing thousands of profiles into
    /// the 1 MB body cap is the only way to reach this — a real
    /// subscription emits a small handful at most.
    case tooManyProfiles(got: Int, max: Int)
    /// `capabilities.http3 == true`. The schema documents this
    /// flag as "always false from a real cool-tunnel-server
    /// deployment" — `naive` is HTTP/2-only, so a `true` value
    /// is a strong counterfeit signal that should refuse import
    /// outright rather than warn.
    case counterfeitCapabilities
    /// `issued_at` is `0` or future-dated beyond clock-skew
    /// tolerance. Either is a counterfeit / stub signal — a real
    /// panel stamps the manifest with `now()` at emission, never
    /// with `0` and never far in the future.
    case invalidIssuedAt
    /// `expires_at < issued_at` — malformed manifest. Real panels
    /// emit `expires_at = issued_at + ttl`; this can only happen
    /// from a stub server or transcription error.
    case malformedExpiry
    /// `expires_at - issued_at > 1 year`. A counterfeit panel
    /// pairing a legitimate-looking `issued_at` with `expires_at =
    /// u64::MAX` would otherwise pass every other check. Real
    /// subscriptions renew well inside a year.
    case validityTooLong(gotSeconds: UInt64, maxSeconds: UInt64)
    /// `expires_at` is in the past — server tells the client to
    /// re-fetch. The user pasted an old cached URL.
    case expired(at: UInt64)
    /// `now - issued_at > 7 days` — almost always a caching proxy on
    /// the user's network serving a stale copy. Re-fetch over a
    /// different network typically resolves it.
    case stale(ageSeconds: TimeInterval)

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
        }
    }
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
