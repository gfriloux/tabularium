# Fleet Status (CLI view) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tabularium status [<host>]` prints the fleet overview (lag, CVEs a deploy / an update would fix) from the exports already in the store, instantly.

**Architecture:** Bash gathers the newest files (records, freshness, one cve export per host) into one JSON document; `src/jq/status.jq` renders it. jq files that share functions live in `src/jq/` (one store path, `TABULARIUM_JQ`), loaded with `jq -L "$TABULARIUM_JQ"`. No `nix`, no network, nothing written.

**Tech Stack:** Bash, jq.

**Spec:** `docs/superpowers/specs/2026-11-08-status-cli-design.md`

## Global Constraints

- Reads only `$TABULARIUM_STORE/<repo>/{deployments,freshness,cve}`; never calls `nix`, `curl` or `vulnxscan`; writes nothing.
- Hosts: union of `deployments/*` directory names and the keys of the newest freshness export's `.predicate.hosts`; sorted like `freshness` (jq `sort`).
- Exit codes: 0 whenever something is shown; 1 when the store has no record and no freshness export, or `<host>` is unknown; 64 usage.
- Dates are UTC as stored: `YYYY-MM-DD`, and `YYYY-MM-DD HH:MM` for `scanned` and `checked`.
- `?` means unknown, `never` means no record / no scan, `-` means not applicable: never `0` for missing data.
- No colour. Docs in fish syntax, terse. Never assign `$out` in a test.

## Review Focus

- A freshness export written by an older tabularium (fields missing, e.g. no `mainCommit`): rows still render with `?`. Test `status_old_freshness` (Task 1).
- A host in freshness but never recorded: row `never` / `-`, no crash. Test `status_never_recorded` (Task 1).
- No local `main` branch: no `main moved` markers, no failure. Test `status_no_main` (Task 1).
- A toplevel name without a date (`/nix/store/…-nixos-system-x`): `nixpkgs` column `?`. Covered by `status_never_scanned` (Task 1).
- Comparison `unavailable` (state skipped/failed): `?`, and the reason in `status <host>`. Tests `status_overview_unavailable` (Task 1), `status_host_unavailable` (Task 2).

---

### Task 1: `tabularium status` (overview)

**Files:**

- Create: `src/jq/status.jq`
- Create: `tests/status.nix`
- Modify: `src/tabularium.sh` (usage, `status`, dispatcher)
- Modify: `flake.nix`, `tests/lib.nix` (`runtimeEnv` `TABULARIUM_JQ = "${./src/jq}"`)
- Modify: `checks/default.nix`

**Interfaces:**

- Consumes: `store`, `latest_record` (existing).
- Produces:
  - `status_input` (bash) → prints `{"main": <sha or null>, "freshness": <export or null>, "hosts": {"<h>": {"record": <record or null>, "cve": <export or null>}}}`. An unreadable file becomes `null` with `tabularium: <file> is unreadable, skipped` on stderr.
  - `src/jq/status.jq`, run as `jq -r -L "$TABULARIUM_JQ" --arg host "<h or empty>" -f "$TABULARIUM_JQ/status.jq" <<<"$(status_input)"`; empty `$host` → overview (this task), else detail (Task 2).

Overview columns (padded like `freshness`'s `table`):

| Column | Value |
|---|---|
| `host` | name |
| `deployed` | record `deployedAt[0:10]`; no record → `never` |
| `nixpkgs` | `YYYY-MM-DD` from the record subject name, regex `\.([0-9]{8})\.[0-9a-f]+$`; no match → `?`; no record → `-` |
| `behind main` | freshness `hosts.<h>.inputs.nixpkgs`: `behind` → `<days> d, <commits> c` (null → `?`), `up-to-date`, `ahead` → `ahead <d> d, <c> c`, other statuses as is; freshness `generatedAt` < record `deployedAt` → `stale`; no freshness or no entry → `?`; no record → `-` |
| `CVE fixed by deploy` | no cve export → `?`; cve `states.deployed.toplevel` ≠ record subject → `stale (redeployed since)`; comparison `unavailable` → `?`; else `<total>` plus `(<n> solid, <n> triage, <n> patch)` listing only non-zero tiers when total > 0; then `[degraded]` and `[+<n> uncertain]` when they apply |
| `by update` | same rules on `comparisons.update` (no stale check); `-` when the deploy column is stale |
| `scanned` | cve `generatedAt` as `YYYY-MM-DD HH:MM`, or `never`; plus `[main moved since scan]` when cve `mainCommit` ≠ `main` (both non-null) |

Footer, one line per freshness input: `<name> (main → upstream): <up-to-date | behind <d> d, <c> c | <status>> (<branch>, checked <generatedAt>)`, plus `[main moved since]` when freshness `mainCommit` ≠ `main`. No freshness: `nixpkgs (main → upstream): ? (no freshness export)`.

Detail after the footer: for each host whose deploy column shows a total > 0, `<h>, fixed by deploy:` then up to 5 lines `<severity>  <id>  <package> <version>` (all tiers merged, severity descending then id), then `… <n> more (tabularium status <h>)` if more.

- [ ] **Step 1: Write the failing tests in `tests/status.nix`**

`mkTest`-based; helpers write fixtures straight into `$TABULARIUM_STORE/nixos/`: `rec <host> <ts> <commit> <subject>`, `fresh <ts> <main> <hosts json> <inputs json>`, `cvex <host> <ts> <main> <deployed toplevel> <deploy comparison json> [<update comparison json>]`. Assertions use `grep -E` with `+` between columns.

| Test | Setup | Assertion (stdout unless said) |
|---|---|---|
| `status_overview` | skitarii record `…-nixos-system-skitarii-26.11.20261020.02c087f`, deployed 2026-11-07; freshness: skitarii behind 15/11301, nixpkgs input up-to-date on nixos-unstable; cve: same subject, main = local main, deploy fixed 5 triage + 1 patch, update fixed 0 | `^skitarii +2026-11-07 +2026-10-20 +15 d, 11301 c +6 \(5 triage, 1 patch\) +0 +2026-11-08 10:27$`; `^nixpkgs \(main → upstream\): up-to-date \(nixos-unstable, checked 2026-11-07 21:52\)$`; `^skitarii, fixed by deploy:$` |
| `status_never_scanned` | clochette record with subject `/nix/store/000…-nixos-system-clochette`, no cve | `^clochette +[0-9-]+ +\? +.* +\? +\? +never$` |
| `status_stale_redeployed` | cve deployed toplevel ≠ record subject | `stale \(redeployed since\)`; no `fixed by deploy:` line for that host |
| `status_main_moved` | cve `mainCommit` = `ffff…` | `\[main moved since scan\]$` |
| `status_freshness_stale` | freshness generatedAt 2026-11-06, record 2026-11-07 | row has ` stale ` in `behind main` |
| `status_detail_cap` | 7 fixed CVEs | 5 detail lines, then `… 2 more (tabularium status skitarii)` |
| `status_unreadable_export` | cve file containing `not json` | stderr `is unreadable, skipped`; row shows `?` and `never` |
| `status_overview_unavailable` | deploy comparison `{"status":"unavailable"}` | deploy column `?` |
| `status_old_freshness` | freshness without `mainCommit` and without `generatedAt` | exit 0, row rendered |
| `status_never_recorded` | freshness host `RogueLeader: {status: "never-recorded"}`, no record | `^RogueLeader +never +- +-` |
| `status_no_main` | repository with only branch `dev` (`git branch -m dev`) | exit 0, no `main moved` |
| `status_empty` / `status_usage` | empty store / `status a b` | exit 1 / 64 |

- [ ] **Step 2: Run them to verify they fail**

Run: `nix build .#checks.x86_64-linux.status_overview -L`
Expected: FAIL, usage (exit 64).

- [ ] **Step 3: Implement**

- `src/jq/status.jq` overview mode; `status_input` and `status` in `src/tabularium.sh` (args: none or one host, else usage); wire `TABULARIUM_JQ` in `flake.nix` and `tests/lib.nix`; import `tests/status.nix` in `checks/default.nix`.

- [ ] **Step 4: Run all checks**

Run: `nix flake check -L`
Expected: all pass.

- [ ] **Step 5: Commit**

```fish
git add src/jq/status.jq src/tabularium.sh flake.nix tests/lib.nix tests/status.nix checks/default.nix
git commit -m "feat: tabularium status, fleet overview from the stored exports"
```

### Task 2: `tabularium status <host>` (detail)

**Files:**

- Create: `src/jq/report.jq`
- Modify: `src/jq/status.jq`, `src/tabularium.sh` (`cve_summary`), `tests/status.nix`

**Interfaces:**

- Consumes: `status_input`, `src/jq/status.jq` (Task 1).
- Produces: detail mode of `status.jq` (`$host` non-empty); `src/jq/report.jq` with `def comparison_lines($states; $comparisons):` (the summary and bumps lines of both comparisons, moved out of `cve_summary`).

Layout:

```text
skitarii
  deployed     2026-11-07 (commit 653ca74, nixpkgs 2026-10-20)
  behind main  15 d, 11301 c
  scanned      2026-11-08 10:27 [main moved since scan]

deployed → main: fixed 6 (solid 0, triage 5, patch 1), new 0, remaining 140, kernel 193 → 193
  fixed, triage:
    8.1  CVE-2026-94300  bind 9.20.29
  fixed, patch:
    3.2  CVE-2025-46394  busybox 1.37.0
bumps deployed → main:
  linux 6.18.57 → 6.18.60
main → update: …
```

- The comparison and bumps lines are exactly `cve`'s: `cve_summary` becomes `jq -r -L "$TABULARIUM_JQ" 'include "report"; .predicate | comparison_lines(.states; .comparisons)'` then the `export:` line; `status.jq` does `include "report";` and calls the same function. `cve`'s output must not change (its tests stay green).
- Under each comparison line, one block per non-empty tier of `fixed` (`fixed, solid:`, `fixed, triage:`, `fixed, patch:`), then `uncertain:` if non-empty; lines as in the overview detail, no cap.
- Unavailable comparison: `deployed → main: unavailable (<state>: <reason>)` as in `cve`.
- No cve export: `no CVE scan (tabularium cve <host>)`. Stale: `CVE scan predates the last deploy (tabularium cve <host>)`.
- [ ] **Step 1: Write the failing tests**

| Test | Setup | Assertion |
|---|---|---|
| `status_host` | as `status_overview`, with bumps linux 6.18.57 → 6.18.60 | `^  deployed +2026-11-07 \(commit 653ca74, nixpkgs 2026-10-20\)$`; `^  fixed, triage:$`; 5 triage lines; `^  linux 6.18.57 → 6.18.60$`; `^main → update:` |
| `status_host_unavailable` | update comparison unavailable, update state skipped `upstream unavailable` | `^main → update: unavailable \(update: upstream unavailable\)$` |
| `status_host_not_scanned` | no cve export | `^no CVE scan \(tabularium cve clochette\)$` |
| `status_host_unknown` | `status nope` | exit 1, stderr `no deployment recorded for nope` |

- [ ] **Step 2: Run them to verify they fail**

Run: `nix build .#checks.x86_64-linux.status_host -L`
Expected: FAIL (detail mode prints nothing).

- [ ] **Step 3: Implement the detail mode**

- [ ] **Step 4: Run all checks**

Run: `nix flake check -L`
Expected: all pass, including every `cve_*` test (unchanged output).

- [ ] **Step 5: Commit**

```fish
git add src/jq/report.jq src/jq/status.jq src/tabularium.sh tests/status.nix
git commit -m "feat: tabularium status <host>, full detail of one host"
```

### Task 3: docs and a real run

**Files:**

- Modify: `CLAUDE.md`, `docs/design.md`
- [ ] **Step 1: Update `CLAUDE.md`** (commands table, "What exists", open items: web view next, then VEX) **and `docs/design.md`** (delivery order: CLI viewer done, web viewer later).
- [ ] **Step 2: Run all checks** — `nix flake check -L`, all pass including the markdown seal.
- [ ] **Step 3: Commit**

```fish
git add CLAUDE.md docs/design.md
git commit -m "docs: tabularium status in CLAUDE.md and design.md"
```

- [ ] **Step 4: Real run from `gfriloux/nixos`**

```fish
cd ~/Apps/github/gfriloux/nixos
nix run ~/Apps/github/gfriloux/tabularium -- status
nix run ~/Apps/github/gfriloux/tabularium -- status skitarii
```

Expected: 4 hosts; skitarii `6 (5 triage, 1 patch)` with `[main moved since scan]` if `main` moved since the last `cve` run; other hosts `?` / `never`; under a second.
