// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/ConnectionFormView.swift
//
// **Phase 2.1 (v0.2):** rewritten as a real
// `Form { Section { … } }.formStyle(.grouped)`. The custom card
// + bespoke text-field styling is gone. Each row is a standard
// `LabeledContent` / `TextField` / `SecureField` / `Picker` —
// the kind System Settings → Network or Mail → Accounts uses.
// Sections render as inset rounded rectangles automatically
// against the inherited `.windowBackground` material.
//
// Profile management lives in two stops:
//
//   - The Profile section's popup picks the active profile.
//     Add / Remove are the standard list-footer +/− pattern; the
//     `confirmationDialog` from Phase 2.0.0 still gates Remove.
//   - First-time hint is now a Section footer rather than a
//     custom blue card — the system renders it in muted text
//     under the form, exactly where Apple-shipped settings put
//     contextual help.

import AppKit
import SwiftUI

@MainActor
public struct ConnectionFormView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator

    /// **Profile-F#1 (v0.2):** removing a profile destroys the
    /// saved server credentials with no undo. Surface a
    /// confirmation alert before calling
    /// `orchestrator.removeSelectedProfile()`.
    @State private var confirmingRemoval = false

    /// Subscription URL field (bound while the user is typing).
    @State private var subscriptionURL: String = ""
    @State private var isImporting: Bool = false
    @State private var importError: String?

    public init() {}

    public var body: some View {
        @Bindable var bindable = orchestrator

        Form {
            Section {
                Picker("Profile", selection: $bindable.selectedProfileID) {
                    ForEach(orchestrator.profiles) { profile in
                        Text(displayName(for: profile))
                            .tag(profile.id as String?)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 4) {
                    Button {
                        orchestrator.addProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a new profile")
                    .accessibilityLabel("Add profile")

                    Button(role: .destructive) {
                        // **Profile-F#1 (v0.2):** stage the
                        // deletion through a confirmation alert
                        // instead of firing it on click.
                        confirmingRemoval = true
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(orchestrator.profiles.count <= 1)
                    .help("Remove the selected profile")
                    .accessibilityLabel("Remove profile")
                    .confirmationDialog(
                        "Remove this profile?",
                        isPresented: $confirmingRemoval,
                        titleVisibility: .visible,
                        presenting: orchestrator.selectedProfile
                    ) { profile in
                        // `displayName` can come from a subscription
                        // manifest (panel-controlled). String-literal
                        // interpolation on `Button(_: LocalizedStringKey)`
                        // and `Text(_: LocalizedStringKey)` auto-resolves
                        // markdown/format specifiers — a hostile panel
                        // returning `host: "**evil**.com"` would render
                        // bolded in the dialog. Build the title up
                        // front (passing a `String` variable selects
                        // the `Button(_: StringProtocol, …)` overload,
                        // which treats the panel-controlled segment
                        // as plain text).
                        let title = "Remove “\(displayName(for: profile))”"
                        Button(title, role: .destructive) {
                            orchestrator.removeSelectedProfile()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { profile in
                        // Same hardening as the actions closure
                        // above — `Text(verbatim:)` skips the
                        // `LocalizedStringKey` markdown interpolation.
                        let message =
                            "“\(displayName(for: profile))” and its saved password "
                            + "will be removed permanently. This can't be undone."
                        Text(verbatim: message)
                    }

                    Spacer()
                }
            } header: {
                Text("Profile")
            } footer: {
                if let profile = orchestrator.selectedProfile,
                    isPlaceholderProfile(profile)
                {
                    firstRunFooter
                }
            }

            Section {
                TextField(
                    "Subscription URL",
                    text: $subscriptionURL,
                    prompt: Text("https://…/api/v1/subscription/…")
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif

                Button {
                    Task { await runImport() }
                } label: {
                    // ZStack overlays the spinner on top of an
                    // always-rendered (but hidden-when-busy) Text
                    // so the button keeps its "Import" intrinsic
                    // width across the idle / importing toggle.
                    // Previously the spinner was narrower than
                    // the label, so the Subscription row visibly
                    // reflowed every time an import started.
                    ZStack {
                        Text("Import")
                            .opacity(isImporting ? 0 : 1)
                        if isImporting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .accessibilityLabel("Importing subscription")
                        }
                    }
                }
                .disabled(subscriptionURL.isBlank || isImporting)
            } header: {
                Text("Import from subscription URL")
            } footer: {
                if let err = importError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else {
                    Text("Paste the subscription URL from your server panel to auto-fill credentials.")
                }
            }

            if let profile = orchestrator.selectedProfile {
                Section {
                    TextField(
                        "Server",
                        text: binding(for: \.server, of: profile),
                        prompt: Text("naive.example.com")
                    )
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    // **v2.0.30 (Defensive Input Logic — "Good
                    // Deed"):** auto-strip a scheme prefix
                    // (`https://`, `naive+https://`, …) and any
                    // trailing path on paste. The runloop tick that
                    // immediately follows the binding update fires
                    // this `.onChange`; if the normaliser changes
                    // the value, we write it back through the
                    // orchestrator so the user sees the field
                    // self-correct without a manual fix step. The
                    // "newValue != normalised" guard prevents
                    // infinite re-firing — once the field is bare
                    // hostname, normaliser is idempotent.
                    .onChange(of: orchestrator.selectedProfile?.server ?? "") { _, newValue in
                        let normalised = Profile.normaliseServer(newValue)
                        guard normalised != newValue,
                            var current = orchestrator.selectedProfile
                        else { return }
                        current.server = normalised
                        orchestrator.selectedProfile = current
                    }

                    if let caption = Self.serverValidationCaption(profile.server) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField(
                        "Username",
                        text: binding(for: \.username, of: profile),
                        prompt: Text("user")
                    )
                    .textContentType(.username)
                    .autocorrectionDisabled()

                    SecureField(
                        "Password",
                        text: binding(for: \.password, of: profile),
                        prompt: Text("Required")
                    )
                    .textContentType(.password)

                    TextField(
                        "Local port",
                        text: binding(for: \.localPort, of: profile),
                        prompt: Text("1080")
                    )
                    .autocorrectionDisabled()

                    if let caption = Self.localPortValidationCaption(profile.localPort) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("naive runs on 127.0.0.1 at the local port; the system proxy points there.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer copy

    private var firstRunFooter: some View {
        Label(
            "First time? Replace the template values below with your NaiveProxy server, username, and password. Local port can stay at 1080.",
            systemImage: "lightbulb"
        )
        .labelStyle(.titleAndIcon)
        .font(.callout)
    }

    /// True when the selected profile still carries the bundled
    /// placeholder values from `Profile.default` — i.e. the user
    /// hasn't customised it yet.
    private func isPlaceholderProfile(_ profile: Profile) -> Bool {
        profile.server == "naive.example.com"
            || profile.server.isEmpty
            || profile.username.isEmpty
            || profile.password.isEmpty
    }

    // MARK: - Bindings

    /// Returns a `Binding<String>` that reads / writes the
    /// designated `keyPath` on the orchestrator's selected
    /// profile. The full profile is round-tripped through
    /// `selectedProfile` on every edit so existing validation
    /// + persistence (and the
    /// "edited active profile while connected" banner from
    /// UX-F#3) runs unchanged.
    private func binding(
        for keyPath: WritableKeyPath<Profile, String>,
        of profile: Profile
    ) -> Binding<String> {
        Binding(
            get: {
                orchestrator.selectedProfile?[keyPath: keyPath]
                    ?? profile[keyPath: keyPath]
            },
            set: { newValue in
                guard var current = orchestrator.selectedProfile else { return }
                current[keyPath: keyPath] = newValue
                orchestrator.selectedProfile = current
            }
        )
    }

    // MARK: - Subscription import

    @MainActor
    private func runImport() async {
        importError = nil
        isImporting = true
        defer { isImporting = false }
        do {
            try await orchestrator.importFromSubscriptionURL(subscriptionURL)
            subscriptionURL = ""
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Display

    private func displayName(for profile: Profile) -> String {
        if profile.id == "default" { return "Default" }
        if !profile.server.isEmpty { return profile.server }
        return "Profile \(profile.id.prefix(6))"
    }

    // MARK: - Defensive-input captions (v2.0.30)

    /// **v2.0.30 (Defensive Input Logic — "First Scold" half):**
    /// translates a [`ServerValidation`] verdict into the inline
    /// red caption shown immediately under the Server field.
    /// Returns `nil` when the value is well-formed or empty
    /// ("still typing"), so the caption only appears when there's
    /// a concrete problem to fix.
    ///
    /// `.hasScheme` and `.hasPath` are auto-corrected by the
    /// `onChange` paste-normaliser on the next runloop tick, so
    /// the captions for those cases use language framed around
    /// what already happened ("we're stripping the …") rather
    /// than instruction. `.malformed` has no auto-fix; the
    /// caption tells the operator the field needs manual
    /// attention.
    fileprivate static func serverValidationCaption(_ server: String) -> String? {
        // Build a throwaway profile to drive the validation —
        // `serverValidation` is pure on `server`, so the other
        // field values don't matter here.
        let probe = Profile(
            id: "_probe", server: server, username: "", password: "", localPort: "")
        switch probe.serverValidation {
        case .valid, .empty:
            return nil
        case .hasScheme(let scheme):
            return "Stripping \"\(scheme)\" — server is just the hostname."
        case .hasPath:
            return "Stripping the path — server is just the hostname."
        case .malformed(let reason):
            return "Server looks malformed (\(reason)). Use \"host\" or \"host:port\"."
        }
    }

    /// **v2.0.30 (Defensive Input Logic):** translates a raw
    /// `localPort` string into the inline red caption shown
    /// immediately under the Local port field. Returns `nil`
    /// when blank (treated as "still typing") or when the value
    /// parses to a `UInt16` ≥ 1024.
    fileprivate static func localPortValidationCaption(_ port: String) -> String? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let value = UInt16(trimmed) else {
            return "Local port must be a number (e.g. 1080)."
        }
        if value < 1024 {
            return "Local port must be ≥ 1024 — `naive` can't bind below that without root."
        }
        return nil
    }
}
