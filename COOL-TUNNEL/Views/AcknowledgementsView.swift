// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/AcknowledgementsView.swift
//
// **Phase 2.4 (v0.2):** licensed-third-party-software disclosure
// pane, opened from Settings → About → Acknowledgements…. The
// upstream licenses (BSD-3-Clause for NaiveProxy; MIT/Apache-2.0
// for the Rust crate graph) require us to surface attribution
// and license text in our shipped product. Pre-2.4 the only
// place this lived was the repo's NOTICE file — invisible to
// any user who didn't open the source.
//
// Render as a separate Window scene rather than a sheet so the
// user can keep it open while they navigate the rest of the
// Settings panel — same pattern Apple's apps use for License
// Agreement / Acknowledgements windows.

import SwiftUI

/// Browseable list of upstream attribution.
///
/// Static list of `Acknowledgement` records for now — the
/// dependency set is small and stable enough that hand-curating
/// is more honest than parsing `Cargo.lock` at runtime (which
/// would surface every transitive crate, most of which the user
/// doesn't care about).
public struct AcknowledgementsView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(Self.entries) { entry in
                    EntryRow(entry: entry)
                }
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        .navigationTitle("Acknowledgements")
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acknowledgements")
                .font(.title2.weight(.semibold))
            Text(
                "Cool Tunnel is built on top of the following open-source software. Each dependency is distributed under the license shown beside its entry; full license text is available at the linked source repository."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(
                "Cool Tunnel itself is distributed under the GNU Affero General Public License, Version 3 (AGPL-3.0-only). "
                    + "Copyright © 2026 coolwhite LLC. The bundled and linked components below ship under their own "
                    + "upstream licences (BSD-3-Clause, MIT, Apache-2.0, MPL-2.0, ISC) — all AGPL-3.0-compatible."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Link(
                    "View the full NOTICE file on GitHub",
                    destination: URL(
                        string: "https://github.com/coo1white/cool-tunnel/blob/main/NOTICE")!
                )
                .font(.callout)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Data

    fileprivate struct Acknowledgement: Identifiable {
        let id: String
        let name: String
        let copyright: String
        let license: String
        let summary: String
        let url: URL
    }

    fileprivate static let entries: [Acknowledgement] = [
        Acknowledgement(
            id: "naiveproxy",
            name: "NaiveProxy",
            copyright: "Copyright klzgrad and contributors",
            license: "BSD 3-Clause License",
            summary:
                "The bundled `naive` Mach-O binary is built unmodified from upstream release tags pinned in COOL-TUNNEL/naive.upstream.json. NaiveProxy provides the HTTP/2-based censorship-resistant proxy transport at the core of the tunnel.",
            url: URL(string: "https://github.com/klzgrad/naiveproxy")!
        ),
        Acknowledgement(
            id: "rust-crates",
            name: "Rust crate graph (`cool-tunnel-core`)",
            copyright: "Copyright the respective authors",
            license: "MIT and/or Apache-2.0 (per crate)",
            summary:
                "Core engine dependencies: tokio, serde, serde_json, tracing, tracing-subscriber, thiserror, regex, bytes, and their transitive crates. The full pinned graph lives in core/Cargo.lock; license texts are embedded in each crate's source repository.",
            url: URL(string: "https://github.com/coo1white/cool-tunnel/blob/main/core/Cargo.toml")!
        ),
        Acknowledgement(
            id: "sf-symbols",
            name: "SF Symbols",
            copyright: "Copyright Apple Inc.",
            license: "Subject to the Apple Inc. SF Symbols License Agreement",
            summary:
                "Icon glyphs throughout the app (mode picker, status row, log header, menu-bar item, settings rows) are SF Symbols — used per the SF Symbols license, which permits inclusion in apps that ship for Apple platforms.",
            url: URL(string: "https://developer.apple.com/sf-symbols/")!
        ),
    ]

    // MARK: - Per-entry row

    fileprivate struct EntryRow: View {
        let entry: Acknowledgement

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name)
                        .font(.headline)
                    Spacer()
                    Text(entry.license)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                        .accessibilityLabel("License: \(entry.license)")
                }
                Text(entry.copyright)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(entry.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Link(entry.url.absoluteString, destination: entry.url)
                        .font(.caption)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(entry.name). \(entry.license). \(entry.copyright). \(entry.summary)"
            )
        }
    }
}
