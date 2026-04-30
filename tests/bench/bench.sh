#!/bin/bash
# nayr performance benchmark
#
# Follows the same methodology as https://pnpm.io/benchmarks
# covering all 9 scenarios from the official benchmark matrix:
#
#   action | cache | lockfile | node_modules
#   -------|-------|----------|-------------
#   install|       |          |              clean install
#   install|  ✔   |    ✔    |      ✔       no-op (nothing changed)
#   install|  ✔   |    ✔    |              cache + lockfile, no node_modules
#   install|  ✔   |          |              cache only
#   install|  ✔   |          |      ✔       cache + node_modules, no lockfile
#   install|       |    ✔    |      ✔       lockfile + node_modules, no cache
#   install|       |          |      ✔       node_modules only
#   install|       |    ✔    |              lockfile only (CI fresh machine)
#   update |  n/a  |   n/a   |     n/a      dep version changed, reinstall
#
# Supported fixtures:
#   simple        - lodash, ms, is-odd (~3 packages)
#   workspace     - monorepo with 2 sub-packages
#   alotta-files  - identical to pnpm's own benchmark fixture (~100 top-level deps)
#
# Usage: bash tests/bench/bench.sh [options]
#
#   --runs N          Repetitions per scenario, median taken (default: 3)
#   --fixture NAME    Fixture name (default: simple)
#   --no-yarn         Skip yarn comparison
#   --no-pnpm         Skip pnpm comparison
#   --nayr-only       Benchmark nayr only
#   --json            Machine-readable JSON output

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAYR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAYR_BIN="$NAYR_ROOT/zig-out/bin/nayr"
FIXTURES_DIR="$NAYR_ROOT/tests/integration/fixtures"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
RUNS=3
FIXTURE="simple"
SKIP_YARN=0
SKIP_PNPM=0
JSON_OUTPUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)      shift; RUNS="$1" ;;
        --fixture)   shift; FIXTURE="$1" ;;
        --no-yarn)   SKIP_YARN=1 ;;
        --no-pnpm)   SKIP_PNPM=1 ;;
        --nayr-only) SKIP_YARN=1; SKIP_PNPM=1 ;;
        --json)      JSON_OUTPUT=1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Colours (disabled for non-TTY / JSON mode)
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ "$JSON_OUTPUT" = "0" ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------
ms_now() {
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N
    else
        python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || \
        python  -c "import time; print(int(time.time() * 1000))"
    fi
}

time_cmd() {
    local var="$1"; shift
    local t0 t1
    t0="$(ms_now)"
    "$@" >/dev/null 2>&1
    t1="$(ms_now)"
    eval "$var=$((t1 - t0))"
}

run_n_times() {
    local fn="$1" dir="$2" runs="$3" var="$4"
    local times="" elapsed i=0
    while [ "$i" -lt "$runs" ]; do
        time_cmd elapsed "$fn" "$dir"
        times="$times $elapsed"
        i=$((i + 1))
    done
    local sorted count mid
    sorted="$(printf '%s\n' $times | sort -n | grep -v '^$')"
    count="$(printf '%s\n' $sorted | wc -l | tr -d ' ')"
    mid=$(( (count + 1) / 2 ))
    eval "$var=$(printf '%s\n' $sorted | sed -n "${mid}p")"
}

# ---------------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------------
clear_nayr_cache() {
    local d="$HOME/.nayr/cache"
    [ -d "$d" ] && rm -rf "$d" && mkdir -p "$d" || true
}

clear_yarn_cache() {
    (source ~/.nvm/nvm.sh 2>/dev/null; yarn cache clean --force) >/dev/null 2>&1 || true
}

clear_pnpm_cache() {
    local store
    store="$(source ~/.nvm/nvm.sh 2>/dev/null; pnpm store path 2>/dev/null)" || true
    [ -n "$store" ] && rm -rf "$store" || true
}

# ---------------------------------------------------------------------------
# Per-fixture "update" dep config.
# The update scenario bumps one dep to a different exact version so the
# package manager must re-resolve and update node_modules.
# Both the original and bumped versions are pre-warmed in the cache during
# setup so network latency doesn't skew the measurement.
# ---------------------------------------------------------------------------
case "$FIXTURE" in
    alotta-files)
        UPDATE_DEP="lodash"
        UPDATE_TO="4.17.20"   # pinned older version, clearly different
        ;;
    *)
        UPDATE_DEP="ms"
        UPDATE_TO="2.1.0"
        ;;
esac

# Find the package.json that declares UPDATE_DEP in the given project dir.
find_update_pkg() {
    local dir="$1"
    for f in "$dir/package.json" "$dir"/packages/*/package.json; do
        [ -f "$f" ] && grep -q "\"$UPDATE_DEP\"" "$f" && echo "$f" && return
    done
}

# Bump UPDATE_DEP to UPDATE_TO in the given package.json file.
bump_dep() {
    sed -i "s/\"$UPDATE_DEP\": \"[^\"]*\"/\"$UPDATE_DEP\": \"$UPDATE_TO\"/" "$1"
}

# ---------------------------------------------------------------------------
# Scenario runner functions - nayr
# ---------------------------------------------------------------------------
bench_nayr_clean() {
    clear_nayr_cache; rm -f "$1/nayr.lock"; rm -rf "$1/node_modules"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_noop() { (cd "$1" && "$NAYR_BIN" install); }
bench_nayr_c_lf() {
    rm -rf "$1/node_modules"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_c() {
    rm -f "$1/nayr.lock"; rm -rf "$1/node_modules"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_c_nm() {
    rm -f "$1/nayr.lock"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_lf_nm() {
    clear_nayr_cache
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_nm() {
    clear_nayr_cache; rm -f "$1/nayr.lock"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_lf() {
    clear_nayr_cache; rm -rf "$1/node_modules"
    (cd "$1" && "$NAYR_BIN" install)
}
bench_nayr_update() {
    local dir="$1"
    local pkg; pkg="$(find_update_pkg "$dir")" || return 1
    local orig; orig="$(cat "$pkg")"
    bump_dep "$pkg"
    rm -f "$dir/nayr.lock"
    (cd "$dir" && "$NAYR_BIN" install)
    printf '%s' "$orig" > "$pkg"
    (cd "$dir" && "$NAYR_BIN" install) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Scenario runner functions - pnpm
# ---------------------------------------------------------------------------
bench_pnpm_clean() {
    clear_pnpm_cache; rm -f "$1/pnpm-lock.yaml"; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_noop() { (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install); }
bench_pnpm_c_lf() {
    rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_c() {
    rm -f "$1/pnpm-lock.yaml"; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_c_nm() {
    rm -f "$1/pnpm-lock.yaml"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_lf_nm() {
    clear_pnpm_cache
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_nm() {
    clear_pnpm_cache; rm -f "$1/pnpm-lock.yaml"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_lf() {
    clear_pnpm_cache; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
}
bench_pnpm_update() {
    local dir="$1"
    local pkg; pkg="$(find_update_pkg "$dir")" || return 1
    local orig; orig="$(cat "$pkg")"
    bump_dep "$pkg"
    rm -f "$dir/pnpm-lock.yaml"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install)
    printf '%s' "$orig" > "$pkg"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Scenario runner functions - yarn
# ---------------------------------------------------------------------------
bench_yarn_clean() {
    clear_yarn_cache; rm -f "$1/yarn.lock"; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_noop() { (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent); }
bench_yarn_c_lf() {
    rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_c() {
    rm -f "$1/yarn.lock"; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_c_nm() {
    rm -f "$1/yarn.lock"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_lf_nm() {
    clear_yarn_cache
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_nm() {
    clear_yarn_cache; rm -f "$1/yarn.lock"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_lf() {
    clear_yarn_cache; rm -rf "$1/node_modules"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
}
bench_yarn_update() {
    local dir="$1"
    local pkg; pkg="$(find_update_pkg "$dir")" || return 1
    local orig; orig="$(cat "$pkg")"
    bump_dep "$pkg"
    rm -f "$dir/yarn.lock"
    (cd "$1" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent)
    printf '%s' "$orig" > "$pkg"
    (cd "$dir" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
fmt_ms() {
    local ms="$1"
    if [ "$ms" -ge 1000 ]; then
        printf "%d.%02ds" "$((ms / 1000))" "$((ms % 1000 / 10))"
    else
        printf "%dms" "$ms"
    fi
}

speedup() { awk "BEGIN { printf \"%.1fx\", $2 / $1 }"; }

# print_row ACTION CACHE LF NM NAYR_MS PNPM_MS YARN_MS
print_row() {
    local action="$1" cache="$2" lf="$3" nm="$4"
    local nayr_ms="$5" pnpm_ms="$6" yarn_ms="$7"
    local nayr_fmt; nayr_fmt="$(fmt_ms "$nayr_ms")"

    if [ "$SKIP_PNPM" = "1" ] && [ "$SKIP_YARN" = "1" ]; then
        printf "  %-8s  %-5s  %-8s  %-12s  ${GREEN}%-10s${RESET}\n" \
            "$action" "$cache" "$lf" "$nm" "$nayr_fmt"
    elif [ "$SKIP_PNPM" = "1" ]; then
        local yarn_fmt ratio_yarn
        yarn_fmt="$(fmt_ms "$yarn_ms")"; ratio_yarn="$(speedup "$nayr_ms" "$yarn_ms")"
        printf "  %-8s  %-5s  %-8s  %-12s  ${GREEN}%-10s${RESET}  %-10s  ${YELLOW}%s${RESET}\n" \
            "$action" "$cache" "$lf" "$nm" "$nayr_fmt" "$yarn_fmt" "$ratio_yarn"
    elif [ "$SKIP_YARN" = "1" ]; then
        local pnpm_fmt ratio_pnpm
        pnpm_fmt="$(fmt_ms "$pnpm_ms")"; ratio_pnpm="$(speedup "$nayr_ms" "$pnpm_ms")"
        printf "  %-8s  %-5s  %-8s  %-12s  ${GREEN}%-10s${RESET}  %-10s  ${YELLOW}%s${RESET}\n" \
            "$action" "$cache" "$lf" "$nm" "$nayr_fmt" "$pnpm_fmt" "$ratio_pnpm"
    else
        local pnpm_fmt yarn_fmt ratio_pnpm ratio_yarn
        pnpm_fmt="$(fmt_ms "$pnpm_ms")"; yarn_fmt="$(fmt_ms "$yarn_ms")"
        ratio_pnpm="$(speedup "$nayr_ms" "$pnpm_ms")"
        ratio_yarn="$(speedup "$nayr_ms" "$yarn_ms")"
        printf "  %-8s  %-5s  %-8s  %-12s  ${GREEN}%-10s${RESET}  %-10s  %-10s  ${YELLOW}%-8s${RESET}  ${YELLOW}%s${RESET}\n" \
            "$action" "$cache" "$lf" "$nm" \
            "$nayr_fmt" "$pnpm_fmt" "$yarn_fmt" \
            "vs pnpm: $ratio_pnpm" "vs yarn: $ratio_yarn"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [ ! -f "$NAYR_BIN" ]; then
    printf "${YELLOW}Building nayr (ReleaseFast)...${RESET}\n"
    (cd "$NAYR_ROOT" && zig build -Doptimize=ReleaseFast) || { printf "Build failed\n"; exit 1; }
fi

if [ ! -d "$FIXTURES_DIR/$FIXTURE" ]; then
    printf "Fixture not found: %s\n" "$FIXTURES_DIR/$FIXTURE"; exit 1
fi

# ---------------------------------------------------------------------------
# Setup: create isolated temp dirs and prime all caches
# ---------------------------------------------------------------------------
if [ "$JSON_OUTPUT" = "0" ]; then
    printf "\n${BOLD}${CYAN}nayr benchmark - fixture: %s, %d runs each${RESET}\n" "$FIXTURE" "$RUNS"
    printf "  Methodology: https://pnpm.io/benchmarks\n\n"
    printf "  Preparing (this may take a while on first run)...\n"
fi

NAYR_DIR="$(mktemp -d)"
PNPM_DIR="$(mktemp -d)"
YARN_DIR="$(mktemp -d)"
trap 'rm -rf "$NAYR_DIR" "$PNPM_DIR" "$YARN_DIR"' EXIT

cp -r "$FIXTURES_DIR/$FIXTURE/." "$NAYR_DIR/"
cp -r "$FIXTURES_DIR/$FIXTURE/." "$PNPM_DIR/"
cp -r "$FIXTURES_DIR/$FIXTURE/." "$YARN_DIR/"

# Prime nayr cache (original + update dep version).
(cd "$NAYR_DIR" && "$NAYR_BIN" install) >/dev/null 2>&1 || true
UPDATE_PKG_NAYR="$(find_update_pkg "$NAYR_DIR")"
if [ -n "$UPDATE_PKG_NAYR" ]; then
    ORIG_NAYR="$(cat "$UPDATE_PKG_NAYR")"
    bump_dep "$UPDATE_PKG_NAYR"
    (cd "$NAYR_DIR" && "$NAYR_BIN" install) >/dev/null 2>&1 || true
    printf '%s' "$ORIG_NAYR" > "$UPDATE_PKG_NAYR"
    (cd "$NAYR_DIR" && "$NAYR_BIN" install) >/dev/null 2>&1 || true
fi

# Prime pnpm cache.
if [ "$SKIP_PNPM" = "0" ]; then
    (cd "$PNPM_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install) >/dev/null 2>&1 || true
    UPDATE_PKG_PNPM="$(find_update_pkg "$PNPM_DIR")"
    if [ -n "$UPDATE_PKG_PNPM" ]; then
        ORIG_PNPM="$(cat "$UPDATE_PKG_PNPM")"
        bump_dep "$UPDATE_PKG_PNPM"
        (cd "$PNPM_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install) >/dev/null 2>&1 || true
        printf '%s' "$ORIG_PNPM" > "$UPDATE_PKG_PNPM"
        (cd "$PNPM_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; pnpm install) >/dev/null 2>&1 || true
    fi
fi

# Prime yarn cache.
if [ "$SKIP_YARN" = "0" ]; then
    (cd "$YARN_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent) >/dev/null 2>&1 || true
    UPDATE_PKG_YARN="$(find_update_pkg "$YARN_DIR")"
    if [ -n "$UPDATE_PKG_YARN" ]; then
        ORIG_YARN="$(cat "$UPDATE_PKG_YARN")"
        bump_dep "$UPDATE_PKG_YARN"
        (cd "$YARN_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent) >/dev/null 2>&1 || true
        printf '%s' "$ORIG_YARN" > "$UPDATE_PKG_YARN"
        (cd "$YARN_DIR" && source ~/.nvm/nvm.sh 2>/dev/null; yarn install --silent) >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# Run all 9 scenarios
# ---------------------------------------------------------------------------
SCENARIOS="clean noop c_lf c c_nm lf_nm nm lf update"

NAYR_CLEAN=0; NAYR_NOOP=0; NAYR_C_LF=0; NAYR_C=0; NAYR_C_NM=0
NAYR_LF_NM=0; NAYR_NM=0; NAYR_LF=0; NAYR_UPDATE=0
PNPM_CLEAN=0; PNPM_NOOP=0; PNPM_C_LF=0; PNPM_C=0; PNPM_C_NM=0
PNPM_LF_NM=0; PNPM_NM=0; PNPM_LF=0; PNPM_UPDATE=0
YARN_CLEAN=0; YARN_NOOP=0; YARN_C_LF=0; YARN_C=0; YARN_C_NM=0
YARN_LF_NM=0; YARN_NM=0; YARN_LF=0; YARN_UPDATE=0

if [ "$JSON_OUTPUT" = "0" ]; then
    printf "  Running %d reps per scenario...\n\n" "$RUNS"
fi

for sc in $SCENARIOS; do
    VAR_SUFFIX="$(echo "$sc" | tr '[:lower:]' '[:upper:]')"

    [ "$JSON_OUTPUT" = "0" ] && printf "  [%s]" "$sc"

    run_n_times "bench_nayr_${sc}" "$NAYR_DIR" "$RUNS" "NAYR_${VAR_SUFFIX}"
    [ "$JSON_OUTPUT" = "0" ] && printf " nayr"

    if [ "$SKIP_PNPM" = "0" ]; then
        run_n_times "bench_pnpm_${sc}" "$PNPM_DIR" "$RUNS" "PNPM_${VAR_SUFFIX}"
        [ "$JSON_OUTPUT" = "0" ] && printf ", pnpm"
    fi

    if [ "$SKIP_YARN" = "0" ]; then
        run_n_times "bench_yarn_${sc}" "$YARN_DIR" "$RUNS" "YARN_${VAR_SUFFIX}"
        [ "$JSON_OUTPUT" = "0" ] && printf ", yarn"
    fi

    [ "$JSON_OUTPUT" = "0" ] && printf " done\n"
done

# ---------------------------------------------------------------------------
# Output results
# ---------------------------------------------------------------------------
if [ "$JSON_OUTPUT" = "0" ]; then
    printf "\n${BOLD}Results - fixture: %s (median of %d runs):${RESET}\n\n" "$FIXTURE" "$RUNS"

    if [ "$SKIP_PNPM" = "0" ] && [ "$SKIP_YARN" = "0" ]; then
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %-10s  %-16s  %s\n" \
            "action" "cache" "lockfile" "node_modules" "nayr" "pnpm" "yarn" "vs pnpm" "vs yarn"
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %-10s  %-16s  %s\n" \
            "------" "-----" "--------" "------------" "----" "----" "----" "-------" "-------"
    elif [ "$SKIP_PNPM" = "0" ]; then
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %s\n" \
            "action" "cache" "lockfile" "node_modules" "nayr" "pnpm" "speedup"
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %s\n" \
            "------" "-----" "--------" "------------" "----" "----" "-------"
    else
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %s\n" \
            "action" "cache" "lockfile" "node_modules" "nayr" "yarn" "speedup"
        printf "  %-8s  %-5s  %-8s  %-12s  %-10s  %-10s  %s\n" \
            "------" "-----" "--------" "------------" "----" "----" "-------"
    fi

    print_row "install" ""  ""  ""  "$NAYR_CLEAN"  "$PNPM_CLEAN"  "$YARN_CLEAN"
    print_row "install" "✔" "✔" "✔" "$NAYR_NOOP"   "$PNPM_NOOP"   "$YARN_NOOP"
    print_row "install" "✔" "✔" ""  "$NAYR_C_LF"   "$PNPM_C_LF"   "$YARN_C_LF"
    print_row "install" "✔" ""  ""  "$NAYR_C"      "$PNPM_C"      "$YARN_C"
    print_row "install" "✔" ""  "✔" "$NAYR_C_NM"   "$PNPM_C_NM"   "$YARN_C_NM"
    print_row "install" ""  "✔" "✔" "$NAYR_LF_NM"  "$PNPM_LF_NM"  "$YARN_LF_NM"
    print_row "install" ""  ""  "✔" "$NAYR_NM"     "$PNPM_NM"     "$YARN_NM"
    print_row "install" ""  "✔" ""  "$NAYR_LF"     "$PNPM_LF"     "$YARN_LF"
    print_row "update"  "n/a" "n/a" "n/a" "$NAYR_UPDATE" "$PNPM_UPDATE" "$YARN_UPDATE"

    printf "\n"
    if [ "$NAYR_NOOP" -lt 500 ]; then
        printf "  ${GREEN}✔ no-op under 500ms target${RESET}\n"
    else
        printf "  ${YELLOW}⚠ no-op over 500ms target (%dms)${RESET}\n" "$NAYR_NOOP"
    fi
    printf "\n"
else
    printf '{"fixture":"%s","runs":%d' "$FIXTURE" "$RUNS"
    printf ',"nayr":{"clean":%d,"noop":%d,"c_lf":%d,"c":%d,"c_nm":%d,"lf_nm":%d,"nm":%d,"lf":%d,"update":%d}' \
        "$NAYR_CLEAN" "$NAYR_NOOP" "$NAYR_C_LF" "$NAYR_C" "$NAYR_C_NM" \
        "$NAYR_LF_NM" "$NAYR_NM" "$NAYR_LF" "$NAYR_UPDATE"
    if [ "$SKIP_PNPM" = "0" ]; then
        printf ',"pnpm":{"clean":%d,"noop":%d,"c_lf":%d,"c":%d,"c_nm":%d,"lf_nm":%d,"nm":%d,"lf":%d,"update":%d}' \
            "$PNPM_CLEAN" "$PNPM_NOOP" "$PNPM_C_LF" "$PNPM_C" "$PNPM_C_NM" \
            "$PNPM_LF_NM" "$PNPM_NM" "$PNPM_LF" "$PNPM_UPDATE"
    fi
    if [ "$SKIP_YARN" = "0" ]; then
        printf ',"yarn":{"clean":%d,"noop":%d,"c_lf":%d,"c":%d,"c_nm":%d,"lf_nm":%d,"nm":%d,"lf":%d,"update":%d}' \
            "$YARN_CLEAN" "$YARN_NOOP" "$YARN_C_LF" "$YARN_C" "$YARN_C_NM" \
            "$YARN_LF_NM" "$YARN_NM" "$YARN_LF" "$YARN_UPDATE"
    fi
    printf '}\n'
fi
