# Lot 3: SBOMs — design

Status: draft, 2026-11-08. Parent: `docs/design.md` (delivery order, lot 3).

## Intent

Lot 4 will find CVEs; it needs an inventory first. Lot 3 produces, per host,
the inventory of **what is deployed**: packages, versions, licences,
dependencies, as CycloneDX. Lot 3 is strict: it emits the SBOM as bombon
produces it and measures its gaps, it does not fill them.

## Spike (2026-11-08, exampleHost, commit `e605c9b`)

Throwaway flake: `bombon.lib.x86_64-linux.buildBom` on
`nixosConfigurations.exampleHost.config.system.build.toplevel` of
`git+file://…/nixos?rev=<deployed commit>`.

| Measure | Result |
|---|---|
| Time | 2 min 27 wall, 30 s CPU; most of it is building bombon's transformer once |
| Toplevel evaluated vs record `subject` | identical (`2w96jw…`) |
| Format | CycloneDX 1.7, 2.7 MB |
| Components | 1519 |
| Version | 1519 |
| PURL | 1518, all `pkg:nix/<name>@<version>` (no upstream PURL) |
| CPE | 40 (none on linux, openssl, samba, tailscale) |
| Licences | 177 (none on linux, openssl, samba, tailscale) |
| Dependency graph | complete (1520 entries) |

Consequences:

- Cost is negligible while the deployed closure is in the local store.
- `docs/design.md` says "upstream PURLs are used": false for bombon today,
  to be corrected.
- Low CPE coverage is lot 4's problem (owner: "le CPE on verra au lot 4").

## Goals

1. `tabularium sbom <host>`: the CycloneDX SBOM of the host's last deployed
   toplevel (lot 1 record), written to the store.
2. A short terminal summary: component count and coverage of PURL, CPE,
   licences; then `export: <path>`.

## Non-goals

- SBOM of `main` (needs building every host; later, depending on cost —
  owner).
- Container images (owner: out of lot 3). Note for later: every image in
  `nixos` is referenced by tag without digest, so a registry scan cannot
  prove it describes what runs.
- Filling CPE, upstream PURLs or licences: lot 4.
- CVE matching, VEX: lot 4.
- All hosts in one call.

## Anti-goals

- An SBOM that does not describe what is deployed (wrong toplevel, dirty
  tree) written as if it did.
- A silent full host build (minutes to an hour) triggered by an inventory
  command.
- Logging into a host, anything running on the hosts.

## Constraints

- From `docs/design.md` and `CLAUDE.md`: fish syntax in docs, POC first,
  one change at a time, tabularium never commits or pushes, `nix flake check`
  stays cheap (no network, no system builds in checks).
- SBOMs are derived facts: the store file is a cache, recomputable from the
  commit.
- Vulnerability data must not be public; an SBOM is not vulnerability data,
  but it stays in the uncommitted store like the rest.

## Decided (owner)

| Topic | Decision |
|---|---|
| Scope | hosts only, at the deployed commit |
| Tool | bombon, output kept as is |
| Gaps (CPE, licences) | measured and shown, not fixed (lot 4) |
| Containers | out of lot 3 |
| CLI and path | `tabularium sbom <host>` → `$TABULARIUM_STORE/<repo>/sbom/<host>/<commit>.cdx.json`, raw bombon CycloneDX, no in-toto envelope ("ça me va pour le moment") |
| Closure missing from the local store | refuse by default; `--build` forces the build |
| Closure retention | none: no GC root added by `record` or `sbom`. Run `sbom` soon after deploying; `--build` is the fallback. Keeping the last build of every host does not scale (owner: "si demain nous avons un dépôt avec 30 hosts…") |
| bombon rebuild | acceptable: `nixos` keeps `tabularium.inputs.nixpkgs.follows`, bombon's transformer is rebuilt on each nixpkgs bump there (~2 min) |

## Builder's calls (proposed in conversation, not objected to)

| Topic | Call |
|---|---|
| Source | newest record of `<host>` (same reading as `last`): `gitCommit` and `subject[0].name` |
| No record | exit 1, like `last` |
| Dirty record | refuse, write nothing: the commit does not describe the deployed tree |
| Evaluated toplevel ≠ record `subject` | refuse, write nothing, dedicated exit code |
| File already exists for this commit | reuse it: print the summary and `export:`, no recomputation |
| Cache key | the commit, not a date: same commit, same SBOM |

## Builder's calls (made while writing, not discussed)

| Topic | Call |
|---|---|
| bombon pin | input of tabularium's flake, following tabularium's `nixpkgs` (which consumers may override) |
| "Missing" means | a **local build** would be needed. Paths substitutable from a binary cache are downloaded without `--build`: the owner's concern is CPU, not bandwidth |
| Cache and bombon upgrades | the cache key is the commit only; after a bombon upgrade, delete the file to recompute (POC) |
| Remote hosts | clochette, RogueLeader, skitarii are deployed with `nixos-rebuild --target-host` from exampleHost: their closures are in its store until the next GC |
| Evaluation | the analysed repo at `git+file://<repo>?rev=<commit>` (the commit must exist in the local clone; the working tree is not used) |
| Write | through the shared `write_new` (temp file then hard link): never partial |

## Left to the builder

- How tabularium hands the toplevel to bombon (`nix build --expr` with
  `builtins.getFlake`, a generated flake, …) and how the "closure is
  present" check is done before any build.
- Exit codes for new failures (dirty, mismatch, closure missing), within the
  existing scheme (`CLAUDE.md`).
- Exact summary layout.
- Tests: the fake `nix` in `tests/lib.nix` serves a fixture CycloneDX file;
  real bombon is only exercised by hand on exampleHost.
- Bash vs Rust: Bash is acceptable while it stays small.
