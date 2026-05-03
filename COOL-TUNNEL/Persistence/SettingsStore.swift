// Persistence/SettingsStore.swift
//
// Settings unrelated to a specific profile: the direct-domain list, an
// optional override path for the bundled `naive` binary, and the user's
// preference about confirmation dialogs.

import Foundation

/// Persisted user settings.
public struct AppSettings: Sendable, Codable, Equatable {
    public var directDomains: [String]
    public var customNaiveBinaryPath: String
    /// Optional override for the `cool-tunnel-core` binary the
    /// orchestrator spawns at boot. Empty = use the bundled engine
    /// inside `Cool tunnel.app/Contents/Resources/`. Populated by
    /// the Settings → Rust Core → Update flow once
    /// `RustCoreUpdater` finishes installing the downloaded binary
    /// into Application Support; takes effect on the next launch.
    public var customRustCorePath: String
    public var skipProxyConfirmations: Bool

    public init(
        directDomains: [String],
        customNaiveBinaryPath: String,
        customRustCorePath: String = "",
        skipProxyConfirmations: Bool
    ) {
        self.directDomains = directDomains
        self.customNaiveBinaryPath = customNaiveBinaryPath
        self.customRustCorePath = customRustCorePath
        self.skipProxyConfirmations = skipProxyConfirmations
    }

    /// Default `AppSettings` matching the previously hard-coded Swift
    /// defaults.
    public static let `default` = AppSettings(
        directDomains: defaultDirectDomains,
        customNaiveBinaryPath: "",
        customRustCorePath: "",
        skipProxyConfirmations: false
    )

    /// Direct-domain list shipped out of the box. Mirrors
    /// `core::config::pac::DEFAULT_DIRECT_DOMAINS`.
    public static let defaultDirectDomains: [String] = [
        ".cn", "baidu.com", "bdstatic.com", "bilibili.com", "douyin.com",
        "jd.com", "mi.com", "netease.com", "qq.com", "taobao.com",
        "tmall.com", "weibo.com", "weixin.qq.com", "xiaohongshu.com",
        "youku.com", "zhihu.com",
    ]
}

/// Persists [`AppSettings`] in `UserDefaults`. Each field has its own key
/// so partial reads remain useful when a future field is added.
///
/// Marked `@unchecked Sendable` because `UserDefaults` is documented
/// thread-safe but does not yet conform to `Sendable` itself. The
/// safety invariant for this store is unconditional: every read and
/// write happens on the MainActor (the orchestrator owns the only
/// instance and is itself `@MainActor`), and every `UserDefaults`
/// call returns synchronously — there are no `await` points across
/// which a race could appear.
public struct SettingsStore: @unchecked Sendable {

    private enum Keys {
        static let directDomains = "directDomains"
        static let customBinary = "customNaiveBinaryPath"
        static let customRustCore = "customRustCorePath"
        static let skipConfirmations = "skipProxyConfirmations"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        let direct =
            defaults.stringArray(forKey: Keys.directDomains)
            ?? AppSettings.defaultDirectDomains
        let custom = defaults.string(forKey: Keys.customBinary) ?? ""
        let rust = defaults.string(forKey: Keys.customRustCore) ?? ""
        let skip = defaults.bool(forKey: Keys.skipConfirmations)
        return AppSettings(
            directDomains: direct,
            customNaiveBinaryPath: custom,
            customRustCorePath: rust,
            skipProxyConfirmations: skip
        )
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.directDomains, forKey: Keys.directDomains)
        defaults.set(settings.customNaiveBinaryPath, forKey: Keys.customBinary)
        defaults.set(settings.customRustCorePath, forKey: Keys.customRustCore)
        defaults.set(settings.skipProxyConfirmations, forKey: Keys.skipConfirmations)
    }
}
