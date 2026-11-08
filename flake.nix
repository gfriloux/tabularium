{
  description = "tabularium: health records of a NixOS fleet, derived from its repository";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    stc = {
      url = "github:gfriloux/stc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bombon = {
      url = "github:nikstur/bombon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sbomnix = {
      url = "github:tiiuae/sbomnix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    stc,
    bombon,
    sbomnix,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    tabularium = pkgs.writeShellApplication {
      name = "tabularium";
      runtimeInputs = with pkgs; [git jq nix coreutils findutils gnugrep gnused curl miller sbomnix.packages.${system}.default];
      runtimeEnv = {
        TABULARIUM_SBOM_NIX = "${./src/sbom.nix}";
        TABULARIUM_BOMBON = "${bombon}";
        TABULARIUM_NIXPKGS = "${nixpkgs}";
        TABULARIUM_IMPORTANT_NIX = "${./src/important.nix}";
        TABULARIUM_CVE_JQ = "${./src/cve.jq}";
        TABULARIUM_JQ = "${./src/jq}";
      };
      text = builtins.readFile ./src/tabularium.sh;
    };
  in {
    packages.${system} = {
      inherit tabularium;
      default = tabularium;
    };

    checks.${system} = import ./checks {
      inherit pkgs tabularium;
      seals = stc.lib.puritySeals.${system};
      src = self;
    };

    formatter.${system} = pkgs.alejandra;
  };
}
