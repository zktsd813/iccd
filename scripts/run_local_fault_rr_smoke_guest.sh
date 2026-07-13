#!/usr/bin/env bash
set -euo pipefail

SYSFS_NUMA="${SYSFS_NUMA:-/sys/kernel/mm/numa_balancing}"
DURATION_SEC="${DURATION_SEC:-60}"
BYTES_PER_NODE_MB="${BYTES_PER_NODE_MB:-512}"
NODE0_CPUS="${NODE0_CPUS:-0-7}"
NODE1_CPUS="${NODE1_CPUS:-8-15}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-100}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-200}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-64}"

read_stat() {
  local key="$1"
  awk -v key="${key}" '$1 == key { print $2; found = 1 } END { if (!found) print 0 }' \
    "${SYSFS_NUMA}/local_fault_stats"
}

write_knob() {
  local path="$1" value="$2"
  [[ -w "${path}" ]] || {
    echo "missing writable knob: ${path}" >&2
    exit 1
  }
  echo "${value}" > "${path}"
}

[[ -r "${SYSFS_NUMA}/local_fault_stats" ]] || {
  echo "missing local_fault_stats under ${SYSFS_NUMA}" >&2
  exit 1
}

if [[ -w /proc/sys/kernel/numa_balancing ]]; then
  echo 0 > /proc/sys/kernel/numa_balancing
fi
write_knob "${SYSFS_NUMA}/local_fault_rate" "${LOCAL_FAULT_RATE}"
write_knob "${SYSFS_NUMA}/local_fault_scan_period_ms" "${LOCAL_FAULT_SCAN_PERIOD_MS}"
write_knob "${SYSFS_NUMA}/local_fault_scan_size_mb" "${LOCAL_FAULT_SCAN_SIZE_MB}"

before_node0="$(read_stat local_fault_node0_pte_updates)"
before_node1="$(read_stat local_fault_node1_pte_updates)"
before_node2_attempts="$(read_stat local_fault_node2_scan_attempts)"
before_node3_attempts="$(read_stat local_fault_node3_scan_attempts)"

NODE0_CPUS="${NODE0_CPUS}" NODE1_CPUS="${NODE1_CPUS}" \
BYTES_PER_NODE_MB="${BYTES_PER_NODE_MB}" DURATION_SEC="${DURATION_SEC}" \
python3 - <<'PY'
import os
import threading
import time


def parse_cpus(text):
    cpus = set()
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            cpus.update(range(int(start), int(end) + 1))
        else:
            cpus.add(int(part))
    if not cpus:
        raise SystemExit("empty CPU list")
    return cpus


def worker(cpus, mb, duration):
    os.sched_setaffinity(0, cpus)
    size = mb * 1024 * 1024
    page = os.sysconf("SC_PAGE_SIZE")
    buf = bytearray(size)
    for offset in range(0, size, page):
        buf[offset] = 1

    deadline = time.monotonic() + duration
    value = 1
    while time.monotonic() < deadline:
        value = (value + 1) & 0xff
        for offset in range(0, size, page):
            buf[offset] = value


duration = int(os.environ["DURATION_SEC"])
mb = int(os.environ["BYTES_PER_NODE_MB"])
threads = [
    threading.Thread(target=worker, args=(parse_cpus(os.environ["NODE0_CPUS"]), mb, duration)),
    threading.Thread(target=worker, args=(parse_cpus(os.environ["NODE1_CPUS"]), mb, duration)),
]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
PY

after_node0="$(read_stat local_fault_node0_pte_updates)"
after_node1="$(read_stat local_fault_node1_pte_updates)"
after_node2_attempts="$(read_stat local_fault_node2_scan_attempts)"
after_node3_attempts="$(read_stat local_fault_node3_scan_attempts)"

delta_node0=$((after_node0 - before_node0))
delta_node1=$((after_node1 - before_node1))
delta_node2_attempts=$((after_node2_attempts - before_node2_attempts))
delta_node3_attempts=$((after_node3_attempts - before_node3_attempts))

cat "${SYSFS_NUMA}/local_fault_stats"
echo "smoke_delta_node0_pte_updates ${delta_node0}"
echo "smoke_delta_node1_pte_updates ${delta_node1}"
echo "smoke_delta_node2_scan_attempts ${delta_node2_attempts}"
echo "smoke_delta_node3_scan_attempts ${delta_node3_attempts}"

if (( delta_node0 <= 0 )); then
  echo "node0 local-fault PTE updates did not increase" >&2
  exit 1
fi
if (( delta_node1 <= 0 )); then
  echo "node1 local-fault PTE updates did not increase" >&2
  exit 1
fi
if (( delta_node2_attempts != 0 || delta_node3_attempts != 0 )); then
  echo "slow-tier node was scanned by local-fault RR" >&2
  exit 1
fi
