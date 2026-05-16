// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/cargo.test.ts — tests for the Cargo + rust-toolchain
// parsers. Tests rehomed from package_release.test.ts +
// security_check.test.ts when the parsers moved to scripts/lib/.

import { describe, expect, test } from "bun:test";

import {
    parseCargoTomlVersion,
    parseLockfileVersion,
    parseToolchainChannel,
} from "./cargo.ts";

describe("lib/cargo parseCargoTomlVersion", () => {
    test("top-level version line → extracted", () => {
        const toml = '[package]\nname = "cool-tunnel-core"\nversion = "2.0.59"\nedition = "2024"\n';
        expect(parseCargoTomlVersion(toml)).toBe("2.0.59");
    });

    test("dependency table version line → first anchored match wins", () => {
        const toml = '[dependencies.serde]\nversion = "1.0"\n[package]\nname = "x"\nversion = "2.0.59"\n';
        expect(parseCargoTomlVersion(toml)).toBe("1.0");
    });

    test("indented version line → not anchored, skipped", () => {
        const toml = '[dependencies]\n    version = "9.9.9"\n[package]\nversion = "2.0.59"\n';
        expect(parseCargoTomlVersion(toml)).toBe("2.0.59");
    });

    test("missing version → null", () => {
        const toml = '[package]\nname = "x"\nedition = "2024"\n';
        expect(parseCargoTomlVersion(toml)).toBeNull();
    });

    test("whitespace tolerated around =", () => {
        const toml = 'version   =   "1.2.3"\n';
        expect(parseCargoTomlVersion(toml)).toBe("1.2.3");
    });
});

describe("lib/cargo parseLockfileVersion", () => {
    test("standard Cargo.lock entry → version extracted", () => {
        const lock =
            '[[package]]\n' +
            'name = "serde"\n' +
            'version = "1.0.197"\n' +
            'source = "registry+..."\n\n' +
            '[[package]]\n' +
            'name = "cool-tunnel-core"\n' +
            'version = "2.0.59"\n';
        expect(parseLockfileVersion(lock, "cool-tunnel-core")).toBe("2.0.59");
    });

    test("missing package → null", () => {
        const lock =
            '[[package]]\nname = "other"\nversion = "1.0"\n';
        expect(parseLockfileVersion(lock, "cool-tunnel-core")).toBeNull();
    });

    test("first occurrence wins on duplicate name lines", () => {
        const lock =
            'name = "x"\n' +
            'version = "1.0"\n' +
            'name = "x"\n' +
            'version = "2.0"\n';
        expect(parseLockfileVersion(lock, "x")).toBe("1.0");
    });

    test("name line not followed by a quoted line → null", () => {
        const lock = 'name = "x"\n# end of file\n';
        expect(parseLockfileVersion(lock, "x")).toBeNull();
    });
});

describe("lib/cargo parseToolchainChannel", () => {
    test("standard pin → extracted", () => {
        const toml = '[toolchain]\nchannel = "1.95.0"\nprofile = "minimal"\n';
        expect(parseToolchainChannel(toml)).toBe("1.95.0");
    });

    test("whitespace tolerated around =", () => {
        expect(parseToolchainChannel('channel   =   "stable"\n')).toBe("stable");
    });

    test("missing channel → null", () => {
        expect(parseToolchainChannel('profile = "minimal"\n')).toBeNull();
    });

    test("indented channel → not anchored, null", () => {
        expect(parseToolchainChannel('    channel = "x"\n')).toBeNull();
    });
});
