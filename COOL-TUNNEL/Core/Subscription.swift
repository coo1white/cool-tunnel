// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// Codable mirror of cool-tunnel-server's v=2 subscription manifest
// — the JSON shape served at
// `GET https://<panel-domain>/api/v1/subscription/<token>`.
//
// v3.0.0 pivots the wire protocol from the v2.x NaiveProxy
// basic-auth shape to sing-box VLESS+Reality. The manifest shape
// evolves accordingly:
//
//   - `version` bumps `1 → 2`.
//   - `profiles[*].password` (cleartext basic-auth password) is
//     replaced by `profiles[*].uuid` (the VLESS user_id — the
//     credential, like an API key).
//   - Each profile gains a `reality: { public_key, dest_host,
//     short_id }` block carrying the Reality handshake params the
//     client plugs into its sing-box vless outbound.
//   - The v=1 top-level `server_naive_pin` is renamed to
//     `server_singbox_pin` with a single `upstream_tag` field; the
//     client compares against its own embedded
//     singbox-core.upstream.json for cross-end binary-identity
//     confirmation.
//
// The v=1 manifest shape is incompatible — v2.x clients fetching a
// v=2 manifest fail at decode time (the `password` field is missing).
// The cool-tunnel-server v0.4.0 release co-ordinates the cut: it
// emits v=2 only, so operators upgrade the server first, then roll
// out v3.0.0 clients.
//
// Trust model: TLS authenticates the panel domain. The manifest's
// HMAC `signature` is computed with the panel-only `APP_KEY` and
// is not client-verifiable; it exists for server-side auditing.
// The panel returns cover-site HTML at HTTP 200 for every error
// path (bad token, expired, rate-limited, missing APP_KEY,
// malformed JSON). Reading `Content-Type` and attempting JSON
// decode is the only honest signal that the token was rejected.
//
// HTTPS-only URL enforcement and the 1 MB body cap live in
// `SubscriptionClient`, not here.

import Foundation

/// One-shot manifest the panel returns for a subscription URL.
///
/// The type is named `SubscriptionManifestV2` to distinguish it
/// from the (now removed) v=1 mirror; the on-the-wire `version`
/// field is `2`.
public struct SubscriptionManifestV2: Sendable, Codable, Hashable {
    /// Always `2` for this struct. The cool-tunnel-server v0.4.0
    /// release emits v=2 only; v=1 manifests from older servers
    /// fail at the version check below.
    public let version: UInt32
    /// Server domain (display only — match against the URL the user
    /// pasted to detect a hijacked panel returning a foreign server).
    public let server: String
    /// One or more profiles this subscription resolves to. Clients
    /// usually pick the first; the rest are operator-defined
    /// alternates.
    public let profiles: [SubscriptionProfileV2]
    /// Server capabilities the operator has opted into.
    public let capabilities: ServerCapabilitiesV2
    /// Unix timestamp the manifest was issued.
    public let issuedAt: UInt64
    /// Unix timestamp after which clients must re-fetch.
    public let expiresAt: UInt64
    /// Free-form operator note; rendered in the UI when present.
    public let note: String?
    /// Cross-end binary-identity confirmation. Carries the sing-box
    /// upstream tag the panel container was built against; the
    /// client compares it to the tag pinned in its own embedded
    /// `singbox.upstream.json`. Mismatch is a soft-warn (the
    /// release pipeline aims to keep both ends pinned to the same
    /// tag, but a server that auto-bumped to a newer sing-box and
    /// a client that hasn't yet released still talks fine if the
    /// VLESS+Reality wire is stable across the tag delta).
    public let serverSingboxPin: ServerSingboxPinV2?
    /// HMAC-SHA-256 of the canonical body, hex-encoded. Not
    /// client-verifiable — the panel signs with `APP_KEY` which
    /// the client doesn't hold.
    public let signature: String?

    private enum CodingKeys: String, CodingKey {
        case version, server, profiles, capabilities, note, signature
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case serverSingboxPin = "server_singbox_pin"
    }
}

/// One profile entry inside a [`SubscriptionManifestV2`].
public struct SubscriptionProfileV2: Sendable, Codable, Hashable {
    /// Upstream proxy hostname.
    public let host: String
    /// Upstream proxy port (typically 443 for the standard
    /// SNI-fronted topology).
    public let port: UInt16
    /// Display username — VLESS uses it as the per-user `name`
    /// field for log readability; the credential is the `uuid`
    /// below.
    public let username: String
    /// VLESS user_id (RFC 4122 UUID). This IS the credential —
    /// like an API key — that the panel rotates per `Regenerate
    /// UUID` action. v2.x basic-auth `password` is gone.
    public let uuid: String
    /// Per-profile Reality handshake parameters. Required in v=2:
    /// the client cannot plug the credential into its sing-box
    /// vless outbound without the matching public_key + dest_host
    /// + short_id.
    public let reality: RealityV2
    /// Free-form label the operator picked. Optional.
    public let label: String?
}

/// Reality handshake parameters carried per-profile.
public struct RealityV2: Sendable, Codable, Hashable {
    /// X25519 public key (base64url, 32 bytes). The client plugs
    /// this into its sing-box vless outbound's
    /// `tls.reality.public_key` field; cool-tunnel-server's
    /// `ServerConfig.reality_private_key` is the matching half.
    public let publicKey: String
    /// Cover-site SNI the client uses on its `tls.server_name`
    /// (and the server's vless inbound forwards to). Typical
    /// operator pick: `www.microsoft.com`, `www.apple.com`,
    /// `www.cloudflare.com`.
    public let destHost: String
    /// short_id the client sends inside the Reality handshake.
    /// Empty string is the conventional "no short_id challenge"
    /// value; the server accepts it when the operator hasn't
    /// configured any explicit short_ids.
    public let shortId: String

    private enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case destHost = "dest_host"
        case shortId = "short_id"
    }
}

/// Cross-end pin block (top-level on the manifest).
public struct ServerSingboxPinV2: Sendable, Codable, Hashable {
    /// Pinned upstream sing-box release tag (e.g. `v1.13.12`).
    /// Sourced from cool-tunnel-server's
    /// `singbox-core/singbox.upstream.json::upstream_tag` via the
    /// bundled `singbox-core` binary's `version --json` output.
    public let upstreamTag: String

    private enum CodingKeys: String, CodingKey {
        case upstreamTag = "upstream_tag"
    }
}

/// Server-side feature flags the operator opted into.
public struct ServerCapabilitiesV2: Sendable, Codable, Hashable {
    /// Anti-tracking features the server is enforcing. Empty array
    /// means none — surface a warning in the UI before the user
    /// connects.
    public let antiTracking: [AntiTrackingFeature]
    /// Always `false` from a real deployment (the v0.4.0 sing-box
    /// VLESS+Reality stack runs over TCP only; no QUIC listener
    /// wired). A `true` value is a strong counterfeit signal — the
    /// validator below treats it as a hard reject.
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
/// future flag this v=2 client doesn't know decodes into
/// [`unknown`] rather than failing the entire array decode and
/// bricking every v=2 client on a server-side rollout.
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

extension SubscriptionManifestV2 {
    /// The manifest schema version this client speaks. Bumped from
    /// `1` (v2.x clients on NaiveProxy basic-auth) to `2` for the
    /// v3.0.0 VLESS+Reality cut.
    public static let supportedVersion: UInt32 = 2

    /// Maximum manifest age the client accepts (7 days). Matches
    /// the cool-tunnel-server-side
    /// `MANIFEST_TTL_SECONDS = 60*60*24*7` constant and the
    /// `ct-protocol::SubscriptionManifestV1::FRESHNESS_WINDOW_SECONDS`
    /// spec value. (Server-side, v0.4.0 clamped the previously-30-day
    /// emitted expiry down to 7 days to match this gate.)
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
    public var primaryProfile: SubscriptionProfileV2? {
        profiles.first
    }

    /// Validates the manifest against the schema-version,
    /// profile-cardinality, blocked-host, capability-counterfeit,
    /// reality-completeness, issued-at, forward-skew,
    /// expiry-ordering, validity-window, expiry, and freshness
    /// rules. Throws [`SubscriptionValidationError`] describing
    /// the first violated rule. `now` is injected for testability.
    public func validate(now: Date = Date()) throws {
        if version != Self.supportedVersion {
            throw SubscriptionValidationError.unsupportedVersion(
                got: version, expected: Self.supportedVersion
            )
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
            if profile.uuid.trimmingCharacters(in: .whitespaces).isEmpty {
                throw SubscriptionValidationError.missingUuid(host: profile.host)
            }
            if profile.reality.publicKey.trimmingCharacters(in: .whitespaces).isEmpty {
                throw SubscriptionValidationError.missingRealityPublicKey(host: profile.host)
            }
            if profile.reality.destHost.trimmingCharacters(in: .whitespaces).isEmpty {
                throw SubscriptionValidationError.missingRealityDestHost(host: profile.host)
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
/// Routed through `TunnelOrchestrator.importFromSubscriptionURL(_:)`
/// into `SubscriptionImportError` for the UI; conforms to
/// `LocalizedError` so any direct render path also reads cleanly.
public enum SubscriptionValidationError: LocalizedError, Sendable, Equatable {
    /// Manifest's `version` field is not `2`.
    case unsupportedVersion(got: UInt32, expected: UInt32)
    /// Empty `profiles` array.
    case noProfiles
    /// Profile count exceeds [`SubscriptionManifestV2.maxProfiles`].
    case tooManyProfiles(got: Int, max: Int)
    /// `capabilities.http3 == true` (strong counterfeit signal —
    /// real v0.4.0 sing-box VLESS+Reality is TCP-only).
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
    /// Profile's `uuid` is empty — server-side configuration error
    /// (the panel's regenerate-UUID flow should always populate it).
    case missingUuid(host: String)
    /// Profile's `reality.public_key` is empty — the cool-tunnel-
    /// server operator hasn't run reality-keygen and persisted the
    /// keypair to ServerConfig. The client cannot complete the
    /// VLESS+Reality handshake without it.
    case missingRealityPublicKey(host: String)
    /// Profile's `reality.dest_host` is empty — same operator-side
    /// fix as missingRealityPublicKey.
    case missingRealityDestHost(host: String)

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
        case .missingUuid(let host):
            return "Subscription profile for \(host) is missing its VLESS UUID."
        case .missingRealityPublicKey(let host):
            return
                "Subscription profile for \(host) is missing its Reality public key — the server operator must run reality-keygen first."
        case .missingRealityDestHost(let host):
            return "Subscription profile for \(host) is missing its Reality dest_host."
        }
    }
}

// MARK: - Conversion to local Profile
//
// **v3.0.0 (sub-phase F):** the rewire landed — the local
// `Profile` model in Protocol.swift now carries `uuid` and a
// `reality { publicKey, destHost, shortId }` block, matching the
// manifest's `SubscriptionProfileV2` shape one-to-one.
// `TunnelOrchestrator.importFromSubscriptionURL(_:)` constructs
// the local Profile inline (the rename touches one call site
// only). A dedicated `toLocalProfile()` helper isn't pulled into
// the manifest type because the conversion needs orchestrator
// context (existing profile id, localPort, subscriptionURL) that
// the manifest itself doesn't carry — keeping the inline shape
// in the orchestrator avoids a wider API change here.