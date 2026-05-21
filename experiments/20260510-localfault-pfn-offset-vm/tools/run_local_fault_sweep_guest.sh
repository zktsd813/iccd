#!/usr/bin/env bash
set -euo pipefail

OUTDIR="${OUTDIR:-/tmp/local_fault_sweep}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
SWEEP_BIN="${MBENCH:-/root/mbench}"
CGROOT="${CGROOT:-/sys/fs/cgroup}"
CG_NAME="${CG_NAME:-localfault_sweep}"
LOCAL_NODE="${LOCAL_NODE:-0}"
CPUSET_CPUS="${CPUSET_CPUS:-0-31}"
CPUSET_MEMS="${CPUSET_MEMS:-0,1}"
ALLOC_SIZE="${ALLOC_SIZE:-16G}"
CAPACITY_PAGES="${CAPACITY_PAGES:-8388608}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
NUMA_FAST_SCAN="${NUMA_FAST_SCAN:-0}"
HOT_THRESHOLD_MS="${HOT_THRESHOLD_MS:-0}"
NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
NUMA_LOCAL_FAULT_ON_TIERING="${NUMA_LOCAL_FAULT_ON_TIERING:-10}"
WAIT_MAX_SEC="${WAIT_MAX_SEC:-420}"
POLL_SEC="${POLL_SEC:-5}"

RUN_ROOT="${OUTDIR}/${RUN_ID}"
CASE_DIR="${RUN_ROOT}/local_fault_sweep"
CG="${CGROOT}/${CG_NAME}"
READY="${CASE_DIR}/ready"
GO="${CASE_DIR}/go"
DONE="${CASE_DIR}/done"
LOG="${CASE_DIR}/sweep.log"
POLL_CSV="${CASE_DIR}/scan_wait.csv"

mkdir -p "${CASE_DIR}"

log() {
	printf '[local-fault-sweep] %s\n' "$*" | tee -a "${LOG}"
}

read_optional() {
	local path="$1"
	[[ -f "${path}" ]] && cat "${path}" || true
}

write_optional() {
	local path="$1"
	local value="$2"
	[[ -w "${path}" ]] && echo "${value}" > "${path}" || true
}

pick_knob_file() {
	local cg="$1"
	local name="$2"
	local candidate

	for candidate in "${cg}/${name}" "${cg}/memory.${name}"; do
		if [[ -f "${candidate}" ]]; then
			echo "${candidate}"
			return 0
		fi
	done
	return 1
}

write_knob() {
	local cg="$1"
	local name="$2"
	local value="$3"
	local knob

	knob="$(pick_knob_file "${cg}" "${name}")"
	echo "${value}" > "${knob}"
}

write_knob_optional() {
	write_knob "$@" 2>/dev/null || true
}

read_migrate_key() {
	local key="$1"
	local file

	file="$(pick_knob_file "${CG}" "numa_migrate_state")" || {
		echo 0
		return
	}
	awk -v k="${key}" '$1 == k { print $2; found=1 } END { if (!found) print 0 }' "${file}"
}

snapshot() {
	local out="$1"

	{
		echo "time_ms $(date +%s%3N)"
		if [[ -f "${CG}/memory.numa_migrate_state" ]]; then
			cat "${CG}/memory.numa_migrate_state"
		elif [[ -f "${CG}/numa_migrate_state" ]]; then
			cat "${CG}/numa_migrate_state"
		fi
		if [[ -f "${CG}/memory.stat" ]]; then
			sed 's/^/memory.stat./' "${CG}/memory.stat"
		elif [[ -f "${CG}/stat" ]]; then
			sed 's/^/memory.stat./' "${CG}/stat"
		fi
	} > "${out}"
}

enable_controllers() {
	local ctrl

	if [[ -f "${CGROOT}/cgroup.controllers" ]]; then
		for ctrl in cpuset memory; do
			if grep -qw "${ctrl}" "${CGROOT}/cgroup.controllers" &&
			   ! grep -qw "${ctrl}" "${CGROOT}/cgroup.subtree_control"; then
				echo "+${ctrl}" > "${CGROOT}/cgroup.subtree_control" || true
			fi
		done
	fi
}

cleanup_cg() {
	local pid

	if [[ -d "${CG}" && -f "${CG}/cgroup.procs" && -f "${CGROOT}/cgroup.procs" ]]; then
		while IFS= read -r pid; do
			[[ -n "${pid}" ]] || continue
			echo "${pid}" > "${CGROOT}/cgroup.procs" 2>/dev/null || true
		done < "${CG}/cgroup.procs"
	fi
	rmdir "${CG}" 2>/dev/null || true
}

parse_pages() {
	python3 - "$1" <<'PY'
import sys
s=sys.argv[1].strip()
mult=1
if s[-1:].lower()=="g":
    mult=1024**3; s=s[:-1]
elif s[-1:].lower()=="m":
    mult=1024**2; s=s[:-1]
elif s[-1:].lower()=="k":
    mult=1024; s=s[:-1]
print(int(int(s,0)*mult//4096))
PY
}

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
write_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
write_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
write_optional /proc/sys/kernel/numa_balancing 0
[[ -f /sys/kernel/mm/lru_gen/enabled ]] && echo 0x0007 > /sys/kernel/mm/lru_gen/enabled || true

enable_controllers
cleanup_cg
mkdir -p "${CG}"
[[ -f "${CG}/cpuset.cpus" ]] && echo "${CPUSET_CPUS}" > "${CG}/cpuset.cpus"
[[ -f "${CG}/cpuset.mems" ]] && echo "${LOCAL_NODE}" > "${CG}/cpuset.mems"
write_knob_optional "${CG}" "node_capacity" "${LOCAL_NODE} ${CAPACITY_PAGES}"
write_knob "${CG}" "node_balancing" "${NODE_BALANCING_ON}"
write_knob_optional "${CG}" "kswapd_demotion_enabled" 0
write_knob_optional "${CG}" "numa_balancing_fast_scan" "${NUMA_FAST_SCAN}"
write_knob_optional "${CG}" "numa_balancing_hot_threshold_ms" "${HOT_THRESHOLD_MS}"
write_knob_optional "${CG}" "numa_local_fault_on_tiering" 0

{
	echo "run_id=${RUN_ID}"
	echo "kernel=$(uname -a)"
	echo "lru_gen_enabled=$(read_optional /sys/kernel/mm/lru_gen/enabled)"
	echo "alloc_size=${ALLOC_SIZE}"
	echo "alloc_pages=$(parse_pages "${ALLOC_SIZE}")"
	echo "target_rate=${NUMA_LOCAL_FAULT_ON_TIERING}"
	echo "expected_selected_pages=$(( $(parse_pages "${ALLOC_SIZE}") * NUMA_LOCAL_FAULT_ON_TIERING / 100 ))"
	echo "scan_size_mb=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb)"
	echo "scan_period_min_ms=$(read_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms)"
	echo "global_numa_balancing=$(read_optional /proc/sys/kernel/numa_balancing)"
	echo "numa_fast_scan=${NUMA_FAST_SCAN}"
	echo "wait_max_sec=${WAIT_MAX_SEC}"
} > "${RUN_ROOT}/run_meta.txt"

log "starting allocation with cpuset.mems=${LOCAL_NODE}"
(
	echo "${BASHPID}" > "${CG}/cgroup.procs"
	exec "${SWEEP_BIN}" "${ALLOC_SIZE}" "${READY}" "${GO}" "${DONE}" "${WAIT_MAX_SEC}"
) > "${CASE_DIR}/sweep.stdout" 2> "${CASE_DIR}/sweep.stderr" &
SWEEP_PID=$!

deadline=$((SECONDS + 180))
while [[ ! -f "${READY}" ]]; do
	if ! kill -0 "${SWEEP_PID}" 2>/dev/null; then
		echo "sweep process exited before ready" >&2
		wait "${SWEEP_PID}" || true
		exit 1
	fi
	if (( SECONDS > deadline )); then
		echo "timed out waiting for allocation ready" >&2
		exit 1
	fi
	sleep 1
done
log "allocation ready"
snapshot "${CASE_DIR}/before_scan_enable.txt"

[[ -f "${CG}/cpuset.mems" ]] && echo "${CPUSET_MEMS}" > "${CG}/cpuset.mems"
write_knob_optional "${CG}" "node_capacity" "${LOCAL_NODE} ${CAPACITY_PAGES}"
write_knob "${CG}" "node_balancing" "${NODE_BALANCING_ON}"
write_knob_optional "${CG}" "kswapd_demotion_enabled" 0
write_knob_optional "${CG}" "numa_migration_stop_enabled" 0
write_knob_optional "${CG}" "numa_pingpong_stat_enabled" 0
write_knob_optional "${CG}" "numa_local_fault_on_tiering" "${NUMA_LOCAL_FAULT_ON_TIERING}"
write_knob_optional "${CG}" "numa_local_fault_refault_hit_ms" 1000
snapshot "${CASE_DIR}/after_scan_enable.txt"

alloc_pages="$(parse_pages "${ALLOC_SIZE}")"
target_pages=$(( alloc_pages * NUMA_LOCAL_FAULT_ON_TIERING / 100 ))
target_floor=$(( target_pages * 98 / 100 ))
echo "elapsed_sec,pfn_candidates,pfn_selected,pfn_selected_bp,pte_updates,refault,lost" > "${POLL_CSV}"

log "waiting for scan target pte_updates>=${target_floor} expected=${target_pages}"
start_sec="${SECONDS}"
while true; do
	cand="$(read_migrate_key numa_local_fault_pfn_candidates)"
	sel="$(read_migrate_key numa_local_fault_pfn_selected)"
	bp="$(read_migrate_key numa_local_fault_pfn_selected_bp)"
	pte="$(read_migrate_key numa_local_fault_pte_updates)"
	refault="$(read_migrate_key numa_local_fault_refault)"
	lost="$(read_migrate_key numa_local_fault_lost)"
	printf '%s,%s,%s,%s,%s,%s,%s\n' \
		"$((SECONDS - start_sec))" "${cand}" "${sel}" "${bp}" "${pte}" "${refault}" "${lost}" >> "${POLL_CSV}"
	if (( pte >= target_floor )); then
		log "scan target reached pte=${pte}"
		break
	fi
	if (( SECONDS - start_sec >= WAIT_MAX_SEC )); then
		log "scan wait max reached pte=${pte}"
		break
	fi
	sleep "${POLL_SEC}"
done

snapshot "${CASE_DIR}/before_sweep.txt"
date +%s%3N > "${GO}"
deadline=$((SECONDS + 180))
while [[ ! -f "${DONE}" ]]; do
	if ! kill -0 "${SWEEP_PID}" 2>/dev/null; then
		echo "sweep process exited before done" >&2
		wait "${SWEEP_PID}" || true
		exit 1
	fi
	if (( SECONDS > deadline )); then
		echo "timed out waiting for sweep done" >&2
		exit 1
	fi
	sleep 1
done
wait "${SWEEP_PID}"
snapshot "${CASE_DIR}/after_sweep.txt"

python3 - "${CASE_DIR}" "${target_pages}" > "${CASE_DIR}/summary.json" <<'PY'
import json, pathlib, sys
case = pathlib.Path(sys.argv[1])
target = int(sys.argv[2])

def parse(path):
    out = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        parts = raw.split()
        if len(parts) >= 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                out[parts[0]] = parts[1]
    return out

before = parse(case / "before_sweep.txt")
after = parse(case / "after_sweep.txt")
enable = parse(case / "after_scan_enable.txt")
summary = {"expected_selected_pages": target}
for key in [
    "numa_local_fault_pfn_candidates",
    "numa_local_fault_pfn_selected",
    "numa_local_fault_pfn_selected_bp",
    "numa_local_fault_pte_updates",
    "numa_local_fault_sampled",
    "numa_local_fault_refault",
    "numa_local_fault_lost",
    "memory.stat.numa_hint_faults",
    "memory.stat.numa_pte_updates",
]:
    summary[f"before.{key}"] = before.get(key, 0)
    summary[f"after.{key}"] = after.get(key, 0)
    summary[f"delta.{key}"] = after.get(key, 0) - before.get(key, 0) if isinstance(after.get(key, 0), int) else 0
    summary[f"enabled.{key}"] = enable.get(key, 0)
if target:
    summary["pte_updates_vs_expected_pct"] = before.get("numa_local_fault_pte_updates", 0) * 100 / target
    summary["refault_delta_vs_expected_pct"] = summary["delta.numa_local_fault_refault"] * 100 / target
print(json.dumps(summary, indent=2, sort_keys=True))
PY

cat "${CASE_DIR}/summary.json"
log "artifacts ${RUN_ROOT}"
