#!/bin/sh
# nayr performance benchmark
#
# Measures and compares install time for nayr vs yarn classic across three
# scenarios that matter most in real-world CI and dev usage:
#
#   cold    - no cache, no lockfile (worst case)
#   warm    - cache populated, no lockfile (typical CI after first run)
#   locked  - cache populated, lockfile present (typical dev re-install)
#   noop    - already installed, nothing changed (<500ms target)
#
# Usage: sh tests/bench/bench.sh [--runs N] [--fixture <name>] [--no-yarn]
#
#   --runs N        Number of repetitions per scenario (default: 3)
#   --fixture       Fixture to use: simple (default) | workspace
#   --no-yarn       Skip yarn runs (only benchmark nayr)
#   --json          Output results as JSON (for programmatic use)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAYR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAYR_BIN="$NAYR_ROOT/zig-out/bin/nayr"
FIXTURES_DIR="$NAYR_ROOT/tests/integration/fixtures"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
RUNS=3
FIXTURE="simple"
SKIP_YARN=0
JSON_OUTPUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)    shift; RUNS="$1" ;;
        --fixture) shift; FIXTURE="$1" ;;
        --no-yarn) SKIP_YARN=1 ;;
        --json)    JSON_OUTPUT=1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Colours (disabled when JSON output requested)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ "$JSON_OUTPUT" = "0" ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ms_now - current time in milliseconds
ms_now() {
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N
    else
        # macOS fallback: use python
        python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || \
        python  -c "import time; print(int(time.time() * 1000))"
    fi
}

# time_cmd <label_var> <cmd...> - times a command, stores ms in $label_var
time_cmd() {
    local var="$1"; shift
    local t0 t1
    t0="$(ms_now)"
    "$@" >/dev/null 2>&1
    t1="$(ms_now)"
    eval "$var=$((t1 - t0))"
}

# run_n_times <cmd_fn> <dir> <runs> <result_var>
# Runs cmd_fn in dir N times, stores the median ms in result_var.
run_n_times() {
    local fn="$1" dir="$2" runs="$3" var="$4"
    local times="" elapsed i
    i=0
    while [ $i -lt "$runs" ]; do
        time_cmd elapsed "$fn" "$dir"
        times="$times $elapsed"
        i=$((i + 1))
    done
    # Median of collected times (sort, pick middle).
    local sorted count mid
    sorted="$(echo "$times" | tr ' ' '\n' | sort -n | grep -v '^$')"
    count="$(echo "$sorted" | wc -l | tr -d ' ')"
    mid=$(( (count + 1) / 2 ))
    eval "$var=$(echo "$sorted" | sed -n "${mid}p")"
}

# ---------------------------------------------------------------------------
# Runner functions per scenario
# ---------------------------------------------------------------------------

# Clears nayr's global cache (only nayr's, leaves system packages alone).
clear_nayr_cache() {
    local cache_dir="$HOME/.nayr/cache"
    [ -d "$cache_dir" ] && rm -rf "$cache_dir" && mkdir -p "$cache_dir" || true
}

# Clears yarn's global cache.
clear_yarn_cache() {
    (source ~/.nvm/nvm.sh 2>/dev/null; yarn cache clean --force) >/dev/null 2>&1 || true
}

# --- cold install (no cache, no lockfile) ---
bench_nayr_cold() {
    local dir="$1"
    clear_nayr_cache
    rm -f "$dir/nayr.lock"
    rm -rf "$dir/node_modules"
    (cd "$dir" && "$NAYR_BIN" install)
}

bench_yarn_cold() {
    local dir="$1"
    clear_yarn_cache
    rm -f "$dir/yarn.lock"
    rm -rf "$dir/node_modules"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}

# --- warm install (cache hit, no lockfile) ---
bench_nayr_warm() {
    local dir="$1"
    rm -f "$dir/nayr.lock"
    rm -rf "$dir/node_modules"
    (cd "$dir" && "$NAYR_BIN" install)
}

bench_yarn_warm() {
    local dir="$1"
    rm -f "$dir/yarn.lock"
    rm -rf "$dir/node_modules"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}

# --- locked install (cache + lockfile, no node_modules) ---
bench_nayr_locked() {
    local dir="$1"
    rm -rf "$dir/node_modules"
    (cd "$dir" && "$NAYR_BIN" install)
}

bench_yarn_locked() {
    local dir="$1"
    rm -rf "$dir/node_modules"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}

# --- noop install (cache + lockfile + node_modules) ---
bench_nayr_noop() {
    local dir="$1"
    (cd "$dir" && "$NAYR_BIN" install)
}

bench_yarn_noop() {
    local dir="$1"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
fmt_ms() {
    local ms="$1"
    if [ "$ms" -ge 1000 ]; then
        printf "%d.%02ds" "$((ms / 1000))" "$((ms % 1000 / 10))"
    else
        printf "%dms" "$ms"
    fi
}

speedup() {
    local nayr="$1" yarn="$2"
    # integer division gives X.Y - awk for float
    awk "BEGIN { printf \"%.1fx\", $yarn / $nayr }"
}

print_row() {
    local label="$1" nayr_ms="$2" yarn_ms="$3"
    local nayr_fmt yarn_fmt ratio
    nayr_fmt="$(fmt_ms "$nayr_ms")"
    if [ "$SKIP_YARN" = "1" ]; then
        printf "  %-20s  %s${RESET}  %s  %s\n" \
            "$label" "${GREEN}${nayr_fmt}" "" ""
    else
        yarn_fmt="$(fmt_ms "$yarn_ms")"
        ratio="$(speedup "$nayr_ms" "$yarn_ms")"
        printf "  %-20s  ${GREEN}%-10s${RESET}  %-10s  ${YELLOW}%s${RESET}\n" \
            "$label" "$nayr_fmt" "$yarn_fmt" "$ratio faster"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ ! -f "$NAYR_BIN" ]; then
    printf "${YELLOW}Building nayr...${RESET}\n"
    (cd "$NAYR_ROOT" && zig build -Doptimize=ReleaseFast) || {
        printf "Build failed\n"; exit 1
    }
fi

if [ ! -d "$FIXTURES_DIR/$FIXTURE" ]; then
    printf "Fixture not found: $FIXTURES_DIR/$FIXTURE\n"; exit 1
fi

# ---------------------------------------------------------------------------
# Setup: prepare temp dirs and prime caches for warm/locked scenarios
# ---------------------------------------------------------------------------
if [ "$JSON_OUTPUT" = "0" ]; then
    printf "\n${BOLD}${CYAN}nayr benchmark — fixture: %s, %d runs each${RESET}\n\n" "$FIXTURE" "$RUNS"
    printf "  Preparing scenarios...\n"
fi

NAYR_DIR="$(mktemp -d)"
YARN_DIR="$(mktemp -d)"
cp -r "$FIXTURES_DIR/$FIXTURE/." "$NAYR_DIR/"
cp -r "$FIXTURES_DIR/$FIXTURE/." "$YARN_DIR/"

# Prime nayr cache and generate lockfile.
(cd "$NAYR_DIR" && "$NAYR_BIN" install) >/dev/null 2>&1 || true
# Prime yarn cache and generate lockfile.
if [ "$SKIP_YARN" = "0" ]; then
    (cd "$YARN_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent) >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
SCENARIOS="cold warm locked noop"

declare_results() {
    NAYR_COLD=0; NAYR_WARM=0; NAYR_LOCKED=0; NAYR_NOOP=0
    YARN_COLD=0; YARN_WARM=0; YARN_LOCKED=0; YARN_NOOP=0
}
declare_results

printf "  Running %d reps per scenario (this will take a while)...\n\n" "$RUNS"

for scenario in $SCENARIOS; do
    printf "  [%s]" "$scenario"
    run_n_times "bench_nayr_${scenario}" "$NAYR_DIR" "$RUNS" "NAYR_$(echo "$scenario" | tr '[:lower:]' '[:upper:]')"
    printf " nayr done"
    if [ "$SKIP_YARN" = "0" ]; then
        run_n_times "bench_yarn_${scenario}" "$YARN_DIR" "$RUNS" "YARN_$(echo "$scenario" | tr '[:lower:]' '[:upper:]')"
        printf ", yarn done"
    fi
    printf "\n"
done

rm -rf "$NAYR_DIR" "$YARN_DIR"

# ---------------------------------------------------------------------------
# Print results table
# ---------------------------------------------------------------------------
if [ "$JSON_OUTPUT" = "0" ]; then
    printf "\n${BOLD}Results (median of $RUNS runs):${RESET}\n\n"
    if [ "$SKIP_YARN" = "0" ]; then
        printf "  %-20s  %-10s  %-10s  %s\n" "Scenario" "nayr" "yarn" "Speedup"
        printf "  %-20s  %-10s  %-10s  %s\n" "--------" "----" "----" "-------"
    else
        printf "  %-20s  %s\n" "Scenario" "nayr"
        printf "  %-20s  %s\n" "--------" "----"
    fi
    print_row "cold install"   "$NAYR_COLD"   "$YARN_COLD"
    print_row "warm install"   "$NAYR_WARM"   "$YARN_WARM"
    print_row "locked install" "$NAYR_LOCKED" "$YARN_LOCKED"
    print_row "no-op install"  "$NAYR_NOOP"   "$YARN_NOOP"
    printf "\n"

    # Target check: noop should be <500ms.
    if [ "$NAYR_NOOP" -lt 500 ]; then
        printf "  ${GREEN}✔ no-op install under 500ms target${RESET}\n"
    else
        printf "  ${YELLOW}⚠ no-op install over 500ms target (%dms)${RESET}\n" "$NAYR_NOOP"
    fi
    printf "\n"
else
    printf '{"fixture":"%s","runs":%d,"nayr":{"cold":%d,"warm":%d,"locked":%d,"noop":%d}' \
        "$FIXTURE" "$RUNS" "$NAYR_COLD" "$NAYR_WARM" "$NAYR_LOCKED" "$NAYR_NOOP"
    if [ "$SKIP_YARN" = "0" ]; then
        printf ',"yarn":{"cold":%d,"warm":%d,"locked":%d,"noop":%d}' \
            "$YARN_COLD" "$YARN_WARM" "$YARN_LOCKED" "$YARN_NOOP"
    fi
    printf '}\n'
fi
