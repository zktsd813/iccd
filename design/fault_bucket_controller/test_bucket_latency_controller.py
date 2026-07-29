#!/usr/bin/env python3

import csv
import io
import os
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

import bucket_latency_controller as ctrl


V5_TEXT = """\
schema quantile_snapshot_v5
window_seq 42
algorithm kll_weighted_ms_v1
value_source sketch_latency_ms_to_ns
local_protected_pages 1000
local_cancelled_pages 0
local_dropped_fault_pages 7
remote_protected_pages 1000
remote_cancelled_pages 0
remote_dropped_fault_pages 11
local_total 500
remote_total 100
local_q75_ns 240000000
local_cdf_lt_local_q75_ppm 740000
local_cdf_le_local_q75_ppm 750000
remote_cdf_lt_local_q75_ppm 490000
remote_cdf_le_local_q75_ppm 500000
"""


def snapshot(
    *,
    window_seq=2,
    local_protected=1000,
    local_cancelled=0,
    remote_protected=1000,
    remote_cancelled=0,
    local_faults=1000,
    remote_faults=1000,
    local_le_ppm=750000,
    remote_le_ppm=500000,
    local_lt_ppm=None,
    remote_lt_ppm=None,
    local_p75_ns=240,
):
    return ctrl.QuantileSnapshot(
        schema=ctrl.QUANTILE_SCHEMA,
        window_seq=window_seq,
        algorithm=ctrl.QUANTILE_ALGORITHM,
        value_source=ctrl.QUANTILE_VALUE_SOURCE,
        local_protected_pages=local_protected,
        local_cancelled_pages=local_cancelled,
        local_dropped_fault_pages=0,
        remote_protected_pages=remote_protected,
        remote_cancelled_pages=remote_cancelled,
        remote_dropped_fault_pages=0,
        local_fault_pages=local_faults,
        remote_fault_pages=remote_faults,
        local_p75_ns=local_p75_ns,
        local_cdf_lt_local_p75_ppm=(
            max(0, local_le_ppm - 10000)
            if local_lt_ppm is None
            else local_lt_ppm
        ),
        local_cdf_le_local_p75_ppm=local_le_ppm,
        remote_cdf_lt_local_p75_ppm=(
            max(0, remote_le_ppm - 10000)
            if remote_lt_ppm is None
            else remote_lt_ppm
        ),
        remote_cdf_le_local_p75_ppm=remote_le_ppm,
    )


def start_snapshot(*, window_seq=2, **kwargs):
    """Return a valid window exactly on the default START gap boundary."""
    kwargs.setdefault("local_lt_ppm", 740000)
    kwargs.setdefault("remote_lt_ppm", 840000)
    kwargs.setdefault("remote_le_ppm", 950000)
    return snapshot(
        window_seq=window_seq,
        **kwargs,
    )


def observe(
    snap,
    *,
    state=None,
    controller_state="on",
    local_resident_pages=1000,
    remote_resident_pages=1000,
    local_capacity_pages=1000,
    start_cdf_gap_ppm=ctrl.DEFAULT_START_CDF_GAP_PPM,
    start_cdf_gap_reduction_ppm=ctrl.DEFAULT_START_CDF_GAP_REDUCTION_PPM,
    start_hot_coverage_ppm=ctrl.DEFAULT_START_HOT_COVERAGE_PPM,
    stop_hot_coverage_ppm=ctrl.DEFAULT_STOP_HOT_COVERAGE_PPM,
    start_stagnation_windows=ctrl.DEFAULT_START_STAGNATION_WINDOWS,
    start_policy=ctrl.DEFAULT_START_POLICY,
    stop_capacity_ratio_threshold=ctrl.DEFAULT_STOP_CAPACITY_RATIO_THRESHOLD,
):
    if state is None:
        state = ctrl.StartDecisionState(1)
    return ctrl.evaluate_window_capacity_policy(
        snap,
        controller_state=controller_state,
        local_resident_pages=local_resident_pages,
        remote_resident_pages=remote_resident_pages,
        local_capacity_pages=local_capacity_pages,
        local_target_pct=75,
        min_protected_pages=256,
        min_local_fault_pages=16,
        start_cdf_gap_ppm=start_cdf_gap_ppm,
        start_cdf_gap_reduction_ppm=start_cdf_gap_reduction_ppm,
        start_hot_coverage_ppm=start_hot_coverage_ppm,
        stop_hot_coverage_ppm=stop_hot_coverage_ppm,
        start_stagnation_windows=start_stagnation_windows,
        start_policy=start_policy,
        stop_capacity_ratio_threshold=stop_capacity_ratio_threshold,
        decision_state=state,
    )


class QuantileParserTests(unittest.TestCase):
    def test_parse_complete_v5_snapshot(self):
        parsed = ctrl.parse_quantile_text(V5_TEXT)
        self.assertEqual(parsed.schema, ctrl.QUANTILE_SCHEMA)
        self.assertEqual(parsed.window_seq, 42)
        self.assertEqual(parsed.local_protected_pages, 1000)
        self.assertEqual(parsed.remote_protected_pages, 1000)
        self.assertEqual(parsed.local_fault_pages, 500)
        self.assertEqual(parsed.remote_fault_pages, 100)
        self.assertEqual(parsed.local_dropped_fault_pages, 7)
        self.assertEqual(parsed.remote_dropped_fault_pages, 11)
        self.assertEqual(parsed.local_cdf_le_local_p75_ppm, 750000)
        self.assertEqual(parsed.remote_cdf_le_local_p75_ppm, 500000)

    def test_missing_fields_remain_missing(self):
        parsed = ctrl.parse_quantile_text(
            "schema quantile_snapshot_v5\nwindow_seq 1\n"
        )
        self.assertIsNone(parsed.local_protected_pages)
        self.assertIsNone(parsed.remote_fault_pages)
        self.assertIsNone(parsed.local_cdf_le_local_p75_ppm)

    def test_parser_accepts_key_equals_value(self):
        parsed = ctrl.parse_quantile_text(
            V5_TEXT.replace("window_seq 42", "window_seq=43")
        )
        self.assertEqual(parsed.window_seq, 43)

    def test_required_v5_abi_accepts_complete_snapshot(self):
        ctrl.require_quantile_abi(ctrl.parse_quantile_text(V5_TEXT))

    def test_required_v5_abi_rejects_old_schema(self):
        parsed = ctrl.parse_quantile_text(
            V5_TEXT.replace("quantile_snapshot_v5", "quantile_snapshot_v4")
        )
        with self.assertRaisesRegex(RuntimeError, "incompatible quantile schema"):
            ctrl.require_quantile_abi(parsed)

    def test_required_v5_abi_rejects_missing_audit_field(self):
        parsed = ctrl.parse_quantile_text(
            V5_TEXT.replace("local_dropped_fault_pages 7\n", "")
        )
        with self.assertRaisesRegex(
            RuntimeError,
            "local_dropped_fault_pages",
        ):
            ctrl.require_quantile_abi(parsed)


class CycleWindowTests(unittest.TestCase):
    def test_cycle_waits_for_minimum_time(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=2,
            last_cycle_count=1,
            elapsed_ms=4999,
            min_sec=5,
            max_sec=20,
        )
        self.assertFalse(gate.ready)

    def test_advanced_cycle_opens_at_minimum_time(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=2,
            last_cycle_count=1,
            elapsed_ms=5000,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "cycle")

    def test_timeout_opens_without_cycle_progress(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=1,
            last_cycle_count=1,
            elapsed_ms=20000,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "max_timeout")

    def test_cycle_at_maximum_is_accepted(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=2,
            last_cycle_count=1,
            elapsed_ms=20000,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "cycle")

    def test_cycle_after_maximum_is_timeout(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=2,
            last_cycle_count=1,
            elapsed_ms=20001,
            min_sec=5,
            max_sec=20,
        )
        self.assertTrue(gate.ready)
        self.assertEqual(gate.reason, "max_timeout")

    def test_zero_timeout_waits_for_cycle_indefinitely(self):
        gate = ctrl.cycle_window_gate(
            cycle_count=1,
            last_cycle_count=1,
            elapsed_ms=60000,
            min_sec=5,
            max_sec=0,
        )
        self.assertFalse(gate.ready)

    def test_first_cycle_is_warmup_then_alignment_is_ready(self):
        alignment = ctrl.CycleWindowAlignment()
        self.assertEqual(
            alignment.invalid_reason("cycle"),
            "cycle_alignment_warmup",
        )
        self.assertIsNone(alignment.invalid_reason("cycle"))

    def test_timeout_is_a_policy_window_and_preserves_cycle_alignment(self):
        alignment = ctrl.CycleWindowAlignment()
        alignment.invalid_reason("cycle")
        self.assertIsNone(alignment.invalid_reason("cycle"))
        self.assertIsNone(alignment.invalid_reason("max_timeout"))
        self.assertIsNone(alignment.invalid_reason("cycle"))

    def test_timeout_before_first_cycle_establishes_sampling_boundary(self):
        alignment = ctrl.CycleWindowAlignment()
        self.assertIsNone(alignment.invalid_reason("max_timeout"))
        self.assertIsNone(alignment.invalid_reason("cycle"))

    def test_late_cycle_timeout_preserves_existing_alignment(self):
        alignment = ctrl.CycleWindowAlignment()
        alignment.invalid_reason("cycle")
        self.assertIsNone(alignment.invalid_reason("cycle"))

        late = ctrl.cycle_window_gate(
            cycle_count=3,
            last_cycle_count=2,
            elapsed_ms=20001,
            min_sec=5,
            max_sec=20,
        )
        self.assertEqual(late.reason, "max_timeout")
        self.assertIsNone(alignment.invalid_reason(late.reason))
        self.assertIsNone(alignment.invalid_reason("cycle"))


class StartDecisionStateTests(unittest.TestCase):
    def test_distinct_positive_windows_are_fresh(self):
        state = ctrl.StartDecisionState(1)
        self.assertTrue(state.observe_window(window_seq=1))
        self.assertTrue(state.observe_window(window_seq=3))

    def test_duplicate_preserves_start_baseline(self):
        state = ctrl.StartDecisionState(1)
        self.assertTrue(state.observe_window(window_seq=4))
        state.record_start(150000)
        self.assertFalse(state.observe_window(window_seq=4))
        self.assertEqual(state.start_baseline_gap_ppm, 150000)

    def test_invalid_sequence_value_preserves_start_baseline(self):
        state = ctrl.StartDecisionState(1)
        state.record_start(150000)
        self.assertFalse(state.observe_window(window_seq=0))
        self.assertEqual(state.start_baseline_gap_ppm, 150000)

    def test_baseline_is_fixed_until_recorded_stop(self):
        state = ctrl.StartDecisionState(1)
        state.record_start(150000)
        state.observe_window(window_seq=1)
        state.observe_window(window_seq=2)
        self.assertEqual(state.start_baseline_gap_ppm, 150000)
        state.record_stop()
        self.assertIsNone(state.start_baseline_gap_ppm)

    def test_window_confirmation_must_be_positive(self):
        for count in (0, -1):
            with self.subTest(count=count), self.assertRaisesRegex(
                ValueError,
                "must be >= 1",
            ):
                ctrl.StartDecisionState(count)

    def test_window_confirmation_counts_consecutive_start_raw(self):
        state = ctrl.StartDecisionState(2)
        self.assertEqual(state.observe_start_raw(True), 1)
        self.assertEqual(state.observe_start_raw(True), 2)
        self.assertEqual(state.observe_start_raw(False), 0)


class WindowCdfGapPolicyTests(unittest.TestCase):
    def test_start_and_stop_are_independent_signals(self):
        result = observe(start_snapshot())
        self.assertTrue(result.valid)
        self.assertEqual(result.local_p75_slow_pages, 250.0)
        self.assertEqual(result.remote_p75_fast_pages, 950.0)
        self.assertEqual(result.start_cdf_gap_ppm, 100000)
        self.assertIsNone(result.start_cdf_gap_baseline_ppm)
        self.assertIsNone(result.start_cdf_gap_reduction_ppm)
        self.assertFalse(result.start_retention_raw)
        self.assertTrue(result.start_raw)
        self.assertEqual(result.stop_capacity_ratio, 3.8)
        self.assertTrue(result.stop_raw)
        self.assertEqual(result.start_consecutive, 0)
        self.assertFalse(result.start_confirmed)
        self.assertEqual(result.arbitration, "STOP")

    def test_stop_mass_uses_inclusive_p75_cdf(self):
        snap = ctrl.QuantileSnapshot(
            **{
                **snapshot().__dict__,
                "local_cdf_lt_local_p75_ppm": 100000,
                "remote_cdf_lt_local_p75_ppm": 0,
            }
        )
        result = observe(snap)
        self.assertTrue(result.valid)
        self.assertEqual(result.local_p75_slow_pages, 250.0)
        self.assertEqual(result.remote_p75_fast_pages, 500.0)

    def test_rss_stop_mass_above_target_does_not_block_start_signal(self):
        result = observe(start_snapshot(local_faults=1000))
        self.assertEqual(result.local_p75_slow_pages, 250.0)
        self.assertEqual(result.remote_p75_fast_pages, 950.0)
        self.assertTrue(result.start_raw)
        self.assertTrue(result.stop_raw)
        self.assertEqual(result.arbitration, "STOP")

    def test_rss_stop_mass_does_not_create_start(self):
        result = observe(snapshot(local_faults=900, remote_faults=150))
        self.assertEqual(result.local_p75_slow_pages, 250.0)
        self.assertEqual(result.remote_p75_fast_pages, 500.0)
        self.assertFalse(result.start_raw)

    def test_start_cdf_gap_uses_inclusive_integer_boundary(self):
        equal = observe(start_snapshot())
        just_below = observe(
            snapshot(
                local_lt_ppm=740000,
                remote_lt_ppm=839999,
                remote_le_ppm=950000,
            )
        )
        self.assertEqual(equal.start_cdf_gap_ppm, 100000)
        self.assertEqual(just_below.start_cdf_gap_ppm, 99999)
        self.assertTrue(equal.start_raw)
        self.assertFalse(just_below.start_raw)

    def test_start_uses_strict_cdfs_not_inclusive_cdfs(self):
        low_inclusive = observe(start_snapshot(local_le_ppm=740000))
        high_inclusive = observe(
            start_snapshot(local_le_ppm=1000000, remote_le_ppm=1000000)
        )
        self.assertTrue(low_inclusive.start_raw)
        self.assertTrue(high_inclusive.start_raw)
        self.assertEqual(
            low_inclusive.start_cdf_gap_ppm,
            high_inclusive.start_cdf_gap_ppm,
        )

    def test_zero_remote_candidates_do_not_request_stop(self):
        result = observe(snapshot(remote_faults=0, remote_le_ppm=0))
        self.assertTrue(result.valid)
        self.assertEqual(result.remote_p75_fast_pages, 0.0)
        self.assertEqual(result.stop_capacity_ratio, 0.0)
        self.assertFalse(result.start_raw)
        self.assertFalse(result.stop_raw)
        self.assertEqual(result.arbitration, "HOLD")

    def test_stop_uses_strict_ratio_boundary(self):
        equal = observe(snapshot(remote_le_ppm=225000))
        above = observe(snapshot(remote_le_ppm=225001))
        self.assertEqual(equal.local_p75_slow_pages, 250.0)
        self.assertEqual(equal.remote_p75_fast_pages, 225.0)
        self.assertEqual(equal.stop_capacity_ratio, 0.9)
        self.assertFalse(equal.stop_raw)
        self.assertGreater(above.stop_capacity_ratio, 0.9)
        self.assertTrue(above.stop_raw)

    def test_zero_local_slow_mass_uses_exact_cross_product(self):
        positive_remote = observe(
            snapshot(
                local_le_ppm=1000000,
                remote_faults=1,
                remote_le_ppm=1000000,
            )
        )
        zero_remote = observe(
            snapshot(
                local_le_ppm=1000000,
                remote_faults=0,
                remote_le_ppm=0,
            )
        )

        self.assertEqual(positive_remote.local_p75_slow_pages, 0.0)
        self.assertEqual(positive_remote.remote_p75_fast_pages, 1000.0)
        self.assertEqual(positive_remote.stop_capacity_ratio, float("inf"))
        self.assertTrue(positive_remote.stop_raw)
        self.assertEqual(positive_remote.arbitration, "STOP")

        self.assertEqual(zero_remote.local_p75_slow_pages, 0.0)
        self.assertEqual(zero_remote.remote_p75_fast_pages, 0.0)
        self.assertIsNone(zero_remote.stop_capacity_ratio)
        self.assertFalse(zero_remote.stop_raw)
        self.assertEqual(zero_remote.arbitration, "HOLD")

    def test_custom_stop_threshold_uses_exact_decimal_boundary(self):
        threshold = ctrl.positive_decimal("0.8")
        equal = observe(
            snapshot(remote_le_ppm=200000),
            stop_capacity_ratio_threshold=threshold,
        )
        above = observe(
            snapshot(remote_le_ppm=200001),
            stop_capacity_ratio_threshold=threshold,
        )
        self.assertEqual(equal.stop_capacity_ratio, 0.8)
        self.assertFalse(equal.stop_raw)
        self.assertTrue(above.stop_raw)

    def test_policy_rejects_nonpositive_or_nonfinite_stop_threshold(self):
        for threshold in (
            Decimal("0"),
            Decimal("-0.1"),
            Decimal("NaN"),
            Decimal("Infinity"),
        ):
            with self.subTest(threshold=threshold), self.assertRaises(ValueError):
                observe(
                    snapshot(),
                    stop_capacity_ratio_threshold=threshold,
                )

    def test_stop_uses_inclusive_remote_cdf(self):
        snap = ctrl.QuantileSnapshot(
            **{
                **snapshot(remote_le_ppm=225001).__dict__,
                "remote_cdf_lt_local_p75_ppm": 0,
            }
        )
        result = observe(snap)
        self.assertTrue(result.stop_raw)

    def test_stop_scales_with_resident_page_mass_not_installed_fault_density(self):
        below = observe(snapshot(remote_faults=1000), remote_resident_pages=400)
        above = observe(snapshot(remote_faults=1), remote_resident_pages=500)
        self.assertEqual(below.stop_capacity_ratio, 0.8)
        self.assertFalse(below.stop_raw)
        self.assertEqual(above.stop_capacity_ratio, 1.0)
        self.assertTrue(above.stop_raw)

    def test_state_gated_trace_skips_one_window_after_start_then_stops(self):
        state = ctrl.StartDecisionState(1)
        seq9 = observe(
            start_snapshot(window_seq=9),
            state=state,
            controller_state="off",
        )
        self.assertTrue(seq9.start_raw and seq9.stop_raw)
        self.assertEqual(seq9.start_consecutive, 1)
        self.assertTrue(seq9.start_confirmed)
        self.assertEqual(seq9.arbitration, "START")
        started = ctrl.state_transition("off", seq9.arbitration)
        self.assertEqual(started.state, "on")

        seq10 = observe(
            start_snapshot(window_seq=10),
            state=state,
            controller_state=started.state,
        )
        self.assertTrue(seq10.start_raw)
        self.assertTrue(seq10.stop_raw)
        self.assertEqual(seq10.start_cdf_gap_baseline_ppm, 100000)
        self.assertEqual(seq10.start_cdf_gap_reduction_ppm, 0)
        self.assertFalse(seq10.start_retention_raw)
        self.assertEqual(seq10.start_consecutive, 0)
        self.assertFalse(seq10.start_confirmed)
        self.assertTrue(seq10.decision_cooldown_raw)
        self.assertEqual(seq10.arbitration, "HOLD")

        seq11 = observe(
            start_snapshot(window_seq=11),
            state=state,
            controller_state=started.state,
        )
        self.assertTrue(seq11.stop_raw)
        self.assertFalse(seq11.decision_cooldown_raw)
        self.assertEqual(seq11.arbitration, "STOP")
        stopped = ctrl.state_transition(started.state, seq11.arbitration)
        self.assertEqual(stopped.state, "off")

    def test_exact_reduction_boundary_retains_on_over_stop(self):
        state = ctrl.StartDecisionState(1)
        started = observe(
            start_snapshot(window_seq=1),
            state=state,
            controller_state="off",
        )
        retained = observe(
            snapshot(
                window_seq=2,
                local_lt_ppm=740000,
                remote_lt_ppm=790000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        self.assertEqual(started.start_cdf_gap_baseline_ppm, 100000)
        self.assertEqual(retained.start_cdf_gap_baseline_ppm, 100000)
        self.assertEqual(retained.start_cdf_gap_reduction_ppm, 50000)
        self.assertTrue(retained.start_retention_raw)
        self.assertTrue(retained.stop_raw)
        self.assertEqual(retained.arbitration, "HOLD")
        self.assertEqual(state.start_baseline_gap_ppm, 100000)

    def test_reduction_one_ppm_below_boundary_allows_stop(self):
        state = ctrl.StartDecisionState(1)
        observe(
            start_snapshot(window_seq=1),
            state=state,
            controller_state="off",
        )
        cooldown = observe(
            snapshot(
                window_seq=2,
                local_lt_ppm=740000,
                remote_lt_ppm=790001,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        self.assertEqual(cooldown.start_cdf_gap_reduction_ppm, 49999)
        self.assertFalse(cooldown.start_retention_raw)
        self.assertTrue(cooldown.stop_raw)
        self.assertTrue(cooldown.decision_cooldown_raw)
        self.assertEqual(cooldown.arbitration, "HOLD")
        self.assertEqual(state.start_baseline_gap_ppm, 100000)

        stopped = observe(
            snapshot(
                window_seq=3,
                local_lt_ppm=740000,
                remote_lt_ppm=790001,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        self.assertFalse(stopped.decision_cooldown_raw)
        self.assertTrue(stopped.stop_raw)
        self.assertEqual(stopped.arbitration, "STOP")
        self.assertIsNone(state.start_baseline_gap_ppm)
        restart_cooldown = observe(
            start_snapshot(window_seq=4),
            state=state,
            controller_state="off",
        )
        self.assertTrue(restart_cooldown.decision_cooldown_raw)
        self.assertEqual(restart_cooldown.arbitration, "HOLD")

        restarted = observe(
            start_snapshot(window_seq=5),
            state=state,
            controller_state="off",
        )
        self.assertFalse(restarted.decision_cooldown_raw)
        self.assertEqual(restarted.arbitration, "START")
        self.assertEqual(restarted.start_cdf_gap_baseline_ppm, 100000)

    def test_start_baseline_stays_fixed_across_retained_windows(self):
        state = ctrl.StartDecisionState(1)
        started = observe(
            snapshot(
                window_seq=1,
                local_lt_ppm=740000,
                remote_lt_ppm=890000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="off",
        )
        first = observe(
            snapshot(
                window_seq=2,
                local_lt_ppm=740000,
                remote_lt_ppm=830000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        second = observe(
            snapshot(
                window_seq=3,
                local_lt_ppm=740000,
                remote_lt_ppm=820000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        self.assertEqual(started.start_cdf_gap_baseline_ppm, 150000)
        self.assertEqual(first.start_cdf_gap_baseline_ppm, 150000)
        self.assertEqual(second.start_cdf_gap_baseline_ppm, 150000)
        self.assertEqual(first.start_cdf_gap_reduction_ppm, 60000)
        self.assertEqual(second.start_cdf_gap_reduction_ppm, 70000)
        self.assertEqual(first.arbitration, "HOLD")
        self.assertEqual(second.arbitration, "HOLD")

    def test_initial_on_without_start_baseline_uses_stop_immediately(self):
        state = ctrl.StartDecisionState(1)
        result = observe(snapshot(window_seq=1), state=state, controller_state="on")
        self.assertIsNone(result.start_cdf_gap_baseline_ppm)
        self.assertIsNone(result.start_cdf_gap_reduction_ppm)
        self.assertFalse(result.start_retention_raw)
        self.assertTrue(result.stop_raw)
        self.assertEqual(result.arbitration, "STOP")

    def test_on_ignores_start_when_stop_is_false(self):
        result = observe(
            start_snapshot(remote_faults=200),
            controller_state="on",
            remote_resident_pages=200,
        )
        self.assertTrue(result.start_raw)
        self.assertFalse(result.stop_raw)
        self.assertFalse(result.start_confirmed)
        self.assertEqual(result.arbitration, "HOLD")

    def test_off_ignores_stop_when_start_is_false(self):
        result = observe(snapshot(), controller_state="off")
        self.assertFalse(result.start_raw)
        self.assertTrue(result.stop_raw)
        self.assertFalse(result.start_confirmed)
        self.assertEqual(result.arbitration, "HOLD")

    def test_off_start_does_not_depend_on_resident_pages(self):
        result = observe(
            start_snapshot(),
            controller_state="off",
            local_resident_pages=None,
            remote_resident_pages=None,
        )
        self.assertTrue(result.valid)
        self.assertTrue(result.start_raw)
        self.assertIsNone(result.stop_capacity_ratio)
        self.assertFalse(result.stop_raw)
        self.assertTrue(result.start_confirmed)
        self.assertEqual(result.arbitration, "START")

    def test_on_stop_requires_resident_pages_for_rss_projection(self):
        result = observe(
            start_snapshot(),
            controller_state="on",
            local_resident_pages=None,
            remote_resident_pages=None,
        )
        self.assertTrue(result.valid)
        self.assertIsNone(result.stop_capacity_ratio)
        self.assertFalse(result.stop_raw)
        self.assertEqual(result.arbitration, "HOLD")

    def test_duplicate_window_holds_in_off_state(self):
        state = ctrl.StartDecisionState(1)
        observe(
            snapshot(
                window_seq=8,
                local_lt_ppm=740000,
                remote_lt_ppm=790000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="off",
        )
        first = observe(
            start_snapshot(window_seq=9),
            state=state,
            controller_state="off",
        )
        duplicate = observe(
            start_snapshot(window_seq=9),
            state=state,
            controller_state="off",
        )
        self.assertEqual(first.arbitration, "START")
        self.assertFalse(duplicate.fresh)
        self.assertEqual(duplicate.start_consecutive, 0)
        self.assertFalse(duplicate.start_confirmed)
        self.assertEqual(duplicate.arbitration, "HOLD")

    def test_unknown_controller_state_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unknown controller state"):
            observe(snapshot(), controller_state="unknown")

    def test_start_is_independent_of_rss_and_capacity(self):
        low_rss = observe(
            start_snapshot(local_faults=1000),
            local_resident_pages=500,
            remote_resident_pages=200,
            local_capacity_pages=500,
        )
        high_rss = observe(
            start_snapshot(local_faults=1000),
            local_resident_pages=1000,
            remote_resident_pages=1000,
            local_capacity_pages=2000,
        )
        self.assertEqual(low_rss.local_p75_slow_pages, 125.0)
        self.assertEqual(high_rss.local_p75_slow_pages, 250.0)
        self.assertEqual(low_rss.remote_p75_fast_pages, 190.0)
        self.assertEqual(high_rss.remote_p75_fast_pages, 950.0)
        self.assertTrue(low_rss.start_raw)
        self.assertTrue(high_rss.start_raw)

    def test_hot_coverage_policy_starts_when_local_cap_progress_is_low(self):
        result = observe(
            snapshot(
                local_faults=500,
                remote_faults=1000,
                local_le_ppm=750000,
                remote_le_ppm=10000,
            ),
            controller_state="off",
            local_resident_pages=100,
            remote_resident_pages=1000,
            local_capacity_pages=100,
            start_policy="hot-coverage",
        )

        self.assertEqual(result.start_cdf_gap_ppm, 1000000)
        self.assertEqual(result.hot_coverage_progress_ppm, 500000)
        self.assertTrue(result.start_raw)
        self.assertFalse(result.stop_raw)
        self.assertEqual(result.arbitration, "START")

    def test_hot_coverage_policy_starts_when_start_and_stop_are_both_raw(self):
        result = observe(
            snapshot(
                local_faults=500,
                remote_faults=1000,
                local_le_ppm=750000,
                remote_le_ppm=1000000,
            ),
            controller_state="off",
            local_resident_pages=100,
            remote_resident_pages=1000,
            local_capacity_pages=100,
            start_policy="hot-coverage",
        )

        self.assertEqual(result.hot_coverage_progress_ppm, 500000)
        self.assertTrue(result.start_raw)
        self.assertTrue(result.stop_raw)
        self.assertTrue(result.start_confirmed)
        self.assertEqual(result.arbitration, "START")

    def test_hot_coverage_start_does_not_require_remote_density_advantage(self):
        result = observe(
            snapshot(
                local_faults=400,
                remote_faults=300,
                local_le_ppm=750000,
                remote_le_ppm=10000,
            ),
            controller_state="off",
            local_resident_pages=100,
            remote_resident_pages=1000,
            local_capacity_pages=100,
            start_policy="hot-coverage",
        )

        self.assertEqual(result.start_cdf_gap_ppm, -250000)
        self.assertEqual(result.hot_coverage_progress_ppm, 400000)
        self.assertTrue(result.start_raw)
        self.assertEqual(result.arbitration, "START")

    def test_hot_coverage_policy_retains_on_while_start_is_raw(self):
        result = observe(
            snapshot(
                local_faults=500,
                remote_faults=1000,
                local_le_ppm=750000,
                remote_le_ppm=1000000,
            ),
            controller_state="on",
            local_resident_pages=100,
            remote_resident_pages=1000,
            local_capacity_pages=100,
            start_policy="hot-coverage",
        )

        self.assertEqual(result.hot_coverage_progress_ppm, 500000)
        self.assertTrue(result.start_raw)
        self.assertTrue(result.stop_raw)
        self.assertFalse(result.stop_guard_raw)
        self.assertEqual(result.arbitration, "HOLD")

    def test_hot_coverage_policy_allows_existing_latency_stop_when_cap_is_filled(self):
        result = observe(
            snapshot(
                local_faults=1000,
                remote_faults=500,
                local_le_ppm=750000,
                remote_le_ppm=1000000,
            ),
            controller_state="on",
            local_resident_pages=100,
            remote_resident_pages=1000,
            local_capacity_pages=100,
            start_policy="hot-coverage",
        )

        self.assertEqual(result.hot_coverage_progress_ppm, 1000000)
        self.assertEqual(result.start_cdf_gap_ppm, -500000)
        self.assertFalse(result.start_raw)
        self.assertTrue(result.stop_raw)
        self.assertFalse(result.stop_guard_raw)
        self.assertEqual(result.arbitration, "STOP")

    def test_policy_rejects_out_of_range_start_gap(self):
        for gap in (-1, ctrl.PPM + 1):
            with self.subTest(gap=gap), self.assertRaises(ValueError):
                observe(snapshot(), start_cdf_gap_ppm=gap)

    def test_policy_rejects_out_of_range_reduction_threshold(self):
        for reduction in (-1, 2 * ctrl.PPM + 1):
            with self.subTest(reduction=reduction), self.assertRaises(ValueError):
                observe(snapshot(), start_cdf_gap_reduction_ppm=reduction)

    def test_policy_rejects_out_of_range_hot_coverage_thresholds(self):
        for value in (-1, ctrl.PPM + 1):
            with self.subTest(start=value), self.assertRaises(ValueError):
                observe(snapshot(), start_hot_coverage_ppm=value)
            with self.subTest(stop=value), self.assertRaises(ValueError):
                observe(snapshot(), stop_hot_coverage_ppm=value)

    def test_cancelled_pages_are_removed_from_denominator(self):
        result = observe(
            snapshot(
                local_protected=300,
                local_cancelled=45,
                local_faults=16,
            )
        )
        self.assertFalse(result.valid)
        self.assertEqual(result.local_eligible_protected_pages, 255)
        self.assertEqual(result.reason, "insufficient_local_protected")

    def test_cancelled_pages_do_not_change_rss_stop_mass(self):
        result = observe(
            snapshot(
                local_protected=1000,
                local_cancelled=200,
                remote_protected=1000,
                remote_cancelled=400,
                local_faults=400,
                remote_faults=300,
                local_le_ppm=500000,
                remote_le_ppm=1000000,
            )
        )

        self.assertTrue(result.valid)
        self.assertEqual(result.local_eligible_protected_pages, 800)
        self.assertEqual(result.remote_eligible_protected_pages, 600)
        self.assertEqual(result.local_p75_slow_pages, 500.0)
        self.assertEqual(result.remote_p75_fast_pages, 1000.0)
        self.assertEqual(result.stop_capacity_ratio, 2.0)
        self.assertTrue(result.stop_raw)

    def test_each_tier_needs_minimum_eligible_protections(self):
        local = observe(snapshot(local_protected=255, local_faults=16))
        remote = observe(snapshot(remote_protected=255))
        self.assertEqual(local.reason, "insufficient_local_protected")
        self.assertEqual(remote.reason, "insufficient_remote_protected")

    def test_only_local_faults_have_a_minimum(self):
        local = observe(snapshot(local_faults=15))
        remote = observe(snapshot(local_faults=16, remote_faults=0))
        self.assertEqual(local.reason, "insufficient_local_faults")
        self.assertTrue(remote.valid)

    def test_fault_count_cannot_exceed_eligible_protections(self):
        local = observe(snapshot(local_faults=1001))
        remote = observe(snapshot(remote_faults=1001))
        self.assertEqual(local.reason, "local_faults_exceed_protected")
        self.assertEqual(remote.reason, "remote_faults_exceed_protected")

    def test_missing_required_count_holds(self):
        bad = ctrl.QuantileSnapshot(
            **{**snapshot().__dict__, "remote_cancelled_pages": None}
        )
        result = observe(bad)
        self.assertFalse(result.valid)
        self.assertEqual(result.reason, "missing_window_counts")
        self.assertEqual(result.arbitration, "HOLD")

    def test_invalid_window_does_not_create_start(self):
        state = ctrl.StartDecisionState(1)
        invalid = observe(
            ctrl.QuantileSnapshot(
                **{**start_snapshot(window_seq=1).__dict__, "schema": "old"}
            ),
            state=state,
            controller_state="off",
        )
        accepted = observe(
            start_snapshot(window_seq=2),
            state=state,
            controller_state="off",
        )
        self.assertEqual(invalid.start_consecutive, 0)
        self.assertEqual(accepted.start_consecutive, 1)
        self.assertEqual(invalid.arbitration, "HOLD")
        self.assertEqual(accepted.arbitration, "START")

    def test_invalid_and_duplicate_windows_hold_and_preserve_baseline(self):
        state = ctrl.StartDecisionState(1)
        started = observe(
            start_snapshot(window_seq=1),
            state=state,
            controller_state="off",
        )
        invalid = ctrl.evaluate_window_capacity_policy(
            start_snapshot(window_seq=3),
            controller_state="on",
            local_resident_pages=1000,
            remote_resident_pages=1000,
            local_capacity_pages=1000,
            local_target_pct=75,
            min_protected_pages=256,
            min_local_fault_pages=16,
            start_cdf_gap_ppm=ctrl.DEFAULT_START_CDF_GAP_PPM,
            start_cdf_gap_reduction_ppm=ctrl.DEFAULT_START_CDF_GAP_REDUCTION_PPM,
            stop_capacity_ratio_threshold=(
                ctrl.DEFAULT_STOP_CAPACITY_RATIO_THRESHOLD
            ),
            decision_state=state,
            invalid_reason="forced_invalid_for_test",
        )
        duplicate = observe(
            snapshot(
                window_seq=3,
                local_lt_ppm=740000,
                remote_lt_ppm=790000,
                remote_le_ppm=950000,
            ),
            state=state,
            controller_state="on",
        )
        self.assertEqual(started.arbitration, "START")
        self.assertFalse(invalid.valid)
        self.assertEqual(invalid.arbitration, "HOLD")
        self.assertEqual(invalid.start_cdf_gap_baseline_ppm, 100000)
        self.assertFalse(duplicate.fresh)
        self.assertEqual(duplicate.arbitration, "HOLD")
        self.assertEqual(duplicate.start_cdf_gap_baseline_ppm, 100000)
        self.assertEqual(state.start_baseline_gap_ppm, 100000)

    def test_target_is_floor_of_capacity_fraction(self):
        result = observe(snapshot(), local_capacity_pages=1001)
        self.assertEqual(result.local_target_pages, 750)


class TransitionTests(unittest.TestCase):
    def test_start_turns_off_state_on(self):
        transition = ctrl.state_transition("off", "START")
        self.assertEqual(transition.event, "on")
        self.assertEqual(transition.migration_enabled, 1)

    def test_stop_turns_on_state_off(self):
        transition = ctrl.state_transition("on", "STOP")
        self.assertEqual(transition.event, "off")
        self.assertEqual(transition.migration_enabled, 0)

    def test_hold_does_not_write_migration_knob(self):
        transition = ctrl.state_transition("on", "HOLD")
        self.assertEqual(transition.state, "on")
        self.assertIsNone(transition.migration_enabled)


class CapacityAndResidencyTests(unittest.TestCase):
    def test_node_memtotal_is_converted_to_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            node = root / "node3"
            node.mkdir()
            (node / "meminfo").write_text(
                "Node 3 MemTotal: 4000 kB\n",
                encoding="ascii",
            )
            with mock.patch.object(ctrl.os, "sysconf", return_value=4096):
                pages = ctrl.read_node_memtotal_pages(3, node_sysfs_root=root)
        self.assertEqual(pages, 1000)

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

    def test_missing_pid_file_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            pages = ctrl.read_resident_pages_from_pid_file(
                Path(tmp) / "missing.pid",
                0,
                1,
            )
        self.assertIsNone(pages)


class InterfaceTests(unittest.TestCase):
    def test_final_cli_defaults(self):
        args = ctrl.parse_args(["--workload-pid-file", "/tmp/workload.pid"])
        self.assertEqual(args.local_target_pct, 75)
        self.assertEqual(args.window_min_protected_pages, 256)
        self.assertEqual(args.window_min_local_fault_pages, 16)
        self.assertEqual(args.window_consecutive, 1)
        self.assertEqual(args.start_cdf_gap_ppm, 100000)
        self.assertEqual(args.start_cdf_gap_reduction_ppm, 50000)
        self.assertEqual(
            args.stop_capacity_ratio_threshold,
            ctrl.DEFAULT_STOP_CAPACITY_RATIO_THRESHOLD,
        )
        self.assertEqual(args.cycle_window_min_sec, 5.0)
        self.assertEqual(args.cycle_window_max_sec, 20.0)
        self.assertIsNone(args.local_capacity_pages)

    def test_nonzero_diagnostic_timeout_is_allowed(self):
        args = ctrl.parse_args(
            [
                "--workload-pid-file",
                "/tmp/workload.pid",
                "--cycle-window-min-sec",
                "5",
                "--cycle-window-max-sec",
                "7",
            ]
        )
        self.assertEqual(args.cycle_window_max_sec, 7.0)

    def test_invalid_final_policy_options_are_rejected(self):
        for option, value in (
            ("--local-target-pct", "0"),
            ("--window-min-protected-pages", "0"),
            ("--window-min-local-fault-pages", "0"),
            ("--window-consecutive", "0"),
            ("--start-cdf-gap-ppm", "1000001"),
            ("--start-cdf-gap-reduction-ppm", "-1"),
            ("--start-cdf-gap-reduction-ppm", "2000001"),
        ):
            with self.subTest(option=option), mock.patch(
                "sys.stderr", new=io.StringIO()
            ), self.assertRaises(SystemExit):
                ctrl.parse_args(
                    ["--workload-pid-file", "/tmp/workload.pid", option, value]
                )

        args = ctrl.parse_args(
            [
                "--workload-pid-file",
                "/tmp/workload.pid",
                "--window-consecutive",
                "2",
            ]
        )
        self.assertEqual(args.window_consecutive, 2)

        for value in ("0", "-0.1", "nan", "inf", "-inf"):
            with self.subTest(stop_threshold=value), mock.patch(
                "sys.stderr", new=io.StringIO()
            ), self.assertRaises(SystemExit):
                ctrl.parse_args(
                    [
                        "--workload-pid-file",
                        "/tmp/workload.pid",
                        "--stop-capacity-ratio-threshold",
                        value,
                    ]
                )

        for value in ("-1", "4"):
            with self.subTest(cycle_window_max_sec=value), mock.patch(
                "sys.stderr", new=io.StringIO()
            ), self.assertRaises(SystemExit):
                ctrl.parse_args(
                    [
                        "--workload-pid-file",
                        "/tmp/workload.pid",
                        "--cycle-window-min-sec",
                        "5",
                        "--cycle-window-max-sec",
                        value,
                    ]
                )

    def test_csv_schema_contains_only_final_policy_terms(self):
        required = {
            "local_capacity_pages",
            "local_target_pages",
            "local_protected_pages",
            "remote_protected_pages",
            "local_p75_slow_pages",
            "remote_p75_fast_pages",
            "stop_capacity_ratio",
            "stop_capacity_ratio_threshold",
            "start_cdf_gap_ppm",
            "start_cdf_gap_baseline_ppm",
            "start_cdf_gap_reduction_ppm",
            "start_cdf_gap_threshold_ppm",
            "start_cdf_gap_reduction_threshold_ppm",
            "start_retention_raw",
            "start_raw",
            "start_consecutive",
            "arbitration",
        }
        self.assertTrue(required.issubset(ctrl.CSV_FIELDS))
        self.assertEqual(len(ctrl.CSV_FIELDS), len(set(ctrl.CSV_FIELDS)))
        self.assertNotIn("stop_consecutive", ctrl.CSV_FIELDS)
        self.assertNotIn("stop_confirmed", ctrl.CSV_FIELDS)
        self.assertNotIn("start_cdf_gap_previous_ppm", ctrl.CSV_FIELDS)
        self.assertNotIn("start_cdf_gap_improvement_ppm", ctrl.CSV_FIELDS)

    def test_controller_first_cycle_is_alignment_warmup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sysfs = root / "numa_balancing"
            sysfs.mkdir()
            invalid = V5_TEXT.replace("local_total 500", "local_total 0")
            for name, value in (
                ("fault_latency_quantiles", invalid),
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
                    "0",
                    "--max-windows",
                    "1",
                    "--local-capacity-pages",
                    "1000",
                    "--stop-capacity-ratio-threshold",
                    "0.80",
                ]
            )
            with mock.patch.object(ctrl, "read_int_file", side_effect=[0, 1]):
                self.assertEqual(ctrl.run_controller(args), 0)
            with output.open(newline="", encoding="ascii") as source:
                rows = list(csv.DictReader(source))
            final_migration_state = (sysfs / "migration_enabled").read_text()

        self.assertEqual([row["event"] for row in rows], ["start", "sample", "exit"])
        self.assertTrue(all(row["policy"] == ctrl.POLICY_NAME for row in rows))
        self.assertEqual(rows[0]["controller_state"], "on")
        self.assertEqual(final_migration_state, "1\n")
        self.assertEqual(rows[1]["cycle_window_reason"], "cycle")
        self.assertEqual(rows[1]["window_reason"], "cycle_alignment_warmup")
        self.assertEqual(rows[1]["window_valid"], "0")
        self.assertEqual(rows[1]["window_fresh"], "1")
        self.assertEqual(rows[1]["arbitration"], "HOLD")
        self.assertTrue(
            all(row["stop_capacity_ratio_threshold"] == "0.80" for row in rows)
        )

    def test_controller_timeout_evaluates_and_applies_capped_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sysfs = root / "numa_balancing"
            sysfs.mkdir()
            stop_snapshot = V5_TEXT.replace(
                "local_total 500", "local_total 1000"
            ).replace("remote_total 100", "remote_total 1000")
            for name, value in (
                ("fault_latency_quantiles", stop_snapshot),
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
                    "--max-windows",
                    "1",
                    "--local-capacity-pages",
                    "1000",
                ]
            )
            with mock.patch.object(
                ctrl, "read_int_file", side_effect=[0, 0]
            ), mock.patch.object(
                ctrl, "monotonic_ms", side_effect=[0, 20000, 20000]
            ), mock.patch.object(
                ctrl, "sleep_interruptible", return_value=True
            ), mock.patch.object(
                ctrl, "write_text", wraps=ctrl.write_text
            ) as write_text_mock:
                self.assertEqual(ctrl.run_controller(args), 0)
            window_advances = [
                call
                for call in write_text_mock.call_args_list
                if call.args[0] == sysfs / "local_fault_window"
            ]
            with output.open(newline="", encoding="ascii") as source:
                rows = list(csv.DictReader(source))
            final_migration_state = (sysfs / "migration_enabled").read_text()

        self.assertEqual([row["event"] for row in rows], ["start", "off", "exit"])
        self.assertEqual(rows[1]["cycle_window_reason"], "max_timeout")
        self.assertEqual(rows[1]["cycle_window_elapsed_ms"], "20000")
        self.assertEqual(rows[1]["window_reason"], "ok")
        self.assertEqual(rows[1]["window_valid"], "1")
        self.assertEqual(rows[1]["stop_raw"], "1")
        self.assertEqual(rows[1]["arbitration"], "STOP")
        self.assertEqual(rows[1]["transition_action"], "migration_stop")
        self.assertEqual(final_migration_state, "0\n")
        self.assertEqual(len(window_advances), 2)

    def test_controller_rejects_incompatible_abi_before_enabling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sysfs = root / "numa_balancing"
            sysfs.mkdir()
            for name, value in (
                (
                    "fault_latency_quantiles",
                    V5_TEXT.replace("quantile_snapshot_v5", "wrong_schema"),
                ),
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
            args = ctrl.parse_args(
                [
                    "--workload-pid-file",
                    str(pid_file),
                    "--sysfs-numa-dir",
                    str(sysfs),
                    "--numa-balancing-path",
                    str(numa_balancing),
                    "--local-capacity-pages",
                    "1000",
                ]
            )
            with self.assertRaisesRegex(RuntimeError, "incompatible quantile schema"):
                ctrl.run_controller(args)
            self.assertEqual((sysfs / "migration_enabled").read_text(), "0\n")
            self.assertEqual(numa_balancing.read_text(), "0\n")


if __name__ == "__main__":
    unittest.main()
