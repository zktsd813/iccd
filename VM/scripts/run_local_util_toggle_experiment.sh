#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

REENABLE_CONSECUTIVE="${REENABLE_CONSECUTIVE:-2}" \
  "${SCRIPT_DIR}/run_local_util_adapt_experiment.sh" \
  --reenable-consecutive "${REENABLE_CONSECUTIVE:-2}" \
  "$@"
