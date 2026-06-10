#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BASE_RUN_ID="${BASE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-bc-warmup-trial-promotions-local32}"
RESULTS_ROOT="${RESULTS_ROOT:-${EXP_ROOT}/results}"
SUMMARY_ROOT="${SUMMARY_ROOT:-${RESULTS_ROOT}/${BASE_RUN_ID}-summary}"
LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB:-32}"
CONFIGS="${CONFIGS:-tiering_0x2 controller_0x2}"
WORKLOAD="${WORKLOAD:-bc}"
REPEAT_COUNT="${REPEAT_COUNT:-2}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-1}"
OMP_THREADS="${OMP_THREADS:-32}"
TRACE_BC_TRIAL_PROMOTIONS="${TRACE_BC_TRIAL_PROMOTIONS:-1}"

log() {
  printf '[bc-warmup-promotions] %s\n' "$*" >&2
}

main() {
  mkdir -p "${SUMMARY_ROOT}/logs" "${SUMMARY_ROOT}/summaries"
  : > "${SUMMARY_ROOT}/run_roots.tsv"

  local config run_id run_root
  for config in ${CONFIGS}; do
    run_id="${BASE_RUN_ID}-${config}"
    run_root="${RESULTS_ROOT}/${run_id}"
    log "start config=${config} run_id=${run_id}"
    env \
      RUN_ID="${run_id}" \
      RESULTS_ROOT="${RESULTS_ROOT}" \
      LOCAL_SIZE_GIB="${LOCAL_SIZE_GIB}" \
      CONFIG="${config}" \
      WORKLOAD="${WORKLOAD}" \
      REPEAT_COUNT="${REPEAT_COUNT}" \
      SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC}" \
      OMP_THREADS="${OMP_THREADS}" \
      TRACE_BC_TRIAL_PROMOTIONS="${TRACE_BC_TRIAL_PROMOTIONS}" \
      "${SCRIPT_DIR}/run_bc_tiering_repeats_host.sh" \
      > "${SUMMARY_ROOT}/logs/${config}.log" 2>&1
    printf '%s\t%s\n' "${config}" "${run_root}" >> "${SUMMARY_ROOT}/run_roots.tsv"
    log "done config=${config} run_root=${run_root}"
  done

  python3 - "${SUMMARY_ROOT}/run_roots.tsv" "${SUMMARY_ROOT}/summaries/bc_trial_promotions.csv" <<'PY'
import csv
import sys
from pathlib import Path

run_roots_tsv = Path(sys.argv[1])
out_csv = Path(sys.argv[2])
rows = []

def status_map(case_dir: Path) -> dict[str, str]:
    status = case_dir / "status.txt"
    data = {}
    if status.exists():
        for line in status.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v
    return data

for line in run_roots_tsv.read_text().splitlines():
    if not line.strip():
        continue
    config, root = line.split("\t", 1)
    root_path = Path(root)
    for phase, case_name, used in (
        ("warmup_discarded", "bc", "0"),
        ("measured", "bc_rep2", "1"),
    ):
        case_dir = root_path / "guest-results" / "local32" / config / case_name
        trace = case_dir / "trial_promotion.csv"
        if not trace.exists():
            rows.append({
                "config": config,
                "phase": phase,
                "used_for_result": used,
                "case_dir": str(case_dir),
                "status": "missing-trial-promotion",
            })
            continue
        st = status_map(case_dir)
        with trace.open(newline="") as f:
            reader = csv.DictReader(f)
            for r in reader:
                if r.get("event") != "trial_end":
                    continue
                rows.append({
                    "config": config,
                    "phase": phase,
                    "used_for_result": used,
                    "case_dir": str(case_dir),
                    "status": st.get("returncode", ""),
                    "elapsed_s": st.get("elapsed_s", ""),
                    "trial": r.get("trial", ""),
                    "read_s": r.get("read_s", ""),
                    "trial_time_s": r.get("trial_time_s", ""),
                    "cum_trial_s": r.get("cum_trial_s", ""),
                    "pgpromote_success_delta": r.get("pgpromote_success_delta", ""),
                    "pgpromote_candidate_delta": r.get("pgpromote_candidate_delta", ""),
                    "pgpromote_candidate_demoted_delta": r.get("pgpromote_candidate_demoted_delta", ""),
                    "numa_hint_faults_delta": r.get("numa_hint_faults_delta", ""),
                    "pgdemote_kswapd_delta": r.get("pgdemote_kswapd_delta", ""),
                    "pgdemote_direct_delta": r.get("pgdemote_direct_delta", ""),
                    "numa_pages_migrated_delta": r.get("numa_pages_migrated_delta", ""),
                })

fieldnames = [
    "config",
    "phase",
    "used_for_result",
    "case_dir",
    "status",
    "elapsed_s",
    "trial",
    "read_s",
    "trial_time_s",
    "cum_trial_s",
    "pgpromote_success_delta",
    "pgpromote_candidate_delta",
    "pgpromote_candidate_demoted_delta",
    "numa_hint_faults_delta",
    "pgdemote_kswapd_delta",
    "pgdemote_direct_delta",
    "numa_pages_migrated_delta",
]
out_csv.parent.mkdir(parents=True, exist_ok=True)
with out_csv.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)
print(out_csv)
PY
  log "summary ${SUMMARY_ROOT}/summaries/bc_trial_promotions.csv"
}

main "$@"
