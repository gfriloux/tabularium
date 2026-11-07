# Lot 2: Freshness — design

Status: draft, 2026-11-07. Parent: `docs/design.md` (delivery order, lot 2).

## Intent

The owner updates the fleet every few weeks without knowing what is being
caught up, or when a well-known CVE makes the news. tabularium's goal is to
decide updates from facts: how far each host lags, and (later lots) which
vulnerabilities touch it. No production scanning, no login to hosts.

Lot 2 is the first half: **lag**. It is the first column of a report that
lots 3–4 (SBOM, CVE) will extend, so its output must leave room for them.

## Goals

1. For each host, two lags of its nixpkgs, each in **days + commits**:

   | Lag | Question it answers | From → to |
   |---|---|---|
   | deployed → `main` | "did I forget to deploy this host?" | nixpkgs rev in the `flake.lock` of the host's deployed commit (lot 1 record) → nixpkgs rev in `main`'s `flake.lock` |
   | `main` → upstream | "did I forget `nix flake update`?" | nixpkgs rev in `main`'s `flake.lock` → current head of the upstream branch the input follows |

   Reading them together: `main` fresh but host behind = forgotten host;
   `main` behind = inputs not updated, every host behind with it.

2. **Release awareness** for nixpkgs, from the branch in the input's URL:

   | Branch followed | Shown |
   |---|---|
   | `nixos-unstable` | days + commits |
   | current stable (e.g. `nixos-26.05` today) | days + commits |
   | older stable (e.g. `nixos-25.11` today) | **N releases behind** + days + commits on that branch |

   Always days **and** commits, never one or the other (owner).

3. **Output:**
   - an in-toto Statement v1 JSON file, the export a future web viewer will
     ingest (sent by hand or by CI);
   - a readable table on the terminal, usable now.

## Non-goals

- Inputs other than nixpkgs (home-manager, stc, snowfall-lib…): wanted,
  but later (owner). Parked in `CLAUDE.md` "Polish, later".
- CVEs, SBOMs: lots 3–4.
- The web viewer: lot 6, separate design.
- Any host-side check.

## Anti-goals

- Logging into a host, or anything running on the hosts.
- Persisting state that can be recomputed: the export is a dated snapshot,
  not a database to keep in sync.
- A lag figure that silently mixes up branches (e.g. counting commits of
  `nixos-25.11` against `nixos-unstable`).

## Constraints

- From `docs/design.md` and `CLAUDE.md`: fish syntax in docs, POC first,
  one change at a time, tabularium never commits/pushes, nothing on hosts,
  `nix flake check` stays cheap (no network, no system builds in checks).
- The store is local and uncommitted: CI can compute `main` → upstream, but
  not deployed → `main` (needs lot 1 records). A full export runs on
  exampleHost.
- The upstream head is read online at analysis time. Offline: deployed →
  `main` still works, `main` → upstream is reported as unavailable, not as
  zero.

## Decided (owner)

| Topic | Decision |
|---|---|
| Lag unit | days + commits, always |
| Older stable | releases behind + days + commits on its own branch |
| Lags shown | both, separately (deployed → `main`, `main` → upstream) |
| Scope | nixpkgs only |
| Final consumer | a web app ingesting exports (by hand, CI…) |
| Output | JSON in-toto statement in the store + terminal table ("ça me va pour le moment") |

## Builder's calls (proposed in conversation, not objected to)

| Topic | Call |
|---|---|
| CLI | `tabularium freshness`, run from the consumer repo like `record` / `last` |
| Export path | `$TABULARIUM_STORE/<repo>/freshness/<YYYYMMDDTHHMMSSZ>.json` |
| Envelope | in-toto Statement v1, subject = `main`'s `flake.lock` (git blob sha1 as digest), predicate type `https://github.com/gfriloux/tabularium/predicates/freshness/v0.1` |
| `main` | the consumer's local `main` ref (not `origin/main`), so it works offline; the export records which commit it was |
| Which nixpkgs | **root** inputs whose locked source is `github:nixos/nixpkgs`, keyed by root input name. Today: only `nixpkgs` (`nixos-unstable`). `nixpkgs-stable` (`nixos-25.11`) is an input of `stc` used by an ansible devShell, not by the hosts; `nixpkgs_2` is noosphere's. Both ignored. The older-stable case is tested with fixtures only |
| Host list | `nix eval` of `nixosConfigurations` attribute names at `main` (one cheap eval, same fake `nix` in tests). A host with no lot 1 record shows `never recorded`. Store directories are not used: they cannot show a never-deployed host |
| Dirty record | used as is, flagged `dirty` in the export and the table (the record already carries it) |
| Deployed commit missing from the clone | status `unavailable` for deployed → `main`, not a failure |
| Deployed ahead of `main` | status `ahead` (deployed from an unmerged branch, as nixos did during lot 1); days + commits stay positive, direction is in the status. Statuses: `behind`, `up-to-date`, `ahead`, `unavailable`, `never recorded` |

## Left to the builder

- **Days.** Suggested: upstream-side commit date minus locked-side commit
  date, using `lastModified` from `flake.lock` where available.
- **Commits.** Suggested: GitHub compare API (`behind_by`), unauthenticated
  (60 req/h is enough for ~3 inputs × 5 comparisons). A local nixpkgs clone
  is the alternative; avoid if heavier.
- **Current stable.** Suggested: highest `nixos-YY.MM` branch on upstream
  (`git ls-remote`), excluding `-small` and `-darwin`. "Releases behind" =
  number of newer release branches.
- **Host with no record.** Shown as "never recorded", not as an error.
- **Exact JSON field names**, terminal layout, exit codes for new failures,
  test strategy (fake network, as the fake `nix` in lot 1).
- Bash vs Rust: lot 1 is Bash; staying in Bash for this lot is acceptable
  if it stays small.
