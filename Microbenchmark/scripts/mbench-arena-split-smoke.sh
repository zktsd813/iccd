#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(dirname -- "$SCRIPT_DIR")
BIN="$ROOT_DIR/mbench"

if [ "$#" -eq 2 ]; then
    LOCAL_NODE=$1
    REMOTE_NODE=$2
elif [ "$#" -eq 0 ]; then
    set -- $(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' \
        -printf '%f\n' 2>/dev/null | sed 's/^node//' | sort -n | head -n 2)
    if [ "$#" -lt 2 ]; then
        printf '[arena-split-smoke] SKIP: two NUMA nodes are required\n'
        exit 0
    fi
    LOCAL_NODE=$1
    REMOTE_NODE=$2
else
    printf 'Usage: %s [LOCAL_NODE REMOTE_NODE]\n' "$0" >&2
    exit 2
fi

if [ ! -x "$BIN" ]; then
    make -C "$ROOT_DIR"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mbench-arena-split.XXXXXX")
READY_FILE="$TMP_DIR/ready"
START_FILE="$TMP_DIR/start"
STDOUT_FILE="$TMP_DIR/stdout"
STDERR_FILE="$TMP_DIR/stderr"
PID=

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

expect_config_failure() {
    if MBENCH_FORCE_WARMUP_MS=0 "$BIN" "$@" >/dev/null 2>&1; then
        printf '[arena-split-smoke] expected configuration failure: %s\n' "$*" >&2
        exit 1
    fi
}

BASE_ARGS="--mode skewed-hotset --threads 1 --arena-size 64M --window-size 4M --window-offset 60M --hotset-pages 1024 --hot-prob-pct 100 --hotset-read-pct 100 --hotset-write-pct 0 --hotset-rmw-pct 0 --hotset-index-mode mulshift"

# arena-split requires an explicit, non-empty local prefix smaller than the arena.
# shellcheck disable=SC2086
expect_config_failure $BASE_ARGS --placement "arena-split:$LOCAL_NODE,$REMOTE_NODE"
# shellcheck disable=SC2086
expect_config_failure $BASE_ARGS --placement "arena-split:$LOCAL_NODE,$REMOTE_NODE" \
    --arena-split-local 64M
# shellcheck disable=SC2086
expect_config_failure $BASE_ARGS --placement "arena-split:$LOCAL_NODE,$REMOTE_NODE" \
    --arena-split-local 32M --no-prefault
# shellcheck disable=SC2086
expect_config_failure $BASE_ARGS --placement "arena-split:$LOCAL_NODE,$LOCAL_NODE" \
    --arena-split-local 32M

# Hold execution after runtime preparation so initial residency can be inspected.
# shellcheck disable=SC2086
MBENCH_FORCE_WARMUP_MS=0 MBENCH_READY_FILE="$READY_FILE" \
MBENCH_START_FILE="$START_FILE" "$BIN" $BASE_ARGS \
    --placement "arena-split:$LOCAL_NODE,$REMOTE_NODE" \
    --arena-split-local 32M --ops-per-pass 4096 --target-ops 4096 \
    >"$STDOUT_FILE" 2>"$STDERR_FILE" &
PID=$!

i=0
while [ ! -e "$READY_FILE" ] && kill -0 "$PID" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 200 ]; then
        printf '[arena-split-smoke] timed out waiting for ready marker\n' >&2
        cat "$STDERR_FILE" >&2
        exit 1
    fi
    sleep 0.05
done

if [ ! -e "$READY_FILE" ]; then
    cat "$STDERR_FILE" >&2
    wait "$PID" || true
    PID=
    exit 1
fi

PAGE_SIZE=$(getconf PAGESIZE)
ARENA_PAGES=$((64 * 1024 * 1024 / PAGE_SIZE))
HALF_PAGES=$((32 * 1024 * 1024 / PAGE_SIZE))
ARENA_LINE=$(awk -v pages="$ARENA_PAGES" '
    {
        for (i = 1; i <= NF; i++) {
            if ($i == "anon=" pages) {
                print
                exit
            }
        }
    }
' "/proc/$PID/numa_maps")

if [ -z "$ARENA_LINE" ]; then
    printf '[arena-split-smoke] 64M arena mapping not found\n' >&2
    exit 1
fi

POLICY=$(printf '%s\n' "$ARENA_LINE" | awk '{print $2}')
LOCAL_PAGES=$(printf '%s\n' "$ARENA_LINE" | awk -v key="N$LOCAL_NODE=" '
    { for (i = 1; i <= NF; i++) if (index($i, key) == 1) { sub(key, "", $i); print $i; exit } }
')
REMOTE_PAGES=$(printf '%s\n' "$ARENA_LINE" | awk -v key="N$REMOTE_NODE=" '
    { for (i = 1; i <= NF; i++) if (index($i, key) == 1) { sub(key, "", $i); print $i; exit } }
')

if [ "$POLICY" != default ] || [ "${LOCAL_PAGES:-0}" -ne "$HALF_PAGES" ] || \
   [ "${REMOTE_PAGES:-0}" -ne "$HALF_PAGES" ]; then
    printf '[arena-split-smoke] unexpected arena residency: %s\n' "$ARENA_LINE" >&2
    exit 1
fi

grep -q '^placement=arena-split nodes=' "$STDERR_FILE"
grep -q 'arena_split_local_bytes=33554432' "$STDERR_FILE"

touch "$START_FILE"
wait "$PID"
PID=

printf '[arena-split-smoke] PASS local_node=%s remote_node=%s local_pages=%s remote_pages=%s policy=%s\n' \
    "$LOCAL_NODE" "$REMOTE_NODE" "$LOCAL_PAGES" "$REMOTE_PAGES" "$POLICY"
