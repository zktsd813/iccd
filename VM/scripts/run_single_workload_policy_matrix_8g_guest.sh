#!/usr/bin/env bash
set -euo pipefail

OUTROOT="${OUTROOT:-/root/single-policy-matrix-8g}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
WORKLOADS="${WORKLOADS:-pr bc FT LU SP gups graph500 btree xsbench silo}"
POLICIES="${POLICIES:-off on all_local all_slow ours_w5 ours_w10}"
CAPACITY_PAGES="${CAPACITY_PAGES:-2097152}"
OMP_THREADS="${OMP_THREADS:-32}"
TRIALS="${TRIALS:-8}"
TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-10}"
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

require_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    log "missing required file: ${path}"
    return 1
  fi
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
    silo)
      local bin
      bin="$(resolve_existing_file "${BENCHMARK_DIR}/silo/out-perf.masstree/benchmarks/dbtest")" || return 1
      CMD=("${bin}" --verbose --num-threads "${OMP_THREADS}" --bench ycsb --scale-factor "${SILO_SCALE_FACTOR}" --ops-per-worker="${SILO_OPS_PER_WORKER}")
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

set_common_kernel_state() {
  if [[ -e /sys/kernel/mm/lru_gen/enabled ]]; then
    echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true
  fi
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  [[ -e /sys/kernel/debug/sched/numa_balancing/scan_size_mb ]] && echo 256 > /sys/kernel/debug/sched/numa_balancing/scan_size_mb || true
  [[ -e /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms ]] && echo 1000 > /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms || true
}

run_direct_policy() {
  local workload="$1"
  local policy="$2"
  local node="$3"
  local outdir="${OUTROOT}/${workload}/${policy}"
  mkdir -p "${outdir}"
  set_common_kernel_state
  echo 0 > /proc/sys/kernel/numa_balancing || true
  [[ -e /sys/kernel/mm/numa/demotion_enabled ]] && echo 0 > /sys/kernel/mm/numa/demotion_enabled || true
  [[ -e /sys/kernel/mm/numa/demotion_target ]] && echo "0 1" > /sys/kernel/mm/numa/demotion_target || true
  drop_caches
  cat /proc/vmstat > "${outdir}/vmstat.before" || true
  {
    echo "workload=${workload}"
    echo "policy=${policy}"
    echo "placement_node=${node}"
    echo "command=${CMD_DISPLAY}"
    echo "capacity_pages=0"
    echo "omp_threads=${OMP_THREADS}"
    echo "timeout_sec=${TIMEOUT_SEC}"
    echo "uname=$(uname -a)"
    echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  } > "${outdir}/run_config.txt"

  log "start workload=${workload} policy=${policy}"
  set +e
  /usr/bin/time -f "execution time %e (s)" timeout "${TIMEOUT_SEC}" \
    env OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores \
    numactl --physcpubind=0-31 --membind="${node}" "${CMD[@]}" \
    > "${outdir}/workload.stdout.log" 2> "${outdir}/workload.stderr.log"
  local rc=$?
  set -e
  cat /proc/vmstat > "${outdir}/vmstat.after" || true
  {
    echo "returncode=${rc}"
    echo "policy=${policy}"
  } > "${outdir}/status.txt"
  log "done workload=${workload} policy=${policy} rc=${rc}"
}

run_cgroup_policy() {
  local workload="$1"
  local label="$2"
  local policy="$3"
  local window="$4"
  local outdir="${OUTROOT}/${workload}/${label}"
  mkdir -p "${outdir}"
  set_common_kernel_state
  drop_caches
  log "start workload=${workload} policy=${label}"
  CONTROLLER="${CONTROLLER}" "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-${label}-8g" \
    --cgroup-name "single_${workload}_${label}_8g_$$" \
    --policy "${policy}" \
    --capacity-node 0 \
    --capacity-pages "${CAPACITY_PAGES}" \
    --node-balancing 2 \
    --kswapd-demotion "$([[ "${policy}" == "off" ]] && echo 0 || echo 1)" \
    --global-numa-balancing 0 \
    --global-demotion-enabled "$([[ "${policy}" == "off" ]] && echo 0 || echo 1)" \
    --global-demotion-target "0 1" \
    --scan-size-mb 256 \
    --scan-period-min-ms 1000 \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus 0-31 \
    --cpuset-mems 0,1 \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --window-sec "${window}" \
    --threshold-pct 80 \
    --consecutive 3 \
    --min-pte-updates 1 \
    --remote-threshold-pct 20 \
    --remote-consecutive 3 \
    --min-hint-faults 1 \
    --local-fault-rate "${LOCAL_FAULT_RATE}" \
    --local-fault-sample-pct "${LOCAL_FAULT_RATE}" \
    --eval-lag prev \
    -- \
    "${CMD[@]}" || true
  log "done workload=${workload} policy=${label}"
}

summarize_results() {
  python3 - <<'PY' "${OUTROOT}"
import csv
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = root / "summary.csv"

def read_kv(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v
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

def parse_stderr_time(path):
    if not path.exists():
        return ""
    text = path.read_text(errors="replace")
    matches = re.findall(r"execution time\s+([0-9.]+)", text)
    return matches[-1] if matches else ""

def vmstat(path):
    vals = {}
    if not path.exists():
        return vals
    for line in path.read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) == 2:
            try:
                vals[fields[0]] = int(fields[1])
            except ValueError:
                pass
    return vals

def delta(case_dir, key):
    before = vmstat(case_dir / "vmstat.before")
    after = vmstat(case_dir / "vmstat.after")
    return after.get(key, 0) - before.get(key, 0)

def controller_events(path):
    if not path.exists():
        return "", "", ""
    off = []
    on = []
    last_reason = ""
    for row in csv.DictReader(path.open()):
        event = row.get("event", "")
        if event in ("migration_off", "off"):
            off.append(row.get("elapsed_ms", ""))
            last_reason = row.get("stop_reason", "")
        elif event in ("migration_on", "on"):
            on.append(row.get("elapsed_ms", ""))
    return ";".join(off), ";".join(on), last_reason

fields = [
    "workload", "policy", "returncode", "elapsed_s", "read_s",
    "avg_trial_s", "trial_count", "migration_off_ms", "migration_on_ms",
    "stop_reason", "numa_hint_faults", "pgpromote_success",
    "pgdemote_kswapd", "pgdemote_direct",
] + [f"trial{i}_s" for i in range(1, 21)]

rows = []
for case_dir in sorted(p for p in root.glob("*/*") if p.is_dir()):
    workload = case_dir.parent.name
    policy = case_dir.name
    status = read_kv(case_dir / "status.txt")
    read_s, avg_s, trials = parse_stdout(case_dir / "workload.stdout.log")
    elapsed = status.get("elapsed_s", "")
    if not elapsed:
        elapsed = parse_stderr_time(case_dir / "workload.stderr.log")
    if not avg_s:
        avg_s = elapsed
    off_ms, on_ms, reason = controller_events(case_dir / "controller.csv")
    row = {
        "workload": workload,
        "policy": policy,
        "returncode": status.get("returncode", ""),
        "elapsed_s": elapsed,
        "read_s": read_s,
        "avg_trial_s": avg_s,
        "trial_count": len(trials),
        "migration_off_ms": off_ms,
        "migration_on_ms": on_ms,
        "stop_reason": reason,
        "numa_hint_faults": delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": delta(case_dir, "pgdemote_direct"),
    }
    for i, value in enumerate(trials, 1):
        if i > 20:
            break
        row[f"trial{i}_s"] = value
    rows.append(row)

with out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
print(out)
PY
}

require_file "${RUNNER}"
require_file "${CONTROLLER}"
chmod +x "${RUNNER}" "${CONTROLLER}"
set_common_kernel_state

{
  echo "uname=$(uname -a)"
  echo "lru_gen_enabled=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true)"
  echo "workloads=${WORKLOADS}"
  echo "policies=${POLICIES}"
  echo "capacity_pages=${CAPACITY_PAGES}"
  echo "omp_threads=${OMP_THREADS}"
  echo "trials=${TRIALS}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "local_fault_rate=${LOCAL_FAULT_RATE}"
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
  for policy in ${POLICIES}; do
    case "${policy}" in
      off)
        run_cgroup_policy "${workload}" off off 10
        ;;
      on)
        run_cgroup_policy "${workload}" on on 10
        ;;
      all_local)
        run_direct_policy "${workload}" all_local 0
        ;;
      all_slow)
        run_direct_policy "${workload}" all_slow 1
        ;;
      ours_w5)
        run_cgroup_policy "${workload}" ours_w5 ours 5
        ;;
      ours_w10)
        run_cgroup_policy "${workload}" ours_w10 ours 10
        ;;
      *)
        log "unknown policy=${policy}; skip"
        ;;
    esac
    summarize_results
  done
done

summarize_results
log "summary=${OUTROOT}/summary.csv"
