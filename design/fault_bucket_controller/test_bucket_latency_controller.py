#!/usr/bin/env python3

import csv
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import bucket_latency_controller as ctrl


KLL_TEXT = """\
schema quantile_snapshot_v4
window_seq 42
algorithm kll_weighted_ms_v1
value_source sketch_latency_ms_to_ns
local_total 2000
remote_total 3000
local_q75_ns 240000000
remote_query_rank_ppm 220000
remote_query_q_ns 100000000
remote_query_valid 1
remote_cdf_lt_local_q75_ppm 200000
remote_cdf_le_local_q75_ppm 250000
"""


def snapshot(
    *,
    local_total=2000,
    remote_total=3000,
    local_p75_ns=240,
    remote_query_rank_ppm=220000,
    remote_query_q_ns=100,
    remote_query_valid=True,
    remote_lt_ppm=220000,
    remote_le_ppm=250000,
):
    return ctrl.QuantileSnapshot(
        schema=ctrl.KLL_SCHEMA,
        window_seq=1,
        algorithm=ctrl.KLL_ALGORITHM,
        value_source=ctrl.KLL_VALUE_SOURCE,
        local_total=local_total,
        remote_total=remote_total,
        local_p75_ns=local_p75_ns,
        remote_query_rank_ppm=remote_query_rank_ppm,
        remote_query_q_ns=remote_query_q_ns,
        remote_query_valid=remote_query_valid,
        remote_cdf_lt_local_p75_ppm=remote_lt_ppm,
        remote_cdf_le_local_p75_ppm=remote_le_ppm,
    )


def observe(
    snap,
    *,
    local_pages=16,
    remote_pages=60,
    state=None,
    p75_state=None,
    threshold=0.9,
    margin_pct=10,
):
    return ctrl.evaluate_policy(
        snap,
        local_resident_pages=local_pages,
        remote_resident_pages=remote_pages,
        min_local_pages=1024,
        min_remote_pages=1024,
        stop_capacity_ratio_threshold=threshold,
        start_capacity_margin_pct=margin_pct,
        start_state=state or ctrl.StartState(2),
        p75_stagnation_state=p75_state
        or ctrl.P75StagnationState(
            ctrl.DEFAULT_P75_STAGNATION_DECREASE_PCT,
            ctrl.DEFAULT_P75_STAGNATION_CONSECUTIVE_WINDOWS,
            ctrl.DEFAULT_P75_RESTART_DEGRADATION_PCT,
            ctrl.DEFAULT_P75_RESTART_CONSECUTIVE_WINDOWS,
            ctrl.DEFAULT_REMOTE_RESTART_IMPROVEMENT_PCT,
        ),
    )


class QuantileTests(unittest.TestCase):
    def test_parse_required_kll_fields(self):
        snap = ctrl.parse_quantile_text(KLL_TEXT)
        self.assertEqual(snap.window_seq, 42)
        self.assertEqual(snap.algorithm, ctrl.KLL_ALGORITHM)
        self.assertEqual(snap.value_source, ctrl.KLL_VALUE_SOURCE)
        self.assertEqual(snap.local_total, 2000)
        self.assertEqual(snap.remote_total, 3000)
        self.assertEqual(snap.local_p75_ns, 240000000)
        self.assertEqual(snap.remote_query_rank_ppm, 220000)
        self.assertEqual(snap.remote_query_q_ns, 100000000)
        self.assertTrue(snap.remote_query_valid)
        self.assertEqual(snap.remote_cdf_lt_local_p75_ppm, 200000)
        self.assertEqual(snap.remote_cdf_le_local_p75_ppm, 250000)
        ctrl.validate_quantile_source(snap)

    def test_non_kll_source_is_rejected(self):
        snap = snapshot()
        bad = ctrl.QuantileSnapshot(
            **{
                **snap.__dict__,
                "algorithm": "not_kll",
                "value_source": "not_kll",
            }
        )
        with self.assertRaisesRegex(RuntimeError, "required v4 weighted KLL"):
            ctrl.validate_quantile_source(bad)

    def test_missing_required_value_source_is_rejected(self):
        snap = snapshot()
        bad = ctrl.QuantileSnapshot(**{**snap.__dict__, "value_source": ""})
        with self.assertRaises(RuntimeError):
            ctrl.validate_quantile_source(bad)


class CycleWindowTests(unittest.TestCase):
    def test_cycle_waits_for_minimum_time(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=11,
            last_cycle_count=10,
            elapsed_ms=4999,
            min_sec=5,
            max_sec=20,
        )
        self.assertFalse(gate.ready)

    def test_advanced_cycle_opens_at_minimum_time(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=11,
            last_cycle_count=10,
            elapsed_ms=5000,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "cycle")

    def test_timeout_opens_without_cycle_progress(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=10,
            last_cycle_count=10,
            elapsed_ms=20000,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "max_timeout")


class StopPolicyTests(unittest.TestCase):
    def test_stop_is_strictly_greater_than_threshold(self):
        # Local=40, remote=10: a 90% inclusive CDF gives 9/10 exactly.
        at_boundary = observe(
            snapshot(remote_lt_ppm=0, remote_le_ppm=900000),
            local_pages=40,
            remote_pages=10,
        )
        self.assertAlmostEqual(at_boundary.stop_capacity_ratio, 0.9)
        self.assertFalse(at_boundary.stop_raw)

        above = observe(
            snapshot(remote_lt_ppm=0, remote_le_ppm=900001),
            local_pages=40,
            remote_pages=10,
        )
        self.assertGreater(above.stop_capacity_ratio, 0.9)
        self.assertTrue(above.stop_raw)

    def test_stop_uses_inclusive_remote_cdf(self):
        obs = observe(
            snapshot(remote_lt_ppm=0, remote_le_ppm=250000),
            local_pages=16,
            remote_pages=60,
        )
        self.assertFalse(obs.start_raw)
        self.assertAlmostEqual(obs.local_tail_pages, 4.0)
        self.assertAlmostEqual(obs.remote_candidate_pages, 15.0)
        self.assertAlmostEqual(obs.stop_capacity_ratio, 3.75)
        self.assertTrue(obs.stop_raw)
        self.assertEqual(obs.stop_reason, "capacity_ratio")

    def test_missing_inclusive_cdf_does_not_request_stop(self):
        obs = observe(snapshot(remote_le_ppm=None))
        self.assertFalse(obs.stop_valid)
        self.assertEqual(obs.stop_reason, "missing_inclusive_remote_cdf")
        self.assertFalse(obs.stop_raw)


class StartPolicyTests(unittest.TestCase):
    def test_capacity_selected_quantile_rank_and_latency_boundary(self):
        obs = observe(
            snapshot(remote_lt_ppm=220000),
            local_pages=16,
            remote_pages=60,
        )
        self.assertEqual(obs.local_head_pages, 12.0)
        self.assertEqual(obs.start_capacity_margin_pct, 10)
        self.assertEqual(obs.start_required_pages, 13.2)
        self.assertEqual(obs.start_remote_quantile_rank_ppm, 220000)
        self.assertTrue(obs.start_raw)

        below = observe(
            snapshot(remote_lt_ppm=219999),
            local_pages=16,
            remote_pages=60,
        )
        self.assertFalse(below.start_raw)

    def test_margin_rejects_the_unmargined_boundary(self):
        snap = snapshot(remote_lt_ppm=200000)
        self.assertFalse(observe(snap, margin_pct=10).start_raw)
        self.assertTrue(observe(snap, margin_pct=0).start_raw)

    def test_start_excludes_samples_tied_at_local_p75(self):
        obs = observe(
            snapshot(remote_lt_ppm=219999, remote_le_ppm=250000),
            local_pages=16,
            remote_pages=60,
        )
        self.assertFalse(obs.start_raw)
        self.assertTrue(obs.stop_raw)

    def test_remote_capacity_below_start_requirement_cannot_start(self):
        obs = observe(
            snapshot(remote_lt_ppm=ctrl.PPM),
            local_pages=16,
            remote_pages=10,
        )
        self.assertTrue(obs.start_valid)
        self.assertEqual(
            obs.start_reason, "remote_capacity_below_start_requirement"
        )
        self.assertGreater(obs.start_remote_quantile_rank_ppm, ctrl.PPM)
        self.assertFalse(obs.start_raw)

    def test_two_windows_confirm_and_start_overrides_stop(self):
        state = ctrl.StartState(2)
        first = observe(snapshot(), state=state)
        self.assertTrue(first.stop_raw)
        self.assertTrue(first.start_raw)
        self.assertEqual(first.start_consecutive, 1)
        self.assertFalse(first.start_confirmed)
        self.assertEqual(first.arbitration, "STOP")

        second = observe(snapshot(), state=state)
        self.assertEqual(second.start_consecutive, 2)
        self.assertTrue(second.start_confirmed)
        self.assertEqual(second.arbitration, "START")

    def test_false_and_invalid_windows_reset_confirmation(self):
        state = ctrl.StartState(2)
        observe(snapshot(), state=state)
        confirmed = observe(snapshot(), state=state)
        self.assertTrue(confirmed.start_confirmed)

        false = observe(snapshot(remote_lt_ppm=0), state=state)
        self.assertEqual(false.start_consecutive, 0)
        self.assertFalse(false.start_confirmed)

        observe(snapshot(), state=state)
        invalid = observe(snapshot(remote_lt_ppm=None), state=state)
        self.assertFalse(invalid.start_valid)
        self.assertEqual(invalid.start_reason, "missing_strict_remote_cdf")
        self.assertEqual(invalid.start_consecutive, 0)

    def test_sample_validity_uses_required_fields_only(self):
        obs = observe(snapshot())
        self.assertTrue(obs.start_valid)
        self.assertTrue(obs.stop_valid)

    def test_insufficient_samples_fail_closed(self):
        state = ctrl.StartState(2)
        observe(snapshot(), state=state)
        obs = observe(snapshot(local_total=100), state=state)
        self.assertFalse(obs.start_valid)
        self.assertFalse(obs.stop_valid)
        self.assertEqual(obs.start_reason, "insufficient_local_samples")
        self.assertEqual(obs.start_consecutive, 0)
        self.assertEqual(obs.arbitration, "HOLD")

    def test_current_residency_is_recomputed_for_each_observation(self):
        first = observe(snapshot(), local_pages=16, remote_pages=60)
        second = observe(snapshot(), local_pages=32, remote_pages=44)
        self.assertEqual(first.start_remote_quantile_rank_ppm, 220000)
        self.assertEqual(second.start_remote_quantile_rank_ppm, 600000)
        self.assertTrue(first.start_raw)
        self.assertFalse(second.start_raw)


class P75StagnationPolicyTests(unittest.TestCase):
    def make_states(self, start_windows=2):
        return (
            ctrl.StartState(start_windows),
            ctrl.P75StagnationState(10.0, 3, 10.0, 3, 10.0),
        )

    def latch(self, start_state, p75_state):
        observe(
            snapshot(local_p75_ns=100),
            state=start_state,
            p75_state=p75_state,
        )
        observations = [
            observe(
                snapshot(local_p75_ns=value),
                state=start_state,
                p75_state=p75_state,
            )
            for value in (120, 110, 115)
        ]
        return observations

    def direct_observe(self, state, **kwargs):
        return state.observe(
            current_remote_rank_ppm=220000,
            remote_query_rank_ppm=220000,
            remote_query_q_ns=100,
            remote_query_valid=True,
            **kwargs,
        )

    def test_trigger_latches_max_of_three_incrementing_windows(self):
        start_state, p75_state = self.make_states(start_windows=1)
        observations = self.latch(start_state, p75_state)

        self.assertEqual(
            [item.p75_stagnation_count for item in observations], [1, 2, 3]
        )
        self.assertEqual(
            [item.p75_stagnation_previous_local_p75_ns for item in observations],
            [100, 120, 110],
        )
        latched = observations[-1]
        self.assertEqual(latched.p75_stagnation_state_before, "NORMAL")
        self.assertEqual(latched.p75_stagnation_state, "FORCED_OFF")
        self.assertEqual(
            latched.p75_stagnation_transition, "forced_stop_latched"
        )
        self.assertEqual(
            latched.p75_stagnation_reference_local_p75_ns, 120
        )
        self.assertEqual(
            latched.p75_stagnation_reference_remote_rank_ppm, 220000
        )
        self.assertEqual(latched.p75_stagnation_reference_remote_q_ns, 100)
        self.assertTrue(latched.p75_stagnation_forced_stop)
        self.assertFalse(latched.p75_stagnation_restart)
        self.assertEqual(latched.start_consecutive, 0)
        self.assertFalse(latched.start_confirmed)
        self.assertEqual(latched.arbitration, "STOP")

    def test_three_joint_candidates_restart_immediately(self):
        start_state, p75_state = self.make_states(start_windows=2)
        latched = self.latch(start_state, p75_state)[-1]
        controller_state = ctrl.state_transition("on", latched.arbitration).state
        self.assertEqual(controller_state, "off")

        candidates = [
            observe(
                snapshot(local_p75_ns=132, remote_query_q_ns=90),
                state=start_state,
                p75_state=p75_state,
            )
            for _ in range(3)
        ]
        self.assertEqual(
            [item.p75_stagnation_forced_off_consecutive for item in candidates],
            [1, 2, 3],
        )
        self.assertTrue(all(item.p75_stagnation_degradation_met for item in candidates))
        self.assertTrue(
            all(item.p75_stagnation_remote_improvement_met for item in candidates)
        )
        self.assertEqual([item.arbitration for item in candidates], ["STOP", "STOP", "START"])
        restarted = candidates[-1]
        self.assertEqual(restarted.p75_stagnation_state, "NORMAL")
        self.assertEqual(
            restarted.p75_stagnation_transition, "restart_confirmed"
        )
        self.assertFalse(restarted.p75_stagnation_forced_stop)
        self.assertTrue(restarted.p75_stagnation_restart)
        self.assertEqual(restarted.start_consecutive, 2)
        self.assertTrue(restarted.start_confirmed)
        self.assertEqual(
            ctrl.state_transition(controller_state, restarted.arbitration).state,
            "on",
        )

    def test_forced_off_candidate_failure_resets_three_window_count(self):
        start_state, p75_state = self.make_states()
        self.latch(start_state, p75_state)

        for _ in range(2):
            candidate = observe(
                snapshot(local_p75_ns=132, remote_query_q_ns=90),
                state=start_state,
                p75_state=p75_state,
            )
        self.assertEqual(candidate.p75_stagnation_forced_off_consecutive, 2)

        reset = observe(
            snapshot(local_p75_ns=132, remote_query_q_ns=91),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(reset.p75_stagnation_state, "FORCED_OFF")
        self.assertEqual(reset.p75_stagnation_transition, "forced_off_reset")
        self.assertEqual(reset.p75_stagnation_forced_off_consecutive, 0)

        again = observe(
            snapshot(local_p75_ns=132, remote_query_q_ns=90),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(again.p75_stagnation_forced_off_consecutive, 1)

    def test_remote_query_echo_mismatch_resets_restart_count(self):
        start_state, p75_state = self.make_states()
        self.latch(start_state, p75_state)
        candidate = observe(
            snapshot(local_p75_ns=132, remote_query_q_ns=90),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(candidate.p75_stagnation_forced_off_consecutive, 1)

        invalid = observe(
            snapshot(
                local_p75_ns=132,
                remote_query_rank_ppm=219999,
                remote_query_q_ns=90,
            ),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(invalid.p75_stagnation_state, "FORCED_OFF")
        self.assertEqual(invalid.p75_stagnation_transition, "forced_off_invalid")
        self.assertFalse(invalid.p75_stagnation_remote_query_match)
        self.assertEqual(invalid.p75_stagnation_forced_off_consecutive, 0)
        self.assertEqual(invalid.arbitration, "STOP")

        restarted_count = observe(
            snapshot(local_p75_ns=132, remote_query_q_ns=90),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(
            restarted_count.p75_stagnation_forced_off_consecutive, 1
        )

    def test_exact_ten_percent_degradation_qualifies_but_raw_start_is_required(self):
        start_state, p75_state = self.make_states()
        self.latch(start_state, p75_state)

        exact = observe(
            snapshot(local_p75_ns=132, remote_query_q_ns=90),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(exact.p75_stagnation_degradation_pct, 10.0)
        self.assertTrue(exact.p75_stagnation_degradation_met)
        self.assertEqual(exact.p75_stagnation_remote_improvement_pct, 10.0)
        self.assertTrue(exact.p75_stagnation_remote_improvement_met)
        self.assertEqual(exact.p75_stagnation_forced_off_consecutive, 1)

        no_raw_start = observe(
            snapshot(
                local_p75_ns=140,
                remote_query_q_ns=90,
                remote_lt_ppm=0,
            ),
            state=start_state,
            p75_state=p75_state,
        )
        self.assertTrue(no_raw_start.start_valid)
        self.assertFalse(no_raw_start.start_raw)
        self.assertTrue(no_raw_start.p75_stagnation_degradation_met)
        self.assertEqual(
            no_raw_start.p75_stagnation_forced_off_consecutive, 0
        )
        self.assertEqual(no_raw_start.arbitration, "STOP")

    def test_forced_off_freezes_query_rank_but_start_uses_current_capacity(self):
        start_state, p75_state = self.make_states()
        self.latch(start_state, p75_state)
        self.assertEqual(p75_state.query_rank_ppm(600000), 220000)

        candidate = observe(
            snapshot(
                local_p75_ns=132,
                remote_query_rank_ppm=220000,
                remote_query_q_ns=90,
                remote_lt_ppm=600000,
            ),
            local_pages=32,
            remote_pages=44,
            state=start_state,
            p75_state=p75_state,
        )
        self.assertEqual(candidate.start_remote_quantile_rank_ppm, 600000)
        self.assertTrue(candidate.start_raw)
        self.assertTrue(candidate.p75_stagnation_remote_query_match)
        self.assertEqual(candidate.p75_stagnation_forced_off_consecutive, 1)

    def test_exact_ten_percent_drop_resets_count(self):
        below_state = ctrl.P75StagnationState(10.0, 3)
        self.direct_observe(
            below_state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=1000,
        )
        below_threshold = self.direct_observe(
            below_state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=901,
        )
        self.assertAlmostEqual(below_threshold.decrease_pct, 9.9)
        self.assertEqual(below_threshold.count, 1)

        exact_state = ctrl.P75StagnationState(10.0, 3)
        self.direct_observe(
            exact_state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=1000,
        )
        exact_threshold = self.direct_observe(
            exact_state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=900,
        )
        self.assertEqual(exact_threshold.decrease_pct, 10.0)
        self.assertEqual(exact_threshold.count, 0)

    def test_overlap_break_resets_count_but_keeps_latest_valid_baseline(self):
        state = ctrl.P75StagnationState(10.0, 3)
        self.direct_observe(
            state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=100,
        )
        self.direct_observe(
            state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=95,
        )

        no_overlap = self.direct_observe(
            state,
            start_valid=True,
            start_raw=False,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=80,
        )
        self.assertEqual(no_overlap.count, 0)

        overlap_returns = self.direct_observe(
            state,
            start_valid=True,
            start_raw=True,
            stop_valid=True,
            stop_raw=True,
            local_p75_ns=75,
        )
        self.assertEqual(overlap_returns.previous_local_p75_ns, 80)
        self.assertAlmostEqual(overlap_returns.decrease_pct, 6.25)
        self.assertEqual(overlap_returns.count, 1)

    def test_invalid_or_zero_p75_resets_count_and_baseline(self):
        for invalid_kwargs in (
            {
                "start_valid": False,
                "start_raw": False,
                "stop_valid": True,
                "stop_raw": True,
                "local_p75_ns": 94,
            },
            {
                "start_valid": True,
                "start_raw": True,
                "stop_valid": True,
                "stop_raw": True,
                "local_p75_ns": 0,
            },
        ):
            with self.subTest(invalid_kwargs=invalid_kwargs):
                state = ctrl.P75StagnationState(10.0, 3)
                self.direct_observe(
                    state,
                    start_valid=True,
                    start_raw=True,
                    stop_valid=True,
                    stop_raw=True,
                    local_p75_ns=100,
                )
                self.direct_observe(
                    state,
                    start_valid=True,
                    start_raw=True,
                    stop_valid=True,
                    stop_raw=True,
                    local_p75_ns=95,
                )
                reset = self.direct_observe(state, **invalid_kwargs)
                self.assertEqual(reset.count, 0)
                self.assertFalse(reset.forced_stop)

                new_baseline = self.direct_observe(
                    state,
                    start_valid=True,
                    start_raw=True,
                    stop_valid=True,
                    stop_raw=True,
                    local_p75_ns=90,
                )
                self.assertIsNone(new_baseline.previous_local_p75_ns)
                self.assertIsNone(new_baseline.decrease_pct)
                self.assertEqual(new_baseline.count, 0)


class TransitionTests(unittest.TestCase):
    def test_start_turns_off_state_on(self):
        transition = ctrl.state_transition("off", "START")
        self.assertEqual(transition.event, "on")
        self.assertEqual(transition.state, "on")
        self.assertEqual(transition.action, "migration_start")
        self.assertEqual(transition.migration_enabled, 1)

    def test_stop_turns_on_state_off(self):
        transition = ctrl.state_transition("on", "STOP")
        self.assertEqual(transition.event, "off")
        self.assertEqual(transition.state, "off")
        self.assertEqual(transition.migration_enabled, 0)

    def test_hold_preserves_both_states_without_a_write(self):
        for state in ("on", "off"):
            with self.subTest(state=state):
                transition = ctrl.state_transition(state, "HOLD")
                self.assertEqual(transition.state, state)
                self.assertIsNone(transition.migration_enabled)


class ResidentCapacityTests(unittest.TestCase):
    def test_process_tree_pages_are_aggregated(self):
        with mock.patch.object(ctrl, "parse_pid_file", return_value=10), mock.patch.object(
            ctrl, "collect_process_tree", return_value=[10, 11, 12]
        ), mock.patch.object(
            ctrl,
            "read_numa_maps_node_pages",
            side_effect=[(100, 200), None, (300, 400)],
        ):
            pages = ctrl.read_resident_pages_from_pid_file(Path("pid"), 0, 1)
        self.assertEqual(pages, (400, 600))

    def test_missing_pid_file_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            pages = ctrl.read_resident_pages_from_pid_file(
                Path(tmp) / "missing.pid", 0, 1
            )
        self.assertIsNone(pages)

    def test_zero_resident_capacity_is_invalid(self):
        obs = observe(snapshot(), local_pages=0, remote_pages=60)
        self.assertFalse(obs.start_valid)
        self.assertFalse(obs.stop_valid)
        self.assertEqual(obs.start_reason, "missing_resident_capacity")


class InterfaceTests(unittest.TestCase):
    def test_final_cli_defaults(self):
        args = ctrl.parse_args(["--workload-pid-file", "/tmp/workload.pid"])
        self.assertEqual(args.start_consecutive, 2)
        self.assertEqual(args.start_capacity_margin_pct, 10)
        self.assertEqual(args.stop_capacity_ratio_threshold, 0.9)
        self.assertEqual(args.p75_stagnation_required_decrease_pct, 10.0)
        self.assertEqual(args.p75_stagnation_required_windows, 3)
        self.assertEqual(args.p75_stagnation_restart_degradation_pct, 10.0)
        self.assertEqual(args.p75_stagnation_restart_required_windows, 3)
        self.assertEqual(args.remote_restart_improvement_pct, 10.0)
        self.assertEqual(args.cycle_window_min_sec, 5.0)
        self.assertEqual(args.cycle_window_max_sec, 20.0)
        self.assertEqual(args.local_node, 0)
        self.assertEqual(args.remote_node, 1)

    def test_local_sampling_cannot_be_disabled(self):
        with mock.patch("sys.stderr", new=io.StringIO()):
            with self.assertRaises(SystemExit):
                ctrl.parse_args(
                    [
                        "--workload-pid-file",
                        "/tmp/workload.pid",
                        "--local-rate",
                        "0",
                    ]
                )

    def test_compact_csv_has_only_final_policy_fields(self):
        required = {
            "local_p75_ns",
            "remote_cdf_lt_local_p75_ppm",
            "remote_cdf_le_local_p75_ppm",
            "stop_capacity_ratio",
            "start_capacity_margin_pct",
            "start_required_pages",
            "start_remote_quantile_rank_ppm",
            "start_consecutive",
            "start_confirmed",
            "p75_stagnation_required_decrease_pct",
            "p75_stagnation_required_windows",
            "p75_stagnation_restart_degradation_pct",
            "p75_stagnation_restart_required_windows",
            "remote_restart_improvement_pct",
            "p75_stagnation_previous_local_p75_ns",
            "p75_stagnation_decrease_pct",
            "p75_stagnation_count",
            "p75_stagnation_state_before",
            "p75_stagnation_state",
            "p75_stagnation_transition",
            "p75_stagnation_reference_local_p75_ns",
            "p75_stagnation_reference_remote_rank_ppm",
            "p75_stagnation_reference_remote_q_ns",
            "p75_stagnation_degradation_pct",
            "p75_stagnation_degradation_met",
            "p75_stagnation_remote_query_match",
            "p75_stagnation_remote_improvement_pct",
            "p75_stagnation_remote_improvement_met",
            "p75_stagnation_forced_off_consecutive",
            "p75_stagnation_forced_stop",
            "p75_stagnation_restart",
            "arbitration",
        }
        self.assertTrue(required.issubset(ctrl.CSV_FIELDS))
        removed = {
            "remote_percentile_ppm",
            "remote_fast_pages",
            "timestamp",
            "controller_state_before",
            "numa_balancing",
            "migration_enabled",
            "quantile_algorithm",
            "quantile_value_source",
            "rank_error_ppm",
            "sample_file",
        }
        self.assertTrue(removed.isdisjoint(ctrl.CSV_FIELDS))

    def test_controller_loop_uses_minimal_sysfs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sysfs = root / "numa_balancing"
            sysfs.mkdir()
            invalid_kll = KLL_TEXT.replace(
                "local_total 2000", "local_total 0"
            ).replace("remote_total 3000", "remote_total 0")
            for name, value in (
                ("fault_latency_quantiles", invalid_kll),
                ("remote_quantile_rank_ppm", "0\n"),
                ("local_fault_window", "0\n"),
                ("local_fault_rate", "0\n"),
                ("migration_enabled", "0\n"),
                ("remote_scan_cycles", "0\n"),
            ):
                (sysfs / name).write_text(value, encoding="ascii")
            numa_balancing = root / "numa_balancing.proc"
            numa_balancing.write_text("0\n", encoding="ascii")
            pid_file = root / "workload.pid"
            pid_file.write_text(f"{os.getpid()}\n", encoding="ascii")
            output = root / "controller.csv"
            args = ctrl.parse_args(
                [
                    "--workload-pid-file",
                    str(pid_file),
                    "--sysfs-numa-dir",
                    str(sysfs),
                    "--numa-balancing-path",
                    str(numa_balancing),
                    "--output",
                    str(output),
                    "--window-sec",
                    "0.001",
                    "--cycle-window-min-sec",
                    "0",
                    "--cycle-window-max-sec",
                    "0.003",
                    "--max-windows",
                    "1",
                ]
            )
            self.assertEqual(ctrl.run_controller(args), 0)

            self.assertEqual(numa_balancing.read_text(encoding="ascii"), "2\n")
            self.assertEqual(
                (sysfs / "migration_enabled").read_text(encoding="ascii"), "1\n"
            )
            self.assertEqual(
                (sysfs / "local_fault_rate").read_text(encoding="ascii"), "5\n"
            )
            with output.open(newline="", encoding="ascii") as source:
                rows = list(csv.DictReader(source))
            self.assertEqual([row["event"] for row in rows], ["start", "sample", "exit"])
            self.assertEqual(rows[1]["cycle_window_reason"], "max_timeout")
            self.assertTrue(
                all(row["start_capacity_margin_pct"] == "10" for row in rows)
            )
            self.assertEqual(rows[1]["p75_stagnation_count"], "0")
            self.assertEqual(rows[1]["p75_stagnation_forced_stop"], "0")
            self.assertEqual(rows[1]["p75_stagnation_state"], "NORMAL")
            self.assertEqual(rows[1]["p75_stagnation_restart"], "0")
            self.assertEqual(
                rows[1]["p75_stagnation_required_decrease_pct"], "10.0"
            )
            self.assertEqual(rows[1]["p75_stagnation_required_windows"], "3")
            self.assertEqual(
                rows[1]["p75_stagnation_restart_degradation_pct"], "10.0"
            )
            self.assertEqual(
                rows[1]["p75_stagnation_restart_required_windows"], "3"
            )
            self.assertEqual(rows[1]["remote_restart_improvement_pct"], "10.0")


if __name__ == "__main__":
    unittest.main()
