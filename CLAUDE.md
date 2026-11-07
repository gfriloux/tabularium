# tabularium — Context

Health records of a NixOS fleet ("its smell"), derived from the repository and a
local, uncommitted store. Read `docs/design.md` first: it is the intent, and it
is expected to move as iterative development teaches us things. Update it
rather than forcing the code to fit.

## What exists (lots 1 and 2, 2026-11-07)

`src/tabularium.sh`, packaged with `writeShellApplication` (runtime: git, jq,
nix, coreutils; nix is pinned by this flake, not the system's).

| Command | Effect |
|---|---|
| `tabularium record <host> [--allow-dirty] -- <cmd…>` | Refuses a dirty tree (exit 2), runs `<cmd>` with the terminal attached, and on success writes an in-toto Statement v1 to `$TABULARIUM_STORE/<repo>/deployments/<host>/<YYYYMMDDTHHMMSSZ>.json` |
| `tabularium last <host>` | `<commit> <deployedAt> [dirty]` of the newest record, exit 1 if none or unreadable |
| `tabularium freshness` | No argument (64 otherwise). Prints an input table (root nixpkgs inputs of `flake.lock` on `main`: lag vs upstream, days + commits), a host table (each host's last deployed commit vs `main`, days + commits) and `export: <path>` |

- Store: `${TABULARIUM_STORE:-$HOME/.tabularium}`, never committed.
- Exit codes: wrapped command's code on failure, 2 dirty, 3 record exists, 4 tree changed during the deploy (not recorded), 64 usage.
- Out path is evaluated **before** the deploy (unknown host fails early); HEAD + `git diff HEAD` are re-checked after it.
- Record written to `.new.XXXXXX` then hard-linked (shared `write_new`): never partial, never overwritten (race → exit 3).
- `freshness`: exit 1 if no `main` branch or no `flake.lock` on `main`; exit 0 whenever an export is written, even partial.
- `freshness` export: `$TABULARIUM_STORE/<repo>/freshness/<YYYYMMDDTHHMMSSZ>.json`, predicate type `https://github.com/gfriloux/tabularium/predicates/freshness/v0.1`.
- `freshness` scope: root nixpkgs inputs only; lags in days + commits. `GITHUB_TOKEN` optional (unauthenticated GitHub API: 60 req/h). Offline: commits `?`/null, upstream `unavailable`.
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

1. Lot 2 (freshness) is done. Next: lot 3 (SBOMs) per `docs/design.md`. Rust may come with the analysers.
2. **Polish, later** (POC first, owner 2026-11-07). Review minors:
   `deployedAt` is the start time; `last` takes any `*.json`; store key is
   the checkout dirname; host not validated (`--allow-dirty` as host); fake
   `nix` ignores cwd; other flake inputs (home-manager, stc…) in freshness; `design.md` still says lot 1 waits for #89; nixos
   `nh os switch .` picks the host by hostname, not `-H`.

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
