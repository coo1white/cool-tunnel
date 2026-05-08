// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/UpdaterError.swift
//
// Shared error type for the three Cool Tunnel updaters
// (`AppUpdater`, `NaiveUpdater`, `RustCoreUpdater`). Prior
// to v0.1.7.15 each updater had its own error enum with the
// same shape:
//
//   - AppUpdater.UpdaterError       (nested in class)
//   - NaiveUpdater.UpdaterError     (file-scope, naive's file)
//   - RustCoreUpdater.RustUpdaterError (file-scope, rust's file)
//
// All three were `enum X: Error, Sendable, Equatable {
// case message(String) }` — pure code duplication. The
// architectural review (ARCH-F#1) flagged this; this module
// is the single source of truth.

import Foundation

/// User-facing pipeline error raised by any of the three Cool
/// Tunnel updaters. The single `message(String)` variant carries
/// a sentence that the Settings UI surfaces verbatim via
/// `state = .failed(message: …)`.
///
/// String content rules (across all updaters):
///   - Plain English; assume non-technical reader.
///   - No file paths or attacker-influenced bytes — those go
///     to `os.Logger` only (per AU-2 / AU-7 / AU-8 hardening).
///   - End with a recovery action where one exists ("Try Update
///     again", "Drag to Applications", etc.).
enum UpdaterError: Error, Sendable, Equatable {
    case message(String)
}
