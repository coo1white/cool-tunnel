// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/LipoOutputParserTests.swift
//
// Pure-parser coverage for the `lipo -info` output handler shared
// by `SingboxBinaryResolver` and `RustCoreResolver`. Both resolvers
// previously embedded the same colon-split + tokenize + known-arch
// filter logic near-verbatim; pulling the parser out closed a
// duplicated-helper smell AND opened a unit-testable surface that
// doesn't require spawning subprocesses or fabricating Mach-O
// binaries on disk.
//
// Every documented `lipo -info` output shape gets one test that
// names the shape it covers. The defensive allow-list against
// unknown arch annotations also gets explicit coverage — a
// future `lipo` update that adds a new annotation type shouldn't
// leak into the UI or the universal-binary invariant.

import XCTest

@testable import Cool_Tunnel

final class LipoOutputParserTests: XCTestCase {

    // MARK: - Thin (non-fat) binary forms

    /// `lipo -info <path>` on an arm64-only binary emits:
    ///   `Non-fat file: <path> is architecture: arm64`
    func testParsesNonFatArm64() {
        let out = "Non-fat file: /usr/bin/sing-box is architecture: arm64"
        XCTAssertEqual(LipoOutputParser.parse(out), ["arm64"])
    }

    /// Pair to the above for x86_64-only thin binaries.
    func testParsesNonFatX8664() {
        let out = "Non-fat file: /usr/bin/sing-box is architecture: x86_64"
        XCTAssertEqual(LipoOutputParser.parse(out), ["x86_64"])
    }

    /// `arm64e` is the pointer-auth ABI shipped on every Apple Silicon
    /// system shared library. Recognise it in the allow-list so a
    /// future bundled binary that picks it up doesn't get silently
    /// dropped.
    func testParsesNonFatArm64e() {
        let out = "Non-fat file: /usr/lib/dyld is architecture: arm64e"
        XCTAssertEqual(LipoOutputParser.parse(out), ["arm64e"])
    }

    /// `i386` is recognised for completeness — no actively shipped
    /// Cool Tunnel binary needs it, but the allow-list pinning means
    /// a future arm64-removed-x86_64-only-i386-only deployment
    /// doesn't fail parsing if it ever happens.
    func testParsesNonFatI386() {
        let out = "Non-fat file: /old/foo is architecture: i386"
        XCTAssertEqual(LipoOutputParser.parse(out), ["i386"])
    }

    // MARK: - Fat (universal) binary forms

    /// The shape `cut_release.sh` enforces for every Cool Tunnel
    /// release artifact:
    ///   `Architectures in the fat file: <path> are: x86_64 arm64`
    func testParsesFatUniversalArm64AndX8664() {
        let out =
            "Architectures in the fat file: /Applications/Cool\\ Tunnel.app/Contents/Resources/sing-box are: x86_64 arm64"
        XCTAssertEqual(LipoOutputParser.parse(out), ["x86_64", "arm64"])
    }

    /// Reversed token order — `lipo` doesn't guarantee a stable
    /// arch ordering across hosts. Set semantics absorb the
    /// ordering difference; this test pins that.
    func testParsesFatUniversalRegardlessOfArchOrder() {
        let a = "Architectures in the fat file: /x are: arm64 x86_64"
        let b = "Architectures in the fat file: /x are: x86_64 arm64"
        XCTAssertEqual(LipoOutputParser.parse(a), LipoOutputParser.parse(b))
    }

    // MARK: - Defensive cases

    /// Empty input — the resolver's `runProcess` returns the empty
    /// string when a subprocess produces no stdout (rare but
    /// possible if `lipo` errored on stderr).
    func testReturnsEmptySetForEmptyInput() {
        XCTAssertEqual(LipoOutputParser.parse(""), [])
    }

    /// Whitespace-only input — same case as a `lipo` that printed
    /// only a newline.
    func testReturnsEmptySetForWhitespaceOnlyInput() {
        XCTAssertEqual(LipoOutputParser.parse(" \t\n  "), [])
    }

    /// Output without a colon — defensive against a future `lipo`
    /// format change. The parser splits on `:` and takes `.last`;
    /// a colonless input would return the whole string as `tail`
    /// without our filter, which is exactly what the known-arch
    /// allow-list defends against. This test pins that the
    /// fallback returns the empty set rather than a junk token.
    func testRejectsColonlessOutput() {
        XCTAssertEqual(LipoOutputParser.parse("garbage output"), [])
    }

    /// Trailing whitespace and newlines tolerated. `runProcess`
    /// already trims, but the parser should be robust to its own
    /// inputs in case it's reused outside the resolvers.
    func testTrimsTrailingWhitespace() {
        let out = "Non-fat file: /x is architecture: arm64   \n\n"
        XCTAssertEqual(LipoOutputParser.parse(out), ["arm64"])
    }

    /// Unknown arch tokens are silently dropped. This is the
    /// allow-list discipline — a future `lipo` adding
    /// `ptrauth:arm64e` or an experimental slice name shouldn't
    /// propagate into UI or the universal-binary check.
    func testFiltersOutUnknownArchitectures() {
        let out =
            "Architectures in the fat file: /x are: x86_64 arm64 ptrauth experimental_new_slice"
        XCTAssertEqual(LipoOutputParser.parse(out), ["x86_64", "arm64"])
    }

    /// A line containing ONLY unknown tokens after the colon
    /// returns the empty set (no arch we can act on).
    func testReturnsEmptySetForOnlyUnknownTokens() {
        let out = "Architectures in the fat file: /x are: future_arch_a future_arch_b"
        XCTAssertEqual(LipoOutputParser.parse(out), [])
    }

    /// Multi-line input — `lipo -info` can produce multiple lines
    /// in degenerate cases (e.g. with `lipo -info -arch`). The
    /// parser splits on `:` globally and takes `.last`, so a
    /// trailing line with an arch token wins. We don't try to be
    /// clever about multi-line; pin the actual behavior so a
    /// future change is reviewer-visible.
    func testHandlesMultiLineOutputByTakingFinalColonTail() {
        let out =
            "Architectures in the fat file: /x are: x86_64 arm64\nsome other line: arm64e"
        // The final colon tail is "arm64e".
        XCTAssertEqual(LipoOutputParser.parse(out), ["arm64e"])
    }

    // MARK: - Allow-list invariant

    /// Pinning the allow-list so a refactor that accidentally drops
    /// or adds an arch surfaces in this test. The set is intentionally
    /// small — every entry is a macOS-shipping ABI Cool Tunnel could
    /// plausibly want to support.
    func testKnownArchitecturesAllowListIsExact() {
        XCTAssertEqual(
            LipoOutputParser.knownArchitectures,
            ["arm64", "arm64e", "x86_64", "i386"]
        )
    }
}
