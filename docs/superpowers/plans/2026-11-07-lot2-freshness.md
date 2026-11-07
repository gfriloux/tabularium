# Lot 2: Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tabularium freshness` reports, for each root nixpkgs input, how far `main` lags behind upstream and how far each host's deployed commit lags behind `main`, in days + commits, as an in-toto export in the store and a terminal table.

**Architecture:** One more subcommand in `src/tabularium.sh` (Bash, `writeShellApplication`). Revs and dates come from `flake.lock` read with `git show <commit>:flake.lock` (no checkout). Upstream heads, release branches and commit counts come from the GitHub REST API through one helper, `gh_api`, over `curl`. Tests fake `curl` and `nix` the way lot 1 fakes `nix`.

**Tech Stack:** Bash, jq, curl, git, GitHub REST API v3, in-toto Statement v1.

**Spec:** `docs/superpowers/specs/2026-11-07-lot2-freshness-design.md`

## Global Constraints

- nixpkgs only: **root** inputs whose locked source is `type == "github"`, owner `nixos` (case-insensitive), repo `nixpkgs`. Transitive inputs ignored.
- Every lag is **days + commits**, never one or the other.
- Older stable: **releases behind** + days + commits on its own branch.
- Two lags, separately: deployed → `main` (per host), `main` → upstream (per input).
- Never contacts a host. tabularium never commits or pushes.
- Offline: deployed → `main` still reports days and status; commits and `main` → upstream become `unavailable`, never zero.
- `nix flake check` stays offline and cheap: no real network, no real `nix eval` in tests.
- Export: in-toto Statement v1 at `$TABULARIUM_STORE/<repo>/freshness/<YYYYMMDDTHHMMSSZ>.json`, predicate type `https://github.com/gfriloux/tabularium/predicates/freshness/v0.1`.
- Docs in fish syntax, terse (tables, commands). POC first.

## Decisions pinned by this plan

| Item | Value |
|---|---|
| CLI | `tabularium freshness` (no argument; 64 on extra args) |
| `main` | local ref `main`; missing → exit 1, `tabularium: no main branch` |
| Host list | `nix eval --json "git+file://$top?rev=$main_commit#nixosConfigurations" --apply builtins.attrNames` |
| Deployed commit | newest lot 1 record of the host (same rule as `last`) |
| Branch of an input | `.original.ref` in `flake.lock`; absent → branch `null`, upstream `unavailable` |
| Release branch | `^nixos-[0-9]{2}\.[0-9]{2}$`. Current stable = highest such branch upstream. `releasesBehind` = number of upstream release branches above it. `nixos-unstable` and others: `release: null` |
| Upstream head | `GET repos/NixOS/nixpkgs/git/matching-refs/heads/nixos-` → `.object.sha` of `refs/heads/<branch>` (same call lists release branches) |
| Upstream head date | `GET repos/NixOS/nixpkgs/commits/<sha>` → `.commit.committer.date` |
| Commits | `GET repos/NixOS/nixpkgs/compare/<from>...<to>`: `status == "ahead"` → `behind`, commits = `.ahead_by`; `"behind"` → `ahead`, commits = `.behind_by`; `"identical"` → `up-to-date`, 0; `"diverged"` → `diverged`, commits = `.ahead_by` |
| Days | `(to − from) / 86400`, integer, absolute value. `from`/`to` = `lastModified` from `flake.lock`, or the upstream head date |
| Offline / API error | lag status from `lastModified` (equal revs → `up-to-date`, older → `behind`, newer → `ahead`), `commits: null` |
| Auth | `GITHUB_TOKEN` sent as `Authorization: Bearer` when set; optional |
| Lag object | `{"status": …, "days": int\|null, "commits": int\|null}` |
| Lag statuses | `behind`, `up-to-date`, `ahead`, `diverged`, `branch-changed`, `unavailable` |
| Host statuses | `recorded`, `never-recorded` |
| Exit codes | 0 when an export is written (even partial); 1 no `main` / no `flake.lock` on `main`; 64 usage |

`branch-changed` and `diverged` are additions to the spec's status list: they stop a lag from silently mixing two branches (spec anti-goal).

Export shape (values illustrative):

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{ "name": "flake.lock", "digest": { "gitBlob": "<git rev-parse main:flake.lock>" } }],
  "predicateType": "https://github.com/gfriloux/tabularium/predicates/freshness/v0.1",
  "predicate": {
    "repository": "nixos",
    "mainCommit": "<sha>",
    "generatedAt": "2026-11-07T18:30:00Z",
    "inputs": {
      "nixpkgs": {
        "branch": "nixos-unstable", "rev": "<sha>", "lastModified": 1792502884,
        "release": null,
        "upstream": { "rev": "<sha>", "status": "behind", "days": 3, "commits": 142 }
      }
    },
    "hosts": {
      "clochette": {
        "status": "recorded", "deployedCommit": "<sha>", "deployedAt": "…", "dirty": false,
        "inputs": { "nixpkgs": { "rev": "<sha>", "status": "behind", "days": 12, "commits": 410 } }
      },
      "skitarii": { "status": "never-recorded" }
    }
  }
}
```

`release`, when not null: `{"currentStable": "nixos-26.05", "releasesBehind": 1}`.

Terminal table (stdout), then `export: <path>`:

```text
input    branch          release    main→upstream
nixpkgs  nixos-unstable  -          behind 3d 142c

host         input    deployed→main
clochette    nixpkgs  behind 12d 410c
exampleHost  nixpkgs  up-to-date 0d 0c dirty
skitarii     -        never recorded
```

Unknown numbers print `?` (`behind 12d ?c`).

## Review Focus

1. **Input added after a host's deploy**: the deployed `flake.lock` lacks it → that host's lag for it is `unavailable`, the others still computed. Test `freshness_input_missing_in_deployed` (Task 3).
2. **Repository without `main`** (e.g. `master`): exit 1, `no main branch`, no export. Test `freshness_no_main` (Task 1).
3. **API answers some calls and fails others** (rate limit mid-run): each failed lag falls back alone; export still written, exit 0. Test `freshness_partial_api` (Task 1).
4. **Input without `ref`** (`github:nixos/nixpkgs`): branch `null`, upstream `unavailable`, no crash. Test `freshness_no_ref` (Task 1).
5. **Mixed-case host** (`RogueLeader`): record lookup uses exact case. Test `freshness_mixed_case` (Task 3).

---

### Task 1: `freshness` for `main` → upstream, export and table

**Files:**

- Modify: `tests/lib.nix`: `git init -q -b main`; fake `nix` also answers `eval --json <ref>#nixosConfigurations --apply builtins.attrNames` with `["RogueLeader","clochette","exampleHost","skitarii"]`; add fake `curl` (below); add `curl` stand-in to the test package's `runtimeInputs`; add shell helper `lock <name> <rev> <lastModified> [ref]` that writes/merges a root nixpkgs input into `flake.lock` (no `ref` argument → no `.original.ref`).
- Modify: `flake.nix`: add `curl` to `runtimeInputs`.
- Modify: `src/tabularium.sh`
- Create: `tests/freshness.nix`, wired in `checks/default.nix`

**Fake `curl`:** takes the last argument as URL, strips `https://api.github.com/`, prints `$FAKE_GH/<that path>`; file absent or `FAKE_GH` unset → exit 22 (what `curl -f` does on 404).

**Interfaces:**

- Consumes: `store()`, `TABULARIUM_NOW` (lot 1).
- Produces:
  - `gh_api <path>`: JSON on stdout, non-zero on any failure.
  - `lag <from_rev> <from_epoch> <to_rev> <to_epoch>`: prints a lag object; uses `gh_api` for commits, falls back per Decisions.
  - `nixpkgs_inputs <commit>`: prints `name<TAB>rev<TAB>lastModified<TAB>ref` per root nixpkgs input of `<commit>:flake.lock`; empty if the file is missing.
  - `write_new <file>`: stdin → `mktemp` in the same dir → `ln` → exit 3 if `<file>` exists. `record` is refactored to use it (behaviour unchanged).
  - Export with `predicate.inputs` filled, `predicate.hosts` = `{}` (Task 3 fills it).
- [ ] **Step 1: Write the failing tests** in `tests/freshness.nix`. Each commits a `flake.lock` built with `lock`, sets `FAKE_GH=$TMPDIR/gh` and `TABULARIUM_NOW=20261107T183000Z`:
  - `freshness_upstream_behind`: `lock nixpkgs A 1000000 nixos-unstable`; fake refs list `refs/heads/nixos-unstable` → `B`, commit `B` dated `1970-01-15T13:46:40Z` (epoch 1259200, 3 days after 1000000), compare `A...B` = `{"status":"ahead","ahead_by":142,"behind_by":0}`. Export: `.predicate.inputs.nixpkgs.upstream == {"rev":"B","status":"behind","days":3,"commits":142}`, `.release == null`, `.subject[0].digest.gitBlob == $(git rev-parse main:flake.lock)`, `._type` and `.predicateType` as pinned. Stdout contains `nixpkgs  nixos-unstable` and `behind 3d 142c`, last line `export: $TABULARIUM_STORE/nixos/freshness/20261107T183000Z.json`.
  - `freshness_upstream_identical`: upstream head = locked rev → `up-to-date`, 0, 0.
  - `freshness_offline`: `FAKE_GH` unset → upstream `{"rev":null,"status":"unavailable","days":null,"commits":null}`, exit 0, export written.
  - `freshness_partial_api`: refs and commit date present, compare missing → status `behind` (from dates), days 3, commits `null`; stdout `behind 3d ?c`.
  - `freshness_no_ref`: `lock nixpkgs A 1000000` → `.branch == null`, upstream `unavailable`.
  - `freshness_no_main`: `git branch -m main master` → exit 1, stderr `no main branch`, no file under `freshness/`.
  - `freshness_ignores_transitive`: a non-root node `nixpkgs_2` on `nixos/nixpkgs` → absent from `.predicate.inputs`.
- [ ] **Step 2: Run** `nix flake check` → the new checks FAIL (unknown subcommand, exit 64).
- [ ] **Step 3: Implement** `gh_api`, `lag`, `nixpkgs_inputs`, `write_new`, and `freshness` in `src/tabularium.sh`. `cd` to the toplevel first, like `record`. Guard every `gh_api` call (`if json=$(gh_api …)`): `errexit` must never end the run on an API failure.
- [ ] **Step 4: Run** `nix flake check` → all pass, lot 1 tests included.
- [ ] **Step 5: Commit** `feat: tabularium freshness reports how far main lags behind upstream nixpkgs`

### Task 2: Release awareness

**Files:**

- Modify: `src/tabularium.sh`, `tests/freshness.nix`

**Interfaces:**

- Consumes: the matching-refs answer already fetched in Task 1.
- Produces: `.predicate.inputs.<name>.release` = `{"currentStable","releasesBehind"}` or `null`; table column `release` shows `1 behind (nixos-26.05)` or `-`.
- [ ] **Step 1: Write the failing tests:**
  - `freshness_old_stable`: `lock nixpkgs-stable A 1000000 nixos-25.11`; refs list has `nixos-25.05`, `nixos-25.11`, `nixos-26.05`, `nixos-26.05-small`, `nixos-unstable`. Expect `.release == {"currentStable":"nixos-26.05","releasesBehind":1}`, upstream lag computed on `nixos-25.11`'s head (not 26.05's). Stdout contains `1 behind (nixos-26.05)`.
  - `freshness_current_stable`: on `nixos-26.05` → `{"currentStable":"nixos-26.05","releasesBehind":0}`.
- [ ] **Step 2: Run** `nix flake check` → FAIL.
- [ ] **Step 3: Implement** from the refs list per Decisions (sort `YY.MM` lexically; `-small`, `-darwin` excluded by the regex). Refs unavailable → `release: null`.
- [ ] **Step 4: Run** `nix flake check` → pass.
- [ ] **Step 5: Commit** `feat: freshness flags inputs on an older stable release`

### Task 3: Hosts, deployed → `main`

**Files:**

- Modify: `src/tabularium.sh`, `tests/freshness.nix`

**Interfaces:**

- Consumes: `lag`, `nixpkgs_inputs`, lot 1 record layout (`predicate.gitCommit`, `predicate.dirty`, `predicate.deployedAt`); factor the "newest record file" lookup out of `last` as `latest_record <host>` (prints path or nothing) and use it in both.
- Produces: `.predicate.hosts` and the host table.
- [ ] **Step 1: Write the failing tests.** Records are made with the real `tabularium record <host> -- true` at an earlier commit, then `main` moves:
  - `freshness_host_behind`: record clochette at commit with `lock nixpkgs A 1000000 nixos-unstable`, commit `lock nixpkgs B 1259200 nixos-unstable` (3 days later), compare `A...B` ahead_by 410 → `.hosts.clochette == {status:"recorded", deployedCommit:<c1>, dirty:false, deployedAt:…, inputs:{nixpkgs:{rev:"A",status:"behind",days:3,commits:410}}}`; stdout `clochette    nixpkgs  behind 3d 410c`.
  - `freshness_host_up_to_date`: record at `main` → `up-to-date`, 0, 0.
  - `freshness_host_ahead`: record from a branch whose lock is newer than `main`'s → `ahead`.
  - `freshness_never_recorded`: no record for skitarii → `.hosts.skitarii == {"status":"never-recorded"}`; stdout `skitarii     -        never recorded`.
  - `freshness_host_dirty`: record with `--allow-dirty` → `.dirty == true`, stdout row ends in `dirty`.
  - `freshness_branch_changed`: deployed lock on `nixos-25.11`, `main` on `nixos-unstable` → `{"status":"branch-changed","days":null,"commits":null}`, no compare call needed.
  - `freshness_deployed_commit_missing`: rewrite the record's `gitCommit` to an unknown sha → each input `unavailable`.
  - `freshness_input_missing_in_deployed` (Review Focus 1): input `nixpkgs-stable` only on `main` → that host's `nixpkgs-stable` lag `unavailable`, `nixpkgs` lag computed.
  - `freshness_mixed_case` (Review Focus 5): record `RogueLeader` → `.hosts.RogueLeader.status == "recorded"`.
  - `freshness_host_offline`: `freshness_host_behind` without `FAKE_GH` → `behind`, days 3, commits `null`.
- [ ] **Step 2: Run** `nix flake check` → FAIL.
- [ ] **Step 3: Implement** host listing (fake `nix eval`), `latest_record`, per-host per-input `lag` (deployed rev → `main` rev; refs differ → `branch-changed`; `git show <commit>:flake.lock` fails → `unavailable` for all inputs). Cache compare answers per `from...to` pair within a run.
- [ ] **Step 4: Run** `nix flake check` → pass.
- [ ] **Step 5: Commit** `feat: freshness reports how far each host lags behind main`

### Task 4: Docs and real run

**Files:**

- Modify: `CLAUDE.md` ("What exists": `freshness` row, exit codes, `GITHUB_TOKEN`, fake `curl` in Tests), `README.md` (current lot line + one fish example), `docs/design.md` (Delivery order: lot 2 done, link to the spec).
- In `../nixos`: `flake.lock` bump of `tabularium` only after the owner pushed tabularium.
- [ ] **Step 1:** Write the doc changes. `nix flake check` → pass (markdown seal).
- [ ] **Step 2: Commit** `docs: lot 2 freshness in CLAUDE.md, README and design`
- [ ] **Step 3: Owner validation (manual).** The owner pushes tabularium. In `../nixos`: `nix flake update tabularium`, commit `chore(flake): bump tabularium (freshness)` from inside `nix develop` (pre-commit needs `statix`), then the owner runs `tabularium freshness`. Expected: one input (`nixpkgs`, `nixos-unstable`), real day/commit figures, 4 hosts, `skitarii`/`clochette`/`RogueLeader` per their records (some likely `never recorded`), export path printed.
