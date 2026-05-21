#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/gapbs-full-latest-policy-window-sweep}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
TOGGLE_RUNNER="${TOGGLE_RUNNER:-/root/scripts/run_local_util_toggle_experiment.sh}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
OMP_THREADS="${OMP_THREADS:-32}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

require_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    log "missing required file: ${path}"
    exit 1
  fi
}

require_file "${RUNNER}"
require_file "${TOGGLE_RUNNER}"
require_file /root/pr
require_file /root/bc
require_file "${GRAPH}"
chmod +x "${RUNNER}" "${TOGGLE_RUNNER}" /root/pr /root/bc

if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
  echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
fi
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "graph=${GRAPH}"
  echo "graph_size_bytes=$(stat -c %s "${GRAPH}")"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "omp_threads=${OMP_THREADS}"
  echo "scan_size_mb=256"
  echo "scan_period_min_ms=1000"
  echo "fast_scan=0"
  echo "hot_threshold_ms=0"
  echo "toggle_reenable_consecutive=2"
} > "${OUTROOT}/experiment_config.txt"

workload_cmd() {
  local workload="$1"
  if [[ "${workload}" == "pr" ]]; then
    printf '%s\0' /root/pr -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}"
  else
    printf '%s\0' /root/bc -f "${GRAPH}" -i1 -n "${TRIALS}"
  fi
}

run_case() {
  local workload="$1"
  local cap_label="$2"
  local cap_pages="$3"
  local policy="$4"
  local window_sec="${5:-}"
  local runner="${RUNNER}"
  local case_label="${policy}"
  local outdir
  local cmd=()

  if [[ "${policy}" == "oneshot" || "${policy}" == "toggle" ]]; then
    case_label="${policy}-w${window_sec}"
  fi
  outdir="${OUTROOT}/${workload}-${cap_label}/${case_label}"
  mkdir -p "${outdir}"

  mapfile -d '' -t cmd < <(workload_cmd "${workload}")
  log "start workload=${workload} cap=${cap_label} case=${case_label}"
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true

  local common=(
    --outdir "${outdir}"
    --run-id "${workload}-${cap_label}-${case_label}"
    --cgroup-name "gapbs_latest_${workload}_${cap_label}_${case_label//-/_}_$$"
    --capacity-node 0
    --capacity-pages "${cap_pages}"
    --node-balancing 2
    --scan-size-mb 256
    --scan-period-min-ms 1000
    --fast-scan 0
    --hot-threshold-ms 0
    --mglru 0x0007
    --cpuset-cpus 0-31
    --cpuset-mems 0,1
    --omp-threads "${OMP_THREADS}"
    --timeout-sec "${TIMEOUT_SEC}"
  )

  case "${policy}" in
    off)
      "${RUNNER}" \
        "${common[@]}" \
        --policy off \
        --kswapd-demotion 0 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 0 \
        --global-demotion-target "0 1" \
        -- \
        "${cmd[@]}"
      ;;
    on)
      "${RUNNER}" \
        "${common[@]}" \
        --policy on \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
        -- \
        "${cmd[@]}"
      ;;
    oneshot)
      "${RUNNER}" \
        "${common[@]}" \
        --policy ours \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
        --window-sec "${window_sec}" \
        --threshold-pct 80 \
        --consecutive 3 \
        --min-pte-updates 1000 \
        --remote-threshold-pct 20 \
        --remote-consecutive 3 \
        --min-hint-faults 1000 \
        --local-fault-sample-pct 10 \
        --eval-lag prev \
        -- \
        "${cmd[@]}"
      ;;
    toggle)
      "${TOGGLE_RUNNER}" \
        "${common[@]}" \
        --policy ours \
        --kswapd-demotion 1 \
        --global-numa-balancing 0 \
        --global-demotion-enabled 1 \
        --global-demotion-target "0 1" \
        --window-sec "${window_sec}" \
        --threshold-pct 80 \
        --consecutive 3 \
        --min-pte-updates 1000 \
        --remote-threshold-pct 20 \
        --remote-consecutive 3 \
        --min-hint-faults 1000 \
        --local-fault-sample-pct 10 \
        --eval-lag prev \
        -- \
        "${cmd[@]}"
      ;;
    *)
      log "unknown policy ${policy}"
      exit 2
      ;;
  esac

  log "done workload=${workload} cap=${cap_label} case=${case_label}"
}

for workload in pr bc; do
  for cap_spec in "8g:2097152" "16g:4194304"; do
    cap_label="${cap_spec%%:*}"
    cap_pages="${cap_spec##*:}"
    run_case "${workload}" "${cap_label}" "${cap_pages}" off
    run_case "${workload}" "${cap_label}" "${cap_pages}" on
    for window in 5 10 20; do
      run_case "${workload}" "${cap_label}" "${cap_pages}" oneshot "${window}"
      run_case "${workload}" "${cap_label}" "${cap_pages}" toggle "${window}"
    done
  done
done

python3 - <<'PY' "${OUTROOT}/summary.csv" "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

summary = Path(sys.argv[1])
root = Path(sys.argv[2])

def read_kv(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    return data

def parse_stdout(path):
    read_s = ""
    avg_s = ""
    trials = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            m = re.search(r"Read Time:\s*([0-9.]+)", line)
            if m:
                read_s = m.group(1)
            m = re.search(r"Trial Time:\s*([0-9.]+)", line)
            if m:
                trials.append(m.group(1))
            m = re.search(r"Average Time:\s*([0-9.]+)", line)
            if m:
                avg_s = m.group(1)
    return read_s, avg_s, trials

def read_vm(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) >= 2:
                try:
                    data[fields[0]] = int(fields[1])
                except ValueError:
                    pass
    return data

def delta(case_dir, key):
    before = read_vm(case_dir / "vmstat.before")
    after = read_vm(case_dir / "vmstat.after")
    return after.get(key, 0) - before.get(key, 0)

def events(path):
    offs = []
    ons = []
    final_state = ""
    if path.exists():
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                final_state = row.get("controller_state", final_state)
                if row.get("event") == "off":
                    offs.append(row)
                elif row.get("event") == "on":
                    ons.append(row)
    return offs, ons, final_state

rows = []
for case_dir in sorted(root.glob("*-*g/*")):
    if not case_dir.is_dir():
        continue
    m = re.fullmatch(r"(pr|bc)-(8g|16g)", case_dir.parent.name)
    if not m:
        continue
    workload, cap = m.groups()
    case = case_dir.name
    if case in ("off", "on"):
        policy = case
        window_sec = ""
    else:
        m2 = re.fullmatch(r"(oneshot|toggle)-w([0-9]+)", case)
        if not m2:
            continue
        policy, window_sec = m2.groups()
    cfg = read_kv(case_dir / "run_config.txt")
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    offs, ons, final_state = events(case_dir / "controller.csv")
    first_off = offs[0] if offs else {}
    first_on = ons[0] if ons else {}
    row = {
        "workload": workload,
        "cap": cap,
        "policy": policy,
        "window_sec": window_sec,
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "off_count": len(offs),
        "on_count": len(ons),
        "first_off_ms": first_off.get("elapsed_ms", ""),
        "first_off_window": first_off.get("window", ""),
        "first_off_reason": first_off.get("stop_reason", ""),
        "first_on_ms": first_on.get("elapsed_ms", ""),
        "first_on_window": first_on.get("window", ""),
        "final_controller_state": final_state,
        "capacity_pages": cfg.get("capacity_pages", ""),
        "kswapd_demotion_on": cfg.get("kswapd_demotion_on", ""),
        "global_demotion_enabled": cfg.get("global_demotion_enabled", ""),
        "reenable_consecutive": cfg.get("reenable_consecutive", ""),
        "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
    }
    for idx, value in enumerate(trials, 1):
        row[f"trial{idx}_s"] = value
    rows.append(row)

fields = [
    "workload", "cap", "policy", "window_sec", "returncode", "elapsed_s",
    "read_s", "avg_trial_s", "off_count", "on_count", "first_off_ms",
    "first_off_window", "first_off_reason", "first_on_ms", "first_on_window",
    "final_controller_state", "capacity_pages", "kswapd_demotion_on",
    "global_demotion_enabled", "reenable_consecutive", "numa_hint_faults",
    "pgpromote_success", "pgdemote_kswapd", "pgdemote_direct",
] + [f"trial{i}_s" for i in range(1, 9)]

summary.parent.mkdir(parents=True, exist_ok=True)
with summary.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
PY

log "all latest full sweep cases complete; summary=${OUTROOT}/summary.csv"
