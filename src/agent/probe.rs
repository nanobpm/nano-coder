//! Background capability-probe state (issue #116, extraction 1).
//!
//! The endpoint reports four capabilities for the current model — its context
//! window, thinking levels, vision support and published output-token limit.
//! A blocking probe runs at startup / `/model`, and a mid-turn model switch
//! probes in a background task that publishes whenever the endpoint answers.
//!
//! Invariant owned here: a probe result is only published if no model change
//! has happened since the probe was spawned. Every model change goes through
//! [`ProbeState::begin_detect`], which bumps the generation *before* clearing
//! the slots; [`ProbeState::publish_if_current`] re-reads the generation under
//! the window-slot lock and writes all four reports together, so a slow probe
//! for a superseded model can never overwrite the current model's results.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::llm::DetectedWindow;

/// What a capability probe found.
pub(super) struct Detected {
    pub(super) window: Option<DetectedWindow>,
    pub(super) thinking: Option<crate::thinking::Reported>,
    pub(super) vision: Option<crate::vision::Vision>,
    /// The model's published output-token limit, kept separate from `window`
    /// so a configured window (which carries none) never discards it (#114).
    pub(super) max_output: Option<usize>,
}

#[cfg(test)]
impl Detected {
    /// A probe that reported only a window.
    pub(super) fn window(window: DetectedWindow) -> Self {
        Detected { window: Some(window), thinking: None, vision: None, max_output: None }
    }
}

/// The shared slots capability probes publish into, plus the generation
/// counter that guards them. Cloning shares the slots (they are `Arc`s), which
/// is how a background probe task gets a handle to publish through.
#[derive(Clone, Default)]
pub(super) struct ProbeState {
    /// Window reported by the endpoint.
    window: Arc<Mutex<Option<DetectedWindow>>>,
    /// Thinking levels reported by the endpoint.
    thinking: Arc<Mutex<Option<crate::thinking::Reported>>>,
    /// Vision capability reported by the endpoint.
    vision: Arc<Mutex<Option<crate::vision::Vision>>>,
    /// The model's own maximum output tokens as published by the endpoint,
    /// captured on **both** probe paths. Kept separate from `window` so a
    /// configured context window — which clears the detected window — never
    /// discards the discovered output limit (issue #114).
    max_output: Arc<Mutex<Option<usize>>>,
    /// Monotonic model-change counter. A background probe captures the
    /// generation it was spawned under and discards its result if a later
    /// change has since bumped it.
    generation: Arc<AtomicU64>,
}

impl ProbeState {
    /// Invalidate any in-flight probe and clear every report: the previous
    /// model's reports must not leak onto the new one. Returns the new
    /// generation, which a probe spawned now must publish under.
    ///
    /// The generation is bumped *before* the slots are cleared so an in-flight
    /// probe is already invalidated by the time its slot is emptied.
    pub(super) fn begin_detect(&self) -> u64 {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        *self.window.lock().unwrap() = None;
        *self.thinking.lock().unwrap() = None;
        *self.vision.lock().unwrap() = None;
        *self.max_output.lock().unwrap() = None;
        generation
    }

    /// Invalidate any in-flight probe and clear the window and output-limit
    /// reports, leaving thinking/vision for the blocking probe to overwrite.
    pub(super) fn begin_blocking_detect(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        *self.window.lock().unwrap() = None;
        *self.max_output.lock().unwrap() = None;
    }

    /// Whether `generation` is still the live one.
    pub(super) fn is_current(&self, generation: u64) -> bool {
        self.generation.load(Ordering::SeqCst) == generation
    }

    /// Publish a blocking probe's result unconditionally (the caller holds
    /// `&mut Agent`, so no switch can race it). Every report is replaced,
    /// `None` fields clearing their slot.
    pub(super) fn store(&self, detected: Detected) {
        *self.max_output.lock().unwrap() = detected.max_output;
        *self.window.lock().unwrap() = detected.window;
        *self.thinking.lock().unwrap() = detected.thinking;
        *self.vision.lock().unwrap() = detected.vision;
    }

    /// Publish a configured-window probe (thinking / vision / output limit
    /// only), leaving the window slot untouched.
    pub(super) fn store_without_window(
        &self,
        thinking: Option<crate::thinking::Reported>,
        vision: Option<crate::vision::Vision>,
        max_output: Option<usize>,
    ) {
        *self.thinking.lock().unwrap() = thinking;
        *self.vision.lock().unwrap() = vision;
        *self.max_output.lock().unwrap() = max_output;
    }

    /// Publish a background probe's result if `generation` is still current.
    ///
    /// The generation is checked under the window-slot lock so a switch racing
    /// this completion either bumps it before we read (we discard) or clears
    /// the slots after we write. All four reports land together; the window
    /// slot is only written when the probe found a window. Returns the
    /// detected window on success (`Some(None)` when the probe found none),
    /// `None` when the result was stale and discarded.
    pub(super) fn publish_if_current(&self, generation: u64, detected: Detected) -> Option<Option<DetectedWindow>> {
        let Detected { window, thinking, vision, max_output } = detected;
        let mut slot = self.window.lock().unwrap();
        if !self.is_current(generation) {
            return None;
        }
        *self.thinking.lock().unwrap() = thinking;
        *self.vision.lock().unwrap() = vision;
        *self.max_output.lock().unwrap() = max_output;
        if let Some(window) = &window {
            *slot = Some(window.clone());
        }
        Some(window)
    }

    /// The detected window slot.
    pub(super) fn window(&self) -> std::sync::MutexGuard<'_, Option<DetectedWindow>> {
        self.window.lock().unwrap()
    }

    /// The reported thinking levels slot.
    pub(super) fn thinking(&self) -> std::sync::MutexGuard<'_, Option<crate::thinking::Reported>> {
        self.thinking.lock().unwrap()
    }

    /// The reported vision slot.
    pub(super) fn vision(&self) -> std::sync::MutexGuard<'_, Option<crate::vision::Vision>> {
        self.vision.lock().unwrap()
    }

    /// The reported output-limit slot.
    pub(super) fn max_output(&self) -> std::sync::MutexGuard<'_, Option<usize>> {
        self.max_output.lock().unwrap()
    }

    /// A shared handle to the output-limit slot.
    #[cfg(test)]
    pub(super) fn max_output_slot(&self) -> Arc<Mutex<Option<usize>>> {
        self.max_output.clone()
    }

    /// Probe state around an existing window slot and generation counter, with
    /// fresh thinking / vision / output slots.
    #[cfg(test)]
    pub(super) fn with_window(window: Arc<Mutex<Option<DetectedWindow>>>, generation: Arc<AtomicU64>) -> Self {
        ProbeState { window, generation, ..Default::default() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stale_generation_publishes_nothing() {
        let probe = ProbeState::default();
        let stale = probe.begin_detect();
        let live = probe.begin_detect();
        assert!(probe.publish_if_current(stale, Detected::window(DetectedWindow::total(1, "stale"))).is_none());
        assert!(probe.window().is_none());
        let published = probe.publish_if_current(live, Detected::window(DetectedWindow::total(2, "live")));
        assert_eq!(published.unwrap().unwrap().tokens, 2);
        assert_eq!(probe.window().as_ref().unwrap().tokens, 2);
    }

    #[test]
    fn begin_detect_clears_every_report_and_invalidates_in_flight_probes() {
        let probe = ProbeState::default();
        let generation = probe.begin_detect();
        probe.store(Detected {
            window: Some(DetectedWindow::total(3, "x")),
            thinking: None,
            vision: None,
            max_output: Some(7),
        });
        let next = probe.begin_detect();
        assert!(!probe.is_current(generation));
        assert!(probe.is_current(next));
        assert!(probe.window().is_none());
        assert!(probe.max_output().is_none());
    }

    #[test]
    fn a_windowless_result_keeps_the_window_slot_but_publishes_the_rest() {
        let probe = ProbeState::default();
        let generation = probe.begin_detect();
        *probe.window() = Some(DetectedWindow::total(5, "earlier"));
        let published = probe.publish_if_current(
            generation,
            Detected { window: None, thinking: None, vision: None, max_output: Some(9) },
        );
        assert!(matches!(published, Some(None)));
        assert_eq!(probe.window().as_ref().unwrap().tokens, 5);
        assert_eq!(*probe.max_output(), Some(9));
    }
}
