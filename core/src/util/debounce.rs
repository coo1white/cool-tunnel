// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Per-key fixed-window debouncer.
//!
//! Filters bursts of identical events down to one per `window` while
//! letting a *new* key through immediately. The window is fixed-time:
//! every probe inside it is dropped, then the first probe outside
//! wins. Used by [`crate::monitor`] to collapse flapping-anomaly
//! storms.
//!
//! Memory bound: `HashMap<K, Instant>`. [`admit`](Debouncer::admit)
//! runs a lazy prune past [`PRUNE_THRESHOLD`] entries, dropping keys
//! older than `2 × window`.
//!
//! # Example
//!
//! ```
//! use std::time::{Duration, Instant};
//! use cool_tunnel_core::util::debounce::Debouncer;
//!
//! let mut d = Debouncer::new(Duration::from_millis(100));
//! let t0 = Instant::now();
//! assert!(d.admit("anomaly_a", t0));
//! assert!(!d.admit("anomaly_a", t0 + Duration::from_millis(50)));
//! assert!(d.admit("anomaly_a", t0 + Duration::from_millis(150)));
//! assert!(d.admit("anomaly_b", t0));
//! ```

use std::collections::HashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

/// Map size at which [`admit`](Debouncer::admit) starts running its
/// opportunistic prune. Below this the prune is a no-op.
const PRUNE_THRESHOLD: usize = 64;

/// Filters bursts of identical events down to one per `window`.
///
/// Distinct keys are independent. The debouncer is single-threaded
/// by design; wrap in a `tokio::sync::Mutex` to share across tasks.
#[derive(Debug)]
pub struct Debouncer<K> {
    window: Duration,
    last_admitted: HashMap<K, Instant>,
}

impl<K> Debouncer<K>
where
    K: Eq + Hash,
{
    /// Creates an empty debouncer with the given suppression window.
    /// A window of zero degenerates into "always admit".
    #[must_use]
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            last_admitted: HashMap::new(),
        }
    }

    /// Returns `true` when the event should be forwarded.
    ///
    /// On a `true` return the per-key timestamp updates to `now`.
    /// Dropped events do NOT extend the window — the next admission
    /// happens exactly `window` after the most recent *admitted*
    /// event, not the last *seen* event.
    ///
    /// Past [`PRUNE_THRESHOLD`] entries also drops keys older than
    /// `2 × window` as a side effect.
    pub fn admit(&mut self, key: K, now: Instant) -> bool {
        if self.last_admitted.len() >= PRUNE_THRESHOLD {
            self.prune_stale(now);
        }
        match self.last_admitted.get(&key) {
            Some(prev) if now.duration_since(*prev) < self.window => false,
            _ => {
                self.last_admitted.insert(key, now);
                true
            }
        }
    }

    /// Removes every key older than `2 × window`. The doubled
    /// cutoff prevents a slightly-out-of-order probe from
    /// re-admitting a key whose suppression we still consider live.
    pub fn prune_stale(&mut self, now: Instant) {
        let cutoff = self.window.saturating_mul(2);
        self.last_admitted
            .retain(|_, prev| now.duration_since(*prev) < cutoff);
    }

    /// Forgets every key.
    pub fn reset(&mut self) {
        self.last_admitted.clear();
    }

    /// Suppression window. Read-only — changing it post-construction
    /// would invalidate per-key timing semantics callers depend on.
    #[must_use]
    pub fn window(&self) -> Duration {
        self.window
    }

    /// Distinct keys currently tracked.
    #[must_use]
    pub fn tracked_keys(&self) -> usize {
        self.last_admitted.len()
    }
}

/// `Default` is a 50 ms window — the canonical anomaly-debounce
/// duration used by `client_mode::EngineState::default()`.
impl<K> Default for Debouncer<K>
where
    K: Eq + Hash,
{
    fn default() -> Self {
        Self::new(Duration::from_millis(50))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admits_first_drops_within_window_admits_after() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("k", t0));
        assert!(!d.admit("k", t0 + Duration::from_millis(50)));
        assert!(!d.admit("k", t0 + Duration::from_millis(99)));
        assert!(d.admit("k", t0 + Duration::from_millis(100)));
    }

    #[test]
    fn distinct_keys_are_independent() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("A", t0));
        assert!(d.admit("B", t0));
        assert!(d.admit("C", t0));
        assert_eq!(d.tracked_keys(), 3);
    }

    #[test]
    fn stress_collapses_burst_to_one_per_window() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        let t0 = Instant::now();
        let mut admitted = 0usize;
        // 100,000 events spread over 50 ms — inside one window.
        for i in 0..100_000u32 {
            let now = t0 + Duration::from_micros(u64::from(i) * 50_000 / 100_000);
            if d.admit("flapping", now) {
                admitted += 1;
            }
        }
        assert_eq!(admitted, 1, "expected exactly 1 admission per 100ms window");

        assert!(d.admit("flapping", t0 + Duration::from_millis(120)));
        assert!(d.admit("flapping", t0 + Duration::from_millis(240)));
    }

    #[test]
    fn stress_independent_keys_all_admit_once() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        for k in 0..1000u32 {
            assert!(d.admit(k, t0), "first admission of key {k} should win");
        }
        for k in 0..1000u32 {
            assert!(
                !d.admit(k, t0 + Duration::from_millis(50)),
                "duplicate of key {k} within window should drop"
            );
        }
        assert_eq!(d.tracked_keys(), 1000);
    }

    #[test]
    fn reset_clears_state() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("k", t0));
        d.reset();
        assert!(d.admit("k", t0 + Duration::from_millis(1)));
        assert_eq!(d.tracked_keys(), 1);
    }

    #[test]
    fn default_is_50ms_window() {
        let d: Debouncer<&str> = Debouncer::default();
        assert_eq!(d.window(), Duration::from_millis(50));
        assert_eq!(d.tracked_keys(), 0);
    }

    #[test]
    fn prune_stale_removes_only_expired_entries() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        // Anchor via `base + offset` because clippy's
        // `unchecked_time_subtraction` (pedantic) forbids
        // `Instant - Duration`.
        let base = Instant::now();
        let now = base + Duration::from_secs(1);

        d.admit("fresh", now);
        d.admit("middle-aged", base + Duration::from_millis(850)); // 150 ms before now
        d.admit("expired", base + Duration::from_millis(500)); // 500 ms before now
        assert_eq!(d.tracked_keys(), 3);

        // Cutoff at `now` is 200 ms.
        d.prune_stale(now);
        assert_eq!(d.tracked_keys(), 2);

        assert!(d.admit("expired", now));
        assert!(!d.admit("fresh", now + Duration::from_millis(10)));
    }

    #[test]
    fn admit_lazy_prunes_when_over_threshold() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        let base = Instant::now();
        let stale_time = base;
        let now = base + Duration::from_secs(60);

        for k in 0..PRUNE_THRESHOLD {
            d.admit(k, stale_time);
        }
        assert_eq!(d.tracked_keys(), PRUNE_THRESHOLD);

        assert!(d.admit(usize::MAX, now));
        assert_eq!(
            d.tracked_keys(),
            1,
            "lazy prune should have dropped every stale entry"
        );
    }

    #[test]
    fn window_accessor_returns_constructor_value() {
        let d: Debouncer<&str> = Debouncer::new(Duration::from_millis(250));
        assert_eq!(d.window(), Duration::from_millis(250));
    }
}
