# Test harness: the real script, built against a fake `nix` so that no test
# evaluates or builds a NixOS system.
{pkgs}: let
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    case "$1" in
      eval)
        if [ "$2" = --json ]; then
          [ -z "''${FAKE_NIX_EVAL_FAIL:-}" ] || { echo "fake nix: eval failed" >&2; exit 1; }
          # nix eval --json <ref>#nixosConfigurations --apply builtins.attrNames
          echo '["RogueLeader","clochette","exampleHost","skitarii"]'
          exit 0
        fi
        # nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.outPath
        host=''${3#.#nixosConfigurations.}
        host=''${host%%.*}
        case "$host" in
          clochette | RogueLeader | skitarii | exampleHost) ;;
          *) echo "fake nix: attribute '$host' missing" >&2; exit 1 ;;
        esac
        printf '/nix/store/00000000000000000000000000000000-nixos-system-%s' "$host"
        ;;
      path-info)
        # Mimics nix 2.34: plain --json is deprecated, format 2 keys by base name under .info.
        [ "$2 $3 $4" = "--json --json-format 2" ] || { echo "fake nix: expected --json --json-format 2" >&2; exit 98; }
        printf '{"info":{"%s":{"narHash":"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}}}' "''${5#/nix/store/}"
        ;;
      *) echo "fake nix: unexpected $*" >&2; exit 99 ;;
    esac
  '';
  # GitHub API answered from files: $FAKE_GH/<path after https://api.github.com/>.
  fakeCurl = pkgs.writeShellScriptBin "curl" ''
    url=''${!#}
    f=''${FAKE_GH:-}/''${url#https://api.github.com/}
    [ -n "''${FAKE_GH:-}" ] && [ -f "$f" ] || exit 22
    cat "$f"
  '';
  tabularium = pkgs.writeShellApplication {
    name = "tabularium";
    runtimeInputs = with pkgs; [git jq coreutils fakeNix fakeCurl];
    text = builtins.readFile ../src/tabularium.sh;
  };
in {
  inherit tabularium;

  # A fresh git repository named `nixos` (branch main) with one committed flake.nix, then `script`.
  mkTest = name: script:
    pkgs.runCommand "tabularium-${name}" {nativeBuildInputs = with pkgs; [git jq tabularium];} ''
      export HOME=$TMPDIR TABULARIUM_STORE=$TMPDIR/store
      mkdir -p $TMPDIR/nixos && cd $TMPDIR/nixos
      git init -q -b main
      git config user.email test@example.org
      git config user.name test
      echo '{}' > flake.nix
      git add flake.nix && git commit -qm init
      records() { find "$TABULARIUM_STORE" -name '*.json' 2>/dev/null | wc -l; }
      # lock <name> <rev> <lastModified> [ref]: root nixpkgs input in flake.lock.
      lock() {
        [ -f flake.lock ] || echo '{"nodes":{"root":{"inputs":{}}},"root":"root","version":7}' >flake.lock
        jq --arg n "$1" --arg rev "$2" --argjson lm "$3" --arg ref "''${4:-}" '
          .nodes.root.inputs[$n] = $n
          | .nodes[$n] = {
              locked: {type: "github", owner: "NixOS", repo: "nixpkgs", rev: $rev, lastModified: $lm},
              original: ({type: "github", owner: "nixos", repo: "nixpkgs"} + (if $ref == "" then {} else {ref: $ref} end))
            }' flake.lock >flake.lock.new
        mv flake.lock.new flake.lock
      }
      ${script}
      touch $out
    '';
}
