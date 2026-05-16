// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/StringExtensions.swift
//
// Small string helpers used across the orchestrator + form views.
// Keep this file narrow — additions should match an established
// duplication pattern in the codebase, not speculative
// general-purpose helpers.

import Foundation

extension String {

    /// `true` when the string is empty or contains only whitespace
    /// and newline characters. Mirrors the bash-style "non-empty
    /// after trim" guard that user-facing form fields rely on:
    /// pasted credentials and subscription URLs that pick up a
    /// trailing newline shouldn't pass an emptiness check just
    /// because the visible content is non-empty.
    ///
    /// Trimming character set is `.whitespacesAndNewlines` —
    /// deliberately broader than `.whitespaces` so a pasted line
    /// with an embedded `\n` doesn't slip through as "non-blank".
    ///
    /// Callers in `Protocol.swift` that use `.whitespaces`-only
    /// trimming for credential validation **don't** use this
    /// helper — they preserve the narrower character set on
    /// purpose (a newline mid-credential is itself the bug we
    /// want to surface there, not paper over).
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
