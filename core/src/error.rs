// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Crate-wide error type.
//!
//! [`CoreError`] is the public error returned by every fallible engine
//! operation. It is `#[non_exhaustive]` so new variants can be added without
//! breaking `SemVer`.

use thiserror::Error;

use crate::domain::ValidationError;

/// Errors returned by the core engine.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum CoreError {
    /// A profile failed validation.
    #[error("invalid profile: {0}")]
    InvalidProfile(#[from] ValidationError),

    /// The proxy is already running and another start was requested.
    #[error("proxy is already running")]
    AlreadyRunning,

    /// The proxy is not running and an operation requiring it was requested.
    #[error("proxy is not running")]
    NotRunning,

    /// Spawning the bundled `naive` binary failed.
    #[error("failed to spawn naive binary: {0}")]
    Spawn(#[source] std::io::Error),

    /// Reading or writing on stdio failed.
    #[error("stdio error: {0}")]
    Io(#[from] std::io::Error),

    /// Encoding or decoding a wire-format frame failed.
    #[error("protocol error: {0}")]
    Protocol(#[from] serde_json::Error),
}
