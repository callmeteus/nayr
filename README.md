# nayr

[![CI](https://github.com/callmeteus/nayr/actions/workflows/ci.yml/badge.svg)](https://github.com/callmeteus/nayr/actions/workflows/ci.yml)

Fast, lock-free Node.js package manager — drop-in replacement for Yarn Classic v1, written in Zig.

```
nayr v2.0.0  fast · lock-free · yarn-compatible
```

## Why nayr?

Yarn Classic is slow and ships a massive JavaScript runtime just to move files around. nayr does the same work in native code:

- **No JS overhead** — compiled Zig binary, starts in milliseconds
- **Lock-free global cache** — concurrent downloads with zero mutex contention
- **Full workspace support** — monorepo hoisting handled correctly
- **Yarn-compatible** — reads `yarn.lock` v1 (migration), writes `nayr.lock`
- **Multi-registry login** — `nayr login` supports multiple registries simultaneously (Yarn Classic doesn't)
- **Configurable Git pinning** — pinned commit hashes for Git dependencies, controllable per-repo or per-org in `.nayrrc`

---

## Benchmarks

> Median of 5 runs on the same machine (Linux, AMD Ryzen 9, NVMe SSD).  
> Run your own: `sh tests/bench/bench.sh --runs 5`

### Simple fixture (`lodash`, `ms`, `is-odd`)

| Scenario | nayr | yarn 1.22 | Speedup |
|---|---|---|---|
| **cold install** (no cache, no lockfile) | 428 ms | 1010 ms | **2.4×** |
| **warm install** (cache hit, no lockfile) | 214 ms | 694 ms | **3.2×** |
| **locked install** (cache + lockfile, fresh `node_modules`) | 212 ms | 442 ms | **2.1×** |
| **no-op** (nothing changed) | **2 ms** | 337 ms | **168×** |

### Workspace fixture (root + 2 packages, 5 deps total)

| Scenario | nayr | yarn 1.22 | Speedup |
|---|---|---|---|
| **cold install** | 415 ms | 984 ms | **2.4×** |
| **warm install** | 213 ms | 642 ms | **3.0×** |
| **locked install** | 217 ms | 402 ms | **1.9×** |
| **no-op** | **2 ms** | 351 ms | **175×** |

The no-op path is the one developers hit on every save/switch. nayr exits in ~2 ms by checking an integrity stamp; yarn spends ~340 ms in Node.js startup before it can even begin.

Resolution is parallelised via a FIFO worker pool: as soon as any package metadata arrives, its transitive deps are pushed to free workers immediately — no waiting for an entire "wave" to finish. Fetching and linking are also fully parallel.

---

## Installation

```sh
# via yarn (ironic, we know)
yarn global add nayr

# via npm
npm install -g nayr
```

Or build from source (requires [Zig 0.14](https://ziglang.org/download/)):

```sh
git clone https://github.com/callmeteus/nayr
cd nayr
zig build -Doptimize=ReleaseFast
./zig-out/bin/nayr --version
```

---

## Usage

nayr is a drop-in replacement — any command you know from Yarn Classic works:

```sh
nayr install              # install all dependencies
nayr add lodash           # add a package
nayr add -D typescript    # add a dev dependency
nayr remove lodash        # remove a package
nayr upgrade lodash       # upgrade to latest matching range
nayr run build            # run package.json script
nayr build                # shorthand — catch-all for scripts
nayr why lodash           # explain why a package is installed
nayr licenses list        # list all package licenses
nayr audit                # security audit
```

### Workspaces

```sh
nayr workspace @app/web build          # run command in a workspace
nayr workspaces info                   # list all workspaces
```

### Linking (development)

```sh
nayr link                  # register the current package globally
nayr link my-package       # link a globally registered package here
nayr unlink my-package     # remove the link
nayr mklink "packages/*"   # register multiple packages via glob
nayr autolink              # auto-link all registered packages
```

### Registry

```sh
nayr login                        # authenticate (supports multiple registries)
nayr logout                       # remove stored credentials
nayr registry sync                # sync private registry scopes to .npmrc
nayr publish                      # publish to registry
nayr pack                         # create tarball without publishing
```

### Cache

```sh
nayr cache list            # list cached packages
nayr cache clean           # clear the global cache
```

---

## Global options

| Flag | Description |
|---|---|
| `--format=tui\|text\|json` | Output format (default: `tui` when TTY) |
| `--verbose` / `-v` | Verbose output |
| `--silent` / `-s` | Suppress all output except errors |
| `--no-color` | Disable ANSI colours |
| `--cwd <path>` | Set working directory |
| `--frozen-lockfile` | Fail if lockfile would change |
| `--production` | Skip devDependencies |
| `--version` | Print version and exit |
| `--help` / `-h` | Print help |

---

## Configuration

nayr reads configuration from (in order of priority):

1. **`.nayrrc`** — nayr-specific settings (JSON)
2. **`.yarnrc`** — Yarn Classic settings (for compatibility)
3. **`.npmrc`** — npm/registry settings

### `.nayrrc` example

```json
{
  "gitPinning": true,
  "gitPinning.disable": ["github.com/my-org/internal-*"],
  "cache": "~/.nayr/cache",
  "registry": "https://registry.npmjs.org"
}
```

**Git hash pinning** (`gitPinning`) is enabled by default — when installing Git dependencies, nayr records the resolved commit SHA as the integrity hash. Disable it entirely, per-repo, or per-org using `gitPinning.disable`.

---

## Development

When iterating on nayr, link the dev binary globally so `nayr` resolves from anywhere:

```sh
# Build (debug)
zig build

# Link into active nvm node bin
source ~/.nvm/nvm.sh && yarn link:dev

# Verify
which nayr        # ~/.nvm/versions/node/vXX/bin/nayr
nayr --version

# Build release and link
source ~/.nvm/nvm.sh && yarn link:dev:release

# Remove link when done
source ~/.nvm/nvm.sh && yarn unlink:dev
```

### Running tests

```sh
# Unit + integration (no yarn comparison)
yarn test

# Integration tests only
yarn test:integration

# Compare output with yarn
yarn test:compare

# Benchmarks (nayr only)
yarn bench

# Benchmarks vs yarn
yarn bench:compare
```

See [`tests/TESTING.md`](tests/TESTING.md) for full test documentation.

---

## License

MIT
