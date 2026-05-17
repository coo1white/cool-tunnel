// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Domain value types with construction-time validation.
//!
//! Every type in this module makes invalid states unrepresentable: a
//! [`Port`] can never be zero, a [`ServerAddress`] can never contain a
//! scheme or whitespace, [`Credentials`] always carry a valid UUID and
//! a valid Reality block.
//!
//! All types implement `serde::Serialize` and `serde::Deserialize` so they
//! flow over the wire protocol unchanged. Deserialization runs the same
//! validation as direct construction — there is no "raw, unvalidated"
//! variant that can leak past this boundary.

pub mod credentials;
pub mod port;
pub mod profile;
pub mod proxy_mode;
pub mod server;

pub use credentials::{
    Credentials, InvalidCredentials, RawReality, Reality, RealityDestHost, RealityPublicKey,
    RealityShortId, Username, Uuid,
};
pub use port::{InvalidPort, Port};
pub use profile::{Profile, ProfileId, RawProfile, ValidationError};
pub use proxy_mode::{ProxyMode, ProxyTestMode};
pub use server::{InvalidServer, ServerAddress};
