# Test harness: the real script, built against a fake `nix` so that no test
# evaluates or builds a NixOS system.
{pkgs}: let
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    # The flake reference (first argument with a '#') and whether an input is overridden.
    ref="" override=false
    for a in "$@"; do
      case "$a" in
        --override-input) override=true ;;
        *'#'*) [ -n "$ref" ] || ref=$a ;;
      esac
    done
    host=''${ref#*#nixosConfigurations.}
    host=''${host%%.*}
    # Toplevel the reference evaluates to: $FAKE_NIX_TOPLEVELS/update when nixpkgs is
    # overridden, $FAKE_NIX_TOPLEVELS/<rev> when it exists, else a fixed path per host.
    toplevel() {
      local rev=""
      case "$ref" in *'?rev='*) rev=''${ref#*\?rev=}; rev=''${rev%%#*} ;; esac
      if [ -n "''${FAKE_NIX_TOPLEVEL:-}" ]; then
        printf '%s' "$FAKE_NIX_TOPLEVEL"
      elif [ "$override" = true ]; then
        printf '%s' "$(cat "$FAKE_NIX_TOPLEVELS/update")"
      elif [ -n "$rev" ] && [ -f "''${FAKE_NIX_TOPLEVELS:-/nonexistent}/$rev" ]; then
        printf '%s' "$(cat "$FAKE_NIX_TOPLEVELS/$rev")"
      else
        printf '/nix/store/00000000000000000000000000000000-nixos-system-%s' "$host"
      fi
    }
    known_host() {
      case "$host" in
        clochette | RogueLeader | skitarii | exampleHost) ;;
        *) echo "fake nix: attribute '$host' missing" >&2; exit 1 ;;
      esac
    }
    case "$1" in
      eval)
        case "$ref" in
          *'#nixosConfigurations')
            [ -z "''${FAKE_NIX_EVAL_FAIL:-}" ] || { echo "fake nix: eval failed" >&2; exit 1; }
            # nix eval --json <ref>#nixosConfigurations --apply builtins.attrNames
            echo '["RogueLeader","clochette","exampleHost","skitarii"]'
            ;;
          *.config)
            # nix eval --json <ref>#nixosConfigurations.<host>.config --apply <important.nix>
            known_host
            f=''${FAKE_NIX_IMPORTANT:-/nonexistent}/$(basename "$(toplevel)").json
            if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
            ;;
          *)
            # nix eval --raw <ref>#nixosConfigurations.<host>.config.system.build.toplevel.outPath
            known_host
            toplevel
            ;;
        esac
        ;;
      path-info)
        # Mimics nix 2.34: plain --json is deprecated, format 2 keys by base name under .info.
        [ "$2 $3 $4" = "--json --json-format 2" ] || { echo "fake nix: expected --json --json-format 2" >&2; exit 98; }
        [ -z "''${FAKE_NIX_MISSING:-}" ] || { echo "fake nix: path '$5' is not valid" >&2; exit 1; }
        printf '{"info":{"%s":{"narHash":"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}}}' "''${5#/nix/store/}"
        ;;
      build)
        case " $* " in
          *' --file '*)
            # nix build --file sbom.nix --argstr …: logs its arguments, serves a 3-component BOM.
            echo "$*" >>"$TMPDIR/nix-build.log"
            cat >"$TMPDIR/bom.cdx.json" <<'BOM'
    {"bomFormat":"CycloneDX","specVersion":"1.7","components":[
     {"name":"libidn2","version":"2.3.8","purl":"pkg:nix/libidn2@2.3.8","cpe":"cpe:2.3:a:gnu:libidn2:2.3.8:*:*:*:*:*:*:*","licenses":[{"license":{"id":"LGPL-3.0-or-later"}}]},
     {"name":"openssl","version":"3.5.9","purl":"pkg:nix/openssl@3.5.9"},
     {"name":"blob","version":""}]}
    BOM
            echo "$TMPDIR/bom.cdx.json"
            ;;
          *' --dry-run '*)
            # nix build --dry-run <installable>: $FAKE_NIX_TO_BUILD derivations to build.
            known_host
            n=''${FAKE_NIX_TO_BUILD:-0}
            [ "$n" -eq 0 ] || echo "these $n derivations will be built:" >&2
            ;;
          *)
            # nix build --no-link --print-out-paths <installable>: realises the toplevel.
            known_host
            echo "$(toplevel)" | tee -a "$TMPDIR/nix-realise.log"
            ;;
        esac
        ;;
      *) echo "fake nix: unexpected $*" >&2; exit 99 ;;
    esac
  '';
  # vulnxscan <path> --out <csv>: serves $FAKE_VULNX/<basename>.csv and its .log, logs the call.
  fakeVulnxscan = pkgs.writeShellScriptBin "vulnxscan" ''
    echo "$1" >>"$TMPDIR/vulnxscan.log"
    b=''${FAKE_VULNX:-/nonexistent}/$(basename "$1")
    [ -f "$b.csv" ] || { echo "fake vulnxscan: no fixture for $1" >&2; exit 1; }
    cp "$b.csv" "$3"
    [ ! -f "$b.log" ] || cat "$b.log" >&2
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
    runtimeInputs = with pkgs; [git jq coreutils miller fakeNix fakeCurl fakeVulnxscan];
    runtimeEnv = {
      TABULARIUM_SBOM_NIX = "/fake/sbom.nix";
      TABULARIUM_BOMBON = "/fake/bombon";
      TABULARIUM_NIXPKGS = "/fake/nixpkgs";
      TABULARIUM_IMPORTANT_NIX = "${../src/important.nix}";
      TABULARIUM_CVE_JQ = "${../src/cve.jq}";
    };
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
