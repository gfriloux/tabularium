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
  };

  outputs = {
    self,
    nixpkgs,
    stc,
    bombon,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    tabularium = pkgs.writeShellApplication {
      name = "tabularium";
      runtimeInputs = with pkgs; [git jq nix coreutils curl];
      runtimeEnv = {
        TABULARIUM_SBOM_NIX = "${./src/sbom.nix}";
        TABULARIUM_BOMBON = "${bombon}";
        TABULARIUM_NIXPKGS = "${nixpkgs}";
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
