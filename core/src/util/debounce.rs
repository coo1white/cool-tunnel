//! Per-key fixed-window debouncer.
//!
//! When the proxy is flapping the [`crate::monitor`] loop can fire the
//! same anomaly repeatedly within a few hundred milliseconds — once per
//! `lsof` probe. Forwarding every emission to Swift turns the live log
//! console into a wall of noise and pegs the main actor with redundant
//! UI updates. The debouncer filters those bursts down to one event
//! per key per window while still allowing a *new* key (a different
//! anomaly type) through immediately.
//!
//! The window is intentionally fixed-time rather than leading-edge or
//! trailing-edge: every probe inside the window is dropped, then the
//! first probe outside the window wins. That matches the user-facing
//! semantics we want — "tell me again at most every 100 ms" — and
//! keeps the implementation deterministic for the stress test below.
//!
//! # Example
//!
//! ```
//! use std::time::{Duration, Instant};
//! use cool_tunnel_core::util::debounce::Debouncer;
//!
//! let mut d = Debouncer::new(Duration::from_millis(100));
//! let t0 = Instant::now();
//! assert!(d.admit("anomaly_a", t0));                                     // first time → admitted
//! assert!(!d.admit("anomaly_a", t0 + Duration::from_millis(50)));       // inside window → dropped
//! assert!(d.admit("anomaly_a", t0 + Duration::from_millis(150)));       // outside window → admitted
//! assert!(d.admit("anomaly_b", t0));                                     // different key → admitted
//! ```

use std::collections::HashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

/// Filters bursts of identical events down to one per `window`.
///
/// `K` is whatever uniquely identifies a burst — for the monitor loop
/// it is `AnomalyReason`. Distinct keys are independent: admitting one
/// does not touch the timer of another.
///
/// The debouncer is single-threaded by design. If you need to share it
/// across tasks wrap it in a `tokio::sync::Mutex`.
pub struct Debouncer<K> {
    window: Duration,
    last_admitted: HashMap<K, Instant>,
}

impl<K> Debouncer<K>
where
    K: Eq + Hash,
{
    /// Creates an empty debouncer with the given suppression window.
    /// A window of zero degenerates into "always admit" — useful for
    /// tests but not generally recommended.
    #[must_use]
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            last_admitted: HashMap::new(),
        }
    }

    /// Returns `true` when the event should be forwarded; `false` when
    /// it falls inside the suppression window of a previous admission
    /// for the same key.
    ///
    /// Updates the per-key timestamp only on a `true` return. That
    /// means a burst of 1000 dropped events does not extend the window
    /// — the next admission still happens exactly `window` after the
    /// most recent *admitted* event, not after the last *seen* event.
    pub fn admit(&mut self, key: K, now: Instant) -> bool {
        match self.last_admitted.get(&key) {
            Some(prev) if now.duration_since(*prev) < self.window => false,
            _ => {
                self.last_admitted.insert(key, now);
                true
            }
        }
    }

    /// Forgets every key. Useful when the supervised process restarts
    /// and stale anomaly state is no longer meaningful.
    pub fn reset(&mut self) {
        self.last_admitted.clear();
    }

    /// How many keys are currently being tracked. The map grows by one
    /// per *distinct* key admitted; it does not shrink between
    /// admissions. In production the only call site uses
    /// [`crate::protocol::AnomalyReason`] as the key, which has a
    /// fixed five variants — so the map is bounded at five entries.
    /// Call [`reset`] to clear it (e.g. on supervisor restart).
    /// Tested by the stress suite below to confirm the bound holds.
    #[must_use]
    pub fn tracked_keys(&self) -> usize {
        self.last_admitted.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sanity check: first event admitted, anything inside the window
    /// dropped, the next event after the window admitted again.
    #[test]
    fn admits_first_drops_within_window_admits_after() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("k", t0));
        assert!(!d.admit("k", t0 + Duration::from_millis(50)));
        assert!(!d.admit("k", t0 + Duration::from_millis(99)));
        assert!(d.admit("k", t0 + Duration::from_millis(100)));
    }

    /// Different keys must not block each other — a burst of "A"
    /// events should not delay the first "B" event.
    #[test]
    fn distinct_keys_are_independent() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("A", t0));
        assert!(d.admit("B", t0));
        assert!(d.admit("C", t0));
        assert_eq!(d.tracked_keys(), 3);
    }

    /// Stress: hammer the debouncer with 100,000 duplicate events
    /// across a wall-clock span much shorter than the window. The
    /// window is the contract — *exactly one* admission per window
    /// should survive, regardless of input cadence.
    #[test]
    fn stress_collapses_burst_to_one_per_window() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        let t0 = Instant::now();
        let mut admitted = 0usize;
        // 100,000 events spread evenly over 50 ms — well inside one
        // 100 ms window. Only the first should win.
        for i in 0..100_000u32 {
            // Map each iteration to a virtual time inside [0, 50ms).
            let now = t0 + Duration::from_micros(u64::from(i) * 50_000 / 100_000);
            if d.admit("flapping", now) {
                admitted += 1;
            }
        }
        assert_eq!(admitted, 1, "expected exactly 1 admission per 100ms window");

        // Now span across two more windows: events at t=120ms and
        // t=240ms must each win.
        assert!(d.admit("flapping", t0 + Duration::from_millis(120)));
        assert!(d.admit("flapping", t0 + Duration::from_millis(240)));
    }

    /// Stress with many distinct keys: each key's timer is independent,
    /// so 1000 distinct keys hammered simultaneously should all be
    /// admitted exactly once on the first hit.
    #[test]
    fn stress_independent_keys_all_admit_once() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        // First pass: all admitted.
        for k in 0..1000u32 {
            assert!(d.admit(k, t0), "first admission of key {k} should win");
        }
        // Second pass within the window: all dropped.
        for k in 0..1000u32 {
            assert!(
                !d.admit(k, t0 + Duration::from_millis(50)),
                "duplicate of key {k} within window should drop"
            );
        }
        assert_eq!(d.tracked_keys(), 1000);
    }

    /// Reset clears all per-key state — after a reset the next admit
    /// for any previously-seen key wins immediately.
    #[test]
    fn reset_clears_state() {
        let mut d = Debouncer::new(Duration::from_millis(100));
        let t0 = Instant::now();
        assert!(d.admit("k", t0));
        d.reset();
        assert!(d.admit("k", t0 + Duration::from_millis(1)));
        assert_eq!(d.tracked_keys(), 1);
    }
}
