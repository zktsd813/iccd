#!/usr/bin/env python3
import unittest

import bucket_latency_controller as ctrl


LAST_BUCKET_INDEX = len(ctrl.BUCKET_LABELS) - 1
PREV_BUCKET_INDEX = LAST_BUCKET_INDEX - 1
HIST_LOCAL = list(range(len(ctrl.BUCKET_LABELS)))
HIST_REMOTE = list(reversed(HIST_LOCAL))


def pages_at(*entries):
    pages = [0] * len(ctrl.BUCKET_LABELS)
    for index, count in entries:
        pages[index] = count
    return pages


HIST_TEXT = f"""\
window_seq 7
bucket_ms le_1 le_16 le_64 le_128 le_256 le_512 le_1024 le_2048 le_4096 le_8192 gt_8192
local_pages {" ".join(str(value) for value in HIST_LOCAL)}
remote_pages {" ".join(str(value) for value in HIST_REMOTE)}
"""


class HistogramTests(unittest.TestCase):
    def test_parse_histogram(self):
        hist = ctrl.parse_histogram_text(HIST_TEXT)
        self.assertEqual(hist.window_seq, 7)
        self.assertEqual(hist.local_pages, HIST_LOCAL)
        self.assertEqual(hist.remote_pages, HIST_REMOTE)

    def test_percentile_bucket(self):
        index, label = ctrl.percentile_bucket(pages_at((2, 8), (3, 2)), 80)
        self.assertEqual(index, 2)
        self.assertEqual(label, "<=64")
        index, label = ctrl.percentile_bucket([], 80)
        self.assertEqual(index, -1)
        self.assertEqual(label, "NA")

    def test_bucket_signals_zero_remote_is_invalid(self):
        signals = ctrl.bucket_signals(
            pages_at((4, 4096)),
            [0] * len(ctrl.BUCKET_LABELS),
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(signals.valid)
        self.assertEqual(signals.local_p80_index, 4)
        self.assertEqual(signals.remote_p20_index, -1)
        self.assertEqual(signals.remote_p20_label, "NA")

    def test_bucket_signals_zero_local_is_invalid(self):
        signals = ctrl.bucket_signals(
            [0] * len(ctrl.BUCKET_LABELS),
            pages_at((2, 4096)),
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(signals.valid)
        self.assertEqual(signals.local_p80_index, -1)
        self.assertEqual(signals.local_p80_label, "NA")
        self.assertEqual(signals.remote_p20_index, 2)

    def test_bucket_signals_both_zero_is_invalid(self):
        signals = ctrl.bucket_signals(
            [0] * len(ctrl.BUCKET_LABELS),
            [0] * len(ctrl.BUCKET_LABELS),
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(signals.valid)
        self.assertEqual(signals.local_p80_index, -1)
        self.assertEqual(signals.remote_p20_index, -1)

    def test_bucket_signals_low_nonzero_remote_is_invalid(self):
        signals = ctrl.bucket_signals(
            pages_at((4, 4096)),
            pages_at((2, 10)),
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(signals.valid)
        self.assertEqual(signals.local_p80_index, 4)
        self.assertEqual(signals.remote_p20_index, 2)
        self.assertEqual(signals.remote_p20_label, "<=64")

    def test_bucket_signals_both_low_nonzero_is_invalid(self):
        signals = ctrl.bucket_signals(
            pages_at((2, 10)),
            pages_at((2, 10)),
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(signals.valid)
        self.assertEqual(signals.local_p80_index, 2)
        self.assertEqual(signals.remote_p20_index, 2)


class DecisionTests(unittest.TestCase):
    def test_first_valid_window_sets_gap_baseline(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        skipped = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(skipped.decision, "baseline_skip")
        self.assertEqual(skipped.gap, 2)
        decision = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(decision.decision, "need_baseline")
        self.assertEqual(decision.gap, 2)
        self.assertEqual(decision.stop_reason, "")

    def test_same_gap_stops_immediately_after_baseline(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        same = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(same.decision, "stop_no_improve")
        self.assertEqual(same.stop_reason, "no_improve")
        self.assertEqual(same.no_improve_count, 1)

    def test_growing_gap_stops_immediately_after_baseline(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        worse = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=5,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(worse.decision, "stop_no_improve")
        self.assertEqual(worse.stop_reason, "no_improve")

    def test_shrinking_gap_does_not_stop(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=5,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=5,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        improved = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(improved.decision, "improving")
        self.assertEqual(improved.stop_reason, "")
        self.assertEqual(improved.no_improve_count, 0)

    def test_effective_same_or_closer_gap_stops_after_two_windows(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        baseline = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(baseline.decision, "effective_baseline")
        self.assertEqual(baseline.effective_count, 0)
        first = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(first.decision, "effective_candidate")
        self.assertEqual(first.stop_reason, "")
        self.assertEqual(first.effective_count, 1)
        second = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=2,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(second.decision, "stop_effective")
        self.assertEqual(second.stop_reason, "effective")
        self.assertEqual(second.effective_count, 2)

    def test_effective_farther_gap_keeps_migration(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=2,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        baseline = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=2,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(baseline.decision, "effective_baseline")
        candidate = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=2,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(candidate.decision, "effective_candidate")
        self.assertEqual(candidate.effective_count, 1)
        farther = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(farther.decision, "effective_improving")
        self.assertEqual(farther.stop_reason, "")
        self.assertEqual(farther.effective_count, 1)

    def test_effective_candidate_resets_need_baseline(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        need = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(need.decision, "need_baseline")
        self.assertEqual(need.effective_count, 0)

    def test_remote_low_after_first_valid_sample_stops(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        invalid = state.evaluate(
            local_total=10,
            remote_total=10,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(invalid.valid)
        self.assertEqual(invalid.decision, "stop_remote_low_sample")
        self.assertEqual(invalid.stop_reason, "remote_low_sample")
        self.assertEqual(invalid.effective_count, 0)
        self.assertEqual(invalid.no_improve_count, 0)

    def test_remote_low_before_first_valid_sample_is_invalid(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        decision = state.evaluate(
            local_total=4096,
            remote_total=0,
            local_p80_index=4,
            remote_p20_index=-1,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(decision.valid)
        self.assertEqual(decision.decision, "invalid_skip")
        self.assertEqual(decision.stop_reason, "")
        self.assertIsNone(decision.gap)

    def test_low_nonzero_remote_after_first_valid_sample_stops(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        decision = state.evaluate(
            local_total=4096,
            remote_total=7,
            local_p80_index=4,
            remote_p20_index=0,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(decision.valid)
        self.assertEqual(decision.decision, "stop_remote_low_sample")
        self.assertEqual(decision.stop_reason, "remote_low_sample")

    def test_zero_local_window_is_invalid_for_monitor(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        monitor = ctrl.monitor_decision(
            state=state,
            local_total=0,
            remote_total=4096,
            local_p80_index=-1,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(monitor.valid)
        self.assertEqual(monitor.decision, "invalid_skip_off")
        self.assertIsNone(monitor.gap)

    def test_off_monitor_does_not_advance_stop_counters(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        stop = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(stop.decision, "stop_no_improve")
        monitor = ctrl.monitor_decision(
            state=state,
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(monitor.decision, "monitor_off")
        self.assertEqual(monitor.no_improve_count, 1)
        self.assertEqual(state.no_improve_count, 1)


class RestartTests(unittest.TestCase):
    def test_protected_window_arms_restart_on_first_valid_window(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        start = state.begin_protection("no_improve")
        self.assertEqual(start.decision, "restart_protect_start")
        first = state.observe(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            min_remote_pages=10,
            remote_p20_index=LAST_BUCKET_INDEX,
        )
        self.assertEqual(first.decision, "restart_armed")
        self.assertTrue(first.armed)
        self.assertEqual(first.stop_remote_p20_index, LAST_BUCKET_INDEX)
        self.assertEqual(first.compare_bucket_index, LAST_BUCKET_INDEX)

    def test_invalid_protected_window_restarts_protected_count(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.begin_protection("no_improve")
        invalid = state.observe(
            [0] * len(ctrl.BUCKET_LABELS),
            min_remote_pages=10,
            remote_p20_index=-1,
        )
        self.assertEqual(invalid.decision, "restart_protect_invalid")
        again = state.observe(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            min_remote_pages=10,
            remote_p20_index=LAST_BUCKET_INDEX,
        )
        self.assertEqual(again.decision, "restart_armed")

    def test_effective_stop_restarts_when_need_migration_returns(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.begin_protection("effective")
        wait = state.observe(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            min_remote_pages=10,
            remote_p20_index=LAST_BUCKET_INDEX,
            need_migration=False,
        )
        self.assertEqual(wait.decision, "restart_effective_wait")
        self.assertFalse(wait.restart)
        restart = state.observe(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            min_remote_pages=10,
            remote_p20_index=LAST_BUCKET_INDEX,
            need_migration=True,
        )
        self.assertEqual(restart.decision, "restart_need_migration")
        self.assertTrue(restart.restart)

    def test_arm_uses_final_bucket_without_clamp(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        obs = state.arm(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            remote_p20_index=LAST_BUCKET_INDEX,
        )
        self.assertTrue(obs.armed)
        self.assertTrue(obs.valid)
        self.assertEqual(obs.stop_remote_p20_index, LAST_BUCKET_INDEX)
        self.assertEqual(obs.compare_bucket_index, LAST_BUCKET_INDEX)
        self.assertAlmostEqual(obs.baseline_share, 1.0)
        self.assertAlmostEqual(obs.current_share, 1.0)
        self.assertAlmostEqual(obs.ratio, 1.0)

    def test_restart_after_two_windows_above_same_baseline_threshold(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            remote_p20_index=PREV_BUCKET_INDEX,
        )
        first = state.observe(
            pages_at((PREV_BUCKET_INDEX, 25), (LAST_BUCKET_INDEX, 75)),
            min_remote_pages=10,
        )
        self.assertEqual(first.decision, "restart_candidate")
        self.assertFalse(first.restart)
        self.assertEqual(first.consecutive_count, 1)
        self.assertAlmostEqual(first.ratio, 1.25)
        second = state.observe(
            pages_at((PREV_BUCKET_INDEX, 25), (LAST_BUCKET_INDEX, 75)),
            min_remote_pages=10,
        )
        self.assertEqual(second.decision, "restart_remote_share")
        self.assertTrue(second.restart)
        self.assertEqual(second.consecutive_count, 2)
        self.assertAlmostEqual(second.ratio, 1.25)

    def test_restart_wait_resets_consecutive_count(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            remote_p20_index=LAST_BUCKET_INDEX,
        )
        state.observe(
            pages_at((PREV_BUCKET_INDEX, 25), (LAST_BUCKET_INDEX, 75)),
            min_remote_pages=10,
        )
        wait = state.observe(
            pages_at((PREV_BUCKET_INDEX, 22), (LAST_BUCKET_INDEX, 78)),
            min_remote_pages=10,
        )
        self.assertEqual(wait.decision, "restart_wait")
        self.assertEqual(wait.consecutive_count, 0)

    def test_restart_invalid_window_resets_consecutive_count(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm(
            pages_at((PREV_BUCKET_INDEX, 20), (LAST_BUCKET_INDEX, 80)),
            remote_p20_index=LAST_BUCKET_INDEX,
        )
        state.observe(
            pages_at((PREV_BUCKET_INDEX, 25), (LAST_BUCKET_INDEX, 75)),
            min_remote_pages=10,
        )
        invalid = state.observe(
            pages_at((PREV_BUCKET_INDEX, 1), (LAST_BUCKET_INDEX, 1)),
            min_remote_pages=10,
        )
        self.assertEqual(invalid.decision, "restart_invalid")
        self.assertEqual(invalid.consecutive_count, 0)


if __name__ == "__main__":
    unittest.main()
