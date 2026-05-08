// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Cargo build script for `cool-tunnel-core`.
//!
//! Embeds build-time metadata into the binary so `--version` is
//! self-describing for support tickets:
//!
//! ```text
//! $ cool-tunnel-core --version
//! cool-tunnel-core 0.1.7
//! build:    abc1234 2026-05-03 (release)
//! ```
//!
//! The first line is the canonical wire format the Swift
//! `RustCoreResolver` greps for — keep it as
//! `cool-tunnel-core <semver>` so the resolver stays stable.
//! Everything below is pure addition.
//!
//! LTSC posture: we shell out to `git` and `date` rather than
//! pulling in a build-deps crate. Fewer transitive dependencies
//! = fewer surprises across the support window.

use std::process::Command;

/// Cargo build-script entry point. Emits the build SHA + build
/// date as `cargo:rustc-env=...` lines so `main.rs` can read them
/// via `env!()` at compile time.
fn main() {
    let git_sha = capture(&["git", "rev-parse", "--short", "HEAD"]);
    let build_date = capture(&["date", "-u", "+%Y-%m-%d"]);

    println!("cargo:rustc-env=COOL_TUNNEL_BUILD_SHA={git_sha}");
    println!("cargo:rustc-env=COOL_TUNNEL_BUILD_DATE={build_date}");

    // Re-run the build script when HEAD or refs change so the
    // embedded SHA stays accurate. Without this cargo would cache
    // a stale value across commits.
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs");
}

/// Run `program args...`, return the trimmed stdout, or
/// `"unknown"` if anything goes wrong. Build scripts must never
/// fail the build for missing metadata — packaging from a
/// non-git tarball is a legitimate path.
fn capture(command_line: &[&str]) -> String {
    let Some((program, rest)) = command_line.split_first() else {
        return "unknown".to_owned();
    };
    let Ok(output) = Command::new(program).args(rest).output() else {
        return "unknown".to_owned();
    };
    if !output.status.success() {
        return "unknown".to_owned();
    }
    let Ok(text) = String::from_utf8(output.stdout) else {
        return "unknown".to_owned();
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        "unknown".to_owned()
    } else {
        trimmed.to_owned()
    }
}
