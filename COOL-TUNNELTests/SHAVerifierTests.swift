// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/SHAVerifierTests.swift
//
// Pin the streaming-SHA hash function and the shasum-style
// manifest parser. Both are used by `AppUpdater` and
// `RustCoreUpdater` to verify pinned-hash downloads — a regression
// in either silently weakens the supply-chain check that refuses
// to install artifacts whose bytes don't match the published
// `.sha256` manifest line.

import CryptoKit
import XCTest

@testable import Cool_Tunnel

final class SHAVerifierTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cool-tunnel-sha-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, _ contents: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// One-shot CryptoKit SHA-256 returning lowercase hex, matching
    /// the streaming implementation's output format so the two are
    /// byte-comparable.
    private func oneShotSHA256(_ bytes: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: bytes)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - sha256(of:) — known-vector cases

    /// SHA-256 of the empty string is the documented reference
    /// vector. Streaming through a zero-byte file hits the
    /// `chunk.isEmpty → break` path on the first read.
    func testEmptyFileHashesToReferenceVector() throws {
        let url = try writeFile("empty.bin", Data())
        let hash = try SHAVerifier.sha256(of: url)
        XCTAssertEqual(
            hash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// SHA-256 of `"abc"` — the original FIPS 180-2 reference
    /// vector. Pins byte-level correctness of `hasher.update(data:)`
    /// against UTF-8 input.
    func testAbcHashesToReferenceVector() throws {
        let url = try writeFile("abc.bin", Data("abc".utf8))
        let hash = try SHAVerifier.sha256(of: url)
        XCTAssertEqual(
            hash,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Multi-chunk path: stream a buffer larger than the 64 KiB
    /// chunk size and confirm the hash matches one-shot CryptoKit.
    /// Catches a regression where the loop boundary drops bytes or
    /// double-feeds the final partial chunk.
    func testHashesMultiChunkBufferDeterministically() throws {
        var bytes = Data(count: 200 * 1024)
        bytes.withUnsafeMutableBytes { buffer in
            for i in 0..<buffer.count {
                buffer[i] = UInt8(i & 0xFF)
            }
        }
        let url = try writeFile("multichunk.bin", bytes)
        let streamed = try SHAVerifier.sha256(of: url)
        XCTAssertEqual(
            streamed, oneShotSHA256(bytes),
            "streaming and one-shot SHA must agree")
    }

    /// Trying to hash a file that doesn't exist throws. The
    /// `try FileHandle(forReadingFrom:)` is the canonical failure
    /// site; this test pins that the throw surfaces rather than
    /// being swallowed into an empty-string result.
    func testHashingMissingFileThrows() {
        let url = tempDir.appendingPathComponent("never-existed.bin")
        XCTAssertThrowsError(try SHAVerifier.sha256(of: url))
    }

    // MARK: - expectedHash(for:in:) — manifest parser

    /// Standard `shasum -a 256` output: 64-hex + two spaces +
    /// filename. The asset name matches exactly; the hash comes
    /// back lowercased.
    func testReturnsHashForMatchingAsset() throws {
        let manifest = """
            7d865e959b2466918c9863afca942d0fb89d7c9ac0c99bafc3749504ded97730  Cool-tunnel-v2.0.40.zip
            403c7a3e39e3f3e6537bd999f264c50b3c5e6a9655d2d1edbc050dddce49489b  Cool-tunnel-v2.0.40.dmg
            """
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        let hash = try SHAVerifier.expectedHash(for: "Cool-tunnel-v2.0.40.dmg", in: url)
        XCTAssertEqual(hash, "403c7a3e39e3f3e6537bd999f264c50b3c5e6a9655d2d1edbc050dddce49489b")
    }

    /// Case normalisation: uppercase hex in the manifest comes
    /// back lowercased. CryptoKit emits lowercase; the manifest
    /// compare must work regardless of the `shasum` host's case
    /// convention.
    func testNormalisesHashToLowercase() throws {
        let manifest = "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  foo.zip"
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        let hash = try SHAVerifier.expectedHash(for: "foo.zip", in: url)
        XCTAssertEqual(hash, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
    }

    /// Missing asset → nil, NOT a throw. Callers distinguish
    /// "no manifest line for this filename" from "manifest
    /// unreadable" by error type.
    func testReturnsNilForMissingAsset() throws {
        let manifest = "7d865e959b2466918c9863afca942d0fb89d7c9ac0c99bafc3749504ded97730  other.zip"
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        XCTAssertNil(try SHAVerifier.expectedHash(for: "missing.zip", in: url))
    }

    /// Defensive: a 63-char "hash" is rejected, not returned.
    /// Catches a manifest corrupted in transit — the in-app
    /// updater refuses to verify against a half-hash and report
    /// "all good."
    func testReturnsNilForShortHash() throws {
        let manifest = "deadbeef  foo.zip"
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        XCTAssertNil(try SHAVerifier.expectedHash(for: "foo.zip", in: url))
    }

    /// Defensive: a 64-char field with a non-hex character is
    /// rejected. Catches a bad-edit that would otherwise pass the
    /// length check and trip the string-compare with a misleading
    /// "SHA-256 mismatch" instead of "manifest malformed."
    func testReturnsNilForNonHexHash() throws {
        let bad = String(repeating: "g", count: 64)
        let manifest = "\(bad)  foo.zip"
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        XCTAssertNil(try SHAVerifier.expectedHash(for: "foo.zip", in: url))
    }

    /// First-match-wins on duplicate asset names. The behaviour
    /// is documented in the function's comment; this pins it so
    /// a refactor of the parse loop is reviewer-visible.
    func testFirstMatchWinsOnDuplicateAssetName() throws {
        let manifest = """
            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  dup.zip
            bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  dup.zip
            """
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        let hash = try SHAVerifier.expectedHash(for: "dup.zip", in: url)
        XCTAssertEqual(hash, String(repeating: "a", count: 64))
    }

    /// CR-LF and LF line endings both parse. `shasum` emits LF on
    /// macOS / Linux; if the manifest is ever produced on Windows
    /// or round-tripped through a tool that rewrites line endings,
    /// the parser must keep working.
    func testHandlesCrlfLineEndings() throws {
        let hashHex = String(repeating: "f", count: 64)
        let manifest = "\(hashHex)  foo.zip\r\nignored line"
        let url = try writeFile("manifest.txt", Data(manifest.utf8))
        let hash = try SHAVerifier.expectedHash(for: "foo.zip", in: url)
        XCTAssertEqual(hash, hashHex)
    }

    /// Empty manifest → nil. The reader walks zero lines.
    func testReturnsNilForEmptyManifest() throws {
        let url = try writeFile("manifest.txt", Data())
        XCTAssertNil(try SHAVerifier.expectedHash(for: "anything.zip", in: url))
    }

    /// Missing manifest file → throws. The `try String(contentsOf:)`
    /// is the canonical failure site.
    func testThrowsOnMissingManifestFile() {
        let url = tempDir.appendingPathComponent("never-existed.txt")
        XCTAssertThrowsError(try SHAVerifier.expectedHash(for: "x", in: url))
    }
}
