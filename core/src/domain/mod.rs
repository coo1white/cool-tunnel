//! Domain value types with construction-time validation.
//!
//! Every type in this module makes invalid states unrepresentable: a
//! [`Port`] can never be zero, a [`ServerAddress`] can never contain a
//! scheme or whitespace, [`Credentials`] can never be empty.
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

pub use credentials::{Credentials, EncodedCredentials, InvalidCredentials, Password, Username};
pub use port::{InvalidPort, Port};
pub use profile::{Profile, ProfileId, RawProfile, ValidationError};
pub use proxy_mode::{ProxyMode, ProxyTestMode};
pub use server::{InvalidServer, ServerAddress};
