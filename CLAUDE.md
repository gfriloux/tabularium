# tabularium — Context

Health records of a NixOS fleet ("its smell"), derived from the repository and a
local, uncommitted store. Read `docs/design.md` first: it is the intent, and it
is expected to move as iterative development teaches us things. Update it
rather than forcing the code to fit.

## What exists (lots 1 to 4, 2026-11-08)

`src/tabularium.sh`, packaged with `writeShellApplication` (runtime: git, jq,
nix, coreutils, grep, sed, curl; nix is pinned by this flake, not the system's). bombon is an input
of this flake; `src/sbom.nix`, `src/important.nix` and `src/cve.jq` reach the script through
`runtimeEnv`. Lot 4 adds miller (`mlr`, CSV → JSON) and vulnxscan (`tiiuae/sbomnix`
input).

| Command | Effect |
|---|---|
| `tabularium record <host> [--allow-dirty] -- <cmd…>` | Refuses a dirty tree (exit 2), runs `<cmd>` with the terminal attached, and on success writes an in-toto Statement v1 to `$TABULARIUM_STORE/<repo>/deployments/<host>/<YYYYMMDDTHHMMSSZ>.json` |
| `tabularium last <host>` | `<commit> <deployedAt> [dirty]` of the newest record, exit 1 if none or unreadable |
| `tabularium freshness` | No argument (64 otherwise). Prints an input table (root nixpkgs inputs of `flake.lock` on `main`: lag vs upstream, days + commits), a host table (per host: nixpkgs pinned by its last deployed commit vs `main`'s, days + commits) and `export: <path>` |
| `tabularium cve <host> [--no-build] [--osv]` | Scans 3 states with vulnxscan (OSV off unless `--osv`: it would send each host's component list to api.osv.dev): `deployed` (record subject), `main`, `update` (`main` + root `nixpkgs` at upstream head). Prints `deployed → main` and `main → update`: CVEs fixed (solid/triage/patch), new, remaining, kernel apart, bumps of important packages; `export: <path>` |
| `tabularium sbom <host> [--build]` | bombon CycloneDX SBOM of the toplevel of the newest record, at its commit. Prints `components`/`purl`/`cpe`/`licenses` counts and `export: <path>` |

- Store: `${TABULARIUM_STORE:-$HOME/.tabularium}`, never committed.
- Exit codes: wrapped command's code on failure, 2 dirty, 3 record exists, 4 tree changed during the deploy (not recorded), 5 `sbom`: evaluated toplevel ≠ record subject, 6 `sbom`: toplevel not in the local store (rerun with `--build`), 64 usage. `cve`: 1 no record / no `main` / no `flake.lock` on `main`, else 0 whenever an export is written (states may be `skipped`/`failed`).
- Out path is evaluated **before** the deploy (unknown host fails early); HEAD + `git diff HEAD` are re-checked after it.
- Record written to `.new.XXXXXX` then hard-linked (shared `write_new`): never partial, never overwritten (race → exit 3).
- `freshness`: exit 1 if no `main` branch or no `flake.lock` on `main`; exit 0 whenever an export is written, even partial.
- `freshness` export: `$TABULARIUM_STORE/<repo>/freshness/<YYYYMMDDTHHMMSSZ>.json`, predicate type `https://github.com/gfriloux/tabularium/predicates/freshness/v0.1`.
- `freshness` scope: root nixpkgs inputs only; lags in days + commits. `GITHUB_TOKEN` optional (unauthenticated GitHub API: 60 req/h). Offline: commits `?`/null, upstream `unavailable`.
- `sbom` export: `$TABULARIUM_STORE/<repo>/sbom/<host>/<commit>.cdx.json`, a cache keyed by commit: reused as is, delete it to recompute (bombon upgrade). Refuses a dirty record (exit 2) and a commit missing from the clone (exit 1). No GC root: run it soon after deploying.
- `cve` export: `$TABULARIUM_STORE/<repo>/cve/<host>/<YYYYMMDDTHHMMSSZ>.json`, predicate type `https://github.com/gfriloux/tabularium/predicates/cve/v0.1`. Tiers: solid = ≥ 2 sources, triage = 1, patch = named by a nixpkgs patch file (vulnxscan log). A comparison is `degraded` when a source is missing on one side (WARNING lines of vulnxscan's log) or warnings exist. Realises states by default (prints `<state>: N derivations to build`); `--no-build` marks states needing a local build `skipped`.
- Important packages (`src/important.nix`): `environment.systemPackages`, home-manager `home.packages`, `.package` of enabled `services`/`programs`/`virtualisation`, the kernel.
- Dirty = `git diff --quiet HEAD` fails. Untracked files do not count (flakes ignore them).
- Subject = toplevel store path, digest `sha256` = NAR hash in hex (`nix path-info --json --json-format 2`).
- Predicate type: `https://github.com/gfriloux/tabularium/predicates/deployment/v0.1`.
- `TABULARIUM_NOW` overrides the timestamp (tests only).

Consumer: `gfriloux/nixos` wraps every `just install*` recipe with
`tabularium record <Host> --`; `tabularium` comes from the nixos devShell
(direnv). Merged in gfriloux/nixos#131; its input follows this repo's
default branch, `main`.

## Tests

`nix flake check` runs everything: STC purity seals (`nix`, `gitleaks`,
`markdown -d MD013,MD033`) plus one derivation per test in `tests/`.

- `tests/lib.nix` builds its own instance of the script with a **fake `nix`**
  (writeShellApplication prepends runtimeInputs to PATH, so a fake on PATH
  would be shadowed). The fake mimics nix 2.34: it rejects `path-info --json`
  without `--json-format 2`. Real `nix eval` / `path-info` are only exercised
  by hand on exampleHost.
- It also has a fake `curl` (serves `$FAKE_GH/<api path>`) and a `lock`
  helper to write a `flake.lock`; `FAKE_NIX_EVAL_FAIL` makes the fake
  `nix eval --json` fail.
- Fake `nix build` logs its arguments to `$TMPDIR/nix-build.log` and serves a
  3-component CycloneDX fixture. `FAKE_NIX_TOPLEVEL` overrides the evaluated
  toplevel, `FAKE_NIX_MISSING` makes `path-info` fail.
- Lot 4 fakes: `vulnxscan` serves `$FAKE_VULNX/<toplevel basename>.csv` (+ `.log`)
  and logs calls to `$TMPDIR/vulnxscan.log`; fake `nix` maps `?rev=<sha>` to
  `$FAKE_NIX_TOPLEVELS/<sha>` and `--override-input` to `$FAKE_NIX_TOPLEVELS/update`,
  serves `$FAKE_NIX_IMPORTANT/<basename>.json`, `FAKE_NIX_TO_BUILD` drives
  `build --dry-run`, realisations go to `$TMPDIR/nix-realise.log`.
  `important.nix` and `cve.jq` are also tested alone (`tests/important.nix`,
  `tests/cve-diff.nix`).
- `mkTest name script`: fresh git repo named `nixos`, one committed `flake.nix`,
  `TABULARIUM_STORE=$TMPDIR/store`, helper `records` counts JSON files.
- Never assign `$out` inside a test script: it is Nix's output path.
- `writeShellApplication` sets `errexit`, `nounset`, `pipefail`: guard commands
  that may fail (see `last`, which tests the directory before `find`).

## Decisions (owner) — do not revisit without asking

- Deploy with **deploy-rs** (gfriloux/nixos#89), push from exampleHost. No
  comin, no pull GitOps. Build signing is a future goal.
- tabularium **wraps** the deploy command; it never deploys, commits, tags or
  pushes. The owner always pushes.
- Nothing is stored on the hosts; no credentials on the hosts; never log into a
  host to learn its state.
- **CycloneDX** for composition (SBOM, VEX, compliance), Nix facts as
  `properties` under the registered `nix:` namespace. **in-toto** for claims
  about an artifact (deployments). They nest: in-toto can wrap a CycloneDX BOM.
- Vulnerability data is never public. SBOM/CVE are recomputed from a commit;
  VEX goes in `.tabularium`.
- Rejected: Dependency-Track (v5 needs Postgres, no OpenVEX), crystal-forge
  (central), comin, nix-topology, trivy (compromised 2026-03-19).
- Personal project for now; it prefigures professional choices, hence standards.

## Open items, in order

1. Lot 4 (CVEs and important bumps, no VEX) is done. Next (owner's call): a viewer for the exports of lots 2–4, then VEX/triage. Kept for later: bombon has few but exact CPE (40/1519 on exampleHost), sbomnix many guessed ones (376/481 vendor = product); kernel CVE counts do not move with kernel bumps (193 on 6.18.57 and .60); sbomnix also ships `vulnxscan-diff`. Rust may come with the analysers.
2. **Polish, later** (POC first, owner 2026-11-07). Review minors:
   `deployedAt` is the start time; `last` takes any `*.json`; store key is
   the checkout dirname; host not validated (`--allow-dirty` as host); fake
   `nix` ignores cwd; other flake inputs (home-manager, stc…) in freshness; `design.md` still says lot 1 waits for #89; nixos
   `nh os switch .` picks the host by hostname, not `-H`.
   Lot 2 minors: head == locked rev still fetches the commit date;
   compare without `per_page=1`; no test for `diverged`; `nixpkgs-unstable`
   and `-small` branches not handled; offline `nix eval` needs inputs local.
   Deployed ≠ booted: after a `switch` the old kernel runs until reboot,
   and tabularium cannot tell without logging into the host.
   Lot 3: licences on 177/1519 components only (none on linux, openssl,
   samba, tailscale); container SBOMs postponed, images in `nixos` are
   pinned by tag without digest.

## Related

- gfriloux/nixos#89 — deploy-rs study (magic rollback, `confirmTimeout = 120`
  for Tailscale, only `deploy-schema` from `deployChecks`).
- gfriloux/stc#146 — ANSSI-BP-028 matrix generated from a Nix evaluation;
  feeds lot 5 (compliance).
- gfriloux/noosphere — DMS widget tracking flake input lag; possible consumer.

## Owner preferences

- One change at a time; wait for explicit validation before the next.
- Explain non-obvious calls before making them.
- fish shell everywhere: docs and commands in fish syntax.
- Docs are terse: tables and commands, not prose.
- `gh` with `--body-file`, never inline `--body`.
- Never run `git push`. Never SSH into hosts; give the command and wait.
