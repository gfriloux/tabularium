# tabularium — design

> *Tabularium*: the public records office of Rome, where laws, registers and
> official acts were kept.

**Status: intent, not truth.** This document records what the owner wishes for
on 2026-11-07. Iterative development is expected to challenge it; when it does,
update the document rather than forcing the code to fit it.

## Intent

Know the health of a NixOS fleet (its "smell") **from the repository and a
local record store**, without ever logging into a machine: what is deployed where, how far it lags behind, what it
is made of, which vulnerabilities apply, and which security rules it follows.

The model rests on two pieces of information (owner's words):

1. **An analysis of the repository**, the way gitleaks or trivy analyse a
   repository: a tool that reads a flake at a given commit and derives facts
   from it, without touching any host.
2. **The commit each host was deployed from.**

From these two, drift follows: analyse the commit deployed on a host, analyse
`main`, compare.

tabularium produces these facts as **files in standard formats**. Displaying
them is a separate, later concern. Any viewer that reads the formats can be
plugged in, and swapped, without touching the data.

Why a separate repository: no existing tool covers this in an elastic way
(research of 2026-11-07: crystal-forge, Dependency-Track v5, NixFleet and Cachix
Deploy are all central; bombon, grype and flake-checker are isolated bricks).
The work is observation, not configuration, so it belongs neither in `stc`
(configuration library) nor in `nixos` (machine definitions). For now it is a
personal project. The first and only consumer is `gfriloux/nixos` (4 hosts:
exampleHost, clochette, RogueLeader, skitarii). It is also meant to prefigure
professional choices, so it relies on standards, not ad-hoc formats.

## Principles ("elastic")

- **No mandatory central point.** If a viewer or any single brick dies, the
  hosts keep running and the data stays readable.
- **Open formats, as plain files.** Facts are files (CycloneDX, in-toto,
  OpenVEX) in a local `.tabularium` store. Tools read them; no tool owns them.
- **Derived rather than stored, when possible.** A fact that can be recomputed
  from a commit (SBOM, freshness, compliance) does not need to be persisted.
- **Small, replaceable bricks.** Each analysis is independent and can be
  adopted, dropped or replaced on its own, the way `stc` relics are.
- **No administrative weight.** No database to babysit, no accounts, no roles,
  no onboarding.
- **Scales both ways.** Costs nothing on 4 hosts; does not need a new model on
  a larger fleet.

## Goals

1. **Repository analyser.** A tool (Nix, Rust, or both: open) that takes a
   flake and a commit and emits facts:
   - composition: SBOM of each host's NixOS closure and of each declared
     container image, with PURLs;
   - freshness: age of the pinned inputs (nixpkgs first);
   - vulnerabilities: CVEs found in those SBOMs, filtered by VEX statements;
   - compliance: which ANSSI-BP-028 rules each host satisfies, from the data
     `stc` exports (gfriloux/stc#146).
2. **Deployment record.** For each deployment: host, commit, date.
3. **Drift.** For each host: analysis of its deployed commit compared with the
   analysis of `main` (commits behind, inputs behind, packages and CVEs that
   differ).

## Non-goals

- **A frontend.** Out of scope for this design. It comes after real data
  exists. It may live in this repository later.
- **Deploying.** Deployment stays with deploy-rs (gfriloux/nixos#89).
  tabularium only records and observes.
- **Pull-based GitOps** (comin or similar). Rejected by the owner.
- **Certification or compliance scoring.** Compliance data is a fidelity map,
  not a claim.
- **Observing hosts at runtime.** Changes made outside the deploy tool are not
  seen by the git-only model. A host-side check is a possible later addition,
  not part of this design.

## Anti-goals (failure even if it works)

- Anything that requires logging into a host to know its state.
- A server, database or agent that becomes a mandatory point of passage
  (Dependency-Track, crystal-forge, Hydra-style).
- A write credential to the configuration repository stored on the hosts.
- Publishing the vulnerability picture of the fleet (see Constraints).

## Decisions taken

| Topic | Decision | Source |
|---|---|---|
| Model | Repository analysis + deployed commit per host; drift is derived from both | owner |
| Deploy tool | deploy-rs, push from exampleHost | owner |
| Dirty working tree | **Deploying from a dirty tree is refused.** An explicit escape hatch may exist, and marks the record as `dirty` | owner (accepted proposal) |
| Who records deployments | The deploy step, not the hosts, into the local `.tabularium` store. Hosts hold no credentials | owner |
| Data format | **CycloneDX** (1.6+) for SBOM, VEX and compliance; Nix-specific facts as `properties` using the registered `nix:` namespace (nixpkgs manual, `sec-interop.cylonedx-nix`) and a project prefix for what it does not cover | owner |
| Envelope | **in-toto statements** for claims about an artifact, so they can be signed later | owner |
| Future signing | Build signing is a stated future goal. Design must leave room for it | owner |
| Compliance source | `stc` exports its ANSSI-BP-028 mapping from a Nix evaluation (gfriloux/stc#146); tabularium consumes it and owns the conversion to CycloneDX | owner / designer |
| Rejected | Dependency-Track, crystal-forge, comin, nix-topology, trivy (compromised on 2026-03-19, CVE-2026-33634) | owner / research |
| Pushing | tabularium never commits, tags or pushes; the owner pushes, always | owner rule |
| Lot 1 timing | Depends on gfriloux/nixos#89 (deploy-rs) | owner |
| Tracked hosts | **All four**: clochette, RogueLeader, skitarii (deployed remotely by deploy-rs) and exampleHost (deploys itself with `nh os switch`, its recipe records a deployment too) | owner / designer |
| Deploying machine | exampleHost: it runs the deploy recipes, holds `.tabularium` and runs the analyser. It is the observer, and also one of the observed hosts | designer's call |

## Record store: `.tabularium` (owner decision)

Deployment records and other non-derivable facts live in a **`.tabularium`
directory that is never committed** (owner: "on ne doit surtout pas le
commit"). It is not necessarily inside the git working tree; its location is
configurable. When it does sit inside a repository, it must be git-ignored.

What goes there:

| Content | Why stored, not derived |
|---|---|
| Deployment records (host, commit, date, deployed store path) as in-toto statements | The act of deploying leaves no trace in the repository |
| VEX statements (OpenVEX) | Hand-written and private |
| Cached analysis results (optional) | Speed only; always recomputable from a commit |

Consequences (designer's notes):

- The store lives on the deploying machine (exampleHost). Losing it loses the
  deployment history, not the ability to analyse. Backing it up is the
  consumer's concern.
- Signing applies to the in-toto files themselves rather than to git objects.
- Nothing private reaches the public repository by construction.

## Suggested bricks (builder's call, recorded as such)

| Goal | Brick | Note |
|---|---|---|
| Host SBOM | **bombon** (nikstur) | CycloneDX, PURL from nixpkgs `meta.identifiers`, records patches |
| Container SBOM | **syft** on the images declared in `virtualisation.oci-containers` | Pin the CycloneDX schema version |
| CVE | **vulnxscan** (tiiuae/sbomnix: grype + OSV + vulnix, nixpkgs patch detection) | Local DBs + OSV API; chosen over grype alone in lot 4 |
| VEX | **OpenVEX** files, written with **vexctl**, fed to `grype --vex` | No Nix tool emits VEX; statements are authored by hand |
| Lock freshness | **flake-checker** (DeterminateSystems), or read `flake.lock` directly | |

Known limits to plan around: CVE matching on Nix packages relies on CPE and
name heuristics (false positives, nixpkgs backports patches without bumping
versions); `pkg:nix` is not a registered PURL type (purl-spec #876), yet
bombon emits `pkg:nix/<name>@<version>` (1518/1519 components on exampleHost,
2026-11-08) and CPE on 40/1519 only; OSV has no Nix ecosystem.

## Constraints

- **Vulnerability data must not be public.** `gfriloux/nixos` is a public
  repository and its docs are on public GitHub Pages. CVE results and VEX
  statements describe exploitable gaps per host. SBOMs and CVE results are
  recomputed from a commit; VEX statements live in the uncommitted
  `.tabularium` store.
- **GitHub Actions holds no secrets** (deliberate omission in `nixos`'s
  `CLAUDE.md`). CI cannot reach the hosts or a private store.
- `nix flake check` on `nixos` runs on every commit (pre-commit hook) and must
  stay cheap: no full system builds triggered by tabularium checks.
- Building SBOMs needs the system closures, which means building the hosts.
  The analyser runs where that is acceptable (exampleHost), not in pre-commit.
- The owner's shell is fish everywhere; commands in docs use fish syntax.
- Delivery is one brick at a time, each validated before the next. Bare POC
  first, polish later.

## Delivery order

Each lot is usable on its own.

1. **Deployment record.** Deploy recipe refuses dirty trees and writes host +
   commit into `.tabularium`. Depends on #89. **Done** (2026-11-07).
2. **First analysis: freshness.** Cheapest analysis (reads `flake.lock`), gives
   a first drift report (deployed commit vs `main`). **Done** (2026-11-07),
   see [spec](superpowers/specs/2026-11-07-lot2-freshness-design.md).
3. **SBOMs.** Host closures, CycloneDX (bombon). **Done** (2026-11-08), see
   [spec](superpowers/specs/2026-11-08-lot3-sbom-design.md). Container images
   postponed: `nixos` pins them by tag without digest.
4. **CVEs and important bumps.** **Done** (2026-11-08), see
   [spec](superpowers/specs/2026-11-08-lot4-cve-design.md). VEX postponed until
   results can be looked at (owner).
5. **Compliance.** Consume stc#146 output per host.
6. **Viewer** (separate design).

## Open questions (owner)

None blocking. Default location of `.tabularium` is left to the builder.

## Left to the builder

- Nix vs Rust split for the analyser, repository layout, CLI shape.
- Schema files, predicate type URIs, exact property names under the project
  prefix.
- How the deploy recipe wraps deploy-rs and `nh`.
- Default location of `.tabularium` (e.g. repository root, git-ignored, or
  `$XDG_STATE_HOME/tabularium/<repo>`).
- Test strategy.

## Related

- Possible future consumer: `gfriloux/noosphere` (DankMaterialShell widget that
  already tracks flake input lag) could read freshness data.
- Origin of the discussion: review of usmcamp0811/dotfiles and crystal-forge on
  2026-11-07; see gfriloux/nixos#89 and gfriloux/stc#146.
