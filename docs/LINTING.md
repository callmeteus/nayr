# Linting and style (nayr)

This project uses the Zig toolchain plus [ZLint](https://github.com/DonIsaac/zlint). There is no mechanical port of `@lemon/linting` (ESLint/TypeScript); the mapping below is **by intent**.

## Commands

| Command | What it does |
|---------|----------------|
| `yarn lint` | Same as `sh scripts/lint.sh` (`zig fmt --check` + ZLint) |
| `zig build lint` | Same shell script from the Zig build graph |
| `yarn lint:fix` | `zig fmt` (writes files) |

Pinned ZLint version: **v0.8.1** (install via `sh scripts/zlint-install.sh`, or set `ZLINT` to a `zlint` binary when running `yarn lint`). Refresh the inventory when upgrading.

## ZLint configuration

Rules live in [zlint.json](../zlint.json). Listing rules there follows ZLint’s model: **only listed rules run**; everything else is off unless you add it.

`suppressed-errors` is **off** on purpose: Zig code often uses `catch {}` for best-effort cleanup (mirrors common std patterns). Revisit if you want stricter error handling.

## Readability (required project convention)

These are **not** enforced by `zig fmt` or ZLint; reviewers and contributors should follow them anyway.

### 1. Prefer small named units over “everything inline”

Pull non-trivial logic into `fn`, `const` helpers, or focused blocks instead of one long inline chain. Same idea as extracting a private helper in TypeScript instead of nesting ten closures in one function.

### 2. Blank line before control-flow blocks

After one or more statements, put a **blank line** before `if`, `for`, `while`, `switch`, and before a top-level `defer` that is not the first item in the scope.

Good:

```zig
const raffle = try loadRaffle(allocator, id);
defer allocator.free(raffle);

if (!raffle.active) {
    return error.Inactive;
}

for (items) |item| {
    try process(item);
}
```

Avoid:

```zig
const raffle = try loadRaffle(allocator, id);
if (!raffle.active) {
    return error.Inactive;
}
```

**Exceptions**

- First statement in a function: no blank line needed before the first `if`/`for`/etc.
- `else if` / `else`: do not add a blank line between them and the previous closing brace (treat as one chain).
- Right after `{` that opens a block: do not insert a blank line before the first nested `for`/`if` just for “air”. Existing `//` comments that belong to the inner statement stay flush (no extra blank between the comment and the code it describes). Do not add blank lines whose only purpose is to separate a comment from the following line.
- Long `else if` chains: `zig fmt` merges a line break between `else` and `if` back into `else if`. To keep the next branch’s `if` on its own line after `else`, wrap branches as `} else {` then `if (cond) { ... }` (nested). Same semantics, formatter-stable.

## Mapping from `@lemon/linting` (TypeScript)

Refresh this table from your clone of `lemon-linting` (see `typescript.config` in that package).

| TypeScript / ESLint idea | Zig equivalent |
|--------------------------|----------------|
| Formatting (Prettier) | `zig fmt` |
| `no-unused-vars`, dead code | ZLint `unused-decls`; compiler for many cases |
| `eqeqeq`, truthy coercion | Not applicable the same way; use explicit Zig conditions |
| `no-floating-promises` | Different async model; review by hand |
| Readability, spacing, “no wall of inline” | This document (sections above) |

Add rows here when you adopt or drop a lemon rule so the Zig side stays traceable.
