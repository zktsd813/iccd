#!/usr/bin/env python3
import unittest

import bucket_latency_controller as ctrl


HIST_TEXT = """\
window_seq 7
bucket_ms le_128 le_256 le_512 le_1024 le_2048 le_4096 le_8192 gt_8192
local_pages 0 1 2 3 4 5 6 7
remote_pages 8 7 6 5 4 3 2 1
"""


class HistogramTests(unittest.TestCase):
    def test_parse_histogram(self):
        hist = ctrl.parse_histogram_text(HIST_TEXT)
        self.assertEqual(hist.window_seq, 7)
        self.assertEqual(hist.local_pages, [0, 1, 2, 3, 4, 5, 6, 7])
        self.assertEqual(hist.remote_pages, [8, 7, 6, 5, 4, 3, 2, 1])

    def test_percentile_bucket(self):
        index, label = ctrl.percentile_bucket([0, 0, 8, 2, 0, 0, 0, 0], 80)
        self.assertEqual(index, 2)
        self.assertEqual(label, "<=512")
        index, label = ctrl.percentile_bucket([], 80)
        self.assertEqual(index, -1)
        self.assertEqual(label, "NA")


class DecisionTests(unittest.TestCase):
    def test_effective_two_windows_stops(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        first = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(first.decision, "effective")
        self.assertEqual(first.stop_reason, "")
        second = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=2,
            remote_p20_index=4,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(second.decision, "stop_effective")
        self.assertEqual(second.stop_reason, "effective")

    def test_no_improve_counts_after_baseline(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        baseline = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(baseline.decision, "need_baseline")
        self.assertEqual(baseline.no_improve_count, 0)
        same = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=4,
            remote_p20_index=2,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(same.decision, "no_improve")
        self.assertEqual(same.no_improve_count, 1)
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

    def test_improvement_resets_no_improve(self):
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
        self.assertEqual(improved.no_improve_count, 0)

    def test_invalid_window_resets_counters(self):
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
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertFalse(invalid.valid)
        self.assertEqual(invalid.decision, "invalid_skip")
        self.assertEqual(invalid.effective_count, 0)
        self.assertEqual(invalid.no_improve_count, 0)

    def test_off_monitor_does_not_advance_stop_counters(self):
        state = ctrl.DecisionState(consecutive_effective=2, consecutive_no_improve=2)
        state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        stop = state.evaluate(
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(stop.decision, "stop_effective")
        monitor = ctrl.monitor_decision(
            state=state,
            local_total=4096,
            remote_total=4096,
            local_p80_index=1,
            remote_p20_index=3,
            min_local_pages=1024,
            min_remote_pages=1024,
        )
        self.assertEqual(monitor.decision, "monitor_off")
        self.assertEqual(monitor.effective_count, 2)
        self.assertEqual(state.effective_count, 2)


class RestartTests(unittest.TestCase):
    def test_arm_clamps_final_bucket_to_previous_bucket(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        obs = state.arm([0, 0, 0, 0, 0, 0, 20, 80], remote_p20_index=7)
        self.assertTrue(obs.armed)
        self.assertTrue(obs.valid)
        self.assertEqual(obs.stop_remote_p20_index, 7)
        self.assertEqual(obs.compare_bucket_index, 6)
        self.assertAlmostEqual(obs.baseline_share, 0.2)
        self.assertAlmostEqual(obs.current_share, 0.2)
        self.assertAlmostEqual(obs.ratio, 1.0)

    def test_restart_after_two_windows_above_same_baseline_threshold(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm([0, 0, 0, 0, 0, 0, 20, 80], remote_p20_index=7)
        first = state.observe([0, 0, 0, 0, 0, 0, 25, 75], min_remote_pages=10)
        self.assertEqual(first.decision, "restart_candidate")
        self.assertFalse(first.restart)
        self.assertEqual(first.consecutive_count, 1)
        self.assertAlmostEqual(first.ratio, 1.25)
        second = state.observe([0, 0, 0, 0, 0, 0, 25, 75], min_remote_pages=10)
        self.assertEqual(second.decision, "restart_remote_share")
        self.assertTrue(second.restart)
        self.assertEqual(second.consecutive_count, 2)
        self.assertAlmostEqual(second.ratio, 1.25)

    def test_restart_wait_resets_consecutive_count(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm([0, 0, 0, 0, 0, 0, 20, 80], remote_p20_index=7)
        state.observe([0, 0, 0, 0, 0, 0, 25, 75], min_remote_pages=10)
        wait = state.observe([0, 0, 0, 0, 0, 0, 22, 78], min_remote_pages=10)
        self.assertEqual(wait.decision, "restart_wait")
        self.assertEqual(wait.consecutive_count, 0)

    def test_restart_invalid_window_resets_consecutive_count(self):
        state = ctrl.RestartState(threshold=1.2, consecutive_windows=2)
        state.arm([0, 0, 0, 0, 0, 0, 20, 80], remote_p20_index=7)
        state.observe([0, 0, 0, 0, 0, 0, 25, 75], min_remote_pages=10)
        invalid = state.observe([0, 0, 0, 0, 0, 0, 1, 1], min_remote_pages=10)
        self.assertEqual(invalid.decision, "restart_invalid")
        self.assertEqual(invalid.consecutive_count, 0)


if __name__ == "__main__":
    unittest.main()
