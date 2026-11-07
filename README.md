# tabularium

Health records of a NixOS fleet, derived from its repository and a local,
uncommitted `.tabularium` store. No agent on the hosts, no server.

- Design: [docs/design.md](docs/design.md)
- Current lot: deployment record (`tabularium record`, `tabularium last`)

```fish
nix run github:gfriloux/tabularium -- last clochette
```
