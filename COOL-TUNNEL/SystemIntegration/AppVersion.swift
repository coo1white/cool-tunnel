// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/AppVersion.swift
//
// Reads the running app's marketing version + build number from the
// bundle's Info.plist so the Settings footer can show
// "Cool Tunnel v0.1.5.6 (build 1)" without hardcoding the version
// in two places. The string updates automatically every time
// MARKETING_VERSION bumps in the Xcode project.

import Foundation

/// Single read-only view of the running bundle's version metadata.
public struct AppVersion: Sendable, Equatable {
    /// `CFBundleShortVersionString`, e.g. "0.1.5.6". Empty when the
    /// key is missing — should never happen in a built bundle, but
    /// keeps unit tests against an empty plist from crashing.
    public let marketingVersion: String
    /// `CFBundleVersion`, e.g. "1". Increments per build; surfaced
    /// alongside the marketing version so support tickets can pin a
    /// specific build.
    public let buildNumber: String

    /// Cached read at first access. Bundle metadata can't change
    /// without relaunch, so re-querying every Settings open would be
    /// wasteful.
    public static let current: AppVersion = {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return AppVersion(marketingVersion: marketing, buildNumber: build)
    }()

    /// Friendly one-liner for the Settings footer:
    /// `Cool Tunnel v0.1.5.6 (build 1)`.
    public var displayString: String {
        let version = marketingVersion.isEmpty ? "unknown" : marketingVersion
        if buildNumber.isEmpty {
            return "Cool Tunnel v\(version)"
        }
        return "Cool Tunnel v\(version) (build \(buildNumber))"
    }
}
