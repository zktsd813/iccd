#!/usr/bin/env python3
"""Control NUMA migration with the final ICCD fault-quantile policy."""

from __future__ import annotations

import argparse
import csv
import os
import signal
import sys
import time
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Iterable, Optional, TextIO


PPM = 1_000_000
LOCAL_HEAD_PPM = 750_000
LOCAL_TAIL_PPM = 250_000
DEFAULT_START_CAPACITY_MARGIN_PCT = 10
DEFAULT_P75_STAGNATION_DECREASE_PCT = 10.0
DEFAULT_P75_STAGNATION_CONSECUTIVE_WINDOWS = 3
DEFAULT_P75_RESTART_DEGRADATION_PCT = 10.0
DEFAULT_P75_RESTART_CONSECUTIVE_WINDOWS = 3
DEFAULT_REMOTE_RESTART_IMPROVEMENT_PCT = 10.0
KLL_SCHEMA = "quantile_snapshot_v4"
KLL_ALGORITHM = "kll_weighted_ms_v1"
KLL_VALUE_SOURCE = "sketch_latency_ms_to_ns"


@dataclass(frozen=True)
class CycleWindowGate:
    ready: bool
    reason: str
    elapsed_ms: int


def cycle_window_gate(
    *,
    cycle_count: Optional[int],
    last_cycle_count: Optional[int],
    elapsed_ms: int,
    min_sec: float,
    max_sec: float,
) -> CycleWindowGate:
    min_ms = int(min_sec * 1000)
    max_ms = int(max_sec * 1000)
    advanced = (
        cycle_count is not None
        and last_cycle_count is not None
        and cycle_count > last_cycle_count
    )
    if advanced and elapsed_ms >= min_ms:
        return CycleWindowGate(True, "cycle", elapsed_ms)
    if max_ms > 0 and elapsed_ms >= max_ms:
        return CycleWindowGate(True, "max_timeout", elapsed_ms)
    return CycleWindowGate(False, "", elapsed_ms)


@dataclass(frozen=True)
class QuantileSnapshot:
    schema: str
    window_seq: int
    algorithm: str
    value_source: str
    local_total: int
    remote_total: int
    local_p75_ns: Optional[int]
    remote_query_rank_ppm: Optional[int]
    remote_query_q_ns: Optional[int]
    remote_query_valid: bool
    remote_cdf_lt_local_p75_ppm: Optional[int]
    remote_cdf_le_local_p75_ppm: Optional[int]


@dataclass(frozen=True)
class PolicyObservation:
    local_resident_pages: Optional[int]
    remote_resident_pages: Optional[int]
    stop_valid: bool
    stop_reason: str
    local_tail_pages: Optional[float]
    remote_candidate_pages: Optional[float]
    stop_capacity_ratio: Optional[float]
    stop_raw: bool
    start_valid: bool
    start_reason: str
    local_head_pages: Optional[float]
    start_capacity_margin_pct: int
    start_required_pages: Optional[float]
    start_remote_quantile_rank_ppm: Optional[int]
    start_raw: bool
    start_consecutive: int
    start_confirmed: bool
    p75_stagnation_previous_local_p75_ns: Optional[int]
    p75_stagnation_decrease_pct: Optional[float]
    p75_stagnation_count: int
    p75_stagnation_state_before: str
    p75_stagnation_state: str
    p75_stagnation_transition: str
    p75_stagnation_reference_local_p75_ns: Optional[int]
    p75_stagnation_reference_remote_rank_ppm: Optional[int]
    p75_stagnation_reference_remote_q_ns: Optional[int]
    p75_stagnation_degradation_pct: Optional[float]
    p75_stagnation_degradation_met: bool
    p75_stagnation_remote_query_match: bool
    p75_stagnation_remote_improvement_pct: Optional[float]
    p75_stagnation_remote_improvement_met: bool
    p75_stagnation_forced_off_consecutive: int
    p75_stagnation_forced_stop: bool
    p75_stagnation_restart: bool
    arbitration: str


@dataclass(frozen=True)
class StateTransition:
    event: str
    state: str
    action: str
    migration_enabled: Optional[int]


class StartState:
    """Track consecutive valid raw START windows."""

    def __init__(self, consecutive_windows: int):
        self.consecutive_windows = consecutive_windows
        self.consecutive_count = 0

    def observe(self, *, valid: bool, raw: bool) -> tuple[int, bool]:
        if not valid or not raw:
            self.consecutive_count = 0
        else:
            self.consecutive_count = min(
                self.consecutive_windows,
                self.consecutive_count + 1,
            )
        return (
            self.consecutive_count,
            valid and raw and self.consecutive_count >= self.consecutive_windows,
        )

    def reset(self) -> None:
        self.consecutive_count = 0

    def seed_confirmed(self) -> tuple[int, bool]:
        self.consecutive_count = self.consecutive_windows
        return self.consecutive_count, True


@dataclass(frozen=True)
class P75StagnationObservation:
    previous_local_p75_ns: Optional[int]
    decrease_pct: Optional[float]
    count: int
    state_before: str
    state: str
    transition: str
    reference_local_p75_ns: Optional[int]
    reference_remote_rank_ppm: Optional[int]
    reference_remote_q_ns: Optional[int]
    degradation_pct: Optional[float]
    degradation_met: bool
    remote_query_match: bool
    remote_improvement_pct: Optional[float]
    remote_improvement_met: bool
    forced_off_consecutive: int
    forced_stop: bool
    restart: bool


class P75StagnationState:
    """Latch STOP and require joint local/remote evidence before restarting."""

    NORMAL = "NORMAL"
    FORCED_OFF = "FORCED_OFF"

    def __init__(
        self,
        required_decrease_pct: float,
        consecutive_windows: int,
        restart_degradation_pct: float = DEFAULT_P75_RESTART_DEGRADATION_PCT,
        restart_consecutive_windows: int = (
            DEFAULT_P75_RESTART_CONSECUTIVE_WINDOWS
        ),
        remote_restart_improvement_pct: float = (
            DEFAULT_REMOTE_RESTART_IMPROVEMENT_PCT
        ),
    ):
        if required_decrease_pct < 0:
            raise ValueError("required_decrease_pct must be >= 0")
        if consecutive_windows < 1:
            raise ValueError("consecutive_windows must be >= 1")
        if restart_degradation_pct < 0:
            raise ValueError("restart_degradation_pct must be >= 0")
        if restart_consecutive_windows < 1:
            raise ValueError("restart_consecutive_windows must be >= 1")
        if not 0 <= remote_restart_improvement_pct <= 100:
            raise ValueError("remote_restart_improvement_pct must be in [0, 100]")
        self.required_decrease_pct = required_decrease_pct
        self.consecutive_windows = consecutive_windows
        self.restart_degradation_pct = restart_degradation_pct
        self.restart_consecutive_windows = restart_consecutive_windows
        self.remote_restart_improvement_pct = remote_restart_improvement_pct
        self.state = self.NORMAL
        self.previous_valid_local_p75_ns: Optional[int] = None
        self.consecutive_count = 0
        self.trigger_local_p75_ns: list[int] = []
        self.reference_local_p75_ns: Optional[int] = None
        self.reference_remote_rank_ppm: Optional[int] = None
        self.reference_remote_q_ns: Optional[int] = None
        self.forced_off_consecutive = 0

    def _reset_trigger(self, baseline_local_p75_ns: Optional[int] = None) -> None:
        self.previous_valid_local_p75_ns = baseline_local_p75_ns
        self.consecutive_count = 0
        self.trigger_local_p75_ns.clear()

    def query_rank_ppm(self, current_capacity_rank_ppm: Optional[int]) -> int:
        if self.state == self.FORCED_OFF:
            frozen = self.reference_remote_rank_ppm
            if frozen is not None and 1 <= frozen <= PPM:
                return frozen
            return 0
        if (
            current_capacity_rank_ppm is not None
            and 1 <= current_capacity_rank_ppm <= PPM
        ):
            return current_capacity_rank_ppm
        return 0

    @staticmethod
    def _remote_query_matches(
        expected_rank_ppm: Optional[int],
        query_rank_ppm: Optional[int],
        query_q_ns: Optional[int],
        query_valid: bool,
    ) -> bool:
        return bool(
            query_valid
            and expected_rank_ppm is not None
            and 1 <= expected_rank_ppm <= PPM
            and query_rank_ppm == expected_rank_ppm
            and query_q_ns is not None
            and query_q_ns >= 0
        )

    def _restart_observation(
        self,
        *,
        start_valid: bool,
        start_raw: bool,
        current_p75_ns: int,
        remote_query_rank_ppm: Optional[int],
        remote_query_q_ns: Optional[int],
        remote_query_valid: bool,
    ) -> tuple[
        Optional[float],
        bool,
        bool,
        Optional[float],
        bool,
        bool,
    ]:
        reference_p75_ns = self.reference_local_p75_ns
        reference_rank_ppm = self.reference_remote_rank_ppm
        reference_remote_q_ns = self.reference_remote_q_ns
        remote_query_match = self._remote_query_matches(
            reference_rank_ppm,
            remote_query_rank_ppm,
            remote_query_q_ns,
            remote_query_valid,
        )
        if (
            reference_p75_ns is None
            or reference_p75_ns <= 0
            or current_p75_ns <= 0
            or reference_remote_q_ns is None
            or reference_remote_q_ns <= 0
        ):
            return None, False, remote_query_match, None, False, False

        degradation_pct = (
            100.0 * (current_p75_ns - reference_p75_ns) / reference_p75_ns
        )
        degradation_met = Decimal(current_p75_ns) * 100 >= (
            Decimal(reference_p75_ns)
            * (
                Decimal(100)
                + Decimal(str(self.restart_degradation_pct))
            )
        )
        remote_improvement_pct: Optional[float] = None
        remote_improvement_met = False
        if remote_query_match:
            assert remote_query_q_ns is not None
            remote_improvement_pct = (
                100.0
                * (reference_remote_q_ns - remote_query_q_ns)
                / reference_remote_q_ns
            )
            remote_improvement_met = Decimal(remote_query_q_ns) * 100 <= (
                Decimal(reference_remote_q_ns)
                * (
                    Decimal(100)
                    - Decimal(str(self.remote_restart_improvement_pct))
                )
            )
        restart_candidate = bool(
            start_valid
            and start_raw
            and degradation_met
            and remote_query_match
            and remote_improvement_met
        )
        return (
            degradation_pct,
            degradation_met,
            remote_query_match,
            remote_improvement_pct,
            remote_improvement_met,
            restart_candidate,
        )

    def observe(
        self,
        *,
        start_valid: bool,
        start_raw: bool,
        stop_valid: bool,
        stop_raw: bool,
        local_p75_ns: Optional[int],
        current_remote_rank_ppm: Optional[int],
        remote_query_rank_ppm: Optional[int],
        remote_query_q_ns: Optional[int],
        remote_query_valid: bool,
    ) -> P75StagnationObservation:
        state_before = self.state
        current_p75_ns = local_p75_ns or 0
        transition = "none"
        restart = False
        comparison_p75_ns: Optional[int] = None
        decrease_pct: Optional[float] = None
        degradation_pct: Optional[float] = None
        degradation_met = False
        remote_query_match = False
        remote_improvement_pct: Optional[float] = None
        remote_improvement_met = False

        if self.state == self.FORCED_OFF:
            (
                degradation_pct,
                degradation_met,
                remote_query_match,
                remote_improvement_pct,
                remote_improvement_met,
                restart_candidate,
            ) = self._restart_observation(
                start_valid=start_valid,
                start_raw=start_raw,
                current_p75_ns=current_p75_ns,
                remote_query_rank_ppm=remote_query_rank_ppm,
                remote_query_q_ns=remote_query_q_ns,
                remote_query_valid=remote_query_valid,
            )

            if restart_candidate:
                self.forced_off_consecutive += 1
                transition = "forced_off_candidate"
            else:
                self.forced_off_consecutive = 0
                transition = (
                    "forced_off_invalid"
                    if not start_valid
                    or current_p75_ns <= 0
                    or not remote_query_match
                    else "forced_off_reset"
                )

            confirmed_count = self.forced_off_consecutive
            if confirmed_count >= self.restart_consecutive_windows:
                reference_p75_ns = self.reference_local_p75_ns
                reference_rank_ppm = self.reference_remote_rank_ppm
                reference_remote_q_ns = self.reference_remote_q_ns
                self.state = self.NORMAL
                self.reference_local_p75_ns = None
                self.reference_remote_rank_ppm = None
                self.reference_remote_q_ns = None
                self.forced_off_consecutive = 0
                self._reset_trigger(current_p75_ns)
                transition = "restart_confirmed"
                restart = True
                return P75StagnationObservation(
                    previous_local_p75_ns=None,
                    decrease_pct=None,
                    count=0,
                    state_before=state_before,
                    state=self.state,
                    transition=transition,
                    reference_local_p75_ns=reference_p75_ns,
                    reference_remote_rank_ppm=reference_rank_ppm,
                    reference_remote_q_ns=reference_remote_q_ns,
                    degradation_pct=degradation_pct,
                    degradation_met=degradation_met,
                    remote_query_match=remote_query_match,
                    remote_improvement_pct=remote_improvement_pct,
                    remote_improvement_met=remote_improvement_met,
                    forced_off_consecutive=confirmed_count,
                    forced_stop=False,
                    restart=True,
                )

            return P75StagnationObservation(
                previous_local_p75_ns=None,
                decrease_pct=None,
                count=0,
                state_before=state_before,
                state=self.state,
                transition=transition,
                reference_local_p75_ns=self.reference_local_p75_ns,
                reference_remote_rank_ppm=self.reference_remote_rank_ppm,
                reference_remote_q_ns=self.reference_remote_q_ns,
                degradation_pct=degradation_pct,
                degradation_met=degradation_met,
                remote_query_match=remote_query_match,
                remote_improvement_pct=remote_improvement_pct,
                remote_improvement_met=remote_improvement_met,
                forced_off_consecutive=self.forced_off_consecutive,
                forced_stop=True,
                restart=restart,
            )

        remote_query_match = self._remote_query_matches(
            current_remote_rank_ppm,
            remote_query_rank_ppm,
            remote_query_q_ns,
            remote_query_valid,
        )
        reference_query_valid = bool(
            remote_query_match
            and remote_query_q_ns is not None
            and remote_query_q_ns > 0
        )
        jointly_valid = start_valid and stop_valid and reference_query_valid
        overlap = start_raw and stop_raw
        previous_p75_ns = self.previous_valid_local_p75_ns
        comparison_available = (
            jointly_valid
            and current_p75_ns > 0
            and previous_p75_ns is not None
            and previous_p75_ns > 0
        )

        decreased_enough = False
        if comparison_available:
            assert previous_p75_ns is not None
            comparison_p75_ns = previous_p75_ns
            decrease_pct = (
                100.0 * (previous_p75_ns - current_p75_ns) / previous_p75_ns
            )
            decreased_enough = Decimal(previous_p75_ns - current_p75_ns) * 100 >= (
                Decimal(previous_p75_ns)
                * Decimal(str(self.required_decrease_pct))
            )

        if not jointly_valid or current_p75_ns <= 0:
            self._reset_trigger()
        else:
            if overlap and comparison_available and not decreased_enough:
                self.consecutive_count += 1
                self.trigger_local_p75_ns.append(current_p75_ns)
            else:
                self.consecutive_count = 0
                self.trigger_local_p75_ns.clear()
            self.previous_valid_local_p75_ns = current_p75_ns

        forced_stop = bool(
            overlap and self.consecutive_count >= self.consecutive_windows
        )
        if forced_stop:
            trigger_values = self.trigger_local_p75_ns[
                -self.consecutive_windows :
            ]
            if len(trigger_values) != self.consecutive_windows:
                raise RuntimeError("incomplete P75 stagnation trigger history")
            self.reference_local_p75_ns = max(trigger_values)
            self.reference_remote_rank_ppm = current_remote_rank_ppm
            self.reference_remote_q_ns = remote_query_q_ns
            self.state = self.FORCED_OFF
            self.forced_off_consecutive = 0
            transition = "forced_stop_latched"

        return P75StagnationObservation(
            previous_local_p75_ns=comparison_p75_ns,
            decrease_pct=decrease_pct,
            count=self.consecutive_count,
            state_before=state_before,
            state=self.state,
            transition=transition,
            reference_local_p75_ns=self.reference_local_p75_ns,
            reference_remote_rank_ppm=self.reference_remote_rank_ppm,
            reference_remote_q_ns=self.reference_remote_q_ns,
            degradation_pct=None,
            degradation_met=False,
            remote_query_match=remote_query_match,
            remote_improvement_pct=None,
            remote_improvement_met=False,
            forced_off_consecutive=0,
            forced_stop=forced_stop,
            restart=False,
        )


def state_transition(controller_state: str, arbitration: str) -> StateTransition:
    if arbitration == "START":
        if controller_state == "off":
            return StateTransition("on", "on", "migration_start", 1)
        return StateTransition("sample", "on", "hold_on_start", None)
    if arbitration == "STOP":
        if controller_state == "on":
            return StateTransition("off", "off", "migration_stop", 0)
        return StateTransition("sample", "off", "hold_off_stop", None)
    if arbitration == "HOLD":
        return StateTransition("sample", controller_state, "none", None)
    raise ValueError(f"unknown arbitration result: {arbitration}")


def parse_int(value: str) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_quantile_text(text: str) -> QuantileSnapshot:
    values: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            values[parts[0]] = parts[1]

    return QuantileSnapshot(
        schema=values.get("schema", ""),
        window_seq=parse_int(values.get("window_seq", "")) or 0,
        algorithm=values.get("algorithm", ""),
        value_source=values.get("value_source", ""),
        local_total=parse_int(values.get("local_total", "")) or 0,
        remote_total=parse_int(values.get("remote_total", "")) or 0,
        local_p75_ns=parse_int(values.get("local_q75_ns", "")),
        remote_query_rank_ppm=parse_int(
            values.get("remote_query_rank_ppm", "")
        ),
        remote_query_q_ns=parse_int(values.get("remote_query_q_ns", "")),
        remote_query_valid=(
            parse_int(values.get("remote_query_valid", "")) == 1
        ),
        remote_cdf_lt_local_p75_ppm=parse_int(
            values.get("remote_cdf_lt_local_q75_ppm", "")
        ),
        remote_cdf_le_local_p75_ppm=parse_int(
            values.get("remote_cdf_le_local_q75_ppm", "")
        ),
    )


def validate_quantile_source(snapshot: QuantileSnapshot) -> None:
    if (
        snapshot.schema == KLL_SCHEMA
        and snapshot.algorithm == KLL_ALGORITHM
        and snapshot.value_source == KLL_VALUE_SOURCE
    ):
        return
    raise RuntimeError(
        "fault_latency_quantiles is not the required v4 weighted KLL source "
        f"(schema={snapshot.schema or 'missing'}, "
        f"algorithm={snapshot.algorithm or 'missing'}, "
        f"value_source={snapshot.value_source or 'missing'})"
    )


def valid_ppm(value: Optional[int]) -> bool:
    return value is not None and 0 <= value <= PPM


def capacity_selected_remote_rank_ppm(
    local_resident_pages: Optional[int],
    remote_resident_pages: Optional[int],
    start_capacity_margin_pct: int,
) -> Optional[int]:
    local_pages = local_resident_pages or 0
    remote_pages = remote_resident_pages or 0
    if local_pages <= 0 or remote_pages <= 0:
        return None
    margin_denominator = 100
    required_product = (
        LOCAL_HEAD_PPM
        * local_pages
        * (margin_denominator + start_capacity_margin_pct)
    )
    remote_product = remote_pages * margin_denominator
    return (required_product + remote_product - 1) // remote_product


def evaluate_policy(
    snapshot: QuantileSnapshot,
    *,
    local_resident_pages: Optional[int],
    remote_resident_pages: Optional[int],
    min_local_pages: int,
    min_remote_pages: int,
    stop_capacity_ratio_threshold: float,
    start_capacity_margin_pct: int,
    start_state: StartState,
    p75_stagnation_state: P75StagnationState,
) -> PolicyObservation:
    local_pages = local_resident_pages or 0
    remote_pages = remote_resident_pages or 0

    common_reason = "ok"
    if snapshot.local_total < min_local_pages:
        common_reason = "insufficient_local_samples"
    elif snapshot.remote_total < min_remote_pages:
        common_reason = "insufficient_remote_samples"
    elif snapshot.local_p75_ns is None:
        common_reason = "missing_local_p75"
    elif local_pages <= 0 or remote_pages <= 0:
        common_reason = "missing_resident_capacity"

    stop_valid = common_reason == "ok" and valid_ppm(
        snapshot.remote_cdf_le_local_p75_ppm
    )
    stop_reason = common_reason
    if common_reason == "ok" and not stop_valid:
        stop_reason = "missing_inclusive_remote_cdf"

    local_tail_pages: Optional[float] = None
    remote_candidate_pages: Optional[float] = None
    stop_capacity_ratio: Optional[float] = None
    stop_raw = False
    if stop_valid:
        inclusive_cdf = snapshot.remote_cdf_le_local_p75_ppm
        assert inclusive_cdf is not None
        stop_numerator = inclusive_cdf * remote_pages
        stop_denominator = LOCAL_TAIL_PPM * local_pages
        local_tail_pages = local_pages * LOCAL_TAIL_PPM / PPM
        remote_candidate_pages = remote_pages * inclusive_cdf / PPM
        stop_capacity_ratio = stop_numerator / stop_denominator
        stop_raw = Decimal(stop_numerator) > (
            Decimal(stop_denominator)
            * Decimal(str(stop_capacity_ratio_threshold))
        )
        stop_reason = "capacity_ratio" if stop_raw else "below_threshold"

    start_valid = common_reason == "ok" and valid_ppm(
        snapshot.remote_cdf_lt_local_p75_ppm
    )
    start_reason = common_reason
    if common_reason == "ok" and not start_valid:
        start_reason = "missing_strict_remote_cdf"

    local_head_pages: Optional[float] = None
    start_required_pages: Optional[float] = None
    start_remote_quantile_rank_ppm = capacity_selected_remote_rank_ppm(
        local_resident_pages,
        remote_resident_pages,
        start_capacity_margin_pct,
    )
    start_raw = False
    if local_pages > 0 and remote_pages > 0:
        margin_denominator = 100
        margin_numerator = margin_denominator + start_capacity_margin_pct
        required_product = LOCAL_HEAD_PPM * local_pages * margin_numerator
        local_head_pages = local_pages * LOCAL_HEAD_PPM / PPM
        start_required_pages = (
            required_product / (PPM * margin_denominator)
        )
    if start_valid:
        strict_cdf = snapshot.remote_cdf_lt_local_p75_ppm
        assert strict_cdf is not None
        if (
            start_remote_quantile_rank_ppm is None
            or start_remote_quantile_rank_ppm > PPM
        ):
            start_reason = "remote_capacity_below_start_requirement"
        else:
            # Semantic rule: remote Q(required capacity rank) < local Q75.
            # The kernel exports the equivalent strict-CDF query at local Q75.
            start_raw = (
                strict_cdf * remote_pages * margin_denominator
                >= required_product
            )

    p75_stagnation = p75_stagnation_state.observe(
        start_valid=start_valid,
        start_raw=start_raw,
        stop_valid=stop_valid,
        stop_raw=stop_raw,
        local_p75_ns=snapshot.local_p75_ns,
        current_remote_rank_ppm=start_remote_quantile_rank_ppm,
        remote_query_rank_ppm=snapshot.remote_query_rank_ppm,
        remote_query_q_ns=snapshot.remote_query_q_ns,
        remote_query_valid=snapshot.remote_query_valid,
    )
    if p75_stagnation.restart:
        start_consecutive, start_confirmed = start_state.seed_confirmed()
        arbitration = "START"
    elif p75_stagnation.forced_stop:
        start_state.reset()
        start_consecutive = 0
        start_confirmed = False
        arbitration = "STOP"
    else:
        start_consecutive, start_confirmed = start_state.observe(
            valid=start_valid,
            raw=start_raw,
        )
        if start_confirmed:
            arbitration = "START"
        elif stop_raw:
            arbitration = "STOP"
        else:
            arbitration = "HOLD"

    return PolicyObservation(
        local_resident_pages=(local_pages if local_pages > 0 else None),
        remote_resident_pages=(remote_pages if remote_pages > 0 else None),
        stop_valid=stop_valid,
        stop_reason=stop_reason,
        local_tail_pages=local_tail_pages,
        remote_candidate_pages=remote_candidate_pages,
        stop_capacity_ratio=stop_capacity_ratio,
        stop_raw=stop_raw,
        start_valid=start_valid,
        start_reason=start_reason,
        local_head_pages=local_head_pages,
        start_capacity_margin_pct=start_capacity_margin_pct,
        start_required_pages=start_required_pages,
        start_remote_quantile_rank_ppm=start_remote_quantile_rank_ppm,
        start_raw=start_raw,
        start_consecutive=start_consecutive,
        start_confirmed=start_confirmed,
        p75_stagnation_previous_local_p75_ns=(
            p75_stagnation.previous_local_p75_ns
        ),
        p75_stagnation_decrease_pct=p75_stagnation.decrease_pct,
        p75_stagnation_count=p75_stagnation.count,
        p75_stagnation_state_before=p75_stagnation.state_before,
        p75_stagnation_state=p75_stagnation.state,
        p75_stagnation_transition=p75_stagnation.transition,
        p75_stagnation_reference_local_p75_ns=(
            p75_stagnation.reference_local_p75_ns
        ),
        p75_stagnation_reference_remote_rank_ppm=(
            p75_stagnation.reference_remote_rank_ppm
        ),
        p75_stagnation_reference_remote_q_ns=(
            p75_stagnation.reference_remote_q_ns
        ),
        p75_stagnation_degradation_pct=p75_stagnation.degradation_pct,
        p75_stagnation_degradation_met=p75_stagnation.degradation_met,
        p75_stagnation_remote_query_match=(
            p75_stagnation.remote_query_match
        ),
        p75_stagnation_remote_improvement_pct=(
            p75_stagnation.remote_improvement_pct
        ),
        p75_stagnation_remote_improvement_met=(
            p75_stagnation.remote_improvement_met
        ),
        p75_stagnation_forced_off_consecutive=(
            p75_stagnation.forced_off_consecutive
        ),
        p75_stagnation_forced_stop=p75_stagnation.forced_stop,
        p75_stagnation_restart=p75_stagnation.restart,
        arbitration=arbitration,
    )


def parse_pid_file(pid_file: Path) -> Optional[int]:
    try:
        tokens = pid_file.read_text(encoding="ascii", errors="replace").split()
    except OSError:
        return None
    if not tokens:
        return None
    return parse_int(tokens[0])


def read_child_pids(pid: int) -> list[int]:
    children: set[int] = set()
    for path in Path(f"/proc/{pid}/task").glob("*/children"):
        try:
            tokens = path.read_text(encoding="ascii", errors="replace").split()
        except OSError:
            continue
        for token in tokens:
            child = parse_int(token)
            if child is not None:
                children.add(child)
    return sorted(children)


def collect_process_tree(root_pid: int) -> list[int]:
    seen: set[int] = set()
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(read_child_pids(pid))
    return sorted(seen)


def read_numa_maps_node_pages(
    pid: int,
    local_node: int,
    remote_node: int,
) -> Optional[tuple[int, int]]:
    try:
        lines = Path(f"/proc/{pid}/numa_maps").read_text(
            encoding="ascii",
            errors="replace",
        ).splitlines()
    except OSError:
        return None

    local_key = f"N{local_node}="
    remote_key = f"N{remote_node}="
    local_pages = 0
    remote_pages = 0
    for line in lines:
        for token in line.split():
            if token.startswith(local_key):
                local_pages += parse_int(token[len(local_key) :]) or 0
            elif token.startswith(remote_key):
                remote_pages += parse_int(token[len(remote_key) :]) or 0
    return local_pages, remote_pages


def read_resident_pages_from_pid_file(
    pid_file: Path,
    local_node: int,
    remote_node: int,
) -> Optional[tuple[int, int]]:
    root_pid = parse_pid_file(pid_file)
    if root_pid is None:
        return None

    local_pages = 0
    remote_pages = 0
    readable_maps = 0
    for pid in collect_process_tree(root_pid):
        pages = read_numa_maps_node_pages(pid, local_node, remote_node)
        if pages is None:
            continue
        readable_maps += 1
        local_pages += pages[0]
        remote_pages += pages[1]
    if readable_maps == 0:
        return None
    return local_pages, remote_pages


def monotonic_ms() -> int:
    return time.monotonic_ns() // 1_000_000


def read_text(path: Path) -> str:
    return path.read_text(encoding="ascii", errors="replace")


def read_int_file(path: Path) -> Optional[int]:
    try:
        return parse_int(read_text(path).strip())
    except OSError:
        return None


def write_text(path: Path, value: object) -> None:
    path.write_text(f"{value}\n", encoding="ascii")


def require_path(path: Path, mode: str) -> None:
    if not path.exists():
        raise RuntimeError(f"missing required path: {path}")
    if "r" in mode and not os.access(path, os.R_OK):
        raise RuntimeError(f"required path is not readable: {path}")
    if "w" in mode and not os.access(path, os.W_OK):
        raise RuntimeError(f"required path is not writable: {path}")


def sleep_interruptible(
    seconds: float,
    stop_file: Optional[Path],
    stop_flag: dict[str, bool],
) -> bool:
    deadline = time.monotonic() + seconds
    while not stop_flag["stop"]:
        if stop_file is not None and stop_file.exists():
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return True
        time.sleep(min(remaining, 0.2))
    return False


def open_output(path: Optional[Path]) -> tuple[TextIO, bool]:
    if path is None:
        return sys.stdout, False
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("w", newline="", encoding="ascii"), True


CSV_FIELDS = (
    "event",
    "elapsed_ms",
    "window",
    "window_seq",
    "cycle_count",
    "cycle_window_reason",
    "cycle_window_elapsed_ms",
    "controller_state",
    "transition_action",
    "local_sample_pages",
    "remote_sample_pages",
    "local_p75_ns",
    "remote_query_rank_ppm",
    "remote_query_q_ns",
    "remote_query_valid",
    "remote_cdf_lt_local_p75_ppm",
    "remote_cdf_le_local_p75_ppm",
    "local_resident_pages",
    "remote_resident_pages",
    "stop_valid",
    "stop_reason",
    "local_tail_pages",
    "remote_candidate_pages",
    "stop_capacity_ratio",
    "stop_capacity_ratio_threshold",
    "stop_raw",
    "start_valid",
    "start_reason",
    "local_head_pages",
    "start_capacity_margin_pct",
    "start_required_pages",
    "start_remote_quantile_rank_ppm",
    "start_raw",
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
)


def format_optional(value: object) -> object:
    return "" if value is None else value


def run_controller(args: argparse.Namespace) -> int:
    sysfs_dir = args.sysfs_numa_dir
    quantile_path = sysfs_dir / "fault_latency_quantiles"
    remote_quantile_rank_path = sysfs_dir / "remote_quantile_rank_ppm"
    window_path = sysfs_dir / "local_fault_window"
    local_rate_path = sysfs_dir / "local_fault_rate"
    cycle_path = args.remote_scan_cycles_path or sysfs_dir / "remote_scan_cycles"
    migration_path = args.migration_enabled_path or sysfs_dir / "migration_enabled"

    for path, mode in (
        (quantile_path, "r"),
        (remote_quantile_rank_path, "w"),
        (window_path, "w"),
        (local_rate_path, "w"),
        (cycle_path, "r"),
        (args.numa_balancing_path, "w"),
        (migration_path, "w"),
    ):
        require_path(path, mode)

    write_text(args.numa_balancing_path, 2)
    write_text(migration_path, 1)
    write_text(local_rate_path, args.local_rate)

    out, should_close = open_output(args.output)
    writer = csv.DictWriter(out, fieldnames=CSV_FIELDS)
    writer.writeheader()
    out.flush()

    stop_flag = {"stop": False}

    def request_stop(_signum: int, _frame: object) -> None:
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    started_ms = monotonic_ms()
    last_window_ms = started_ms
    last_cycle_count = read_int_file(cycle_path)
    if last_cycle_count is None:
        raise RuntimeError(f"invalid remote scan cycle counter: {cycle_path}")

    controller_state = "on"
    start_state = StartState(args.start_consecutive)
    p75_stagnation_state = P75StagnationState(
        args.p75_stagnation_required_decrease_pct,
        args.p75_stagnation_required_windows,
        args.p75_stagnation_restart_degradation_pct,
        args.p75_stagnation_restart_required_windows,
        args.remote_restart_improvement_pct,
    )
    window = 0

    def emit_base(event: str, action: str) -> dict[str, object]:
        return {
            "event": event,
            "elapsed_ms": monotonic_ms() - started_ms,
            "window": window,
            "controller_state": controller_state,
            "transition_action": action,
            "stop_capacity_ratio_threshold": (
                f"{args.stop_capacity_ratio_threshold:.6f}"
            ),
            "start_capacity_margin_pct": args.start_capacity_margin_pct,
            "p75_stagnation_required_decrease_pct": (
                args.p75_stagnation_required_decrease_pct
            ),
            "p75_stagnation_required_windows": (
                args.p75_stagnation_required_windows
            ),
            "p75_stagnation_restart_degradation_pct": (
                args.p75_stagnation_restart_degradation_pct
            ),
            "p75_stagnation_restart_required_windows": (
                args.p75_stagnation_restart_required_windows
            ),
            "remote_restart_improvement_pct": (
                args.remote_restart_improvement_pct
            ),
        }

    writer.writerow(emit_base("start", "initial_migration_on"))
    out.flush()
    write_text(window_path, 1)

    try:
        while not stop_flag["stop"]:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if args.max_windows and window >= args.max_windows:
                break
            if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                break

            cycle_count = read_int_file(cycle_path)
            gate = cycle_window_gate(
                cycle_count=cycle_count,
                last_cycle_count=last_cycle_count,
                elapsed_ms=monotonic_ms() - last_window_ms,
                min_sec=args.cycle_window_min_sec,
                max_sec=args.cycle_window_max_sec,
            )
            if not gate.ready:
                continue

            window += 1
            elapsed_ms = monotonic_ms() - started_ms
            resident = read_resident_pages_from_pid_file(
                args.workload_pid_file,
                args.local_node,
                args.remote_node,
            )
            local_resident = None if resident is None else resident[0]
            remote_resident = None if resident is None else resident[1]
            current_remote_rank_ppm = capacity_selected_remote_rank_ppm(
                local_resident,
                remote_resident,
                args.start_capacity_margin_pct,
            )
            query_rank_ppm = p75_stagnation_state.query_rank_ppm(
                current_remote_rank_ppm
            )
            write_text(remote_quantile_rank_path, query_rank_ppm)
            snapshot = parse_quantile_text(read_text(quantile_path))
            validate_quantile_source(snapshot)
            observation = evaluate_policy(
                snapshot,
                local_resident_pages=local_resident,
                remote_resident_pages=remote_resident,
                min_local_pages=args.min_local_pages,
                min_remote_pages=args.min_remote_pages,
                stop_capacity_ratio_threshold=args.stop_capacity_ratio_threshold,
                start_capacity_margin_pct=args.start_capacity_margin_pct,
                start_state=start_state,
                p75_stagnation_state=p75_stagnation_state,
            )
            state_before = controller_state
            transition = state_transition(controller_state, observation.arbitration)
            if transition.migration_enabled is not None:
                write_text(migration_path, transition.migration_enabled)
            controller_state = transition.state

            row = emit_base(transition.event, transition.action)
            row.update(
                {
                    "elapsed_ms": elapsed_ms,
                    "window_seq": snapshot.window_seq,
                    "cycle_count": format_optional(cycle_count),
                    "cycle_window_reason": gate.reason,
                    "cycle_window_elapsed_ms": gate.elapsed_ms,
                    "local_sample_pages": snapshot.local_total,
                    "remote_sample_pages": snapshot.remote_total,
                    "local_p75_ns": format_optional(snapshot.local_p75_ns),
                    "remote_query_rank_ppm": format_optional(
                        snapshot.remote_query_rank_ppm
                    ),
                    "remote_query_q_ns": format_optional(
                        snapshot.remote_query_q_ns
                    ),
                    "remote_query_valid": int(snapshot.remote_query_valid),
                    "remote_cdf_lt_local_p75_ppm": format_optional(
                        snapshot.remote_cdf_lt_local_p75_ppm
                    ),
                    "remote_cdf_le_local_p75_ppm": format_optional(
                        snapshot.remote_cdf_le_local_p75_ppm
                    ),
                    "local_resident_pages": format_optional(
                        observation.local_resident_pages
                    ),
                    "remote_resident_pages": format_optional(
                        observation.remote_resident_pages
                    ),
                    "stop_valid": int(observation.stop_valid),
                    "stop_reason": observation.stop_reason,
                    "local_tail_pages": format_optional(
                        observation.local_tail_pages
                    ),
                    "remote_candidate_pages": format_optional(
                        observation.remote_candidate_pages
                    ),
                    "stop_capacity_ratio": format_optional(
                        observation.stop_capacity_ratio
                    ),
                    "stop_raw": int(observation.stop_raw),
                    "start_valid": int(observation.start_valid),
                    "start_reason": observation.start_reason,
                    "local_head_pages": format_optional(
                        observation.local_head_pages
                    ),
                    "start_required_pages": format_optional(
                        observation.start_required_pages
                    ),
                    "start_remote_quantile_rank_ppm": format_optional(
                        observation.start_remote_quantile_rank_ppm
                    ),
                    "start_raw": int(observation.start_raw),
                    "start_consecutive": observation.start_consecutive,
                    "start_confirmed": int(observation.start_confirmed),
                    "p75_stagnation_previous_local_p75_ns": format_optional(
                        observation.p75_stagnation_previous_local_p75_ns
                    ),
                    "p75_stagnation_decrease_pct": format_optional(
                        observation.p75_stagnation_decrease_pct
                    ),
                    "p75_stagnation_count": observation.p75_stagnation_count,
                    "p75_stagnation_state_before": (
                        observation.p75_stagnation_state_before
                    ),
                    "p75_stagnation_state": observation.p75_stagnation_state,
                    "p75_stagnation_transition": (
                        observation.p75_stagnation_transition
                    ),
                    "p75_stagnation_reference_local_p75_ns": format_optional(
                        observation.p75_stagnation_reference_local_p75_ns
                    ),
                    "p75_stagnation_reference_remote_rank_ppm": format_optional(
                        observation.p75_stagnation_reference_remote_rank_ppm
                    ),
                    "p75_stagnation_reference_remote_q_ns": format_optional(
                        observation.p75_stagnation_reference_remote_q_ns
                    ),
                    "p75_stagnation_degradation_pct": format_optional(
                        observation.p75_stagnation_degradation_pct
                    ),
                    "p75_stagnation_degradation_met": int(
                        observation.p75_stagnation_degradation_met
                    ),
                    "p75_stagnation_remote_query_match": int(
                        observation.p75_stagnation_remote_query_match
                    ),
                    "p75_stagnation_remote_improvement_pct": format_optional(
                        observation.p75_stagnation_remote_improvement_pct
                    ),
                    "p75_stagnation_remote_improvement_met": int(
                        observation.p75_stagnation_remote_improvement_met
                    ),
                    "p75_stagnation_forced_off_consecutive": (
                        observation.p75_stagnation_forced_off_consecutive
                    ),
                    "p75_stagnation_forced_stop": int(
                        observation.p75_stagnation_forced_stop
                    ),
                    "p75_stagnation_restart": int(
                        observation.p75_stagnation_restart
                    ),
                    "arbitration": observation.arbitration,
                }
            )
            writer.writerow(row)
            out.flush()

            write_text(window_path, 1)
            if (
                cycle_count is not None
                and last_cycle_count is not None
                and cycle_count > last_cycle_count
            ):
                last_cycle_count = cycle_count
            last_window_ms = monotonic_ms()
    finally:
        writer.writerow(emit_base("exit", "none"))
        out.flush()
        if should_close:
            out.close()
    return 0


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Control migration with KLL fault quantiles and resident capacity."
    )
    parser.add_argument("--window-sec", type=float, default=1.0)
    parser.add_argument("--cycle-window-min-sec", type=float, default=5.0)
    parser.add_argument("--cycle-window-max-sec", type=float, default=20.0)
    parser.add_argument("--local-rate", type=int, default=5)
    parser.add_argument("--min-local-pages", type=int, default=1024)
    parser.add_argument("--min-remote-pages", type=int, default=1024)
    parser.add_argument("--start-consecutive", type=int, default=2)
    parser.add_argument(
        "--start-capacity-margin-pct",
        type=int,
        default=DEFAULT_START_CAPACITY_MARGIN_PCT,
    )
    parser.add_argument(
        "--stop-capacity-ratio-threshold",
        type=float,
        default=0.9,
    )
    parser.add_argument(
        "--p75-stagnation-required-decrease-pct",
        type=float,
        default=DEFAULT_P75_STAGNATION_DECREASE_PCT,
    )
    parser.add_argument(
        "--p75-stagnation-required-windows",
        type=int,
        default=DEFAULT_P75_STAGNATION_CONSECUTIVE_WINDOWS,
    )
    parser.add_argument(
        "--p75-stagnation-restart-degradation-pct",
        type=float,
        default=DEFAULT_P75_RESTART_DEGRADATION_PCT,
    )
    parser.add_argument(
        "--p75-stagnation-restart-required-windows",
        type=int,
        default=DEFAULT_P75_RESTART_CONSECUTIVE_WINDOWS,
    )
    parser.add_argument(
        "--remote-restart-improvement-pct",
        type=float,
        default=DEFAULT_REMOTE_RESTART_IMPROVEMENT_PCT,
    )
    parser.add_argument("--workload-pid-file", type=Path, required=True)
    parser.add_argument("--local-node", type=int, default=0)
    parser.add_argument("--remote-node", type=int, default=1)
    parser.add_argument(
        "--sysfs-numa-dir",
        type=Path,
        default=Path("/sys/kernel/mm/numa_balancing"),
    )
    parser.add_argument(
        "--numa-balancing-path",
        type=Path,
        default=Path("/proc/sys/kernel/numa_balancing"),
    )
    parser.add_argument("--migration-enabled-path", type=Path)
    parser.add_argument("--remote-scan-cycles-path", type=Path)
    parser.add_argument("--stop-file", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-windows", type=int, default=0)
    args = parser.parse_args(argv)

    if args.window_sec <= 0:
        parser.error("--window-sec must be positive")
    if args.cycle_window_min_sec < 0:
        parser.error("--cycle-window-min-sec must be >= 0")
    if args.cycle_window_max_sec <= 0:
        parser.error("--cycle-window-max-sec must be positive")
    if args.cycle_window_max_sec < args.cycle_window_min_sec:
        parser.error("--cycle-window-max-sec must be >= --cycle-window-min-sec")
    if not 1 <= args.local_rate <= 100:
        parser.error("--local-rate must be in [1, 100]")
    if args.min_local_pages < 0 or args.min_remote_pages < 0:
        parser.error("minimum sample counts must be non-negative")
    if args.start_consecutive < 1:
        parser.error("--start-consecutive must be >= 1")
    if args.start_capacity_margin_pct < 0:
        parser.error("--start-capacity-margin-pct must be >= 0")
    if args.stop_capacity_ratio_threshold < 0:
        parser.error("--stop-capacity-ratio-threshold must be >= 0")
    if args.p75_stagnation_required_decrease_pct < 0:
        parser.error("--p75-stagnation-required-decrease-pct must be >= 0")
    if args.p75_stagnation_required_windows < 1:
        parser.error("--p75-stagnation-required-windows must be >= 1")
    if args.p75_stagnation_restart_degradation_pct < 0:
        parser.error("--p75-stagnation-restart-degradation-pct must be >= 0")
    if args.p75_stagnation_restart_required_windows < 1:
        parser.error("--p75-stagnation-restart-required-windows must be >= 1")
    if not 0 <= args.remote_restart_improvement_pct <= 100:
        parser.error("--remote-restart-improvement-pct must be in [0, 100]")
    if args.local_node < 0 or args.remote_node < 0:
        parser.error("NUMA node IDs must be non-negative")
    if args.local_node == args.remote_node:
        parser.error("--local-node and --remote-node must differ")
    if args.max_windows < 0:
        parser.error("--max-windows must be >= 0")
    return args


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        return run_controller(parse_args(argv))
    except Exception as exc:  # noqa: BLE001
        print(f"bucket_latency_controller: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
