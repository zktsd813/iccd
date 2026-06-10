#!/usr/bin/env bash
set -euo pipefail

OUT="${TRIAL_PROMOTION_OUT:?missing TRIAL_PROMOTION_OUT}"
RAW_OUT="${TRIAL_PROMOTION_RAW_OUT:-}"

mkdir -p "$(dirname -- "${OUT}")"
if [[ -n "${RAW_OUT}" ]]; then
  mkdir -p "$(dirname -- "${RAW_OUT}")"
fi

KEYS=(
  pgpromote_success
  pgpromote_candidate
  pgpromote_candidate_nrl
  pgpromote_candidate_demoted
  numa_hint_faults
  pgdemote_kswapd
  pgdemote_direct
  numa_pages_migrated
)

read_counts() {
  local -n dst="$1"
  local key value
  for key in "${KEYS[@]}"; do
    value="$(awk -v key="${key}" '
      $1 == key { print $2; found = 1; exit }
      END { if (!found) print 0 }
    ' /proc/vmstat)"
    dst["${key}"]="${value}"
  done
}

elapsed_since_start() {
  local now_ns
  now_ns="$(date +%s%N)"
  awk -v now="${now_ns}" -v start="${START_NS}" 'BEGIN { printf "%.6f", (now - start) / 1000000000.0 }'
}

write_header() {
  {
    printf 'timestamp,elapsed_s,event,trial,read_s,trial_time_s,cum_trial_s'
    local key
    for key in "${KEYS[@]}"; do
      printf ',%s,%s_delta' "${key}" "${key}"
    done
    printf '\n'
  } > "${OUT}"
}

write_row() {
  local event="$1" trial="$2" read_s="$3" trial_time_s="$4" cum_trial_s="$5"
  local -A cur=()
  local key delta
  read_counts cur
  {
    printf '%s,%s,%s,%s,%s,%s,%s' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
      "$(elapsed_since_start)" \
      "${event}" \
      "${trial}" \
      "${read_s}" \
      "${trial_time_s}" \
      "${cum_trial_s}"
    for key in "${KEYS[@]}"; do
      delta=$((cur["${key}"] - PREV["${key}"]))
      printf ',%s,%s' "${cur["${key}"]}" "${delta}"
      PREV["${key}"]="${cur["${key}"]}"
    done
    printf '\n'
  } >> "${OUT}"
}

if (($# == 0)); then
  echo "usage: TRIAL_PROMOTION_OUT=path $0 COMMAND [ARGS...]" >&2
  exit 2
fi

declare -A PREV=()
START_NS="$(date +%s%N)"
read_counts PREV
write_header
write_row start 0 0 0 0

cmd=("$@")
if command -v stdbuf >/dev/null 2>&1; then
  cmd=(stdbuf -oL -eL "$@")
fi

trial=0
read_s=0
cum_trial_s=0

set +e
"${cmd[@]}" | while IFS= read -r line; do
  printf '%s\n' "${line}"
  if [[ -n "${RAW_OUT}" ]]; then
    printf '%s\n' "${line}" >> "${RAW_OUT}"
  fi
  if [[ "${line}" =~ ^Read[[:space:]]Time:[[:space:]]*([0-9.]+) ]]; then
    read_s="${BASH_REMATCH[1]}"
    write_row read_complete 0 "${read_s}" 0 0
  elif [[ "${line}" =~ ^Trial[[:space:]]Time:[[:space:]]*([0-9.]+) ]]; then
    trial_time_s="${BASH_REMATCH[1]}"
    trial=$((trial + 1))
    cum_trial_s="$(awk -v a="${cum_trial_s}" -v b="${trial_time_s}" 'BEGIN { printf "%.6f", a + b }')"
    write_row trial_end "${trial}" "${read_s}" "${trial_time_s}" "${cum_trial_s}"
  elif [[ "${line}" =~ ^Average[[:space:]]Time:[[:space:]]*([0-9.]+) ]]; then
    write_row average "${trial}" "${read_s}" 0 "${cum_trial_s}"
  fi
done
cmd_status=${PIPESTATUS[0]}
set -e

exit "${cmd_status}"
