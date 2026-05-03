// SystemIntegration/HostMachine.swift
//
// Rich snapshot of the running Mac's hardware: CPU brand string,
// performance / efficiency / total core counts, model identifier,
// installed memory. Used by the Settings "This Mac" panel so the
// chip detection row can show "Apple M3 Pro · 12 cores
// (8P + 4E) · 18 GB" instead of just "Apple Silicon".
//
// All fields are read once at app launch via sysctlbyname; the
// values cannot change without a reboot, so we cache and never
// re-query.
//
// Two layers:
//   - `HostArchitecture` (existing) — coarse arm64 / x86_64 / unknown
//     enum the resolver depends on. Unchanged.
//   - `HostMachine` (new) — the user-facing detail block. Strictly
//     additive; the resolver does not depend on any of it.

import Darwin
import Foundation

/// Rich hardware snapshot, populated from sysctl at first access.
public struct HostMachine: Sendable, Equatable {
    /// Coarse CPU architecture — same value as `HostArchitecture.current`.
    public let architecture: HostArchitecture
    /// `machdep.cpu.brand_string`, e.g. "Apple M2", "Apple M3 Max",
    /// or on Intel "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz".
    /// Empty when sysctl returns nothing.
    public let cpuBrand: String
    /// Total logical CPU count (`hw.ncpu`). On Intel includes
    /// hyper-threads; on Apple Silicon equals the physical core count.
    public let logicalCores: Int
    /// Physical CPU core count (`hw.physicalcpu`).
    public let physicalCores: Int
    /// Apple Silicon performance core count
    /// (`hw.perflevel0.physicalcpu`). Zero on Intel and on the rare
    /// older Apple Silicon SKUs that don't expose perflevels.
    public let performanceCores: Int
    /// Apple Silicon efficiency core count
    /// (`hw.perflevel1.physicalcpu`). Zero on Intel.
    public let efficiencyCores: Int
    /// Installed memory in bytes (`hw.memsize`).
    public let memoryBytes: UInt64
    /// Apple model identifier (`hw.model`), e.g. "Mac15,3".
    public let modelIdentifier: String

    /// Cached lookup. The hardware can't change without a reboot, so
    /// we read sysctl once and reuse the snapshot for every Settings
    /// open and every diagnostic.
    public static let current: HostMachine = HostMachine(
        architecture: .current,
        cpuBrand: SysctlReader.string(name: "machdep.cpu.brand_string"),
        logicalCores: SysctlReader.int(name: "hw.ncpu"),
        physicalCores: SysctlReader.int(name: "hw.physicalcpu"),
        performanceCores: SysctlReader.int(name: "hw.perflevel0.physicalcpu"),
        efficiencyCores: SysctlReader.int(name: "hw.perflevel1.physicalcpu"),
        memoryBytes: SysctlReader.uint64(name: "hw.memsize"),
        modelIdentifier: SysctlReader.string(name: "hw.model")
    )

    /// Friendly description of the CPU + cores, e.g.
    /// "Apple M3 Pro · 12 cores (8P + 4E)" on Apple Silicon, or
    /// "Intel Core i7-9750H · 12 cores" on Intel.
    public var cpuSummary: String {
        let brand = cpuBrand.isEmpty ? architecture.displayName : cpuBrand
        let cores: String
        if performanceCores > 0 || efficiencyCores > 0 {
            cores = "\(physicalCores) cores (\(performanceCores)P + \(efficiencyCores)E)"
        } else if physicalCores > 0 {
            cores = "\(physicalCores) cores"
        } else {
            cores = "\(logicalCores) logical cores"
        }
        return "\(brand) · \(cores)"
    }

    /// Memory rendered in human-friendly form, e.g. "18 GB", "8 GB".
    /// Uses `ByteCountFormatter` so the locale's separator is
    /// honoured automatically.
    public var memorySummary: String {
        guard memoryBytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(memoryBytes))
    }
}

// MARK: - sysctl reading helpers

/// Tiny wrapper around `sysctlbyname` so call sites read as
/// `SysctlReader.string("foo")` instead of two-phase pointer dance.
enum SysctlReader {
    /// Reads a NUL-terminated string. Returns "" on any failure
    /// (missing key, non-UTF-8 bytes, empty buffer).
    static func string(name: String) -> String {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        let trimmed = buffer.prefix(while: { $0 != 0 })
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Reads an `Int`. Returns 0 on any failure — the empty-string
    /// pattern doesn't translate cleanly here, and "0 cores" reads as
    /// "I don't know" which is exactly what we want the UI to show.
    static func int(name: String) -> Int {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return 0
        }
        return value
    }

    /// Reads a `UInt64` — used for `hw.memsize`, which on systems
    /// with 4 GB+ would overflow a signed Int on 32-bit builds (we
    /// don't ship those, but better safe).
    static func uint64(name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return 0
        }
        return value
    }
}
