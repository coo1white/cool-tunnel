// Views/ConnectionFormView.swift
//
// Profile selector + the editable form (server, username, password,
// port). v0.1.5.4 redesign: sits inside a Liquid-Glass card with
// rounded text fields, soft section header, and pastel-tinted
// add/remove buttons that match the rest of the design system.

import SwiftUI

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
                .frame(maxWidth: 220)

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

            if orchestrator.selectedProfile != nil {
                form
            } else {
                Text("No profile selected.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .pupCard(cornerRadius: 8, tint: CTPalette.skyBlue)
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
                .frame(width: 130, alignment: .trailing)
            TextField(placeholder, text: binding(for: keyPath))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 0.5)
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
                .frame(width: 130, alignment: .trailing)
            SecureField("•••••••", text: binding(for: keyPath))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 0.5)
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
