// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// COOL-TUNNELTests/BinaryInspectorTests.swift

import Foundation
import XCTest

@testable import Cool_Tunnel

final class BinaryInspectorTests: XCTestCase {

    func testSingboxVersionUsesVersionSubcommand() async throws {
        let executable = try makeExecutableScript(
            name: "fake-sing-box",
            body: """
                #!/bin/sh
                if [ "$1" = "version" ]; then
                    echo "sing-box version 1.13.12"
                    exit 0
                fi
                echo "unknown flag: $1" >&2
                exit 1
                """
        )

        let version = await BinaryInspector.runVersion(
            at: executable,
            binaryName: "sing-box"
        )

        XCTAssertEqual(version, "sing-box version 1.13.12")
    }

    func testNonSingboxVersionUsesLongVersionFlag() async throws {
        let executable = try makeExecutableScript(
            name: "fake-cool-tunnel-core",
            body: """
                #!/bin/sh
                if [ "$1" = "--version" ]; then
                    echo "cool-tunnel-core 3.0.0"
                    exit 0
                fi
                echo "unknown subcommand: $1" >&2
                exit 1
                """
        )

        let version = await BinaryInspector.runVersion(
            at: executable,
            binaryName: "cool-tunnel-core"
        )

        XCTAssertEqual(version, "cool-tunnel-core 3.0.0")
    }

    private func makeExecutableScript(
        name: String,
        body: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name)
        try body.data(using: .utf8)?.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: url.path),
            file: file,
            line: line
        )
        return url
    }
}
