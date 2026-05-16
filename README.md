# nayr

[![CI](https://github.com/callmeteus/nayr/actions/workflows/ci.yml/badge.svg)](https://github.com/callmeteus/nayr/actions/workflows/ci.yml)

Fast, lock-free Node.js package manager - drop-in replacement for Yarn Classic v1, written in Zig.

```
nayr v2.0.0  fast · lock-free · yarn-compatible
```

## Why nayr?

Yarn Classic is slow and ships a massive JavaScript runtime just to move files around. nayr does the same work in native code:

- **No JS overhead** - compiled Zig binary, starts in milliseconds
- **Lock-free global cache** - concurrent downloads with zero mutex contention
- **Full workspace support** - monorepo hoisting handled correctly
- **Yarn-compatible** - reads `yarn.lock` v1 (migration), writes `nayr.lock`
- **Multi-registry login** - `nayr login` supports multiple registries simultaneously (Yarn Classic doesn't)
- **Configurable Git pinning** - pinned commit hashes for Git dependencies, controllable per-repo or per-org in `.nayrrc`

---

## Benchmarks

> Same methodology as [pnpm.io/benchmarks](https://pnpm.io/benchmarks).
> Machine: Ubuntu 24.04 LTS, Intel i7-13650HX (20 threads), NVMe SSD.
> Run your own: `bash tests/bench/bench.sh --runs 3 [--fixture simple|workspace|alotta-files]`

### Simple fixture (`lodash`, `ms`, `is-odd`) - median of 3 runs

| action  | cache | lockfile | node_modules | nayr | pnpm 10 | yarn 1.22 |
|---------|-------|----------|--------------|------|---------|-----------|
| install |       |          |              | 502 ms | 1064 ms | 1281 ms |
| install | ✔    | ✔       | ✔           | **3 ms** | 348 ms | 318 ms |
| install | ✔    | ✔       |              | 222 ms | 408 ms | 429 ms |
| install | ✔    |          |              | 231 ms | 562 ms | 690 ms |
| install | ✔    |          | ✔           | 240 ms | 391 ms | 845 ms |
| install |       | ✔       | ✔           | **4 ms** | 638 ms | 654 ms |
| install |       |          | ✔           | 445 ms | 933 ms | 1191 ms |
| install |       | ✔       |              | 418 ms | 904 ms | 1042 ms |
| update  | n/a   | n/a      | n/a          | 443 ms | 845 ms | 1056 ms |

### alotta-files fixture (~100 deps, same as pnpm's own benchmark) - median of 2 runs

> Cache-dependent scenarios (clean, nm, lf) are network-bound and vary by connection.

| action  | cache | lockfile | node_modules | nayr | pnpm 10 |
|---------|-------|----------|--------------|------|---------|
| install |       |          |              | ~14.6s | ~20s |
| install | ✔    | ✔       | ✔           | **3 ms** | 496 ms |
| install | ✔    | ✔       |              | 7.8s | 1.4s |
| install | ✔    |          |              | 8.5s | 11.2s |
| install | ✔    |          | ✔           | 8.4s | 2.1s |
| install |       | ✔       | ✔           | **4 ms** | 911 ms |
| install |       |          | ✔           | ~16s | ~11.5s |
| install |       | ✔       |              | ~16.7s | ~5s |
| update  | n/a   | n/a      | n/a          | 18.3s | 3.9s |

The no-op and `lockfile + node_modules` rows (the scenarios developers and CI hit the most) show the biggest gap: nayr exits in **3-4 ms** by checking an integrity stamp; pnpm costs 350-900 ms and yarn 315-650 ms of startup overhead before they even begin.

Where nayr loses ground vs pnpm on the large fixture is `c_lf` (cache + lockfile, fresh install) and `update` - this is the linking phase and hoisting algorithm, which are still being optimised.

Resolution is parallelised via a FIFO worker pool: as soon as any package metadata arrives, its transitive deps are pushed to free workers immediately - no waiting for an entire "wave" to finish. Fetching and linking are also fully parallel.

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

### Linting

```sh
yarn lint       # zig fmt --check + ZLint (see docs/LINTING.md)
yarn lint:fix   # apply zig fmt only
```

Project-specific Zig readability rules (blank line before `if`/`for`/etc., avoid huge inline blocks) are documented in [docs/LINTING.md](docs/LINTING.md). They are not auto-enforced; follow them in review.

---

## Usage

nayr is a drop-in replacement - any command you know from Yarn Classic works:

```sh
nayr install              # install all dependencies
nayr add lodash           # add a package
nayr add -D typescript    # add a dev dependency
nayr remove lodash        # remove a package
nayr upgrade lodash       # upgrade to latest matching range
nayr run build            # run package.json script
nayr build                # shorthand - catch-all for scripts
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
nayr link my-package       # use a globally registered package here
nayr unlink                # unregister the current package
nayr unlink my-package     # remove a specific registration
nayr autolink              # auto-link all registered packages
```

### Global packages

```sh
nayr global add typescript        # install a package globally
nayr global add typescript@5      # install a specific version
nayr add --global typescript      # same, using the --global / -G flag
nayr add -G typescript            # shorthand

nayr global remove typescript     # remove a global package
nayr remove -G typescript         # same via flag

nayr global list                  # list installed global packages
nayr global upgrade               # upgrade all global packages to latest
nayr global bin                   # print the global binary directory (~/.nayr/bin)
nayr global dir                   # print the global package directory (~/.nayr/global)
```

Binaries are symlinked into `~/.nayr/bin/`. Add it to PATH once:

```sh
export PATH="$HOME/.nayr/bin:$PATH"   # add to ~/.bashrc or ~/.zshrc
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

1. **`.nayrrc`** - nayr-specific settings (JSON)
2. **`.yarnrc`** - Yarn Classic settings (for compatibility)
3. **`.npmrc`** - npm/registry settings

### `.nayrrc` example

```json
{
  "gitPinning": true,
  "gitPinning.disable": ["github.com/my-org/internal-*"],
  "cache": "~/.nayr/cache",
  "registry": "https://registry.npmjs.org"
}
```

**Git hash pinning** (`gitPinning`) is enabled by default - when installing Git dependencies, nayr records the resolved commit SHA as the integrity hash. Disable it entirely, per-repo, or per-org using `gitPinning.disable`.

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
