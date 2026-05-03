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
//! semantics we want — "tell me again at most every N ms" — and
//! keeps the implementation deterministic for the stress tests below.
//!
//! ## Memory
//!
//! Internally a `HashMap<K, Instant>`. Each [`admit`](Debouncer::admit)
//! call performs a *bounded* lazy prune: when the map is small the
//! prune is a no-op; once it grows past [`PRUNE_THRESHOLD`] we walk it
//! and drop entries older than `2 × window`. That keeps the map size
//! O(distinct active keys) without a separate timer task and without
//! the allocation spike a periodic `clear` would cause.
//!
//! In production the only call site uses
//! [`crate::protocol::AnomalyReason`] (5 variants) as the key, so the
//! map maxes out at 5 entries and the pruning path never triggers —
//! but the bound is documented for future callers.
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

/// Map size at which [`admit`](Debouncer::admit) starts running its
/// opportunistic prune. Below this we trust the caller's key set is
/// small (the production case has 5 keys); above it we do an O(n)
/// `retain` walk on every admit, which is cheap up to a few hundred
/// keys and bounds the worst-case memory growth.
const PRUNE_THRESHOLD: usize = 64;

/// Filters bursts of identical events down to one per `window`.
///
/// `K` is whatever uniquely identifies a burst — for the monitor loop
/// it is `AnomalyReason`. Distinct keys are independent: admitting one
/// does not touch the timer of another.
///
/// The debouncer is single-threaded by design. If you need to share it
/// across tasks wrap it in a `tokio::sync::Mutex`.
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
    /// On a `true` return the per-key timestamp updates to `now`. A
    /// burst of dropped events does **not** extend the window — the
    /// next admission still happens exactly `window` after the most
    /// recent *admitted* event, not after the last *seen* event.
    ///
    /// As a side effect, when the internal map exceeds
    /// [`PRUNE_THRESHOLD`] entries this call also drops every key
    /// whose timestamp is older than `2 × window` — those keys can no
    /// longer affect any future decision (any admit for them would
    /// trivially succeed) so keeping them costs memory for nothing.
    pub fn admit(&mut self, key: K, now: Instant) -> bool {
        // Bounded lazy prune. Cheap when small, opportunistically
        // shrinks when large. The `2 × window` cutoff is conservative:
        // we keep entries one full window past their effective expiry
        // so probes that arrive slightly out of order cannot suddenly
        // re-admit a recently-suppressed key.
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

    /// Removes every key whose last admission is older than `2 ×
    /// window`. Callers can invoke this proactively (e.g. on a slow
    /// timer) to bound the map size without waiting for the
    /// auto-prune in [`admit`](Self::admit) to fire.
    ///
    /// The cutoff is `2 × window` rather than `window` so a probe
    /// arriving slightly out of order — for example, a delayed
    /// scheduler tick that lands a few ms past expiry — cannot re-
    /// admit a key whose suppression we still consider live.
    pub fn prune_stale(&mut self, now: Instant) {
        let cutoff = self.window.saturating_mul(2);
        self.last_admitted
            .retain(|_, prev| now.duration_since(*prev) < cutoff);
    }

    /// Forgets every key. Useful when the supervised process restarts
    /// and stale anomaly state is no longer meaningful.
    pub fn reset(&mut self) {
        self.last_admitted.clear();
    }

    /// Suppression window this debouncer was constructed with. Read-
    /// only — changing the window after the fact would invalidate the
    /// per-key timing semantics callers depend on.
    #[must_use]
    pub fn window(&self) -> Duration {
        self.window
    }

    /// How many keys are currently being tracked. The map grows by one
    /// per *distinct* key admitted; lazy pruning in
    /// [`admit`](Self::admit) keeps it bounded once it exceeds
    /// [`PRUNE_THRESHOLD`]. In production the only call site uses
    /// [`crate::protocol::AnomalyReason`] as the key, which has a
    /// fixed five variants — so the map is bounded at five entries.
    #[must_use]
    pub fn tracked_keys(&self) -> usize {
        self.last_admitted.len()
    }
}

/// `Default` is a 50 ms window — the canonical anomaly-debounce
/// duration used by `client_mode::EngineState::default()`.
///
/// Tightened from 100 ms in v0.1.7.4 to halve the worst-case
/// time between a real anomaly emission (e.g. naive starting to
/// listen outside loopback) and the UI auto-stop kicking in. The
/// suppression goal is unchanged — collapse a flapping-naive
/// anomaly storm into one event per key — but the window is
/// short enough to feel near-instant to the user. Burst-flooding
/// the UI is bounded by the per-key map: distinct reasons admit
/// independently; the same reason emits at most once per 50 ms.
///
/// Lets callers write `Debouncer::default()` for the common case
/// and `Debouncer::new(other)` for everything else.
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

    /// Default constructs a 50 ms debouncer — the canonical
    /// anomaly-debounce window used by `client_mode::EngineState`.
    /// Tightened from 100 ms in v0.1.7.4 (LTSC patch) to halve
    /// the worst-case latency between an emitted anomaly and the
    /// orchestrator's auto-stop reaction.
    #[test]
    fn default_is_50ms_window() {
        let d: Debouncer<&str> = Debouncer::default();
        assert_eq!(d.window(), Duration::from_millis(50));
        assert_eq!(d.tracked_keys(), 0);
    }

    /// Explicit `prune_stale` removes only entries older than
    /// `2 × window`; recent ones survive so the suppression contract
    /// is preserved.
    #[test]
    fn prune_stale_removes_only_expired_entries() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        // Anchor "now" at one second past `Instant::now()` so we can
        // express past timestamps via plain addition relative to a
        // base — `Instant - Duration` is forbidden by clippy's
        // `unchecked_time_subtraction` lint, which is on under
        // `pedantic`.
        let base = Instant::now();
        let now = base + Duration::from_secs(1);

        // Three keys at three ages, all expressed as `base + offset`.
        d.admit("fresh", now);
        d.admit("middle-aged", base + Duration::from_millis(850)); // 150 ms before now
        d.admit("expired", base + Duration::from_millis(500)); // 500 ms before now
        assert_eq!(d.tracked_keys(), 3);

        // Prune at `now`: cutoff = 200 ms. "fresh" and "middle-aged"
        // are within the cutoff; "expired" is not.
        d.prune_stale(now);
        assert_eq!(d.tracked_keys(), 2);

        // After the prune, "expired" can re-admit immediately because
        // its prior timestamp is gone.
        assert!(d.admit("expired", now));
        // But "fresh" still suppresses a same-window admit.
        assert!(!d.admit("fresh", now + Duration::from_millis(10)));
    }

    /// Auto-prune kicks in once the map crosses `PRUNE_THRESHOLD`.
    /// Confirm the map shrinks back below that bound after a single
    /// `admit` call when most existing entries are stale.
    #[test]
    fn admit_lazy_prunes_when_over_threshold() {
        let window = Duration::from_millis(100);
        let mut d = Debouncer::new(window);
        let base = Instant::now();
        // Use `base` for the stale fill and `base + 60s` for the new
        // admit so the difference exceeds the 2 × window cutoff
        // without any `Instant - Duration` arithmetic.
        let stale_time = base;
        let now = base + Duration::from_secs(60);

        for k in 0..PRUNE_THRESHOLD {
            d.admit(k, stale_time);
        }
        assert_eq!(d.tracked_keys(), PRUNE_THRESHOLD);

        // One more admit at `now` should trigger the lazy prune,
        // drop every stale entry, and leave only the new one.
        assert!(d.admit(usize::MAX, now));
        assert_eq!(
            d.tracked_keys(),
            1,
            "lazy prune should have dropped every stale entry"
        );
    }

    /// Window is read-only and reflects the constructor argument.
    #[test]
    fn window_accessor_returns_constructor_value() {
        let d: Debouncer<&str> = Debouncer::new(Duration::from_millis(250));
        assert_eq!(d.window(), Duration::from_millis(250));
    }
}
