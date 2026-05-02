import SwiftUI
import Foundation
import UniformTypeIdentifiers
import AppKit
import Combine

// MARK: - State

@MainActor
private final class TunnelState: ObservableObject {
    static let shared = TunnelState()

    // Connection
    @Published var server = "naive.example.com"
    @Published var username = "user"
    @Published var password = ""
    @Published var localPort = "1080"

    // Proxy process
    @Published var isRunning = false
    @Published var process: Process?
    @Published var activeProxyMode: ActiveProxyMode = .stopped
    @Published var isModeChanging = false
    @Published var abnormalTrafficBlocked = false
    var proxySessionID = UUID()
    var modeCommandGeneration: UInt64 = 0
    var pendingProxyRequest: PendingProxyRequest?

    // Activity monitor
    @Published var activityTimer: Timer?
    @Published var lastActivitySnapshot = ""

    // Diagnostics
    @Published var isTestRunning = false

    // Logs
    @Published var logLines: [String] = ["Proxy is stopped."]
    @Published var logLineCount = 1
    @Published var logRevision: UInt64 = 0
    var logCarry = ""

    // Profiles
    @Published var profiles = [ProxyProfile.defaultProfile]
    @Published var selectedProfileID: String? = ProxyProfile.defaultProfile.id

    // Settings
    @Published var directDomains = ContentView.defaultDirectDomains
    @Published var customBinaryPath = ""
    @Published var skipProxyConfirmations = false
    var didLoadSettings = false
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var tunnelState = TunnelState.shared
    @State private var showSettings = false
    @State private var stressTask: Task<Void, Never>?
    @State private var profileSyncTask: Task<Void, Never>?
    @State private var isApplyingProfile = false

    // MARK: Storage keys & constants

    fileprivate enum Keys {
        static let directDomains = "directDomains"
        static let customBinaryPath = "tunnelState.customBinaryPath"
        static let profiles = "connectionProfiles"
        static let selectedProfile = "selectedConnectionProfile"
        static let skipProxyConfirmations = "skipProxyConfirmations"
    }

    fileprivate static let appSupportDirectoryName = "NaiveProxyMac"
    fileprivate static let configFileName = "config.json"
    fileprivate static let pacFileName = "smart-proxy.pac"
    fileprivate static let maxLogLines = 1000
    fileprivate static let logTrimBatchSize = 120
    fileprivate static let logAutoScrollThrottleMs: Int = 140

    fileprivate static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f
    }()

    fileprivate static let defaultDirectDomains = [
        ".cn", "baidu.com", "bdstatic.com", "bilibili.com", "douyin.com",
        "jd.com", "mi.com", "netease.com", "qq.com", "taobao.com",
        "tmall.com", "weibo.com", "weixin.qq.com", "xiaohongshu.com",
        "youku.com", "zhihu.com"
    ]

    // MARK: Body

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
        .onAppear { loadSettings() }
        .onChange(of: tunnelState.selectedProfileID) { _, _ in applySelectedProfile() }
        // Debounce profile persistence to avoid stalling UI while typing.
        .onChange(of: tunnelState.server)    { _, _ in scheduleProfileSync() }
        .onChange(of: tunnelState.username)  { _, _ in scheduleProfileSync() }
        .onChange(of: tunnelState.password)  { _, _ in scheduleProfileSync() }
        .onChange(of: tunnelState.localPort) { _, _ in scheduleProfileSync() }
        .onChange(of: tunnelState.skipProxyConfirmations) { _, _ in saveSkipProxyConfirmations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stopProxy()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                directDomains: $tunnelState.directDomains,
                customBinaryPath: $tunnelState.customBinaryPath,
                skipProxyConfirmations: $tunnelState.skipProxyConfirmations,
                onSaveDomains: saveDirectDomains,
                onReplaceBinary: replaceNaiveBinary,
                onResetDomains: resetDirectDomains
            )
        }
    }
}

// MARK: - Subviews

extension ContentView {
    private var cardBackground: some ShapeStyle { .thinMaterial }

    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.82)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
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
                    Text(statusSubtitle).lineLimit(1)
                    Text("•").foregroundStyle(.tertiary)
                    Text("crafted by Nick").lineLimit(1)
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
        if tunnelState.isModeChanging  { return "Applying network settings..." }
        if tunnelState.isTestRunning   { return "Diagnostics are running" }
        return tunnelState.isRunning ? "Secure tunnel is active" : "Ready to start a smart proxy session"
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(tunnelState.activeProxyMode.title)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private var statusColor: Color {
        switch tunnelState.activeProxyMode {
        case .stopped:  return .secondary
        case .smart:    return .green
        case .global:   return .orange
        case .localOnly: return .blue
        }
    }

    private var controlPanel: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 10)],
            alignment: .leading, spacing: 8
        ) {
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
        proxyButton("Start Smart Mode", image: "play.fill", isPrimary: true,
                    disabled: tunnelState.isRunning || tunnelState.isModeChanging) {
            guard !tunnelState.isRunning, !tunnelState.isModeChanging else { return }
            startProxy()
        }
        proxyButton("Stop", image: "stop.fill",
                    disabled: !tunnelState.isRunning) {
            guard tunnelState.isRunning else { return }
            stopProxy()
        }
        proxyButton("Enable Global Proxy", image: "switch.2",
                    disabled: !tunnelState.isRunning || tunnelState.activeProxyMode == .global || tunnelState.isModeChanging) {
            guard tunnelState.isRunning, tunnelState.activeProxyMode != .global, !tunnelState.isModeChanging else { return }
            enableSystemProxy()
        }
        proxyButton("Restore macOS Proxy", image: "xmark.circle",
                    disabled: tunnelState.isModeChanging) {
            guard !tunnelState.isModeChanging else { return }
            disableSystemProxy()
        }
        proxyButton("Timeout Test: Smart", image: "timer",
                    disabled: !tunnelState.isRunning || tunnelState.isTestRunning) {
            guard tunnelState.isRunning, !tunnelState.isTestRunning else { return }
            runTimeoutTest(mode: .smart)
        }
        proxyButton("Timeout Test: Global", image: "timer.circle",
                    disabled: !tunnelState.isRunning || tunnelState.isTestRunning) {
            guard tunnelState.isRunning, !tunnelState.isTestRunning else { return }
            runTimeoutTest(mode: .global)
        }
        proxyButton("Test Proxy", image: "stethoscope",
                    disabled: !tunnelState.isRunning || tunnelState.isTestRunning) {
            guard tunnelState.isRunning, !tunnelState.isTestRunning else { return }
            runDiagnostics()
        }
        proxyButton("Settings", image: "gearshape") {
            showSettings = true
        }

#if DEBUG
        proxyButton(stressTask == nil ? "UX Stress: Rapid Switching" : "Stop UX Stress", image: "bolt") {
            if let stressTask {
                stressTask.cancel()
                self.stressTask = nil
                appendToLog("\n[Stress] Cancel requested.\n")
            } else {
                self.stressTask = Task { @MainActor in
                    await runUXStressSwitching()
                    self.stressTask = nil
                }
            }
        }
#endif
    }

    private func proxyButton(
        _ title: String, image: String,
        isPrimary: Bool = false, disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SidebarButtonLabel(title: title, systemImage: image,
                               isPrimary: isPrimary, isDisabled: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Live Logs", systemImage: "terminal")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button { clearLogs() } label: { Label("Clear", systemImage: "trash") }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tunnelState.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Color(nsColor: .textColor))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator.opacity(0.35), lineWidth: 1)
                }
                // Under heavy logging, scrolling on every append can stall the UI. Throttle instead.
                .onReceive(
                    tunnelState.$logRevision.throttle(
                        for: .milliseconds(Self.logAutoScrollThrottleMs),
                        scheduler: RunLoop.main,
                        latest: true
                    )
                ) { _ in
                    let last = max(0, tunnelState.logLines.count - 1)
                    proxy.scrollTo(last, anchor: .bottom)
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
                HStack(alignment: .top, spacing: 16) { profileList; connectionForm }
                VStack(alignment: .leading, spacing: 12) { profileList; connectionForm }
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
            Text("Profiles").font(.caption.weight(.bold)).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tunnelState.profiles, id: \.id) { profile in
                        Button {
                            tunnelState.selectedProfileID = profile.id
                        } label: {
                            ProfileRow(profile: profile,
                                       isSelected: tunnelState.selectedProfileID == profile.id)
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
                Button { addProfile() } label: { Label("Add", systemImage: "plus") }
                    .disabled(tunnelState.isRunning)
                Button { removeSelectedProfile() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(tunnelState.isRunning || tunnelState.profiles.count <= 1)
            }
            .controlSize(.small)
        }
    }

    private var connectionForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Server").frame(width: 126, alignment: .leading)
                TextField("naive.example.com", text: $tunnelState.server)
                    .textFieldStyle(.roundedBorder).disabled(tunnelState.isRunning)
            }
            GridRow {
                Text("Username").frame(width: 126, alignment: .leading)
                TextField("username", text: $tunnelState.username)
                    .textFieldStyle(.roundedBorder).disabled(tunnelState.isRunning)
            }
            GridRow {
                Text("Password").frame(width: 126, alignment: .leading)
                SecureField("Password", text: $tunnelState.password)
                    .textFieldStyle(.roundedBorder).disabled(tunnelState.isRunning)
            }
            GridRow {
                Text("Local SOCKS Port").frame(width: 126, alignment: .leading)
                TextField("1080", text: $tunnelState.localPort)
                    .textFieldStyle(.roundedBorder).frame(width: 120).disabled(tunnelState.isRunning)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Proxy Lifecycle

extension ContentView {
    private func startProxy() {
        guard !tunnelState.isRunning, !tunnelState.isModeChanging else { return }

        guard let naiveURL = currentNaiveBinaryURL() else {
            setLogs("Error: naive binary not found in app bundle.")
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
            let sessionID = UUID()

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                Task { @MainActor in appendToLog(text) }
            }

            task.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    guard tunnelState.proxySessionID == sessionID || tunnelState.process === task else { return }
                    if tunnelState.process === task { tunnelState.process = nil }
                    tunnelState.isRunning = false
                    tunnelState.isModeChanging = false
                    tunnelState.isTestRunning = false
                    tunnelState.activeProxyMode = .stopped
                    appendToLog("\nProxy stopped.\n")
                }
            }

            setLogs("Starting NaiveProxy...\nBinary: \(naiveURL.path)\nConfig: \(configURL.path)\nRuntime: config file, listen=socks://127.0.0.1:\(safePort), proxy=\(maskedProxyURL)\n")
            appendToLog("Binary size: \(fileSize(at: naiveURL.path)) bytes\n")
            try task.run()

            tunnelState.proxySessionID = sessionID
            tunnelState.process = task
            tunnelState.isRunning = true
            tunnelState.abnormalTrafficBlocked = false
            appendToLog("Process started with pid \(task.processIdentifier).\n")

            waitForProxyListening(port: safePort, sessionID: sessionID, task: task, configURL: configURL)
        } catch {
            appendToLog("Failed to start: \(error.localizedDescription)")
            tunnelState.isRunning = false
        }
    }

    private func waitForProxyListening(port: String, sessionID: UUID, task: Process, configURL: URL) {
        Task.detached(priority: .userInitiated) {
            let maxWaitTime = 15.0
            let checkInterval = 0.5
            var elapsed = 0.0

            while elapsed < maxWaitTime {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                elapsed += checkInterval

                if await checkProxyListening(port: Int(port) ?? 1080) {
                    await MainActor.run {
                        guard tunnelState.isRunning,
                              tunnelState.process === task,
                              tunnelState.proxySessionID == sessionID else { return }
                        appendToLog("✓ NaiveProxy is now listening on port \(port).\n")
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
                appendToLog("- Port \(port) may be in use by another application\n")
                appendToLog("- NaiveProxy binary may have compatibility issues\n")
                appendToLog("- Check the configuration file: \(configURL.path)\n")
                appendToLog("Consider using a different port or checking system logs.\n")
            }
        }
    }

    private func stopProxy() {
        stopActivityMonitor()
        tunnelState.proxySessionID = UUID()
        tunnelState.modeCommandGeneration &+= 1
        tunnelState.isModeChanging = false
        (tunnelState.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        tunnelState.process?.terminate()
        tunnelState.process = nil
        tunnelState.isRunning = false
        tunnelState.activeProxyMode = .stopped
        removeSensitiveRuntimeFiles()
        disableAllSystemProxies()
    }

    private func restartProxy() {
        Task { @MainActor in
            stopProxy()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            startProxy()
        }
    }
}

// MARK: - System Proxy Control

extension ContentView {
    private func enableSystemProxy() {
        guard let safePort = validatedPortString(), let port = Int(safePort) else {
            appendToLog("\nInvalid local port.\n"); return
        }
        guard confirmSystemProxyChange(mode: .global, port: port) else {
            appendToLog("\nCancelled global proxy change.\n"); return
        }

        Task.detached(priority: .userInitiated) {
            let isListening = await checkProxyListening(port: port)
            await MainActor.run {
                guard tunnelState.isRunning else { return }
                if !isListening {
                    appendToLog("\nNaiveProxy is not listening on port \(port). Restarting proxy...\n")
                    restartProxy()
                } else {
                    requestEnableGlobalProxy(port: port)
                }
            }
        }
    }

    private func requestEnableGlobalProxy(port: Int) {
        if tunnelState.isModeChanging {
            tunnelState.pendingProxyRequest = .enableGlobal(port: port)
            appendToLog("\nQueued: enable Global proxy (will run after current change)\n")
            return
        }

        let generation = nextModeCommandGeneration()
        tunnelState.isModeChanging = true
        appendToLog("\n=== Enabling Global SOCKS Proxy ===\n")
        appendToLog("Target: Wi-Fi service\n")
        appendToLog("SOCKS server: 127.0.0.1:\(port)\n")

        Task.detached(priority: .userInitiated) {
            let result = await SystemProxyCommandQueue.shared.enableGlobal(port: port)
            await MainActor.run {
                guard tunnelState.modeCommandGeneration == generation else { return }
                appendToLog(result.output)
                if result.success, tunnelState.isRunning {
                    tunnelState.activeProxyMode = .global
                    appendToLog("✓ Global proxy enabled successfully\n")
                    appendToLog("All traffic should now route through SG VPS\n")
                } else if !tunnelState.isRunning {
                    tunnelState.activeProxyMode = .stopped
                } else {
                    appendToLog("✗ Failed to enable global proxy\n")
                    appendToLog("Check system permissions and network settings\n")
                }
                tunnelState.isModeChanging = false
                drainPendingProxyRequestIfNeeded()
            }
        }
    }

    private func enableSmartProxy() {
        guard let safePort = validatedPortString(), let port = Int(safePort) else {
            appendToLog("\nInvalid local port. Smart proxy was not enabled.\n"); return
        }
        guard confirmSystemProxyChange(mode: .smart, port: port) else {
            appendToLog("\nCancelled smart proxy change.\n"); return
        }

        do {
            let pacURL = try writePACFile(port: port)
            let pacURLString = pacURL.absoluteString
            requestEnableSmartProxy(port: port, pacURLString: pacURLString, pacPathForLog: pacURL.path)
        } catch {
            appendToLog("\nFailed to write PAC file: \(error.localizedDescription)\n")
        }
    }

    private func requestEnableSmartProxy(port: Int, pacURLString: String, pacPathForLog: String) {
        if tunnelState.isModeChanging {
            tunnelState.pendingProxyRequest = .enableSmart(port: port, pacURLString: pacURLString, pacPathForLog: pacPathForLog)
            appendToLog("\nQueued: enable Smart proxy (will run after current change)\n")
            return
        }

        let generation = nextModeCommandGeneration()
        tunnelState.isModeChanging = true
        appendToLog("\n=== Enabling Smart PAC Proxy ===\n")
        appendToLog("PAC file: \(pacPathForLog)\n")
        appendToLog("Direct domains: \(tunnelState.directDomains.count) configured\n")

        Task.detached(priority: .userInitiated) {
            let result = await SystemProxyCommandQueue.shared.enableSmart(port: port, pacURLString: pacURLString)
            await MainActor.run {
                guard tunnelState.modeCommandGeneration == generation else { return }
                appendToLog(result.output)
                if result.success, tunnelState.isRunning {
                    tunnelState.activeProxyMode = .smart
                    appendToLog("✓ Smart proxy enabled successfully\n")
                    appendToLog("China/domains go DIRECT, other traffic via SG VPS\n")
                } else if !tunnelState.isRunning {
                    tunnelState.activeProxyMode = .stopped
                } else {
                    appendToLog("✗ Failed to enable smart proxy\n")
                }
                tunnelState.isModeChanging = false
                drainPendingProxyRequestIfNeeded()
            }
        }
    }

    private func disableSystemProxy() {
        let nextMode: ActiveProxyMode = tunnelState.isRunning ? .localOnly : .stopped
        requestDisableSystemProxy(nextMode: nextMode)
    }

    private func requestDisableSystemProxy(nextMode: ActiveProxyMode) {
        if tunnelState.isModeChanging {
            tunnelState.pendingProxyRequest = .disable(nextMode: nextMode)
            appendToLog("\nQueued: disable system proxy (will run after current change)\n")
            return
        }

        let generation = nextModeCommandGeneration()
        tunnelState.isModeChanging = true
        appendToLog("\nDisabling system proxy...\n")

        Task.detached(priority: .userInitiated) {
            let result = await SystemProxyCommandQueue.shared.disable()
            await MainActor.run {
                guard tunnelState.modeCommandGeneration == generation else { return }
                appendToLog(result.output)
                if result.success { tunnelState.activeProxyMode = nextMode }
                tunnelState.isModeChanging = false
                drainPendingProxyRequestIfNeeded()
            }
        }
    }

    private func disableAllSystemProxies() {
        let generation = nextModeCommandGeneration()
        appendToLog("\nRestoring macOS proxy settings after stop...\n")
        Task.detached(priority: .userInitiated) {
            let result = await SystemProxyCommandQueue.shared.disable()
            await MainActor.run {
                guard tunnelState.modeCommandGeneration == generation else { return }
                appendToLog(result.output)
            }
        }
    }

    private func nextModeCommandGeneration() -> UInt64 {
        tunnelState.modeCommandGeneration &+= 1
        return tunnelState.modeCommandGeneration
    }

    private func confirmSystemProxyChange(mode: ActiveProxyMode, port: Int) -> Bool {
        if tunnelState.skipProxyConfirmations { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = mode == .global ? "Enable Global System Proxy?" : "Enable Smart System Proxy?"
        alert.informativeText = mode == .global
            ? "This will change macOS network settings using networksetup and route proxy-aware traffic through SOCKS 127.0.0.1:\(port). You can undo it with Disable System Proxy."
            : "This will change macOS network settings using networksetup and enable a local PAC file. Matching direct domains bypass the proxy; other proxy-aware traffic uses 127.0.0.1:\(port). You can undo it with Disable System Proxy."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let didEnable = alert.runModal() == .alertFirstButtonReturn
        if didEnable, alert.suppressionButton?.state == .on {
            tunnelState.skipProxyConfirmations = true
            saveSkipProxyConfirmations()
        }
        return didEnable
    }

    private func checkProxyListening(port: Int) async -> Bool {
        let result = runCommandResultStatic("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
        return result.exitCode == 0 && !result.output.isEmpty
    }
}

// MARK: - Activity Monitor

extension ContentView {
    @MainActor
    private func drainPendingProxyRequestIfNeeded() {
        guard !tunnelState.isModeChanging, let req = tunnelState.pendingProxyRequest else { return }
        tunnelState.pendingProxyRequest = nil

        switch req {
        case .enableGlobal(let port):
            requestEnableGlobalProxy(port: port)
        case .enableSmart(let port, let pacURLString, let pacPathForLog):
            requestEnableSmartProxy(port: port, pacURLString: pacURLString, pacPathForLog: pacPathForLog)
        case .disable(let nextMode):
            requestDisableSystemProxy(nextMode: nextMode)
        }
    }

    private func startActivityMonitor(pid: Int32) {
        stopActivityMonitor()
        tunnelState.lastActivitySnapshot = ""
        let monitoredPort = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)

        tunnelState.activityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task.detached(priority: .utility) {
                let inspection = inspectNaiveTraffic(pid: pid, localPort: monitoredPort)
                await MainActor.run { handleTrafficInspection(inspection) }
            }
        }
    }

    private func stopActivityMonitor() {
        tunnelState.activityTimer?.invalidate()
        tunnelState.activityTimer = nil
        tunnelState.lastActivitySnapshot = ""
    }

    private func handleTrafficInspection(_ inspection: TrafficInspection) {
        guard tunnelState.isRunning, !inspection.snapshot.isEmpty else { return }

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
}

// MARK: - Diagnostics

extension ContentView {
    private func runDiagnostics() {
        guard !tunnelState.isTestRunning else {
            appendToLog("\nA test is already running. Please wait.\n"); return
        }
        guard tunnelState.isRunning else {
            appendToLog("\nStart the proxy before running diagnostics.\n"); return
        }
        guard let port = validatedPortString() else {
            appendToLog("\nInvalid local port. Diagnostics were not started.\n"); return
        }

        tunnelState.isTestRunning = true
        appendToLog("\n=== Comprehensive Diagnostics ===\n")

        Task.detached(priority: .userInitiated) {
            let upstreamTask = Task { await testUpstreamConnectivity() }

            let lsofResult = runCommandOutputStatic("/usr/sbin/lsof", [
                "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"
            ])
            let curlResult = runCommandOutputStatic("/usr/bin/curl", [
                "-v", "--max-time", "20", "-x", "socks5h://127.0.0.1:\(port)", "https://ipinfo.io"
            ])

            await upstreamTask.value

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
        guard !tunnelState.isTestRunning else {
            appendToLog("\nA test is already running. Please wait.\n"); return
        }
        guard tunnelState.isRunning else {
            appendToLog("\nStart the proxy before running timeout tests.\n"); return
        }
        guard let port = validatedPortString() else {
            appendToLog("\nInvalid local port. Timeout test was not started.\n"); return
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

    @MainActor
    private func testUpstreamConnectivity() async {
        appendToLog("\n=== Testing Upstream Connectivity ===\n")
        guard let server = validatedServerString() else {
            appendToLog("Invalid configured server. Skipping upstream connectivity test.\n")
            return
        }
        appendToLog("Testing TLS connection to configured server...\n")
        let targetURL = "https://\(server)"

        let result = await Task.detached(priority: .userInitiated) {
            runCommandResultStatic("/usr/bin/curl", [
                "-v", "--max-time", "10", "--connect-timeout", "5", targetURL
            ])
        }.value

        if result.exitCode == 0 {
            appendToLog("✓ Upstream server is reachable\n")
        } else {
            appendToLog("✗ Upstream server connection failed\n")
            appendToLog("This may indicate:\n- Network connectivity issues\n- Server is down or blocking connections\n- Firewall or DNS issues\n")
        }
        appendToLog(result.output)
    }
}

// MARK: - Logging

extension ContentView {
    private func setLogs(_ text: String) {
        tunnelState.logCarry = ""
        tunnelState.logLines = splitToDisplayLines(text, carry: &tunnelState.logCarry)
        if tunnelState.logLines.isEmpty { tunnelState.logLines = [""] }
        tunnelState.logLineCount = tunnelState.logLines.count
        tunnelState.logRevision &+= 1
    }

    private func appendToLog(_ text: String) {
        let newLines = splitToDisplayLines(text, carry: &tunnelState.logCarry)
        if tunnelState.logLines.isEmpty { tunnelState.logLines = [""] }
        if newLines.isEmpty {
            // no complete lines yet; just update last visible line with carry
            tunnelState.logLines[tunnelState.logLines.count - 1] = tunnelState.logCarry
        } else {
            // Replace last line with carry (partial), then append complete lines.
            tunnelState.logLines[tunnelState.logLines.count - 1] = tunnelState.logCarry
            tunnelState.logLines.append(contentsOf: newLines)
        }
        tunnelState.logLineCount = tunnelState.logLines.count
        tunnelState.logRevision &+= 1

        trimLogsIfNeeded()
    }

    private func clearLogs() {
        tunnelState.logCarry = ""
        tunnelState.logLines = [""]
        tunnelState.logLineCount = 1
        tunnelState.logRevision &+= 1
    }

    private func trimLogsIfNeeded() {
        let threshold = Self.maxLogLines + Self.logTrimBatchSize
        guard tunnelState.logLineCount > threshold else { return }
        let dropCount = min(Self.logTrimBatchSize, max(0, tunnelState.logLineCount - Self.maxLogLines))
        guard dropCount > 0 else { return }
        tunnelState.logLines.removeFirst(dropCount)
        if tunnelState.logLines.isEmpty { tunnelState.logLines = [""] }
        tunnelState.logLineCount = tunnelState.logLines.count
    }

    private func splitToDisplayLines(_ incoming: String, carry: inout String) -> [String] {
        if incoming.isEmpty { return [] }
        let combined = carry + incoming
        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if combined.hasSuffix("\n") {
            carry = ""
            return parts
        } else {
            carry = parts.last ?? ""
            return Array(parts.dropLast())
        }
    }
}

// MARK: - Profiles & Persistence

extension ContentView {
    @MainActor
    private func scheduleProfileSync() {
        guard !isApplyingProfile else { return }
        profileSyncTask?.cancel()
        profileSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }
            syncSelectedProfile()
        }
    }

    private func loadSettings() {
        guard !tunnelState.didLoadSettings else { return }
        tunnelState.didLoadSettings = true
        loadProfiles()

        if let saved = UserDefaults.standard.stringArray(forKey: Keys.directDomains), !saved.isEmpty {
            tunnelState.directDomains = saved
        }
        tunnelState.customBinaryPath = UserDefaults.standard.string(forKey: Keys.customBinaryPath) ?? ""
        tunnelState.skipProxyConfirmations = UserDefaults.standard.bool(forKey: Keys.skipProxyConfirmations)
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([ProxyProfile].self, from: data),
           !decoded.isEmpty {
            tunnelState.profiles = decoded
            tunnelState.selectedProfileID = UserDefaults.standard.string(forKey: Keys.selectedProfile) ?? decoded[0].id
        } else {
            tunnelState.profiles = [ProxyProfile(
                id: ProxyProfile.defaultProfile.id,
                server: tunnelState.server, username: tunnelState.username,
                password: tunnelState.password, localPort: tunnelState.localPort
            )]
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
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
        if let id = tunnelState.selectedProfileID {
            UserDefaults.standard.set(id, forKey: Keys.selectedProfile)
        }
    }

    private func applySelectedProfile() {
        guard let _ = tunnelState.selectedProfileID,
              let profile = tunnelState.profiles.first(where: { $0.id == tunnelState.selectedProfileID })
        else { return }

        isApplyingProfile = true
        tunnelState.server = profile.server
        tunnelState.username = profile.username
        tunnelState.password = profile.password
        tunnelState.localPort = profile.localPort
        isApplyingProfile = false
        saveProfiles()
    }

    private func syncSelectedProfile() {
        guard let selectedProfileID = tunnelState.selectedProfileID,
              let index = tunnelState.profiles.firstIndex(where: { $0.id == tunnelState.selectedProfileID })
        else { return }

        let updated = ProxyProfile(
            id: selectedProfileID,
            server: tunnelState.server, username: tunnelState.username,
            password: tunnelState.password, localPort: tunnelState.localPort
        )
        guard tunnelState.profiles[index] != updated else { return }
        tunnelState.profiles[index] = updated
        saveProfiles()
    }

    private func addProfile() {
        let profile = ProxyProfile(
            id: UUID().uuidString, server: "naive.example.com",
            username: "user", password: "", localPort: nextAvailablePort()
        )
        tunnelState.profiles.append(profile)
        tunnelState.selectedProfileID = profile.id
        applySelectedProfile()
        saveProfiles()
        appendToLog("\nAdded connection profile: \(profile.server):\(profile.localPort).\n")
    }

    private func removeSelectedProfile() {
        guard tunnelState.profiles.count > 1,
              let currentID = tunnelState.selectedProfileID,
              let index = tunnelState.profiles.firstIndex(where: { $0.id == currentID })
        else { return }

        let removed = tunnelState.profiles.remove(at: index)
        tunnelState.selectedProfileID = tunnelState.profiles[min(index, tunnelState.profiles.count - 1)].id
        applySelectedProfile()
        saveProfiles()
        appendToLog("\nRemoved connection profile: \(removed.server):\(removed.localPort).\n")
    }

    private func nextAvailablePort() -> String {
        let used = Set(tunnelState.profiles.compactMap { Int($0.localPort) })
        return (1080...1099).first { !used.contains($0) }.map { "\($0)" } ?? "1080"
    }

    private func saveDirectDomains() {
        tunnelState.directDomains = tunnelState.directDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(tunnelState.directDomains, forKey: Keys.directDomains)
        appendToLog("\nSaved \(tunnelState.directDomains.count) direct domains. Restart proxy to regenerate PAC rules.\n")
    }

    private func saveSkipProxyConfirmations() {
        UserDefaults.standard.set(tunnelState.skipProxyConfirmations, forKey: Keys.skipProxyConfirmations)
    }

    private func resetDirectDomains() {
        tunnelState.directDomains = Self.defaultDirectDomains
        UserDefaults.standard.set(tunnelState.directDomains, forKey: Keys.directDomains)
        appendToLog("\nReset direct domains to defaults. Restart proxy to regenerate PAC rules.\n")
    }

    private func replaceNaiveBinary(sourceURL: URL) {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            guard !tunnelState.isRunning else {
                appendToLog("\nStop the proxy before replacing the binary.\n"); return
            }
            guard sourceURL.isFileURL,
                  (try sourceURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            else {
                appendToLog("\nInvalid binary: choose a regular executable file.\n"); return
            }

            let supportURL = appSupportDirectoryURL()
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

            let destinationURL = supportURL.appendingPathComponent("naive-custom")
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)

            tunnelState.customBinaryPath = destinationURL.path
            UserDefaults.standard.set(tunnelState.customBinaryPath, forKey: Keys.customBinaryPath)
            appendToLog("\nReplaced Naive binary: \(tunnelState.customBinaryPath)\nRestart proxy to use the new binary.\n")
        } catch {
            appendToLog("\nFailed to replace Naive binary: \(error.localizedDescription)\n")
        }
    }
}

// MARK: - Configuration & File I/O

extension ContentView {
    private func appSupportDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.appSupportDirectoryName, isDirectory: true)
    }

    private func writeConfig() throws -> URL {
        guard let safeServer = validatedServerString(),
              let safePort = validatedPortString()
        else { throw CocoaError(.fileWriteInvalidFileName) }

        let safeUsername = percentEncodedCredential(tunnelState.username.trimmingCharacters(in: .whitespacesAndNewlines))
        let safePassword = percentEncodedCredential(tunnelState.password.trimmingCharacters(in: .whitespacesAndNewlines))

        let configObject = [
            "listen": "socks://127.0.0.1:\(safePort)",
            "proxy": "https://\(safeUsername):\(safePassword)@\(safeServer)"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: configObject, options: [.prettyPrinted, .sortedKeys])

        let supportURL = appSupportDirectoryURL()
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let configURL = supportURL.appendingPathComponent(Self.configFileName)
        try jsonData.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return configURL
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
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let pacURL = supportURL.appendingPathComponent(Self.pacFileName)
        try pac.write(to: pacURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pacURL.path)
        return pacURL
    }

    private func directDomainsJavaScriptArray() -> String {
        let cleaned = tunnelState.directDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    private func removeSensitiveRuntimeFiles() {
        let configURL = appSupportDirectoryURL().appendingPathComponent(Self.configFileName)
        try? FileManager.default.removeItem(at: configURL)
    }
}

// MARK: - Validation

extension ContentView {
    private func validatedPortString() -> String? {
        let candidate = tunnelState.localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(candidate), (1...65535).contains(port) else { return nil }
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
              !candidate.contains("#")
        else { return nil }

        if let sep = candidate.lastIndex(of: ":") {
            let host = String(candidate[..<sep])
            let portStr = String(candidate[candidate.index(after: sep)...])
            guard !host.isEmpty, let port = Int(portStr), (1...65535).contains(port) else { return nil }
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
        let server = validatedServerString() ?? tunnelState.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = tunnelState.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return "https://\(username):********@\(server)"
    }
}

// MARK: - Helpers

extension ContentView {
    private func currentNaiveBinaryURL() -> URL? {
        if !tunnelState.customBinaryPath.isEmpty {
            let url = URL(fileURLWithPath: tunnelState.customBinaryPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let url = Bundle.main.url(forResource: "naive", withExtension: nil),
           url.path.contains("Resources") {
            return url
        }
        return Bundle.main.url(forResource: "naive", withExtension: nil)
    }

    private func fileSize(at path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64
        else { return "unknown" }
        return Self.byteCountFormatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Model Types

private struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

private struct ProxyCommandResult: Sendable {
    let success: Bool
    let output: String
}

private enum ActiveProxyMode: Sendable {
    case stopped, smart, global, localOnly

    var title: String {
        switch self {
        case .stopped:  return "Stopped"
        case .smart:    return "Smart Mode"
        case .global:   return "Global Proxy"
        case .localOnly: return "Local Only"
        }
    }
}

private enum ProxyTestMode: Sendable {
    case smart, global

    var title: String {
        switch self {
        case .smart:  return "Smart"
        case .global: return "Global"
        }
    }
}

private enum PendingProxyRequest: Sendable {
    case enableGlobal(port: Int)
    case enableSmart(port: Int, pacURLString: String, pacPathForLog: String)
    case disable(nextMode: ActiveProxyMode)
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

private struct ProxyProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var server: String
    var username: String
    var password: String
    var localPort: String

    private enum CodingKeys: String, CodingKey {
        case id, server, username, localPort
    }

    init(id: String, server: String, username: String, password: String, localPort: String) {
        self.id = id; self.server = server; self.username = username
        self.password = password; self.localPort = localPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        server = try c.decode(String.self, forKey: .server)
        username = try c.decode(String.self, forKey: .username)
        password = ""
        localPort = try c.decode(String.self, forKey: .localPort)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(server, forKey: .server)
        try c.encode(username, forKey: .username)
        try c.encode(localPort, forKey: .localPort)
    }

    static let defaultProfile = ProxyProfile(
        id: "default", server: "naive.example.com",
        username: "user", password: "", localPort: "1080"
    )
}

// MARK: - Reusable Views

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
            Text(title).lineLimit(1).minimumScaleFactor(0.78)
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

    private var foregroundColor: Color { isPrimary && !isDisabled ? .white : (isDisabled ? .secondary : .primary) }
    private var backgroundColor: Color {
        isPrimary && !isDisabled ? .accentColor :
            Color(nsColor: isDisabled ? .controlBackgroundColor : .quaternaryLabelColor).opacity(isDisabled ? 0.32 : 0.14)
    }
    private var iconBackground: Color {
        isPrimary && !isDisabled ? .white.opacity(0.18) :
            Color(nsColor: .controlAccentColor).opacity(isDisabled ? 0.08 : 0.12)
    }
    private var borderColor: Color {
        isPrimary && !isDisabled ? .white.opacity(0.18) :
            Color(nsColor: .separatorColor).opacity(0.24)
    }
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
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(profile.username) : \(profile.localPort)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
        }
    }
}

private struct SettingsView: View {
    @Binding var directDomains: [String]
    @Binding var customBinaryPath: String
    @Binding var skipProxyConfirmations: Bool

    let onSaveDomains: () -> Void
    let onReplaceBinary: (URL) -> Void
    let onResetDomains: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var showBinaryImporter = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                headerRow

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        domainsSection
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { binarySection; aboutSection }
                            VStack(alignment: .leading, spacing: 16) { binarySection; aboutSection }
                        }
                        proxyConfirmSection
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(20)
        }
        .frame(width: 680, height: 680)
        .fileImporter(isPresented: $showBinaryImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { onReplaceBinary(url) }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2.bold())
                Text("Tune routing rules and the Cool tunnel proxy engine")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { onSaveDomains(); dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private var domainsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("example.cn or example.com", text: $newDomain).textFieldStyle(.roundedBorder)
                    Button { addDomain() } label: { Label("Add", systemImage: "plus") }
                }
                List {
                    ForEach(directDomains, id: \.self) { Text($0) }
                        .onDelete { offsets in directDomains.remove(atOffsets: offsets); onSaveDomains() }
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button { onSaveDomains() }  label: { Label("Save Domains", systemImage: "checkmark") }
                    Button { onResetDomains() } label: { Label("Reset Defaults", systemImage: "arrow.counterclockwise") }
                }
            }
            .padding(6)
        } label: {
            Label("Direct domains for Smart Start mode", systemImage: "globe.asia.australia")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private var binarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(customBinaryPath.isEmpty ? "Using bundled naive binary." : customBinaryPath)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Button { showBinaryImporter = true } label: {
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
                infoRow("Version", value: appVersion, monospaced: true)
                infoRow("Creator", value: "Nick")
                Divider()
                TechStackRow(label: "App",    value: "SwiftUI macOS")
                TechStackRow(label: "Core",   value: "Foundation, Process, UserDefaults")
                TechStackRow(label: "Proxy",  value: "Cool tunnel, SOCKS5, Smart PAC")
                TechStackRow(label: "System", value: "networksetup, lsof, curl")
                TechStackRow(label: "UI",     value: "Material cards, adaptive grid, live logs")
                Divider()
                Text("Technology power").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                TechnologyLink(title: "NaiveProxy",  subtitle: "Proxy engine",            url: "https://github.com/klzgrad/naiveproxy/tree/master")
                TechnologyLink(title: "Debian",      subtitle: "Server operating system", url: "https://www.debian.org/")
                TechnologyLink(title: "Vultr",       subtitle: "Cloud infrastructure",    url: "https://www.vultr.com/")
                TechnologyLink(title: "Cloudflare",  subtitle: "DNS",                     url: "https://www.cloudflare.com/")
            }
            .padding(6)
        } label: {
            Label("About", systemImage: "info.circle").font(.system(size: 14, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var proxyConfirmSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Skip confirmation dialogs for system proxy changes", isOn: $skipProxyConfirmations)
                    .toggleStyle(.switch)
                Text("If enabled, Smart/Global proxy buttons will change macOS network settings without showing a modal warning each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("System proxy confirmations", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(monospaced ? .system(.caption, design: .monospaced).weight(.semibold) : .caption.weight(.semibold))
        }
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !directDomains.contains(domain) else { newDomain = ""; return }
        directDomains.append(domain)
        directDomains.sort()
        newDomain = ""
        onSaveDomains()
    }

    private var appVersion: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.2"
        return v.hasPrefix("rev") ? v : "rev\(v)"
    }
}

private struct TechStackRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
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
                    Image(systemName: "link").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.caption.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Shell Execution

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
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

private actor SystemProxyCommandQueue {
    static let shared = SystemProxyCommandQueue()

    func enableGlobal(port: Int) -> ProxyCommandResult {
        enableGlobalProxyCommand(port: port)
    }

    func enableSmart(port: Int, pacURLString: String) -> ProxyCommandResult {
        enableSmartProxyCommand(port: port, pacURLString: pacURLString)
    }

    func disable() -> ProxyCommandResult {
        disableSystemProxyCommand()
    }
}

// MARK: - Network Setup Commands

nonisolated private func activeNetworkServiceStatic() -> String? {
    let result = runCommandResultStatic("/usr/sbin/networksetup", ["-listallnetworkservices"])
    let services = result.output
        .split(separator: "\n").map(String.init)
        .filter { !$0.hasPrefix("An asterisk") }
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }

    for preferred in ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN", "Ethernet"] {
        if services.contains(preferred) { return preferred }
    }
    return services.first
}

nonisolated private func verifySocksProxyStatic(service: String) -> String {
    "\nCurrent SOCKS proxy state for \(service):\n" +
    runNetworkSetupStatic(arguments: ["-getsocksfirewallproxy", service]).output
}

nonisolated private func verifyAutoProxyStatic(service: String) -> String {
    "\nCurrent auto proxy state for \(service):\n" +
    runNetworkSetupStatic(arguments: ["-getautoproxyurl", service]).output
}

nonisolated private func enableGlobalProxyCommand(port: Int) -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(success: false, output: "\nCould not find an active network service. Open System Settings > Network and check the service name.\n")
    }

    var output = "\nEnabling SOCKS proxy for service: \(service)\n"
    let pacOff   = runNetworkSetupStatic(arguments: ["-setautoproxystate",       service, "off"])
    let set      = runNetworkSetupStatic(arguments: ["-setsocksfirewallproxy",   service, "127.0.0.1", "\(port)"])
    let stateOn  = runNetworkSetupStatic(arguments: ["-setsocksfirewallproxystate", service, "on"])

    output += pacOff.output + set.output + stateOn.output

    let success = set.exitCode == 0 && stateOn.exitCode == 0
    if success {
        output += "\nGlobal SOCKS proxy enabled on \(service): 127.0.0.1:\(port). All proxy-aware traffic should use SG VPS.\n"
        output += verifySocksProxyStatic(service: service)
    } else {
        output += "\nFailed to enable system SOCKS proxy. Exit codes: \(set.exitCode), \(stateOn.exitCode).\n"
    }
    return ProxyCommandResult(success: success, output: output)
}

nonisolated private func disableSystemProxyCommand() -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(success: false, output: "\nCould not find an active network service. Open System Settings > Network and disable SOCKS manually if needed.\n")
    }

    var output = "\nDisabling SOCKS proxy for service: \(service)\n"
    let socks = runNetworkSetupStatic(arguments: ["-setsocksfirewallproxystate", service, "off"])
    let pac   = runNetworkSetupStatic(arguments: ["-setautoproxystate",          service, "off"])

    output += socks.output + pac.output

    let success = socks.exitCode == 0 && pac.exitCode == 0
    if success {
        output += "\nSystem proxy disabled on \(service).\n"
        output += verifySocksProxyStatic(service: service)
        output += verifyAutoProxyStatic(service: service)
    } else {
        output += "\nFailed to fully disable system proxy. Exit codes: \(socks.exitCode), \(pac.exitCode).\n"
    }
    return ProxyCommandResult(success: success, output: output)
}

nonisolated private func enableSmartProxyCommand(port: Int, pacURLString: String) -> ProxyCommandResult {
    guard let service = activeNetworkServiceStatic() else {
        return ProxyCommandResult(success: false, output: "\nCould not find an active network service. Smart proxy was not enabled.\n")
    }

    var output = "\nEnabling smart PAC proxy for service: \(service)\n"
    let socksOff = runNetworkSetupStatic(arguments: ["-setsocksfirewallproxystate", service, "off"])
    let pacSet   = runNetworkSetupStatic(arguments: ["-setautoproxyurl",            service, pacURLString])
    let pacOn    = runNetworkSetupStatic(arguments: ["-setautoproxystate",          service, "on"])

    output += socksOff.output + pacSet.output + pacOn.output

    let success = pacSet.exitCode == 0 && pacOn.exitCode == 0
    if success {
        output += "\nSmart proxy enabled on \(service).\n"
        output += "China/common mainland domains go DIRECT. Other traffic uses SG VPS through SOCKS 127.0.0.1:\(port).\n"
        output += verifySocksProxyStatic(service: service)
        output += verifyAutoProxyStatic(service: service)
    } else {
        output += "\nFailed to enable smart proxy. Exit codes: \(pacSet.exitCode), \(pacOn.exitCode).\n"
    }
    return ProxyCommandResult(success: success, output: output)
}

// MARK: - Traffic Inspection

nonisolated private func inspectNaiveTraffic(pid: Int32, localPort: String) -> TrafficInspection {
    let maxEstablished   = 160
    let maxLocalClients  = 120
    let maxRemote        = 32

    let result = runCommandResultStatic("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP"])

    var lines = [String]()
    var established = 0, localClients = 0, remote = 0
    var exposedListenLine: String?

    let clientPattern = "127.0.0.1:\(localPort)->127.0.0.1:"
    let listenPattern = "127.0.0.1:\(localPort)"
    let ipv6Pattern   = "[::1]:\(localPort)"
    let portPattern   = ":\(localPort)"

    for sub in result.output.split(separator: "\n") {
        let isEstablished = sub.contains("ESTABLISHED")
        let isListening   = sub.contains("LISTEN")
        guard isEstablished || isListening else { continue }

        let line = String(sub)
        lines.append(line)

        if isEstablished {
            established += 1
            if line.contains(clientPattern) { localClients += 1 }
            if line.contains("->") && !line.contains("127.0.0.1") { remote += 1 }
        } else if exposedListenLine == nil,
                  line.contains(portPattern),
                  !line.contains(listenPattern),
                  !line.contains(ipv6Pattern) {
            exposedListenLine = line
        }
    }

    let abnormalReason: String?
    if let exposed = exposedListenLine {
        abnormalReason = "NaiveProxy is listening outside localhost: \(exposed)"
    } else if established > maxEstablished {
        abnormalReason = "too many active connections (\(established) > \(maxEstablished))"
    } else if localClients > maxLocalClients {
        abnormalReason = "too many local client connections (\(localClients) > \(maxLocalClients))"
    } else if remote > maxRemote {
        abnormalReason = "too many remote socket connections (\(remote) > \(maxRemote))"
    } else {
        abnormalReason = nil
    }

    return TrafficInspection(
        snapshot: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n",
        establishedConnections: established,
        localClientConnections: localClients,
        remoteConnections: remote,
        abnormalReason: abnormalReason
    )
}

// MARK: - Latency Testing

nonisolated private func runLatencyTest(url: String, proxyPort: String?) -> String {
    var args = ["-L", "-o", "/dev/null", "-sS", "--connect-timeout", "5", "--max-time", "12"]
    if let port = proxyPort { args += ["-x", "socks5h://127.0.0.1:\(port)"] }
    args += [
        "-w", "http_code=%{http_code}\\nremote_ip=%{remote_ip}\\ntime_namelookup=%{time_namelookup}\\ntime_connect=%{time_connect}\\ntime_appconnect=%{time_appconnect}\\ntime_starttransfer=%{time_starttransfer}\\ntime_total=%{time_total}\\n",
        url
    ]

    let start  = Date()
    let result = runCommandResultStatic("/usr/bin/curl", args)
    let wallMs = Int(Date().timeIntervalSince(start) * 1000)
    let m      = parseCurlMetrics(result.output)

    return """
    URL: \(url)
    HTTP: \(m["http_code"] ?? "n/a")
    Remote IP: \(m["remote_ip"] ?? "n/a")
    DNS: \(secondsStringToMs(m["time_namelookup"])) ms
    TCP connect: \(secondsStringToMs(m["time_connect"])) ms
    TLS ready: \(secondsStringToMs(m["time_appconnect"])) ms
    First byte: \(secondsStringToMs(m["time_starttransfer"])) ms
    Total: \(secondsStringToMs(m["time_total"])) ms
    Wall clock: \(wallMs) ms
    Exit code: \(result.exitCode)

    """
}

nonisolated private func parseCurlMetrics(_ output: String) -> [String: String] {
    output.split(separator: "\n").reduce(into: [:]) { dict, line in
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { dict[String(parts[0])] = String(parts[1]) }
    }
}

nonisolated private func secondsStringToMs(_ value: String?) -> Int {
    guard let v = value, let s = Double(v) else { return -1 }
    return Int((s * 1000).rounded())
}

// MARK: - Time Formatting

private let shortTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private func shortTimeString() -> String {
    shortTimeFormatter.string(from: Date())
}

// MARK: - Preview

#Preview { ContentView() }

// MARK: - UX Stress Runner (Debug)

extension ContentView {
    @MainActor
    fileprivate func runUXStressSwitching() async {
        // Stress goal: reproduce “user repeatedly switching button functions” without touching
        // macOS network settings or spawning processes. This targets UI stalls/re-renders/log spam.
        let iterations = 1800
        let delayNs: UInt64 = 9_000_000 // ~9ms (higher pressure than a frame)

        appendToLog("\n[Stress] Starting rapid switching (\(iterations) iterations)...\n")

        let clock = ContinuousClock()
        let start = clock.now
        var last = start
        var hitchesOver50ms = 0
        var worstMs = 0
        var injectedProfileCount = 0

        func durationMs(_ d: Duration) -> Int {
            let s = Double(d.components.seconds) * 1000
            let msFromAttos = Double(d.components.attoseconds) / 1e15
            return Int((s + msFromAttos).rounded())
        }

        for n in 1...iterations {
            if Task.isCancelled { break }

            // Simulate fast user toggles across the common buttons:
            // - start/stop (UI state flips only)
            // - smart/global/restore (mode + modeChanging)
            switch n % 6 {
            case 0:
                // "Start Smart Mode" (UI-only simulation)
                tunnelState.isRunning = true
                tunnelState.activeProxyMode = .smart
                appendToLog("[Stress] start -> Smart\n")
            case 1:
                // "Enable Global Proxy" (modeChanging flip)
                tunnelState.isModeChanging = true
                tunnelState.activeProxyMode = .global
                tunnelState.isModeChanging = false
                appendToLog("[Stress] switch -> Global\n")
            case 2:
                // "Restore macOS Proxy" (back to local only)
                tunnelState.isModeChanging = true
                tunnelState.activeProxyMode = .localOnly
                tunnelState.isModeChanging = false
                appendToLog("[Stress] restore -> Local Only\n")
            case 3:
                // "Timeout Test" flag flicker
                tunnelState.isTestRunning = true
                tunnelState.isTestRunning = false
            case 4:
                // Profile switching pressure (simulate user clicking profile list rapidly)
                if tunnelState.profiles.count < 6, injectedProfileCount < 5 {
                    injectedProfileCount += 1
                    tunnelState.profiles.append(ProxyProfile(
                        id: UUID().uuidString,
                        server: "stress-\(injectedProfileCount).example.com",
                        username: "u\(injectedProfileCount)",
                        password: "",
                        localPort: "\(1080 + injectedProfileCount)"
                    ))
                }
                if let random = tunnelState.profiles.randomElement() {
                    tunnelState.selectedProfileID = random.id
                }
            default:
                // "Stop"
                tunnelState.isRunning = false
                tunnelState.activeProxyMode = .stopped
            }

            // Extra logging bursts to test log view pressure.
            if n % 25 == 0 {
                for i in 0..<10 {
                    appendToLog("[Stress] burst \(n).\(i) mode=\(tunnelState.activeProxyMode.title)\n")
                }
            }
            if n % 240 == 0 { clearLogs() }

            let now = clock.now
            let delta = last.duration(to: now)
            let deltaMs = durationMs(delta)
            if deltaMs > 50 {
                hitchesOver50ms += 1
                worstMs = max(worstMs, deltaMs)
            }
            last = now

            try? await Task.sleep(nanoseconds: delayNs)
        }

        let elapsed = start.duration(to: clock.now)
        let elapsedMs = durationMs(elapsed)

        appendToLog("\n[Stress] Done. elapsed=\(elapsedMs)ms, hitches(>50ms)=\(hitchesOver50ms), worst=\(worstMs)ms\n")
    }
}
