# Lot 1: Deployment Record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `tabularium record` command wraps any deploy command. It refuses a dirty tree, and on success writes an in-toto statement (host, commit, store path, date) into the uncommitted `.tabularium` store. A `tabularium last` command reads back the latest record for a host.

**Architecture:** A single Bash program packaged with `writeShellApplication` (runtime deps: git, jq, nix, coreutils) and exposed as a flake package. It wraps the deploy command instead of calling deploy-rs itself. The same recipe therefore works with today's `nixos-rebuild` / `nh` recipes and with deploy-rs once gfriloux/nixos#89 lands, so lot 1 is not blocked on #89 (planner's call, see "Deviations"). Tests are Nix checks that run the program against a throw-away git repository, with a fake `nix` on `PATH`.

**Tech Stack:** Nix flake (plain, no flake-parts), Bash via `writeShellApplication`, jq, in-toto Statement v1, STC purity seals.

**Spec:** `docs/design.md` (this repository)

## Global Constraints

- tabularium never commits, tags or pushes in the consumer repository.
- `.tabularium` is never committed; default location `$HOME/.tabularium`, overridable with `TABULARIUM_STORE`.
- Deploying from a dirty tree is refused; the explicit escape hatch marks the record `dirty`.
- Hosts hold no credentials; everything runs on the deploying machine (exampleHost).
- Tracked hosts: clochette, RogueLeader, skitarii, exampleHost. Host names keep their case (`RogueLeader`).
- Record format: in-toto Statement v1 (`"_type": "https://in-toto.io/Statement/v1"`).
- `nix flake check` must stay cheap: no system builds in checks.
- Docs and examples use fish syntax. Lint: STC purity seals (`nix`, `gitleaks`, `markdown` with `-d MD013,MD033`), as in `gfriloux/nixos`.

## Decisions pinned by this plan

| Item | Value |
|---|---|
| CLI | `tabularium record <host> [--allow-dirty] -- <command…>` and `tabularium last <host>` |
| Store layout | `$TABULARIUM_STORE/<repo>/deployments/<host>/<YYYYMMDDTHHMMSSZ>.json`, `<repo>` = basename of `git rev-parse --show-toplevel` |
| Dirty definition | `git diff --quiet HEAD` fails (tracked changes, staged or not). Untracked files do **not** count: flakes ignore them |
| Store path | `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.outPath`, run after the wrapped command succeeds |
| Subject digest | `sha256` = hex of the NAR hash from `nix path-info --json <path>` (SRI `sha256-…` base64 → hex) |
| Predicate type | `https://github.com/gfriloux/tabularium/predicates/deployment/v0.1` |
| Exit codes | wrapped command's code if it fails; `2` = dirty tree; `3` = record already exists; `64` = usage error |

Record shape (values illustrative):

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    { "name": "/nix/store/abc…-nixos-system-clochette-26.05", "digest": { "sha256": "9f2c…" } }
  ],
  "predicateType": "https://github.com/gfriloux/tabularium/predicates/deployment/v0.1",
  "predicate": {
    "host": "clochette",
    "repository": "nixos",
    "gitCommit": "c45db15…",
    "dirty": false,
    "deployedAt": "2026-11-07T18:30:00Z",
    "command": ["nixos-rebuild", "switch", "--flake", ".#clochette"]
  }
}
```

## Review Focus

1. **Interactive wrapped command** (sudo password prompt from `--ask-sudo-password` or deploy-rs `interactiveSudo`): stdin/stdout/stderr must stay attached to the terminal. The command runs directly, never in a pipe or `$( )`. Test: `record_keeps_stdin` in Task 2.
2. **Run from a subdirectory of the repository**: same commit, same store path. Test: `record_from_subdir` in Task 2.
3. **Two records in the same second for one host**: second write refused with exit 3, first record intact. Test: `record_no_clobber` in Task 2.
4. **Mixed-case host** (`RogueLeader`): directory and `last` lookup use the exact case. Test: `last_mixed_case` in Task 3.
5. **Untracked file present** (e.g. a scratch note): not dirty, record written. Test: `record_untracked_ok` in Task 2.

---

### Task 1: Flake skeleton, package and lint seals

**Files:**

- Create: `flake.nix`, `.gitignore` (`result`, `.tabularium/`), `README.md` (5–10 lines: what it is, link to `docs/design.md`)
- Create: `checks/default.nix` (imports the seals and, from Task 2 on, the tests)
- Create: `src/tabularium.sh` (usage text only for now)

**Interfaces:**

- Produces: `packages.x86_64-linux.tabularium` (and `default`), binary `tabularium`; `checks.x86_64-linux.{nix,gitleaks,markdown}`; `formatter.x86_64-linux` = alejandra.
- Inputs: `nixpkgs` (`github:nixos/nixpkgs/nixos-unstable`), `stc` (`github:gfriloux/stc`, `inputs.nixpkgs.follows = "nixpkgs"`).
- [ ] **Step 1:** Write `flake.nix`. The package is `pkgs.writeShellApplication { name = "tabularium"; runtimeInputs = [git jq nix coreutils]; text = builtins.readFile ./src/tabularium.sh; }`. Seals: `stc.lib.puritySeals.${system}.nix ./.`, `.gitleaks ./.`, `.markdown { path = ./.; args = "-d MD013,MD033"; }`.
- [ ] **Step 2:** `src/tabularium.sh` prints usage on no argument or unknown subcommand and exits 64.
- [ ] **Step 3: Verify**
  Run: `nix run . -- ; echo $status` → usage text, then `64`.
  Run: `nix flake check` → all seals pass.
- [ ] **Step 4: Commit** `chore: flake skeleton with tabularium package and purity seals`

### Task 2: `tabularium record`

**Files:**

- Modify: `src/tabularium.sh`
- Create: `tests/record.nix` (one derivation per test, wired from `checks/default.nix`)
- Create: `tests/lib.nix`: a `mkTest name script` helper that builds a `runCommand` with git, jq, the package, and a fake `nix` script on `PATH`. The fake answers `eval --raw …outPath` with `/nix/store/00000000000000000000000000000000-nixos-system-<host>` and `path-info --json <p>` with `{"<p>":{"narHash":"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}}`. Each test starts with `git init`, a committed `flake.nix`, `git config user.email/name`.

**Interfaces:**

- Consumes: package from Task 1.
- Produces: `tabularium record <host> [--allow-dirty] -- <cmd…>`; record files as pinned above. Task 3 relies on the store layout and the `predicate.gitCommit` field.
- [ ] **Step 1: Write the failing tests** in `tests/record.nix`, each with `TABULARIUM_STORE=$TMPDIR/store`:
  - `record_clean_success`: `tabularium record clochette -- true` exits 0. Exactly one file under `$TABULARIUM_STORE/<repo>/deployments/clochette/`. `jq` asserts `._type == "https://in-toto.io/Statement/v1"`, `.predicate.host == "clochette"`, `.predicate.gitCommit == $(git rev-parse HEAD)`, `.predicate.dirty == false`, `.predicate.command == ["true"]`, `.subject[0].name` equals the fake path, `.subject[0].digest.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`.
  - `record_dirty_refused`: modify a tracked file. Exit code 2, stderr contains `dirty`, no file in the store, and the wrapped command did not run (it would `touch $TMPDIR/ran`; assert absent).
  - `record_dirty_allowed`: same with `--allow-dirty`. Exit 0, `.predicate.dirty == true`.
  - `record_command_fails`: `tabularium record clochette -- sh -c 'exit 7'`. Exit code 7, no file in the store.
  - `record_untracked_ok`: an untracked file exists. Exit 0, record written, `dirty == false`.
  - `record_from_subdir`: run from `mkdir sub; cd sub`. Same `gitCommit`, `<repo>` is the top-level basename.
  - `record_no_clobber`: pre-create the record file for a frozen timestamp (`TABULARIUM_NOW=20261107T183000Z` env override used by tests only). Exit 3, pre-existing file unchanged.
  - `record_keeps_stdin`: `echo secret | tabularium record clochette -- sh -c 'read x; test "$x" = secret'` exits 0.
  - `record_usage`: missing `--` or missing host → exit 64.
- [ ] **Step 2: Run** `nix flake check` → the new checks FAIL (subcommand not implemented).
- [ ] **Step 3: Implement `record` in `src/tabularium.sh`.** Order: parse args → `cd "$(git rev-parse --show-toplevel)"` → dirty check (unless `--allow-dirty`) → capture `HEAD` → run `"$@"` directly (no pipe, no subshell capture) and keep its exit code → on failure exit with it → `nix eval` the out path → `nix path-info --json` → convert the SRI hash (`base64 -d | od -An -tx1 | tr -d ' \n'`) → build the JSON with `jq -n` → write with `set -o noclobber` to `<store>/<repo>/deployments/<host>/<ts>.json` (`mkdir -p` first). Timestamp: `date -u +%Y%m%dT%H%M%SZ` unless `TABULARIUM_NOW` is set. `deployedAt` is the ISO form of the same instant.
- [ ] **Step 4: Run** `nix flake check` → all pass.
- [ ] **Step 5: Commit** `feat: tabularium record wraps a deploy command and writes an in-toto deployment record`

### Task 3: `tabularium last`

**Files:**

- Modify: `src/tabularium.sh`
- Create: `tests/last.nix`

**Interfaces:**

- Consumes: store layout and record shape from Task 2.
- Produces: `tabularium last <host>`. Prints `<gitCommit> <deployedAt>` and the `dirty` marker if true, exit 0. Exit 1 with `no deployment recorded for <host>` on stderr if none. This is the read API lot 2 builds on.
- [ ] **Step 1: Write the failing tests:**
  - `last_latest`: two records at `TABULARIUM_NOW=20261107T100000Z` and `20261107T120000Z` with different commits. Output starts with the second commit.
  - `last_none`: exit 1, stderr `no deployment recorded for skitarii`.
  - `last_mixed_case`: record `RogueLeader`, then `tabularium last RogueLeader` succeeds and `tabularium last rogueleader` exits 1.
  - `last_dirty_marker`: a record made with `--allow-dirty` prints a line ending in `dirty`.
- [ ] **Step 2: Run** `nix flake check` → FAIL.
- [ ] **Step 3: Implement `last`.** Pick the newest file by name (timestamps sort lexically), read it with `jq`.
- [ ] **Step 4: Run** `nix flake check` → all pass.
- [ ] **Step 5: Commit** `feat: tabularium last reads the latest deployment record of a host`

### Task 4: Wire into `gfriloux/nixos`

**Files (in `../nixos`):**

- **Prerequisite:** the owner has published tabularium as `github:gfriloux/tabularium`. A `git+file://` input would break `check.yml`, which runs `nix flake check` on GitHub runners.
- Modify: `flake.nix` (add input `tabularium.url = "github:gfriloux/tabularium"`, `inputs.nixpkgs.follows = "nixpkgs"`)
- Modify: `shells/default/default.nix` (add `inputs.tabularium.packages.${system}.tabularium` to the devShell)
- Modify: `Justfile`: `install`, `install_clochette`, `install_rogueleader`, `install_skitarii` become `tabularium record <Host> -- <current command>`. Same commands as today; only the prefix is added.
- Modify: `docs/src/content/docs/operations/deployment.md` and its `fr/` twin: one short "Deployment record" section (what `.tabularium` holds, `tabularium last <host>`, `--allow-dirty`). Terse, a table and commands.

**Interfaces:**

- Consumes: `tabularium record`, `tabularium last`.
- [ ] **Step 1:** Make the edits. The `install` recipe keeps its `rm -f …gtkrc…` line before the wrapped `nh os switch .`.
- [ ] **Step 2: Verify**
  Run: `nix flake check` → passes (seals unchanged).
  Run: `just --dry-run install_skitarii` → shows `tabularium record skitarii -- nixos-rebuild switch …`.
- [ ] **Step 3: Owner validation (manual).** The owner runs `just install`, then `tabularium last exampleHost`. Expected: current commit, no `dirty`. Then one server deploy of their choice.
- [ ] **Step 4: Commit** (in `nixos`) `feat(deploy): record deployments with tabularium`. The owner pushes.

## Deviations from the design

- **Lot 1 is not blocked on #89.** The design says lot 1 depends on deploy-rs. Wrapping the deploy command keeps tabularium tool-agnostic, so it works today with `nixos-rebuild` / `nh`. When #89 lands, only the wrapped command in the Justfile changes. Planner's call; revert to "wait for #89" if the owner prefers.
- **Bash, not Rust, for lot 1.** The design leaves Nix vs Rust open. Lot 1 is git + jq glue; Rust can come with the analysers (lot 2+). Planner's call.
