# Test harness: the real script, built against a fake `nix` so that no test
# evaluates or builds a NixOS system.
{pkgs}: let
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    case "$1" in
      eval)
        # nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.outPath
        host=''${3#.#nixosConfigurations.}
        host=''${host%%.*}
        printf '/nix/store/00000000000000000000000000000000-nixos-system-%s' "$host"
        ;;
      path-info)
        printf '{"%s":{"narHash":"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}}' "$3"
        ;;
      *) echo "fake nix: unexpected $*" >&2; exit 99 ;;
    esac
  '';
  tabularium = pkgs.writeShellApplication {
    name = "tabularium";
    runtimeInputs = with pkgs; [git jq coreutils fakeNix];
    text = builtins.readFile ../src/tabularium.sh;
  };
in {
  inherit tabularium;

  # A fresh git repository named `nixos` with one committed flake.nix, then `script`.
  mkTest = name: script:
    pkgs.runCommand "tabularium-${name}" {nativeBuildInputs = with pkgs; [git jq tabularium];} ''
      export HOME=$TMPDIR TABULARIUM_STORE=$TMPDIR/store
      mkdir -p $TMPDIR/nixos && cd $TMPDIR/nixos
      git init -q
      git config user.email test@example.org
      git config user.name test
      echo '{}' > flake.nix
      git add flake.nix && git commit -qm init
      records() { find "$TABULARIUM_STORE" -name '*.json' 2>/dev/null | wc -l; }
      ${script}
      touch $out
    '';
}
