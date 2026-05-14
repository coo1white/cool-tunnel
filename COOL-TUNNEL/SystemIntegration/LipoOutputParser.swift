// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/LipoOutputParser.swift
//
// Pure parser for `lipo -info` output, extracted from
// `NaiveBinaryResolver` and `RustCoreResolver` where the same
// colon-split + tokenize + known-arch filter logic was duplicated
// near-verbatim. Both resolvers now delegate the parse step here so:
//
//   - the parse rules are stated once,
//   - the parser is unit-testable without spawning subprocesses,
//   - a future change to `lipo`'s output format (or to the known-arch
//     allow-list) lands in one place, not two.
//
// `lipo -info` emits two formats depending on whether the file is
// thin or fat:
//
//   Non-fat file: <path> is architecture: arm64
//   Architectures in the fat file: <path> are: x86_64 arm64
//
// Either way the architecture tokens follow the **last** colon on
// the line. Splitting on `:` and taking `.last` gives us the tail in
// both cases. The defensive allow-list (`knownArchitectures`)
// protects the UI from rendering whatever junk a future `lipo`
// might add — only canonical macOS slice names propagate.

import Foundation

/// Pure parser surface for `lipo -info` output. No subprocess
/// invocation, no file I/O, no `async`. Public so other macOS
/// binary-inspection paths (current or future) can reuse the
/// same allow-list discipline.
public enum LipoOutputParser {

    /// Architecture names this client knows how to act on. A token
    /// outside this set is silently dropped — `lipo` evolving to
    /// emit a new annotation (`ptrauth`, `arm64_32`, etc.) must
    /// not leak into the UI or affect the universal-binary
    /// invariant the release-cutter enforces.
    ///
    /// Set type rather than array so membership checks are O(1)
    /// — the parser hot-path is per-token contains.
    public static let knownArchitectures: Set<String> = [
        "arm64",
        "arm64e",
        "x86_64",
        "i386",
    ]

    /// Parses `lipo -info` stdout into a set of recognised arch
    /// names. Returns `[]` for empty / malformed / colonless input
    /// so callers can treat the empty-set case as "not a Mach-O"
    /// without distinguishing parse failure from a genuine empty
    /// slice list (the latter doesn't exist in practice; a real
    /// Mach-O always names at least one arch after the colon).
    ///
    /// - Parameter output: Raw stdout from `lipo -info <path>`.
    ///   Tolerant of trailing whitespace, mixed thin/fat shapes,
    ///   and unknown-arch annotations.
    /// - Returns: The set of recognised architectures named in
    ///   the output, filtered against `knownArchitectures`.
    public static func parse(_ output: String) -> Set<String> {
        guard !output.isEmpty else { return [] }
        guard
            let tail =
                output
                .components(separatedBy: ":")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !tail.isEmpty
        else {
            return []
        }
        let tokens = tail.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return Set(tokens.filter { knownArchitectures.contains($0) })
    }
}
