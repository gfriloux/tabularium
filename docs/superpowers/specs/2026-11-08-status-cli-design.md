# Fleet status (CLI view) — design

Status: draft, 2026-11-08. Parent: `docs/design.md` (viewer, after lot 4).

## Intent

Before an update window, the owner wants one screen that answers:

1. which hosts are behind;
2. which CVEs an update (deploy, then `nix flake update`) would fix.

Lots 2 and 4 already compute this, but per command and per host, and they
take minutes. The view **reads the exports already in the store**. It
recomputes nothing and answers instantly.

Two views are wanted (owner): a CLI view now, a web view later.

## Goals

1. `tabularium status`: one overview of the fleet, from the latest
   exports.

   ```text
   host         deployed    nixpkgs     behind main      CVE fixed by deploy      by update     scanned
   exampleHost  2026-11-07  2026-11-05  up-to-date       -                        -             never
   RogueLeader  2026-11-07  2026-10-20  15 d, 11301 c    ?                        ?             never
   skitarii     2026-11-07  2026-10-20  15 d, 11301 c    6 (5 triage, 1 patch)    0             2026-11-08 10:50 [main moved since scan]

   nixpkgs (main → upstream): up-to-date (nixos-unstable, checked 2026-11-07 18:30)

   skitarii, fixed by deploy:
     8.1  CVE-2026-94300  bind 9.20.29
     …
   ```

   The owner accepted this first draft ("ça me va pour le moment"); the
   `nixpkgs` column and the `main moved` marker were added after the
   builder check, on the owner's go.

2. `tabularium status <host>`: the same data for one host, in full: every
   fixed CVE in both comparisons, by tier, and the bumps of important
   packages.

## Non-goals

- The web view: later, separate design (owner).
- Running scans, builds, network calls or `nix` evaluations.
- VEX and triage.
- Writing anything.

## Anti-goals

- Showing old data as current. Every figure carries its date, and data that
  no longer describes the host is marked as such.
- Filling a gap with a guess. A host with no `cve` export shows `?` and
  `never`, not `0`.

## Sources (all in `$TABULARIUM_STORE/<repo>/`)

| Data | File | Lot |
|---|---|---|
| Hosts, deployed commit and date | newest `deployments/<host>/*.json` | 1 |
| Lag deployed → `main`, `main` → upstream | newest `freshness/*.json` | 2 |
| CVEs fixed / new, bumps | newest `cve/<host>/*.json` | 4 |

## Decided (owner)

| Topic | Decision |
|---|---|
| What comes first | hosts behind, and CVEs an update fixes |
| Views | CLI now, web later |
| Layout | the overview above, as a first draft |
| Dates | two columns: `deployed` = `deployedAt` of the newest record; `nixpkgs` = date of the nixpkgs that runs, read from the record subject's name (`nixos-system-<host>-<release>.<YYYYMMDD>.<rev>`), `?` if it does not parse. No `nix` call |
| `main` moved since the CVE scan | export `mainCommit` ≠ local `main` → marker `[main moved since scan]` on the row; figures kept (a new commit does not always change the toplevel, and the view cannot check without `nix`) |

## Builder's calls (made while writing, not discussed)

| Topic | Call |
|---|---|
| Command | `tabularium status [<host>]`, run from the consumer repo like the other commands |
| Host list | union of hosts with a record and hosts in the newest freshness export. No `nix eval`: the view must stay instant |
| Overview "by update" | total of `comparisons.update.fixed` only (`main` → update, on top of the deploy) |
| Comparison skipped, failed or unavailable | `?` plus the reason in `status <host>` |
| Host `never-recorded` in freshness | a row with `never` in `deployed` and `-` elsewhere |
| Overview "fixed by deploy" | total of `comparisons.deploy.fixed` (solid + triage + patch), with the tier split; `uncertain` and `degraded` shown as a marker |
| Overview detail | after the table, the fixed-by-deploy list for each host that has one, sorted by severity, at most 5 per host, then `… N more (tabularium status <host>)` |
| Stale CVE export | the `deployed` toplevel of the cve export ≠ the `subject` of the newest record → the host shows `stale (redeployed since)` instead of figures |
| Stale lag | freshness export older than the host's newest record → the lag shows `stale`; freshness `mainCommit` ≠ local `main` → the footer says `main moved since` |
| Unreadable export | skipped with a warning on stderr; the rest is shown |
| Exit codes | 0 whenever something is shown; 1 when the store has no record at all; 64 usage |
| Colour | none (POC); the layout must stay readable when piped |

## Left to the builder

- Exact column widths and wording, within the overview above.
- Bash + jq, like the rest; one jq program per view is fine.
- Tests: fixture exports written in `$TABULARIUM_STORE` by the test (no
  fake `nix` needed), as in lots 1–4.
