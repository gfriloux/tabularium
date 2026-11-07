# tabularium — Context

Health records of a NixOS fleet ("its smell"), derived from the repository and a
local, uncommitted store. Read `docs/design.md` first: it is the intent, and it
is expected to move as iterative development teaches us things. Update it
rather than forcing the code to fit.

## What exists (lot 1, 2026-11-07)

`src/tabularium.sh`, packaged with `writeShellApplication` (runtime: git, jq,
nix, coreutils; nix is pinned by this flake, not the system's).

| Command | Effect |
|---|---|
| `tabularium record <host> [--allow-dirty] -- <cmd…>` | Refuses a dirty tree (exit 2), runs `<cmd>` with the terminal attached, and on success writes an in-toto Statement v1 to `$TABULARIUM_STORE/<repo>/deployments/<host>/<YYYYMMDDTHHMMSSZ>.json` |
| `tabularium last <host>` | `<commit> <deployedAt> [dirty]` of the newest record, exit 1 if none |

- Store: `${TABULARIUM_STORE:-$HOME/.tabularium}`, never committed.
- Exit codes: wrapped command's code on failure, 2 dirty, 3 record exists, 64 usage.
- Dirty = `git diff --quiet HEAD` fails. Untracked files do not count (flakes ignore them).
- Subject = toplevel store path, digest `sha256` = NAR hash in hex (`nix path-info --json --json-format 2`).
- Predicate type: `https://github.com/gfriloux/tabularium/predicates/deployment/v0.1`.
- `TABULARIUM_NOW` overrides the timestamp (tests only).

Consumer: `gfriloux/nixos` wraps every `just install*` recipe with
`tabularium record <Host> --`; `tabularium` comes from the nixos devShell
(direnv). Branch `feat/tabularium-deploy-record` there, not merged yet.

## Tests

`nix flake check` runs everything: STC purity seals (`nix`, `gitleaks`,
`markdown -d MD013,MD033`) plus one derivation per test in `tests/`.

- `tests/lib.nix` builds its own instance of the script with a **fake `nix`**
  (writeShellApplication prepends runtimeInputs to PATH, so a fake on PATH
  would be shadowed). The fake mimics nix 2.34: it rejects `path-info --json`
  without `--json-format 2`. Real `nix eval` / `path-info` are only exercised
  by hand on exampleHost.
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

1. **Final whole-branch review not done yet** (executing-plans skill): review
   `feat/lot1-deployment-record` here and `feat/tabularium-deploy-record` in
   nixos with a fresh reviewer, Review Focus from the lot 1 plan.
2. **Partial activation is not recorded.** `just install` on 2026-11-07:
   `nh os switch` activated the system, `docker.service` failed (activation
   exit 4, nh exit 1), so nothing was recorded although the system switched.
   Local fix idea: after a failure, compare `/run/current-system` with the
   evaluated out path and record `activation: partial` with the exit code.
   Remote hosts cannot be checked without logging in; deploy-rs's rollback
   makes their outcome binary. Owner decision pending.
3. GitHub default branch is `feat/lot1-deployment-record` (no `main` yet).
4. Lot 2 (freshness) per `docs/design.md`. Rust may come with the analysers.

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
