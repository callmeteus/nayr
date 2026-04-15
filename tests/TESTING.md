# nayr - Test & Benchmark Guide

## Quick start

```sh
# Build + run everything (unit + integration, no yarn comparison)
sh tests/run.sh

# Run only unit tests (Zig)
sh tests/run.sh unit

# Run only integration tests
sh tests/run.sh integration --no-yarn

# Compare behavior with yarn (requires yarn 1.x in PATH)
sh tests/run.sh integration

# Performance benchmark (nayr only)
sh tests/run.sh bench --no-yarn

# Performance benchmark vs yarn
sh tests/run.sh bench
```

Or via the package scripts:

```sh
yarn test            # unit + integration (no yarn compare)
yarn test:unit       # zig build test
yarn test:integration
yarn test:compare    # integration with yarn comparison
yarn bench
yarn bench:compare
yarn ci              # full CI pipeline
```

---

## Structure

```
tests/
├── run.sh                  ← main test runner (unit + integration + bench)
├── TESTING.md              ← this file
│
├── integration/
│   ├── test.sh             ← correctness tests comparing nayr vs yarn
│   └── fixtures/
│       ├── simple/         ← lodash + ms (basic install)
│       ├── scripts/        ← package.json scripts (run, exit codes, args)
│       └── workspace/      ← monorepo with packages/* workspaces
│
├── bench/
│   └── bench.sh            ← performance benchmark
│
└── (unit tests live in src/ as *.zig files, run via `zig build test`)
```

---

## Integration test output

```
Pre-flight checks
  PASS nayr binary exists

Help & version
  PASS help: shows install command
  PASS help: shows run command
  PASS version: prints version string

Error messages
  PASS no package.json: exits 1
  PASS no package.json: mentions package.json in error
  PASS unknown script: exits 1
  PASS unknown script: mentions 'not found'

Script execution
  PASS script greet: exits 0
  PASS script greet: correct output
  PASS script fail: propagates exit code 7
  PASS script args: exits 0
  PASS script args: extra args forwarded
  PASS script: 'nayr greet' == 'nayr run greet'

Install (simple project)
  PASS simple install: exits 0
  PASS simple install: lodash installed
  PASS simple install: ms installed
  PASS simple install: nayr.lock written
  PASS install idempotent: second install exits 0

Results: 19 passed, 0 skipped
```

---

## Benchmark

The bench script measures four scenarios that represent real-world usage:

| Scenario | Description | Target |
|----------|-------------|--------|
| **cold install** | No cache, no lockfile | Baseline |
| **warm install** | Cache populated, no lockfile | Much faster than cold |
| **locked install** | Cache + lockfile, no `node_modules` | CI golden path |
| **no-op install** | Cache + lockfile + `node_modules` already present | < 500 ms |

### Example output

```
nayr benchmark - fixture: simple, 5 runs each

  Scenario              nayr        yarn        Speedup
  --------              ----        ----        -------
  cold install          623ms       795ms       1.3x faster
  warm install          421ms       533ms       1.3x faster
  locked install        434ms       290ms       0.7x faster
  no-op install         2ms         208ms       104.0x faster

  ✔ no-op install under 500ms target
```

> **Note:** actual numbers will vary by machine, network, and fixture size.
> The benchmark uses median of N runs to reduce noise. Use `--runs 5` or
> higher for more stable results. The locked scenario will improve once
> lockfile-as-source-of-truth resolution is implemented.

### Options

```sh
sh tests/bench/bench.sh --runs 5           # more repetitions
sh tests/bench/bench.sh --fixture workspace # test with monorepo
sh tests/bench/bench.sh --no-yarn          # nayr only
sh tests/bench/bench.sh --json             # machine-readable output
```

### Machine-readable output

```sh
sh tests/bench/bench.sh --json --no-yarn
# {"fixture":"simple","runs":3,"nayr":{"cold":3210,"warm":820,"locked":410,"noop":41}}
```

Pipe into `jq` or save for historical comparison:

```sh
sh tests/bench/bench.sh --json --no-yarn | tee bench-$(date +%Y%m%d).json
```

---

## Adding new tests

1. **New integration test**: add an `if should_run "<name>"; then ... fi` block
   to `tests/integration/test.sh`. Use `nayr_run` and `yarn_run` helpers.

2. **New fixture**: create a directory under `tests/integration/fixtures/`
   with a `package.json`.

3. **New unit test**: add test cases to the relevant `.zig` source file
   or create a new `tests/<module>_test.zig` file and reference it in `tests.zig`.
