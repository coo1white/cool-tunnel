// Persistence/SettingsStore.swift
//
// Settings unrelated to a specific profile: the direct-domain list, an
// optional override path for the bundled `naive` binary, and the user's
// preference about confirmation dialogs.

import Foundation
import SwiftUI

/// User-controlled appearance preference. `.system` follows the
/// macOS appearance setting (the default and the right answer
/// for most users); `.light` and `.dark` lock the app regardless
/// of the system. Persisted as a string in UserDefaults so the
/// stored value is grep-able and the schema is forward-compatible
/// (an unknown value falls back to `.system`).
public enum AppearanceMode: String, Sendable, Codable, CaseIterable, Equatable {
    case system
    case light
    case dark

    /// Maps to SwiftUI's `preferredColorScheme` value. `nil`
    /// means "follow the system" (don't override).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// User-facing label for the Settings picker.
    public var displayName: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Persisted user settings.
public struct AppSettings: Sendable, Codable, Equatable {
    public var directDomains: [String]
    public var customNaiveBinaryPath: String
    /// Optional override for the `cool-tunnel-core` binary the
    /// orchestrator spawns at boot. Empty = use the bundled engine
    /// inside `Cool Tunnel.app/Contents/Resources/`. Populated by
    /// the Settings → Rust Core → Update flow once
    /// `RustCoreUpdater` finishes installing the downloaded binary
    /// into Application Support; takes effect on the next launch.
    public var customRustCorePath: String
    public var skipProxyConfirmations: Bool
    /// Light / dark / system appearance preference. Defaults to
    /// `.system` so existing v0.1.7.x users get system-matched
    /// behaviour (the right default; their previous experience
    /// was light-only).
    public var appearanceMode: AppearanceMode

    public init(
        directDomains: [String],
        customNaiveBinaryPath: String,
        customRustCorePath: String = "",
        skipProxyConfirmations: Bool,
        appearanceMode: AppearanceMode = .system
    ) {
        self.directDomains = directDomains
        self.customNaiveBinaryPath = customNaiveBinaryPath
        self.customRustCorePath = customRustCorePath
        self.skipProxyConfirmations = skipProxyConfirmations
        self.appearanceMode = appearanceMode
    }

    /// Default `AppSettings` matching the previously hard-coded Swift
    /// defaults.
    public static let `default` = AppSettings(
        directDomains: defaultDirectDomains,
        customNaiveBinaryPath: "",
        customRustCorePath: "",
        skipProxyConfirmations: false,
        appearanceMode: .system
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
        static let appearanceMode = "appearanceMode"
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
        // Unknown stored values fall back to `.system` so a
        // forward-incompatible value from a future build
        // downgraded to v0.1.7.7 doesn't crash the app.
        let appearance =
            (defaults.string(forKey: Keys.appearanceMode))
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        return AppSettings(
            directDomains: direct,
            customNaiveBinaryPath: custom,
            customRustCorePath: rust,
            skipProxyConfirmations: skip,
            appearanceMode: appearance
        )
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.directDomains, forKey: Keys.directDomains)
        defaults.set(settings.customNaiveBinaryPath, forKey: Keys.customBinary)
        defaults.set(settings.customRustCorePath, forKey: Keys.customRustCore)
        defaults.set(settings.skipProxyConfirmations, forKey: Keys.skipConfirmations)
        defaults.set(settings.appearanceMode.rawValue, forKey: Keys.appearanceMode)
    }
}
