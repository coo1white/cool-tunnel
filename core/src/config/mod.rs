//! Pure functions that turn a validated [`crate::domain::Profile`] into the
//! artifacts `NaiveProxy` and macOS need: a JSON config file and a JavaScript
//! PAC file.

pub mod naive_config;
pub mod pac;

pub use naive_config::NaiveConfig;
pub use pac::{DEFAULT_DIRECT_DOMAINS, generate_pac};
