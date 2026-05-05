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
                        Button("Remove “\(displayName(for: profile))”", role: .destructive) {
                            orchestrator.removeSelectedProfile()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { profile in
                        Text(
                            "“\(displayName(for: profile))” and its saved password will be removed permanently. This can't be undone."
                        )
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

            if let profile = orchestrator.selectedProfile {
                Section {
                    TextField(
                        "Server",
                        text: binding(for: \.server, of: profile),
                        prompt: Text("naive.example.com")
                    )
                    .textContentType(.URL)
                    .autocorrectionDisabled()

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

    // MARK: - Display

    private func displayName(for profile: Profile) -> String {
        if profile.id == "default" { return "Default" }
        if !profile.server.isEmpty { return profile.server }
        return "Profile \(profile.id.prefix(6))"
    }
}
