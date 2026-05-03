// Views/ConnectionFormView.swift
//
// Profile selector + the editable form (server, username, password,
// port). v0.1.5.4 redesign: sits inside a Liquid-Glass card with
// rounded text fields, soft section header, and pastel-tinted
// add/remove buttons that match the rest of the design system.

import SwiftUI

/// Profile picker plus the editable form (server, username,
/// password, local port). All edits flow back through the
/// orchestrator's `selectedProfile` setter, which strips passwords
/// for `UserDefaults` and writes them to the credential store.
@MainActor
public struct ConnectionFormView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator

    public init() {}

    public var body: some View {
        @Bindable var bindable = orchestrator

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(CTPalette.cherryRose)
                Text("Profile")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CTPalette.inkBlue)

                Picker("Profile", selection: $bindable.selectedProfileID) {
                    ForEach(orchestrator.profiles) { profile in
                        Text(profile.id == "default" ? "Default" : displayName(for: profile))
                            .tag(profile.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Wider window allows long server names ("provider-
                // pop-east-1.example.co.uk") to render without
                // mid-string truncation. The 320 ceiling stops a
                // very long single profile name from pushing the
                // Add/Remove buttons off the right edge.
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
                .help(orchestrator.selectedProfile.map(displayName(for:)) ?? "")

                Spacer()

                Button {
                    orchestrator.addProfile()
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SoftButtonStyle(tint: CTPalette.cherryRose))

                Button(role: .destructive) {
                    orchestrator.removeSelectedProfile()
                } label: {
                    Label("Remove", systemImage: "minus.circle.fill")
                }
                .buttonStyle(
                    SoftButtonStyle(tint: orchestrator.profiles.count <= 1 ? .secondary : CTPalette.inkBlue)
                )
                .disabled(orchestrator.profiles.count <= 1)
            }

            if let profile = orchestrator.selectedProfile {
                if isPlaceholderProfile(profile) {
                    firstRunHint
                }
                form
            } else {
                Text("No profile selected.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        // Mode-aware tint so the form pane reads the same colour as
        // the header pill: Smart=blue, Global=pink, Local=green.
        // Tracks `orchestrator.activeMode`, not the last-used mode,
        // so the platinum-grey neutral wins when the proxy is idle.
        .pupCard(cornerRadius: 8, tint: CTPalette.accent(for: orchestrator.activeMode))
    }

    /// Inline help banner that appears whenever the form still
    /// holds the bundled `Profile.default` placeholder values.
    /// First-run users open the app and see template text in
    /// every field; this banner spells out that those fields
    /// expect their *real* server details before Start will work.
    private var firstRunHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(CTPalette.macBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("First time? Replace the template values below.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CTPalette.bodyInk)
                Text(
                    "Server, Username, and Password should be the ones from your "
                        + "NaiveProxy server (see NaiveProxy_Server_Setup.md if you "
                        + "haven't set one up yet). Local Port can stay at 1080."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(CTPalette.macBlueSoft.opacity(0.18))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(CTPalette.macBlue.opacity(0.30), lineWidth: 0.6)
        }
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

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            textRow(title: "Server", placeholder: "naive.example.com", keyPath: \.server, icon: "server.rack")
            textRow(title: "Username", placeholder: "user", keyPath: \.username, icon: "person.fill")
            secureRow(title: "Password", keyPath: \.password)
            textRow(title: "Local Port", placeholder: "1080", keyPath: \.localPort, icon: "number")
        }
    }

    private func textRow(
        title: String,
        placeholder: String,
        keyPath: WritableKeyPath<Profile, String>,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 130, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
            TextField(placeholder, text: binding(for: keyPath))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(CTPalette.paper)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(CTPalette.borderInk.opacity(0.45), lineWidth: 0.7)
                }
        }
    }

    private func secureRow(
        title: String,
        keyPath: WritableKeyPath<Profile, String>
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 130, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
            SecureField("•••••••", text: binding(for: keyPath))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(CTPalette.paper)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(CTPalette.borderInk.opacity(0.45), lineWidth: 0.7)
                }
        }
    }

    /// Returns a `Binding<String>` that reads/writes the field
    /// designated by `keyPath` on the orchestrator's selected profile.
    /// The full profile is round-tripped on every edit so existing
    /// field validation (and persistence) runs without extra wiring.
    private func binding(for keyPath: WritableKeyPath<Profile, String>) -> Binding<String> {
        Binding(
            get: { orchestrator.selectedProfile?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var profile = orchestrator.selectedProfile else { return }
                profile[keyPath: keyPath] = newValue
                orchestrator.selectedProfile = profile
            }
        )
    }

    private func displayName(for profile: Profile) -> String {
        if !profile.server.isEmpty { return profile.server }
        return "Profile \(profile.id.prefix(6))"
    }
}
