// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/BinaryInspector.swift
//
// Stateless utility that owns the four subprocess + verification
// helpers shared between `SingboxBinaryResolver` and
// `RustCoreResolver`. Pre-extraction, both files carried near-
// verbatim copies of every helper here — same flow, same timeout,
// same regex shape, only the binary name in the version pattern
// differed. Lifting them keeps the single-source-of-truth posture
// `LipoOutputParser` (PR #69) already established for `lipo`
// output parsing.
//
// All helpers are async (subprocess work) and swallow failures
// into nil/false/empty — callers decide how to surface them. The
// resolvers' typed errors are still raised at the resolver layer.

import Foundation

public enum BinaryInspector {

    /// Spawns `lipo -info <path>` and parses the output through
    /// `LipoOutputParser`. Returns an empty set if `lipo` failed,
    /// the file isn't a Mach-O, or no recognised arch was named.
    /// Identical to the pre-lift `SingboxBinaryResolver.runLipoInfo`
    /// and `RustCoreResolver.runLipoInfo`.
    static func runLipoInfo(at url: URL) async -> Set<String> {
        let result = await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-info", url.path]
        )
        guard let output = result else { return [] }
        return LipoOutputParser.parse(output)
    }

    /// Runs the candidate binary with `--version` and returns the
    /// first line of output matching `<binaryName> <semver>`, or
    /// `nil` otherwise.
    ///
    /// Validates the shape (`<name>` followed by whitespace and a
    /// 1-4-segment dotted numeric version with optional pre-release
    /// suffix) rather than trusting whatever the subprocess prints.
    /// A misbehaving binary could otherwise emit an error message
    /// containing a config path, a Mach-O load error pointing at a
    /// private framework, or an attacker-controlled string — all of
    /// which would land verbatim in the Settings view's monospaced
    /// "Version" row.
    ///
    /// `binaryName` is the leading literal token the regex anchors
    /// on — `"sing-box"` or `"cool-tunnel-core"` today. Caller
    /// must pass a value that's safe to embed in a regex (the
    /// resolvers pass compile-time string literals; this is not
    /// an external input).
    static func runVersion(
        at url: URL,
        binaryName: String
    ) async -> String? {
        // Upstream binaries disagree on how to ask for their version:
        //
        //   - clap-based binaries (cool-tunnel-core, naive) use the
        //     `--version` long flag, by convention.
        //   - SagerNet/sing-box uses the `version` subcommand
        //     (`sing-box version`) and prints nothing for `--version`.
        //     Passing `--version` against sing-box was a v3.0.0
        //     regression caught only when users opened Settings →
        //     sing-box: the binary loaded, signed, archs all green,
        //     but the version row read "(no `version` output)" and
        //     the verdict pill flipped to NG.
        //
        // Per-binary argv table keeps the call sites unchanged.
        let arguments: [String]
        switch binaryName {
        case "sing-box":
            arguments = ["version"]
        default:
            arguments = ["--version"]
        }
        let output = await runProcess(executable: url, arguments: arguments)
        guard let raw = output else { return nil }
        // sing-box prints `sing-box version 1.13.12` on the first
        // line plus an `Environment:` / `Tags:` tail; cool-tunnel-
        // core prints `cool-tunnel-core 3.0.0`. Same regex shape
        // for both — anchored on the binary name + a 1-4-segment
        // dotted-numeric version with optional pre-release suffix.
        // The optional ` version` literal between name and number
        // matches sing-box's output without the regex tripping on
        // cool-tunnel-core (which omits the word).
        let pattern = #"^\#(binaryName)(\s+version)?\s+\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?\s*$"#
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return trimmed
            }
        }
        return nil
    }

    /// Returns whether `CodeSignVerifier` accepts the binary.
    /// Swallows the typed error because the descriptor stores a
    /// plain Bool; callers re-run the verifier to extract the
    /// `OSStatus` when they need the typed error path.
    static func checkSignature(at url: URL) async -> Bool {
        do {
            try await CodeSignVerifier.verifyValid(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Generic subprocess runner: collects stdout+stderr into one
    /// string, returns `nil` if the process could not be launched
    /// at all. Tolerates non-zero exit codes — `sing-box version`
    /// and `cool-tunnel-core --version` both exit 0 in practice,
    /// but even a non-zero exit accompanied by a version line is
    /// still informative for the UI.
    ///
    /// Routed through `Subprocess.run` so a wedged `lipo` or
    /// `<binary> --version` can't freeze inspection. 10-second
    /// timeout: both helpers typically return in <100 ms; 10s is
    /// generous slack for disk slowness without keeping the user
    /// waiting on a stuck binary.
    static func runProcess(
        executable: URL,
        arguments: [String]
    ) async -> String? {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(
                executable: executable,
                arguments: arguments,
                timeout: 10
            )
        } catch {
            return nil
        }
        return result.stdout.isEmpty ? result.stderr : result.stdout
    }
}
