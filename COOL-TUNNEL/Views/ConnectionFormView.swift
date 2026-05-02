// Views/ConnectionFormView.swift
//
// Profile selector + the editable form (server, username, password, port).
// All edits flow back through the orchestrator's `selectedProfile` setter,
// which persists to UserDefaults.

import SwiftUI

@MainActor
public struct ConnectionFormView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator

    public init() {}

    public var body: some View {
        @Bindable var bindable = orchestrator

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Profile", selection: $bindable.selectedProfileID) {
                    ForEach(orchestrator.profiles) { profile in
                        Text(profile.id == "default" ? "Default" : displayName(for: profile))
                            .tag(profile.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 240)

                Spacer()

                Button {
                    orchestrator.addProfile()
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button(role: .destructive) {
                    orchestrator.removeSelectedProfile()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(orchestrator.profiles.count <= 1)
            }

            if orchestrator.selectedProfile != nil {
                form
            } else {
                Text("No profile selected.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            textRow(title: "Server", placeholder: "naive.example.com", keyPath: \.server)
            textRow(title: "Username", placeholder: "user", keyPath: \.username)
            secureRow(title: "Password", keyPath: \.password)
            textRow(title: "Local Port", placeholder: "1080", keyPath: \.localPort)
        }
    }

    private func textRow(
        title: String,
        placeholder: String,
        keyPath: WritableKeyPath<Profile, String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
            TextField(placeholder, text: binding(for: keyPath))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func secureRow(
        title: String,
        keyPath: WritableKeyPath<Profile, String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
            SecureField("•••••••", text: binding(for: keyPath))
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Returns a `Binding<String>` that reads/writes the field designated
    /// by `keyPath` on the orchestrator's selected profile. The full
    /// profile is round-tripped on every edit so existing field validation
    /// (and persistence) runs without extra wiring.
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
