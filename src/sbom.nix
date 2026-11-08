# SBOM of <host>'s toplevel at commit <rev> of the flake checked out at <repo>.
{
  repo,
  rev,
  host,
  nixpkgs,
  bombon,
}: let
  fleet = builtins.getFlake "git+file://${repo}?rev=${rev}";
  pkgs = import nixpkgs {system = builtins.currentSystem;};
in
  (import bombon {inherit pkgs;}).buildBom fleet.nixosConfigurations.${host}.config.system.build.toplevel {}
