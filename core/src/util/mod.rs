//! Cross-cutting utilities shared by more than one module.
//!
//! Currently the only thing here is [`debounce`], a per-key rate
//! limiter used to keep the monitor loop from spamming the Swift UI
//! with duplicate anomalies when the proxy is flapping.

pub mod debounce;
