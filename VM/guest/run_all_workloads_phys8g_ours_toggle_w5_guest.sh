#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/phys8g-allworkloads-ours-toggle-w5}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
WORKLOADS="${WORKLOADS:-pr bc silo liblinear FT LU SP gups graph500 btree xsbench}"
OMP_THREADS="${OMP_THREADS:-32}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-10}"
REENABLE_CONSECUTIVE="${REENABLE_CONSECUTIVE:-2}"
GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-30000000}"
SILO_SCALE_FACTOR="${SILO_SCALE_FACTOR:-550000}"
SILO_OPS_PER_WORKER="${SILO_OPS_PER_WORKER:-200000000}"
RUNNER="${RUNNER:-/root/scripts/run_local_util_adapt_experiment.sh}"
CONTROLLER="${CONTROLLER:-/root/scripts/local_util_adapt_controller.py}"

mkdir -p "${OUTROOT}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

resolve_existing_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    printf '%s\n' "${path}"
    return 0
  fi
  return 1
}

set_workload_cmd() {
  local workload="$1"
  CMD=()
  CMD_DISPLAY=""

  case "${workload}" in
    pr)
      local bin
      bin="$(resolve_existing_file /root/pr || resolve_existing_file "${BENCHMARK_DIR}/gapbs/pr")" || return 1
      [[ -f "${GRAPH}" ]] || return 1
      CMD=("${bin}" -f "${GRAPH}" -i20 -t1e-4 -n "${TRIALS}")
      ;;
    bc)
      local bin
      bin="$(resolve_existing_file /root/bc || resolve_existing_file "${BENCHMARK_DIR}/gapbs/bc")" || return 1
      [[ -f "${GRAPH}" ]] || return 1
      CMD=("${bin}" -f "${GRAPH}" -i1 -n "${TRIALS}")
      ;;
    silo)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest")" || return 1
      CMD=("${bin}" --verbose --num-threads "${OMP_THREADS}" --bench ycsb --scale-factor "${SILO_SCALE_FACTOR}" --ops-per-worker="${SILO_OPS_PER_WORKER}")
      ;;
    liblinear)
      local bin data
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/train")" || return 1
      data="$(resolve_existing_file "${BENCHMARK_DIR}/liblinear-multicore-2.47/datasets/kdd12")" || return 1
      CMD=("${bin}" -s 6 -m "${OMP_THREADS}" "${data}")
      ;;
    FT|ft)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/ft.H.x")" || return 1
      CMD=("${bin}")
      ;;
    LU|lu)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/lu.H.x")" || return 1
      CMD=("${bin}")
      ;;
    SP|sp)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/sp.H.x")" || return 1
      CMD=("${bin}")
      ;;
    gups)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt")" || return 1
      CMD=("${bin}" "${GUPS_MEMORY_GB}")
      ;;
    graph500)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt")" || return 1
      CMD=("${bin}" -s "${GRAPH500_SCALE}")
      ;;
    btree)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt")" || return 1
      CMD=("${bin}")
      ;;
    xsbench)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench")" || return 1
      CMD=("${bin}" -t "${OMP_THREADS}" -g "${XSBENCH_GRID}" -p "${XSBENCH_PARTICLES}")
      ;;
    *)
      return 1
      ;;
  esac

  printf -v CMD_DISPLAY '%q ' "${CMD[@]}"
}

drop_caches() {
  sync || true
  echo 3 > /proc/sys/vm/drop_caches || true
}

vmstat_delta_summary() {
  python3 - <<'PY' "$1"
from pathlib import Path
import sys

case = Path(sys.argv[1])

def read(path):
    vals = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            fields = line.split()
            if len(fields) == 2:
                try:
                    vals[fields[0]] = int(fields[1])
                except ValueError:
                    pass
    return vals

before = read(case / "vmstat.before")
after = read(case / "vmstat.after")
with (case / "vmstat.delta").open("w") as out:
    for key in sorted(set(before) | set(after)):
        delta = after.get(key, 0) - before.get(key, 0)
        if delta:
            out.write(f"{key} {delta}\n")
PY
}

snapshot_state() {
  local out="$1"
  {
    echo "uname=$(uname -a)"
    echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
    echo "global_numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || true)"
    echo "global_demotion_enabled=$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true)"
    echo "global_demotion_target=$(cat /sys/kernel/mm/numa/demotion_target 2>/dev/null || true)"
    echo "scan_size_mb=$(cat /sys/kernel/debug/sched/numa_balancing/scan_size_mb 2>/dev/null || true)"
    echo "scan_period_min_ms=$(cat /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms 2>/dev/null || true)"
    numactl -H
    free -h
  } > "${out}" 2>&1 || true
}

summarize_results() {
  python3 - <<'PY' "${OUTROOT}"
from pathlib import Path
import csv
import re
import sys

root = Path(sys.argv[1])
out = root / "summary.csv"

def read_kv(path):
    vals = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                key, val = line.split("=", 1)
                vals[key] = val
    return vals

def parse_stdout(path):
    read_s = ""
    avg_s = ""
    took_s = ""
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
            m = re.search(r"Took:\s*([0-9.]+)", line)
            if m:
                took_s = m.group(1)
            m = re.search(r"Time in seconds\s*=\s*([0-9.]+)", line)
            if m:
                avg_s = m.group(1)
    return read_s, avg_s, took_s, trials

def read_delta(case_dir, key):
    path = case_dir / "vmstat.delta"
    if not path.exists():
        return 0
    for line in path.read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == key:
            try:
                return int(fields[1])
            except ValueError:
                return 0
    return 0

def controller_events(path):
    off = []
    on = []
    reason = ""
    final_state = ""
    if path.exists():
        for row in csv.DictReader(path.open()):
            event = row.get("event", "")
            if event == "off":
                off.append(row.get("elapsed_ms", ""))
                reason = row.get("stop_reason", "")
            elif event == "on":
                on.append(row.get("elapsed_ms", ""))
            if event in ("sample", "off", "on", "exit"):
                final_state = row.get("controller_state", final_state)
    return ";".join(off), ";".join(on), reason, final_state

fields = [
    "workload", "returncode", "elapsed_s", "read_s", "avg_trial_s", "took_s",
    "trial_count", "migration_off_ms", "migration_on_ms", "stop_reason",
    "final_controller_state", "numa_hint_faults", "pgpromote_success",
    "pgdemote_kswapd", "pgdemote_direct", "pgmigrate_success",
] + [f"trial{i}_s" for i in range(1, 21)]

rows = []
for case_dir in sorted((p for p in root.glob("*/ours_toggle_w5") if p.is_dir()), key=lambda p: p.parent.name):
    workload = case_dir.parent.name
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, took_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    off_ms, on_ms, reason, final_state = controller_events(case_dir / "controller.csv")
    row = {
        "workload": workload,
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "took_s": took_s,
        "trial_count": len(trials),
        "migration_off_ms": off_ms,
        "migration_on_ms": on_ms,
        "stop_reason": reason,
        "final_controller_state": final_state,
        "numa_hint_faults": read_delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": read_delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": read_delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": read_delta(case_dir, "pgdemote_direct"),
        "pgmigrate_success": read_delta(case_dir, "pgmigrate_success"),
    }
    for idx, val in enumerate(trials[:20], 1):
        row[f"trial{idx}_s"] = val
    rows.append(row)

with out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
print(out)
PY
}

require_runtime() {
  chmod +x "${RUNNER}" "${CONTROLLER}"
  if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
    echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
  fi
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
}

run_workload() {
  local workload="$1"
  local outdir="${OUTROOT}/${workload}/ours_toggle_w5"
  mkdir -p "${outdir}"
  drop_caches
  cat /proc/vmstat > "${outdir}/vmstat.before" || true
  snapshot_state "${outdir}/host_state.before"
  {
    echo "workload=${workload}"
    echo "policy=ours_toggle_w5"
    echo "physical_local=8G"
    echo "capacity_pages=0"
    echo "window_sec=5"
    echo "reenable_consecutive=${REENABLE_CONSECUTIVE}"
    echo "local_fault_rate=${LOCAL_FAULT_RATE}"
    echo "command=${CMD_DISPLAY}"
    echo "timeout_sec=${TIMEOUT_SEC}"
    echo "omp_threads=${OMP_THREADS}"
  } > "${outdir}/case_config.txt"

  log "start workload=${workload} policy=ours_toggle_w5"
  set +e
  CONTROLLER="${CONTROLLER}" "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-phys8g-ours-toggle-w5" \
    --cgroup-name "phys8_${workload}_ours_toggle_w5_$$" \
    --policy ours \
    --capacity-pages 0 \
    --global-numa-balancing 0 \
    --global-demotion-enabled 1 \
    --global-demotion-target "0 1" \
    --node-balancing 2 \
    --kswapd-demotion 1 \
    --local-fault-rate "${LOCAL_FAULT_RATE}" \
    --local-fault-hit-ms 2000 \
    --window-sec 5 \
    --threshold-pct 80 \
    --consecutive 3 \
    --remote-threshold-pct 20 \
    --remote-consecutive 3 \
    --min-pte-updates 1 \
    --min-hint-faults 1 \
    --reenable-consecutive "${REENABLE_CONSECUTIVE}" \
    --eval-lag prev \
    --cpuset-cpus 0-31 \
    --cpuset-mems 0,1 \
    --mglru 0x0007 \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    -- \
    numactl --physcpubind=0-31 "${CMD[@]}"
  local rc=$?
  set -e
  cat /proc/vmstat > "${outdir}/vmstat.after" || true
  snapshot_state "${outdir}/host_state.after"
  vmstat_delta_summary "${outdir}" || true
  log "done workload=${workload} rc=${rc}"
  summarize_results || true
}

require_runtime
snapshot_state "${OUTROOT}/experiment_state.before"
{
  echo "workloads=${WORKLOADS}"
  echo "policy=ours_toggle_w5"
  echo "physical_local=8G"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "gups_memory_gb=${GUPS_MEMORY_GB}"
  echo "graph500_scale=${GRAPH500_SCALE}"
  echo "xsbench_grid=${XSBENCH_GRID}"
  echo "xsbench_particles=${XSBENCH_PARTICLES}"
  echo "silo_scale_factor=${SILO_SCALE_FACTOR}"
  echo "silo_ops_per_worker=${SILO_OPS_PER_WORKER}"
} > "${OUTROOT}/experiment_config.txt"

for workload in ${WORKLOADS}; do
  if ! set_workload_cmd "${workload}"; then
    log "skip workload=${workload}: missing binary/input"
    continue
  fi
  run_workload "${workload}"
done

summarize_results
snapshot_state "${OUTROOT}/experiment_state.after"
log "summary=${OUTROOT}/summary.csv"
