#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 coolwhite LLC
# See LICENSE for full terms.
#
# .claude/hooks/session-start.sh — install Linux-installable
# dev-loop tooling so `bin/ct preflight` and `bin/ct audit` can
# run in Claude Code on the web sessions.
#
# Apple-only tools (xcrun, swift-format, xcodebuild, lipo) cannot
# be installed on Linux; the audit gates `requireOrSkip` them, but
# `bin/ct preflight` requires xcrun by design — that gate will
# always be macOS-only.

set -euo pipefail

# Only run in remote (web) sessions; locally the user owns their env.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

# Install shellcheck (required by preflight, installed by CI via apt).
# `apt-get update` is best-effort — third-party PPAs on the image can
# 403, but cached package lists are usually enough for the install.
if ! command -v shellcheck >/dev/null 2>&1; then
    sudo apt-get update -qq || true
    sudo apt-get install -y -qq shellcheck
fi

# Not installed here: cargo-deny (needs git-fetch of the RustSec
# advisory DB, which the web sandbox network policy blocks),
# swift-format / xcodebuild / lipo / xcrun (Apple-only). The audit
# script `requireOrSkip`s the latter four; preflight requires xcrun
# unconditionally and remains a macOS-only gate by design.
