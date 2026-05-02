import SwiftUI
import Foundation
import UniformTypeIdentifiers
import AppKit
import Combine

@MainActor
private final class TunnelState: ObservableObject {
    static let shared = TunnelState()

    @Published var server = "naive.example.com"
    @Published var username = "user"
    @Published var password = ""
    @Published var localPort = "1080"
    @Published var logs = "Proxy is stopped."
    @Published var logLineCount = 1
    @Published var isRunning = false
    @Published var process: Process?
    @Published var activityTimer: Timer?
    @Published var lastActivitySnapshot = ""
    @Published var directDomains = ContentView.defaultDirectDomains
    @Published var customBinaryPath = ""
    @Published var profiles = [ProxyProfile.defaultProfile]
    @Published var selectedProfileID: String? = ProxyProfile.defaultProfile.id
    @Published var activeProxyMode: ActiveProxyMode = .stopped
    @Published var abnormalTrafficBlocked = false
    @Published var isModeChanging = false
    @Published var isTestRunning = false
    var didLoadSettings = false
}

struct ContentView: View {
    @StateObject private var tunnelState = TunnelState.shared
    private let maxLogLines = 1000
    @State private var showSettings = false

    private static let directDomainsKey = "directDomains"
    private static let customBinaryPathKey = "tunnelState.customBinaryPath"
    private static let profilesKey = "connectionProfiles"
    private static let selectedProfileKey = "selectedConnectionProfile"
    private static let appSupportDirectoryName = "NaiveProxyMac"
    private static let configFileName = "config.json"
    private static let pacFileName = "smart-proxy.pac"
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter
    }()
    fileprivate static let defaultDirectDomains = [
        ".cn",
        "baidu.com",
        "bdstatic.com",
        "bilibili.com",
        "douyin.com",
        "jd.com",
        "mi.com",
        "netease.com",
        "qq.com",
        "taobao.com",
        "tmall.com",
        "weibo.com",
        "weixin.qq.com",
        "xiaohongshu.com",
        "youku.com",
        "zhihu.com"
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                headerView

                controlPanel

                connectionBox

                logsView
                    .frame(maxHeight: .infinity)
            }
            .padding(20)
        }
        .frame(minWidth: 840, idealWidth: 940, minHeight: 760, idealHeight: 820)
        .onAppear {
            loadSettings()
        }
        .onChange(of: tunnelState.selectedProfileID) {
            applySelectedProfile()
        }
        .onChange(of: tunnelState.server) {
            syncSelectedProfile()
        }
        .onChange(of: tunnelState.username) {
            syncSelectedProfile()
        }
        .onChange(of: tunnelState.password) {
            syncSelectedProfile()
        }
        .onChange(of: tunnelState.localPort) {
            syncSelectedProfile()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stopProxy()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                directDomains: $tunnelState.directDomains,
                customBinaryPath: $tunnelState.customBinaryPath,
                onSaveDomains: saveDirectDomains,
                onReplaceBinary: replaceNaiveBinary,
                onResetDomains: resetDirectDomains
            )
        }
    }

    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Cool tunnel")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(statusSubtitle)
                        .lineLimit(1)

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Text("crafted by Alice")
                        .lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            statusPill
        }
        .padding(18)
        .frame(minHeight: 88)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
    }

    private var statusSubtitle: String {
        if tunnelState.isModeChanging {
            return "Applying network settings..."
        }

        if tunnelState.isTestRunning {
            return "Diagnostics are running"
        }

        return tunnelState.isRunning ? "Secure tunnel is active" : "Ready to start a smart proxy session"
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(tunnelState.activeProxyMode.title)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(.separator.opacity(0.4), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        switch tunnelState.activeProxyMode {
        case .stopped:
            return .secondary
        case .smart:
            return .green
        case .global:
            return .orange
        case .localOnly:
            return .blue
        }
    }

    private var cardBackground: some ShapeStyle {
        .thinMaterial
    }

    private var controlPanel: some View {
        let columns = [
            GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 10)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            controlButtons()
        }
        .padding(10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func controlButtons() -> some View {
        Button {
            guard !tunnelState.isRunning else { return }
            startProxy()
        } label: {
            SidebarButtonLabel(
                title: "Start Smart Mode",
                systemImage: "play.fill",
                isPrimary: true,
                isDisabled: tunnelState.isRunning || tunnelState.isModeChanging
            )
        }
        .buttonStyle(.plain)

        Button {
            guard tunnelState.isRunning, !tunnelState.isModeChanging else { return }
            stopProxy()
        } label: {
            SidebarButtonLabel(
                title: "Stop",
                systemImage: "stop.fill",
                isDisabled: !tunnelState.isRunning || tunnelState.isModeChanging
            )
        }
        .buttonStyle(.plain)

        Button {
            guard tunnelState.isRunning && tunnelState.activeProxyMode != .global && !tunnelState.isModeChanging else { return }
            enableSystemProxy()
        } label: {
            SidebarButtonLabel(
                title: "Enable Global Proxy",
                systemImage: "switch.2",
                isDisabled: !tunnelState.isRunning || tunnelState.activeProxyMode == .global || tunnelState.isModeChanging
            )
        }
        .buttonStyle(.plain)

        Button {
            guard !tunnelState.isModeChanging else { return }
            disableSystemProxy()
        } label: {
            SidebarButtonLabel(
                title: "Restore macOS Proxy",
                systemImage: "xmark.circle",
                isDisabled: tunnelState.isModeChanging
            )
        }
        .buttonStyle(.plain)

        Button {
            guard !tunnelState.isTestRunning else { return }
            runTimeoutTest(mode: .smart)
        } label: {
            SidebarButtonLabel(title: "Timeout Test: Smart", systemImage: "timer", isDisabled: tunnelState.isTestRunning)
        }
        .buttonStyle(.plain)

        Button {
            guard !tunnelState.isTestRunning else { return }
            runTimeoutTest(mode: .global)
        } label: {
            SidebarButtonLabel(title: "Timeout Test: Global", systemImage: "timer.circle", isDisabled: tunnelState.isTestRunning)
        }
        .buttonStyle(.plain)

        Button {
            guard !tunnelState.isTestRunning else { return }
            runDiagnostics()
        } label: {
            SidebarButtonLabel(title: "Test Proxy", systemImage: "stethoscope", isDisabled: tunnelState.isTestRunning)
        }
        .buttonStyle(.plain)

        Button {
            showSettings = true
        } label: {
            SidebarButtonLabel(title: "Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
    }

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live Logs", systemImage: "terminal")
                    .font(.system(size: 15, weight: .bold))

                Spacer()

                Button {
                    clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(tunnelState.logs)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .textColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("log-bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator.opacity(0.35), lineWidth: 1)
                }
                .onChange(of: tunnelState.logs) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 1)
        }
    }

    private var connectionBox: some View {
        GroupBox {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    profileList
                    connectionForm
                }

                VStack(alignment: .leading, spacing: 12) {
                    profileList
                    connectionForm
                }
            }
            .padding(6)
        } label: {
            Label("Connection", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .bold))
        }
        .frame(maxWidth: .infinity)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tunnelState.profiles, id: \.id) { profile in
                        Button(action: {
                            tunnelState.selectedProfileID = profile.id
                            applySelectedProfile()
                        }) {
                            ProfileRow(
                                profile: profile,
                                isSelected: tunnelState.selectedProfileID == profile.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(tunnelState.isRunning)
                    }
                }
                .padding(4)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)
            .frame(height: 150)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.3), lineWidth: 1)
            }
            .disabled(tunnelState.isRunning)

            HStack {
                Button {
                    addProfile()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(tunnelState.isRunning)

                Button {
                    removeSelectedProfile()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(tunnelState.isRunning || tunnelState.profiles.count <= 1)
            }
            .controlSize(.small)
        }
    }

    private var connectionForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Server")
                    .frame(width: 126, alignment: .leading)
                TextField("naive.example.com", text: $tunnelState.server)
                    .textFieldStyle(.roundedBorder)
                    .disabled(tunnelState.isRunning)
            }

            GridRow {
                Text("Username")
                    .frame(width: 126, alignment: .leading)
                TextField("username", text: $tunnelState.username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(tunnelState.isRunning)
            }

            GridRow {
                Text("Password")
                    .frame(width: 126, alignment: .leading)
                SecureField("Password", text: $tunnelState.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(tunnelState.isRunning)
            }

            GridRow {
                Text("Local SOCKS Port")
                    .frame(width: 126, alignment: .leading)
                TextField("1080", text: $tunnelState.localPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(tunnelState.isRunning)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    private func startProxy() {
        guard !tunnelState.isRunning, !tunnelState.isModeChanging else { return }

        guard let naiveURL = currentNaiveBinaryURL() else {
            tunnelState.logs = "Error: naive binary not found in app bundle."
            tunnelState.logLineCount = 1
            return
        }

        guard let safePort = validatedPortString() else {
            appendToLog("\nInvalid local port. Use a value from 1 to 65535.\n")
            return
        }

        guard validatedServerString() != nil else {
            appendToLog("\nInvalid server. Use a host name or host:port without a URL scheme, path, spaces, or credentials.\n")
            return
        }

        guard validatedCredentials() else {
            appendToLog("\nMissing username or password. Refusing to start an unauthenticated upstream tunnel.\n")
            return
        }

        do {
            let configURL = try writeConfig()
            let maskedProxyURL = maskedProxyURLString()

            let task = Process()
            task.executableURL = naiveURL
            task.arguments = [configURL.path]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                let text = String(data: data, encoding: .utf8) ?? ""
                Task { @MainActor in
                    appendToLog(text)
                }
            }

            task.terminationHandler = { _ in
                Task { @MainActor in
                    tunnelState.isRunning = false
                    tunnelState.activeProxyMode = .stopped
                    appendToLog("\nProxy stopped.\n")
                }
            }

            tunnelState.logs = "Starting NaiveProxy...\nBinary: \(naiveURL.path)\nConfig: \(configURL.path)\nRuntime: config file, listen=socks://127.0.0.1:\(safePort), proxy=\(maskedProxyURL)\n"
            tunnelState.logLineCount = tunnelState.logs.reduce(0) { count, character in
                character == "\n" ? count + 1 : count
            }
            appendToLog("Binary size: \(fileSize(at: naiveURL.path)) bytes\n")
            try task.run()

            tunnelState.process = task
            tunnelState.isRunning = true
            tunnelState.abnormalTrafficBlocked = false
            appendToLog("Process started with pid \(task.processIdentifier).\n")
            
            // Wait for proxy to start listening
            Task.detached(priority: .userInitiated) {
                let maxWaitTime = 15.0 // seconds
                let checkInterval = 0.5 // seconds
                var elapsedTime = 0.0
                
                while elapsedTime < maxWaitTime {
                    try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                    elapsedTime += checkInterval
                    
                    if await checkProxyListening(port: Int(safePort) ?? 1080) {
                        await MainActor.run {
                            appendToLog("✓ NaiveProxy is now listening on port \(safePort).\n")
                            appendToLog("Starting activity monitor and smart proxy...\n")
                            startActivityMonitor(pid: task.processIdentifier)
                            enableSmartProxy()
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    appendToLog("⚠️ NaiveProxy did not start listening within \(maxWaitTime) seconds.\n")
                    appendToLog("Possible issues:\n")
                    appendToLog("- Port \(safePort) may be in use by another application\n")
                    appendToLog("- NaiveProxy binary may have compatibility issues\n")
                    appendToLog("- Check the configuration file: \(configURL.path)\n")
                    appendToLog("Consider using a different port or checking system tunnelState.logs.\n")
                }
            }
        } catch {
            appendToLog("Failed to start: \(error.localizedDescription)")
            tunnelState.isRunning = false
        }
    }

    private func fileSize(at path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? UInt64 else {
            return "unknown"
        }
        return Self.byteCountFormatter.string(fromByteCount: Int64(fileSize))
    }

    private func currentNaiveBinaryURL() -> URL? {
        if !tunnelState.customBinaryPath.isEmpty {
            let customURL = URL(fileURLWithPath: tunnelState.customBinaryPath)
            if FileManager.default.isExecutableFile(atPath: customURL.path) {
                return customURL
            }
        }

        // Explicitly use the Resources/naive binary (the actual NaiveProxy)
        if let resourceURL = Bundle.main.url(forResource: "naive", withExtension: nil) {
            let resourcePath = resourceURL.path
            // Check if this is the Resources folder (6.9MB) not MacOS folder (1.2MB)
            if resourcePath.contains("Resources") {
                return resourceURL
            }
        }
        
        // Fallback to any naive binary in the bundle
        return Bundle.main.url(forResource: "naive", withExtension: nil)
    }

    private func stopProxy() {
        stopActivityMonitor()
        tunnelState.process?.standardOutput = nil
        tunnelState.process?.standardError = nil
        tunnelState.process?.terminate()
        tunnelState.process = nil
        tunnelState.isRunning = false
        tunnelState.activeProxyMode = .stopped
        removeSensitiveRuntimeFiles()
        if !tunnelState.isModeChanging {
            disableSystemProxy()
        }
    }

    private func appendToLog(_ text: String) {
        tunnelState.logs += text
        tunnelState.logLineCount += text.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }

        if tunnelState.logLineCount > maxLogLines {
            let trimmedLines = tunnelState.logs.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLogLines)
            tunnelState.logs = trimmedLines.joined(separator: "\n")
            tunnelState.logLineCount = trimmedLines.count
        }
    }
    
    private func clearLogs() {
        tunnelState.logs = ""
        tunnelState.logLineCount = 0
    }

    private func startActivityMonitor(pid: Int32) {
        stopActivityMonitor()
        tunnelState.lastActivitySnapshot = ""
        let monitoredPort = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)

        tunnelState.activityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task.detached(priority: .utility) {
                let inspection = inspectNaiveTraffic(pid: pid, localPort: monitoredPort)

                await MainActor.run {
                    handleTrafficInspection(inspection)
                }
            }
        }
    }

    private func handleTrafficInspection(_ inspection: TrafficInspection) {
        guard tunnelState.isRunning else { return }
        guard !inspection.snapshot.isEmpty else { return }

        if inspection.snapshot != tunnelState.lastActivitySnapshot {
            tunnelState.lastActivitySnapshot = inspection.snapshot
            appendToLog("\n[Activity \(shortTimeString())]\n\(inspection.summary)\n\(inspection.snapshot)")
        }

        if let reason = inspection.abnormalReason, !tunnelState.abnormalTrafficBlocked {
            blockAbnormalTraffic(reason: reason)
        }
    }

    private func blockAbnormalTraffic(reason: String) {
        tunnelState.abnormalTrafficBlocked = true
        appendToLog("\n[Security Block] Abnormal traffic detected: \(reason)\n")
        appendToLog("Action: disabled system proxy and stopped NaiveProxy to prevent uncontrolled traffic.\n")
        stopProxy()
    }

    private func stopActivityMonitor() {
        tunnelState.activityTimer?.invalidate()
        tunnelState.activityTimer = nil
        tunnelState.lastActivitySnapshot = ""
    }

    private func writeConfig() throws -> URL {
        guard let safeServer = validatedServerString(),
              let safePort = validatedPortString() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let safeUsername = percentEncodedCredential(tunnelState.username.trimmingCharacters(in: .whitespacesAndNewlines))
        let safePassword = percentEncodedCredential(tunnelState.password.trimmingCharacters(in: .whitespacesAndNewlines))

        let configObject = [
            "listen": "socks://127.0.0.1:\(safePort)",
            "proxy": "https://\(safeUsername):\(safePassword)@\(safeServer)"
        ]

        let jsonData = try JSONSerialization.data(
            withJSONObject: configObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        let supportURL = appSupportDirectoryURL()

        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )

        let configURL = supportURL.appendingPathComponent(Self.configFileName)
        try jsonData.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        return configURL
    }

    private func appSupportDirectoryURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(Self.appSupportDirectoryName, isDirectory: true)
    }

    private func removeSensitiveRuntimeFiles() {
        let configURL = appSupportDirectoryURL().appendingPathComponent(Self.configFileName)
        try? FileManager.default.removeItem(at: configURL)
    }

    private func validatedPortString() -> String? {
        let candidate = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(candidate), (1...65535).contains(port) else {
            return nil
        }
        return "\(port)"
    }

    private func validatedServerString() -> String? {
        let candidate = tunnelState.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= 253,
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !candidate.contains("://"),
              !candidate.contains("@"),
              !candidate.contains("/"),
              !candidate.contains("?"),
              !candidate.contains("#") else {
            return nil
        }

        if let portSeparator = candidate.lastIndex(of: ":") {
            let host = String(candidate[..<portSeparator])
            let portString = String(candidate[candidate.index(after: portSeparator)...])
            guard !host.isEmpty,
                  let port = Int(portString),
                  (1...65535).contains(port) else {
                return nil
            }
        }

        return candidate
    }

    private func validatedCredentials() -> Bool {
        !tunnelState.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !tunnelState.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func percentEncodedCredential(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func maskedProxyURLString() -> String {
        let safeServer = validatedServerString() ?? tunnelState.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeUsername = tunnelState.username.trimmingCharacters(in: .whitespacesAndNewlines)

        return "https://\(safeUsername):********@\(safeServer)"
    }

    private func enableSystemProxy() {
        guard let safePort = validatedPortString(),
              let port = Int(safePort) else {
            appendToLog("\nInvalid local port.\n")
            return
        }

        guard !tunnelState.isModeChanging else {
            appendToLog("\nMode change already running. Please wait.\n")
            return
        }

        guard confirmSystemProxyChange(mode: .global, port: port) else {
            appendToLog("\nCancelled global proxy change.\n")
            return
        }

        // Check if proxy is actually listening on the port
        Task.detached(priority: .userInitiated) {
            let isListening = await checkProxyListening(port: port)
            
            await MainActor.run {
                if !isListening {
                    appendToLog("\nNaiveProxy is not listening on port \(port). Restarting proxy...\n")
                    restartProxy()
                } else {
                    proceedWithGlobalProxy(port: port)
                }
            }
        }
    }
    
    private func checkProxyListening(port: Int) async -> Bool {
        let result = runCommandResultStatic("/usr/sbin/lsof", [
            "-nP",
            "-iTCP:\(port)",
            "-sTCP:LISTEN"
        ])
        return result.exitCode == 0 && !result.output.isEmpty
    }

    private func confirmSystemProxyChange(mode: ActiveProxyMode, port: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = mode == .global ? "Enable Global System Proxy?" : "Enable Smart System Proxy?"
        alert.informativeText = mode == .global
            ? "This will change macOS network settings using networksetup and route proxy-aware traffic through SOCKS 127.0.0.1:\(port). You can undo it with Disable System Proxy."
            : "This will change macOS network settings using networksetup and enable a local PAC file. Matching direct domains bypass the proxy; other proxy-aware traffic uses 127.0.0.1:\(port). You can undo it with Disable System Proxy."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    @MainActor
    private func testUpstreamConnectivity() async {
        appendToLog("\n=== Testing Upstream Connectivity ===\n")
        guard let server = validatedServerString() else {
            appendToLog("Invalid configured server. Skipping upstream connectivity test.\n")
            return
        }

        let targetURL = "https://\(server)"
        appendToLog("Testing TLS connection to configured server...\n")
        
        let result = runCommandResultStatic("/usr/bin/curl", [
            "-v",
            "--max-time",
            "10",
            "--connect-timeout",
            "5",
            targetURL
        ])
        
        if result.exitCode == 0 {
            appendToLog("✓ Upstream tunnelState.server is reachable\n")
        } else {
            appendToLog("✗ Upstream tunnelState.server connection failed\n")
            appendToLog("This may indicate:\n")
            appendToLog("- Network connectivity issues\n")
            appendToLog("- Server is down or blocking connections\n")
            appendToLog("- Firewall or DNS issues\n")
        }
        appendToLog(result.output)
    }
    
    private func restartProxy() {
        Task { @MainActor in
            stopProxy()
            // Wait a moment for cleanup
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            startProxy()
        }
    }
    
    private func proceedWithGlobalProxy(port: Int) {
        tunnelState.isModeChanging = true
        appendToLog("\n=== Enabling Global SOCKS Proxy ===\n")
        appendToLog("Target: Wi-Fi service\n")
        appendToLog("SOCKS tunnelState.server: 127.0.0.1:\(port)\n")

        Task.detached(priority: .userInitiated) {
            let result = enableGlobalProxyCommand(port: port)

            await MainActor.run {
                appendToLog(result.output)
                if result.success {
                    tunnelState.activeProxyMode = .global
                    appendToLog("✓ Global proxy enabled successfully\n")
                    appendToLog("All traffic should now route through SG VPS\n")
                } else {
                    appendToLog("✗ Failed to enable global proxy\n")
                    appendToLog("Check system permissions and network settings\n")
                }
                tunnelState.isModeChanging = false
            }
        }
    }

    private func disableSystemProxy() {
        guard !tunnelState.isModeChanging else {
            appendToLog("\nMode change already running. Please wait.\n")
            return
        }

        let nextMode: ActiveProxyMode = tunnelState.isRunning ? .localOnly : .stopped
        tunnelState.isModeChanging = true
        appendToLog("\nDisabling system proxy...\n")

        Task.detached(priority: .userInitiated) {
            let result = disableSystemProxyCommand()

            await MainActor.run {
                appendToLog(result.output)
                if result.success {
                    tunnelState.activeProxyMode = nextMode
                }
                tunnelState.isModeChanging = false
            }
        }
    }

    private func runNetworkSetup(arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: task.terminationStatus, output: text)
        } catch {
            return CommandResult(exitCode: -1, output: "\nnetworksetup failed: \(error.localizedDescription)\n")
        }
    }

    private func activeNetworkService() -> String? {
        let servicesResult = runCommandResult("/usr/sbin/networksetup", ["-listallnetworkservices"])
        let services = servicesResult.output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("An asterisk") }
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }

        for preferred in ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN", "Ethernet"] {
            if services.contains(preferred) {
                return preferred
            }
        }

        return services.first
    }

    private func verifySocksProxy(service: String) -> String {
        let result = runNetworkSetup(arguments: [
            "-getsocksfirewallproxy",
            service
        ])

        return "\nCurrent SOCKS proxy state for \(service):\n\(result.output)"
    }

    private func enableSmartProxy() {
        guard let safePort = validatedPortString(),
              let port = Int(safePort) else {
            appendToLog("\nInvalid local port. Smart proxy was not enabled.\n")
            return
        }

        guard !tunnelState.isModeChanging else {
            appendToLog("\nMode change already running. Please wait.\n")
            return
        }

        guard confirmSystemProxyChange(mode: .smart, port: port) else {
            appendToLog("\nCancelled smart proxy change.\n")
            return
        }

        do {
            let pacURL = try writePACFile(port: port)
            let pacURLString = pacURL.absoluteString
            tunnelState.isModeChanging = true
            appendToLog("\n=== Enabling Smart PAC Proxy ===\n")
            appendToLog("PAC file: \(pacURL.path)\n")
            appendToLog("Direct domains: \(tunnelState.directDomains.count) configured\n")

            Task.detached(priority: .userInitiated) {
                let result = enableSmartProxyCommand(port: port, pacURLString: pacURLString)

                await MainActor.run {
                    appendToLog(result.output)
                    if result.success {
                        tunnelState.activeProxyMode = .smart
                        appendToLog("✓ Smart proxy enabled successfully\n")
                        appendToLog("China/domains go DIRECT, other traffic via SG VPS\n")
                    } else {
                        appendToLog("✗ Failed to enable smart proxy\n")
                    }
                    tunnelState.isModeChanging = false
                }
            }
        } catch {
            appendToLog("\nFailed to write PAC file: \(error.localizedDescription)\n")
        }
    }

    private func writePACFile(port: Int) throws -> URL {
        let pac = """
        function FindProxyForURL(url, host) {
            host = host.toLowerCase();

            if (isPlainHostName(host) ||
                shExpMatch(host, "localhost") ||
                shExpMatch(host, "127.*") ||
                shExpMatch(host, "10.*") ||
                shExpMatch(host, "172.16.*") ||
                shExpMatch(host, "172.17.*") ||
                shExpMatch(host, "172.18.*") ||
                shExpMatch(host, "172.19.*") ||
                shExpMatch(host, "172.20.*") ||
                shExpMatch(host, "172.21.*") ||
                shExpMatch(host, "172.22.*") ||
                shExpMatch(host, "172.23.*") ||
                shExpMatch(host, "172.24.*") ||
                shExpMatch(host, "172.25.*") ||
                shExpMatch(host, "172.26.*") ||
                shExpMatch(host, "172.27.*") ||
                shExpMatch(host, "172.28.*") ||
                shExpMatch(host, "172.29.*") ||
                shExpMatch(host, "172.30.*") ||
                shExpMatch(host, "172.31.*") ||
                shExpMatch(host, "192.168.*")) {
                return "DIRECT";
            }

            var directDomains = \(directDomainsJavaScriptArray());

            for (var i = 0; i < directDomains.length; i++) {
                var domain = directDomains[i];
                if (dnsDomainIs(host, domain) || shExpMatch(host, "*" + domain)) {
                    return "DIRECT";
                }
            }

            return "SOCKS5 127.0.0.1:\(port); SOCKS 127.0.0.1:\(port); DIRECT";
        }
        """

        let supportURL = appSupportDirectoryURL()

        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )

        let pacURL = supportURL.appendingPathComponent(Self.pacFileName)
        try pac.write(to: pacURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pacURL.path
        )
        return pacURL
    }

    private func directDomainsJavaScriptArray() -> String {
        let cleaned = tunnelState.directDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let data = try? JSONSerialization.data(withJSONObject: cleaned),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }

    private func loadSettings() {
        guard !tunnelState.didLoadSettings else { return }
        tunnelState.didLoadSettings = true

        loadProfiles()

        let savedDomains = UserDefaults.standard.stringArray(forKey: Self.directDomainsKey)
        if let savedDomains, !savedDomains.isEmpty {
            tunnelState.directDomains = savedDomains
        }

        tunnelState.customBinaryPath = UserDefaults.standard.string(forKey: Self.customBinaryPathKey) ?? ""
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ProxyProfile].self, from: data),
           !decoded.isEmpty {
            tunnelState.profiles = decoded
            tunnelState.selectedProfileID = UserDefaults.standard.string(forKey: Self.selectedProfileKey) ?? decoded[0].id
        } else {
            tunnelState.profiles = [
                ProxyProfile(
                    id: ProxyProfile.defaultProfile.id,
                    server: tunnelState.server,
                    username: tunnelState.username,
                    password: tunnelState.password,
                    localPort: tunnelState.localPort
                )
            ]
            tunnelState.selectedProfileID = tunnelState.profiles[0].id
            saveProfiles()
        }

        if !tunnelState.profiles.contains(where: { $0.id == tunnelState.selectedProfileID }) {
            tunnelState.selectedProfileID = tunnelState.profiles[0].id
        }

        applySelectedProfile()
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(tunnelState.profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }

        if let selectedProfileID = tunnelState.selectedProfileID {
            UserDefaults.standard.set(selectedProfileID, forKey: Self.selectedProfileKey)
        }
    }

    private func applySelectedProfile() {
        guard let selectedProfileID = tunnelState.selectedProfileID,
              let profile = tunnelState.profiles.first(where: { $0.id == tunnelState.selectedProfileID }) else {
            return
        }

        tunnelState.server = profile.server
        tunnelState.username = profile.username
        tunnelState.password = profile.password
        tunnelState.localPort = profile.localPort
        saveProfiles()
    }

    private func syncSelectedProfile() {
        guard let selectedProfileID = tunnelState.selectedProfileID,
              let index = tunnelState.profiles.firstIndex(where: { $0.id == tunnelState.selectedProfileID }) else {
            return
        }

        let updatedProfile = ProxyProfile(
            id: selectedProfileID,
            server: tunnelState.server,
            username: tunnelState.username,
            password: tunnelState.password,
            localPort: tunnelState.localPort
        )

        guard tunnelState.profiles[index] != updatedProfile else { return }

        tunnelState.profiles[index] = updatedProfile
        saveProfiles()
    }

    private func addProfile() {
        let nextPort = nextAvailablePort()
        let profile = ProxyProfile(
            id: UUID().uuidString,
            server: "naive.example.com",
            username: "user",
            password: "",
            localPort: nextPort
        )

        tunnelState.profiles.append(profile)
        tunnelState.selectedProfileID = profile.id
        applySelectedProfile()
        saveProfiles()
        appendToLog("\nAdded connection profile: \(profile.server):\(profile.localPort).\n")
    }

    private func removeSelectedProfile() {
        guard tunnelState.profiles.count > 1,
              let currentProfileID = tunnelState.selectedProfileID,
              let index = tunnelState.profiles.firstIndex(where: { $0.id == currentProfileID }) else {
            return
        }

        let removed = tunnelState.profiles.remove(at: index)
        let nextIndex = min(index, tunnelState.profiles.count - 1)
        tunnelState.selectedProfileID = tunnelState.profiles[nextIndex].id
        applySelectedProfile()
        saveProfiles()
        appendToLog("\nRemoved connection profile: \(removed.server):\(removed.localPort).\n")
    }

    private func nextAvailablePort() -> String {
        let usedPorts = Set(tunnelState.profiles.compactMap { Int($0.localPort) })

        for port in 1080...1099 {
            if !usedPorts.contains(port) {
                return "\(port)"
            }
        }

        return "1080"
    }

    private func saveDirectDomains() {
        tunnelState.directDomains = tunnelState.directDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        UserDefaults.standard.set(tunnelState.directDomains, forKey: Self.directDomainsKey)
        appendToLog("\nSaved \(tunnelState.directDomains.count) direct domains. Restart proxy to regenerate PAC rules.\n")
    }

    private func resetDirectDomains() {
        tunnelState.directDomains = Self.defaultDirectDomains
        UserDefaults.standard.set(tunnelState.directDomains, forKey: Self.directDomainsKey)
        appendToLog("\nReset direct domains to defaults. Restart proxy to regenerate PAC rules.\n")
    }

    private func replaceNaiveBinary(sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard !tunnelState.isRunning else {
                appendToLog("\nStop the proxy before replacing the binary.\n")
                return
            }

            guard sourceURL.isFileURL,
                  (try sourceURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                appendToLog("\nInvalid binary: choose a regular executable file.\n")
                return
            }

            let supportURL = appSupportDirectoryURL()

            try FileManager.default.createDirectory(
                at: supportURL,
                withIntermediateDirectories: true
            )

            let destinationURL = supportURL.appendingPathComponent("naive-custom")

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )

            tunnelState.customBinaryPath = destinationURL.path
            UserDefaults.standard.set(tunnelState.customBinaryPath, forKey: Self.customBinaryPathKey)
            appendToLog("\nReplaced Naive binary: \(tunnelState.customBinaryPath)\nRestart proxy to use the new binary.\n")
        } catch {
            appendToLog("\nFailed to replace Naive binary: \(error.localizedDescription)\n")
        }
    }

    private func verifyAutoProxy(service: String) -> String {
        let result = runNetworkSetup(arguments: [
            "-getautoproxyurl",
            service
        ])

        return "\nCurrent auto proxy state for \(service):\n\(result.output)"
    }

    private func runDiagnostics() {
        let port = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelState.isTestRunning else {
            appendToLog("\nA test is already running. Please wait.\n")
            return
        }

        tunnelState.isTestRunning = true
        appendToLog("\n=== Comprehensive Diagnostics ===\n")

        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                Task {
                    await testUpstreamConnectivity()
                }
            }
            
            let lsofResult = runCommandOutputStatic("/usr/sbin/lsof", [
                "-nP",
                "-iTCP:\(port)",
                "-sTCP:LISTEN"
            ])

            let curlResult = runCommandOutputStatic("/usr/bin/curl", [
                "-v",
                "--max-time",
                "20",
                "-x",
                "socks5h://127.0.0.1:\(port)",
                "https://ipinfo.io"
            ])

            await MainActor.run {
                appendToLog("\n=== Local Proxy Status ===\n")
                appendToLog(lsofResult)
                appendToLog("\n=== Proxy Functionality Test ===\n")
                appendToLog("Testing SOCKS proxy with curl to ipinfo.io...\n")
                appendToLog(curlResult)
                appendToLog("\n=== End Diagnostics ===\n")
                tunnelState.isTestRunning = false
            }
        }
    }

    private func runTimeoutTest(mode: ProxyTestMode) {
        let port = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelState.isTestRunning else {
            appendToLog("\nA test is already running. Please wait.\n")
            return
        }

        tunnelState.isTestRunning = true
        appendToLog("\n--- Timeout Test: \(mode.title) ---\n")

        Task.detached(priority: .userInitiated) {
            let results: String

            switch mode {
            case .smart:
                results = [
                    "China direct path:",
                    runLatencyTest(url: "https://www.baidu.com", proxyPort: nil),
                    "Foreign SG proxy path:",
                    runLatencyTest(url: "https://www.google.com/generate_204", proxyPort: port)
                ].joined(separator: "\n")

            case .global:
                results = [
                    "China via SG proxy path:",
                    runLatencyTest(url: "https://www.baidu.com", proxyPort: port),
                    "Foreign via SG proxy path:",
                    runLatencyTest(url: "https://www.google.com/generate_204", proxyPort: port)
                ].joined(separator: "\n")
            }

            await MainActor.run {
                appendToLog(results)
                appendToLog("\n--- End Timeout Test: \(mode.title) ---\n")
                tunnelState.isTestRunning = false
            }
        }
    }

    private func runCommand(_ path: String, _ arguments: [String]) -> String {
        let result = runCommandResult(path, arguments)

        if result.output.isEmpty {
            return "\(path) \(arguments.joined(separator: " "))\nNo output. Exit code: \(result.exitCode)\n"
        }

        return result.output + "\nExit code: \(result.exitCode)\n"
    }

    private func runCommandResult(_ path: String, _ arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: task.terminationStatus, output: text)
        } catch {
            return CommandResult(exitCode: -1, output: "\(path) failed: \(error.localizedDescription)\n")
        }
    }
}

private struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String

    var formattedCommandOutput: String {
        let body = output.isEmpty ? "No output." : output
        return body + "Exit code: \(exitCode)\n"
    }
}

private struct ProxyCommandResult: Sendable {
    let success: Bool
    let output: String
}

private enum ActiveProxyMode: Sendable {
    case stopped
    case smart
    case global
    case localOnly

    var title: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .smart:
            return "Smart Mode"
        case .global:
            return "Global Proxy"
        case .localOnly:
            return "Local Only"
        }
    }
}

private struct SidebarButtonLabel: View {
    let title: String
    let systemImage: String
    var isPrimary = false
    var isDisabled = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 24, height: 24)

                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 0)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .opacity(isDisabled ? 0.62 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var foregroundColor: Color {
        if isPrimary && !isDisabled {
            return .white
        }

        return isDisabled ? .secondary : .primary
    }

    private var backgroundColor: Color {
        if isPrimary && !isDisabled {
            return .accentColor
        }

        return Color(nsColor: isDisabled ? .controlBackgroundColor : .quaternaryLabelColor).opacity(isDisabled ? 0.32 : 0.14)
    }

    private var iconBackground: Color {
        if isPrimary && !isDisabled {
            return .white.opacity(0.18)
        }

        return Color(nsColor: .controlAccentColor).opacity(isDisabled ? 0.08 : 0.12)
    }

    private var borderColor: Color {
        if isPrimary && !isDisabled {
            return .white.opacity(0.18)
        }

        return Color(nsColor: .separatorColor).opacity(0.24)
    }
}

private struct ProxyProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var server: String
    var username: String
    var password: String
    var localPort: String

    private enum CodingKeys: String, CodingKey {
        case id
        case server
        case username
        case localPort
    }

    init(id: String, server: String, username: String, password: String, localPort: String) {
        self.id = id
        self.server = server
        self.username = username
        self.password = password
        self.localPort = localPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        server = try container.decode(String.self, forKey: .server)
        username = try container.decode(String.self, forKey: .username)
        password = ""
        localPort = try container.decode(String.self, forKey: .localPort)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(server, forKey: .server)
        try container.encode(username, forKey: .username)
        try container.encode(localPort, forKey: .localPort)
    }

    static let defaultProfile = ProxyProfile(
        id: "default",
        server: "naive.example.com",
        username: "user",
        password: "",
        localPort: "1080"
    )
}

private struct ProfileRow: View {
    let profile: ProxyProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.34))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.server.isEmpty ? "Untitled" : profile.server)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text("\(profile.username) : \(profile.localPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
        }
    }
}

private enum ProxyTestMode: Sendable {
    case smart
    case global

    var title: String {
        switch self {
        case .smart:
            return "Smart"
        case .global:
            return "Global"
        }
    }
}

nonisolated private func runLatencyTest(url: String, proxyPort: String?) -> String {
    var arguments = [
        "-L",
        "-o",
        "/dev/null",
        "-sS",
        "--connect-timeout",
        "5",
        "--max-time",
        "12"
    ]

    if let proxyPort {
        arguments += [
            "-x",
            "socks5h://127.0.0.1:\(proxyPort)"
        ]
    }

    arguments += [
        "-w",
        "http_code=%{http_code}\\nremote_ip=%{remote_ip}\\ntime_namelookup=%{time_namelookup}\\ntime_connect=%{time_connect}\\ntime_appconnect=%{time_appconnect}\\ntime_starttransfer=%{time_starttransfer}\\ntime_total=%{time_total}\\n",
        url
    ]

    let startedAt = Date()
    let result = runCommandResultStatic("/usr/bin/curl", arguments)
    let wallMs = Int(Date().timeIntervalSince(startedAt) * 1000)

    let parsed = parseCurlMetrics(result.output)
    let httpCode = parsed["http_code"] ?? "n/a"
    let remoteIP = parsed["remote_ip"] ?? "n/a"
    let lookupMs = secondsStringToMs(parsed["time_namelookup"])
    let connectMs = secondsStringToMs(parsed["time_connect"])
    let tlsMs = secondsStringToMs(parsed["time_appconnect"])
    let firstByteMs = secondsStringToMs(parsed["time_starttransfer"])
    let totalMs = secondsStringToMs(parsed["time_total"])

    return """
    URL: \(url)
    HTTP: \(httpCode)
    Remote IP: \(remoteIP)
    DNS: \(lookupMs) ms
    TCP connect: \(connectMs) ms
    TLS ready: \(tlsMs) ms
    First byte: \(firstByteMs) ms
    Total: \(totalMs) ms
    Wall clock: \(wallMs) ms
    Exit code: \(result.exitCode)

    """
}

nonisolated private func parseCurlMetrics(_ output: String) -> [String: String] {
    var values: [String: String] = [:]

    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        values[String(parts[0])] = String(parts[1])
    }

    return values
}

nonisolated private func secondsStringToMs(_ value: String?) -> Int {
    guard let value, let seconds = Double(value) else {
        return -1
    }

    return Int((seconds * 1000).rounded())
}

nonisolated private func runCommandResultStatic(_ path: String, _ arguments: [String]) -> CommandResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(exitCode: task.terminationStatus, output: text)
    } catch {
        return CommandResult(exitCode: -1, output: "\(path) failed: \(error.localizedDescription)\n")
    }
}

nonisolated private func runCommandOutputStatic(_ path: String, _ arguments: [String]) -> String {
    let result = runCommandResultStatic(path, arguments)

    if result.output.isEmpty {
        return "\(path) \(arguments.joined(separator: " "))\nNo output. Exit code: \(result.exitCode)\n"
    }

    return result.output + "\nExit code: \(result.exitCode)\n"
}

nonisolated private func runNetworkSetupStatic(arguments: [String]) -> CommandResult {
    runCommandResultStatic("/usr/sbin/networksetup", arguments)
}

nonisolated private func activeNetworkServiceStatic() -> String? {
    let servicesResult = runCommandResultStatic("/usr/sbin/networksetup", ["-listallnetworkservices"])
    let services = servicesResult.output
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.hasPrefix("An asterisk") }
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }

    for preferred in ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN", "Ethernet"] {
        if services.contains(preferred) {
            return preferred
        }
    }

    return services.first
}

nonisolated private func verifySocksProxyStatic(service: String) -> String {
    let result = runNetworkSetupStatic(arguments: [
        "-getsocksfirewallproxy",
        service
    ])

    return "\nCurrent SOCKS proxy state for \(service):\n\(result.output)"
}

nonisolated private func verifyAutoProxyStatic(service: String) -> String {
    let result = runNetworkSetupStatic(arguments: [
        "-getautoproxyurl",
        service
    ])

    return "\nCurrent auto proxy state for \(service):\n\(result.output)"
}

nonisolated private func enableGlobalProxyCommand(port: Int) -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(
            success: false,
            output: "\nCould not find an active network service. Open System Settings > Network and check the service name.\n"
        )
    }

    var output = "\nEnabling SOCKS proxy for service: \(service)\n"

    let pacOffResult = runNetworkSetupStatic(arguments: [
        "-setautoproxystate",
        service,
        "off"
    ])

    let setResult = runNetworkSetupStatic(arguments: [
        "-setsocksfirewallproxy",
        service,
        "127.0.0.1",
        "\(port)"
    ])

    let stateResult = runNetworkSetupStatic(arguments: [
        "-setsocksfirewallproxystate",
        service,
        "on"
    ])

    output += pacOffResult.output
    output += setResult.output
    output += stateResult.output

    let success = setResult.exitCode == 0 && stateResult.exitCode == 0
    if success {
        output += "\nGlobal SOCKS proxy enabled on \(service): 127.0.0.1:\(port). All proxy-aware traffic should use SG VPS.\n"
        output += verifySocksProxyStatic(service: service)
    } else {
        output += "\nFailed to enable system SOCKS proxy. Exit codes: \(setResult.exitCode), \(stateResult.exitCode).\n"
    }

    return ProxyCommandResult(success: success, output: output)
}

nonisolated private func disableSystemProxyCommand() -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(
            success: false,
            output: "\nCould not find an active network service. Open System Settings > Network and disable SOCKS manually if needed.\n"
        )
    }

    var output = "\nDisabling SOCKS proxy for service: \(service)\n"

    let socksResult = runNetworkSetupStatic(arguments: [
        "-setsocksfirewallproxystate",
        service,
        "off"
    ])

    let pacResult = runNetworkSetupStatic(arguments: [
        "-setautoproxystate",
        service,
        "off"
    ])

    output += socksResult.output
    output += pacResult.output

    let success = socksResult.exitCode == 0 && pacResult.exitCode == 0
    if success {
        output += "\nSystem proxy disabled on \(service).\n"
        output += verifySocksProxyStatic(service: service)
        output += verifyAutoProxyStatic(service: service)
    } else {
        output += "\nFailed to fully disable system proxy. Exit codes: \(socksResult.exitCode), \(pacResult.exitCode).\n"
    }

    return ProxyCommandResult(success: success, output: output)
}

nonisolated private func enableSmartProxyCommand(port: Int, pacURLString: String) -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(
            success: false,
            output: "\nCould not find an active network service. Smart proxy was not enabled.\n"
        )
    }

    var output = "\nEnabling smart PAC proxy for service: \(service)\n"

    let socksOffResult = runNetworkSetupStatic(arguments: [
        "-setsocksfirewallproxystate",
        service,
        "off"
    ])

    let pacSetResult = runNetworkSetupStatic(arguments: [
        "-setautoproxyurl",
        service,
        pacURLString
    ])

    let pacOnResult = runNetworkSetupStatic(arguments: [
        "-setautoproxystate",
        service,
        "on"
    ])

    output += socksOffResult.output
    output += pacSetResult.output
    output += pacOnResult.output

    let success = pacSetResult.exitCode == 0 && pacOnResult.exitCode == 0
    if success {
        output += "\nSmart proxy enabled on \(service).\n"
        output += "China/common mainland domains go DIRECT. Other traffic uses SG VPS through SOCKS 127.0.0.1:\(port).\n"
        output += verifySocksProxyStatic(service: service)
        output += verifyAutoProxyStatic(service: service)
    } else {
        output += "\nFailed to enable smart proxy. Exit codes: \(pacSetResult.exitCode), \(pacOnResult.exitCode).\n"
    }

    return ProxyCommandResult(success: success, output: output)
}

private struct TrafficInspection: Sendable {
    let snapshot: String
    let establishedConnections: Int
    let localClientConnections: Int
    let remoteConnections: Int
    let abnormalReason: String?

    var summary: String {
        "Security guard: established=\(establishedConnections), local_clients=\(localClientConnections), remote=\(remoteConnections)"
    }
}

nonisolated private func inspectNaiveTraffic(pid: Int32, localPort: String) -> TrafficInspection {
    let maxEstablishedConnections = 160
    let maxLocalClientConnections = 120
    let maxRemoteConnections = 32

    let result = runCommandResultStatic("/usr/sbin/lsof", [
        "-nP",
        "-a",
        "-p",
        "\(pid)",
        "-iTCP"
    ])

    var lines = [String]()
    var establishedCount = 0
    var localClientCount = 0
    var remoteCount = 0
    var exposedListenLine: String?
    let localClientPattern = "127.0.0.1:\(localPort)->127.0.0.1:"
    let localListenPattern = "127.0.0.1:\(localPort)"
    let loopbackIPv6ListenPattern = "[::1]:\(localPort)"
    let portPattern = ":\(localPort)"

    for substring in result.output.split(separator: "\n") {
        let isEstablished = substring.contains("ESTABLISHED")
        let isListening = substring.contains("LISTEN")
        guard isEstablished || isListening else { continue }

        let line = String(substring)
        lines.append(line)

        if isEstablished {
            establishedCount += 1

            if line.contains(localClientPattern) {
                localClientCount += 1
            }

            if line.contains("->") && !line.contains("127.0.0.1") {
                remoteCount += 1
            }
        } else if exposedListenLine == nil,
                  line.contains(portPattern),
                  !line.contains(localListenPattern),
                  !line.contains(loopbackIPv6ListenPattern) {
            exposedListenLine = line
        }
    }

    let abnormalReason: String?
    if let exposedListenLine {
        abnormalReason = "NaiveProxy is listening outside localhost: \(exposedListenLine)"
    } else if establishedCount > maxEstablishedConnections {
        abnormalReason = "too many active connections (\(establishedCount) > \(maxEstablishedConnections))"
    } else if localClientCount > maxLocalClientConnections {
        abnormalReason = "too many local client connections (\(localClientCount) > \(maxLocalClientConnections))"
    } else if remoteCount > maxRemoteConnections {
        abnormalReason = "too many remote socket connections (\(remoteCount) > \(maxRemoteConnections))"
    } else {
        abnormalReason = nil
    }

    return TrafficInspection(
        snapshot: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n",
        establishedConnections: establishedCount,
        localClientConnections: localClientCount,
        remoteConnections: remoteCount,
        abnormalReason: abnormalReason
    )
}

private let shortTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func shortTimeString() -> String {
    shortTimeFormatter.string(from: Date())
}

private struct SettingsView: View {
    @Binding var directDomains: [String]
    @Binding var customBinaryPath: String

    let onSaveDomains: () -> Void
    let onReplaceBinary: (URL) -> Void
    let onResetDomains: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var showBinaryImporter = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.title2.bold())

                        Text("Tune routing rules and the Cool tunnel proxy engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Done") {
                        onSaveDomains()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    TextField("example.cn or example.com", text: $newDomain)
                                        .textFieldStyle(.roundedBorder)

                                    Button {
                                        addDomain()
                                    } label: {
                                        Label("Add", systemImage: "plus")
                                    }
                                }

                                List {
                                    ForEach(directDomains, id: \.self) { domain in
                                        Text(domain)
                                    }
                                    .onDelete { offsets in
                                        directDomains.remove(atOffsets: offsets)
                                        onSaveDomains()
                                    }
                                }
                                .frame(height: 170)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                HStack {
                                    Button {
                                        onSaveDomains()
                                    } label: {
                                        Label("Save Domains", systemImage: "checkmark")
                                    }

                                    Button {
                                        onResetDomains()
                                    } label: {
                                        Label("Reset Defaults", systemImage: "arrow.counterclockwise")
                                    }
                                }
                            }
                            .padding(6)
                        } label: {
                            Label("Direct domains for Smart Start mode", systemImage: "globe.asia.australia")
                                .font(.system(size: 14, weight: .bold))
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                binarySettingsSection
                                aboutSection
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                binarySettingsSection
                                aboutSection
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(20)
        }
        .frame(width: 680, height: 680)
        .fileImporter(
            isPresented: $showBinaryImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    onReplaceBinary(url)
                }
            case .failure:
                break
            }
        }
    }

    private var binarySettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(customBinaryPath.isEmpty ? "Using bundled naive binary." : customBinaryPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Button {
                    showBinaryImporter = true
                } label: {
                    Label("Replace Naive Binary", systemImage: "arrow.down.doc")
                }
            }
            .padding(6)
        } label: {
            Label("Cool tunnel proxy engine", systemImage: "shippingbox")
                .font(.system(size: 14, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var aboutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Version")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(appVersion)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }

                HStack {
                    Text("Creator")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Alice")
                        .font(.caption.weight(.semibold))
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    TechStackRow(label: "App", value: "SwiftUI macOS")
                    TechStackRow(label: "Core", value: "Foundation, Process, UserDefaults")
                    TechStackRow(label: "Proxy", value: "Cool tunnel, SOCKS5, Smart PAC")
                    TechStackRow(label: "System", value: "networksetup, lsof, curl")
                    TechStackRow(label: "UI", value: "Material cards, adaptive grid, live tunnelState.logs")
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Technology power")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    TechnologyLink(title: "NaiveProxy", subtitle: "Proxy engine", url: "https://github.com/klzgrad/naiveproxy/tree/master")
                    TechnologyLink(title: "Debian", subtitle: "Server operating system", url: "https://www.debian.org/")
                    TechnologyLink(title: "Vultr", subtitle: "Cloud infrastructure", url: "https://www.vultr.com/")
                    TechnologyLink(title: "Cloudflare", subtitle: "DNS", url: "https://www.cloudflare.com/")
                }
            }
            .padding(6)
        } label: {
            Label("About", systemImage: "info.circle")
                .font(.system(size: 14, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return }
        guard !directDomains.contains(domain) else {
            newDomain = ""
            return
        }

        directDomains.append(domain)
        directDomains.sort()
        newDomain = ""
        onSaveDomains()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "rev0.0.1"
    }
}

private struct TechStackRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

private struct TechnologyLink: View {
    let title: String
    let subtitle: String
    let url: String

    var body: some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ContentView()
}
