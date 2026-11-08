{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  # sbom_file <host>: where the SBOM of <host> at HEAD is exported.
  mkSbom = name: script:
    mkTest name ''
      sbom_file() { echo "$TABULARIUM_STORE/nixos/sbom/$1/$(git rev-parse HEAD).cdx.json"; }
      # refused <code> <message> <tabularium args…>: fails as told, writes no SBOM, builds nothing.
      refused() {
        local want=$1 msg=$2 code
        shift 2
        set +e
        tabularium "$@" 2>err
        code=$?
        set -e
        test "$code" -eq "$want" || { echo "exit $code, want $want" >&2; cat err >&2; exit 1; }
        grep -q -- "$msg" err
        test -z "$(find "$TABULARIUM_STORE/nixos/sbom" -name '*.cdx.json' 2>/dev/null)"
        test ! -e $TMPDIR/nix-build.log
      }
      # rewrite <jq filter>: edits the only record of clochette in place.
      rewrite() {
        local f
        f=$(find $TABULARIUM_STORE/nixos/deployments/clochette -name '*.json')
        jq "$1" "$f" >"$f.new" && mv "$f.new" "$f"
      }
      ${script}
    '';
in {
  sbom_writes = mkSbom "sbom-writes" ''
    tabularium record clochette -- true
    tabularium sbom clochette >stdout
    f=$(sbom_file clochette)
    jq -e '.bomFormat == "CycloneDX" and (.components | length) == 3' "$f"
    grep -qx 'components: 3' stdout
    grep -qx 'purl: 2' stdout
    grep -qx 'cpe: 1' stdout
    grep -qx 'licenses: 1' stdout
    grep -qx "export: $f" stdout
    grep -q -- "--argstr rev $(git rev-parse HEAD)" $TMPDIR/nix-build.log
    grep -q -- "--argstr host clochette" $TMPDIR/nix-build.log
  '';

  sbom_no_record = mkSbom "sbom-no-record" ''
    tabularium record RogueLeader -- true
    refused 1 'no deployment recorded for rogueleader' sbom rogueleader
  '';

  sbom_bad_record = mkSbom "sbom-bad-record" ''
    TABULARIUM_NOW=20261107T100000Z tabularium record clochette -- true
    touch $TABULARIUM_STORE/nixos/deployments/clochette/20261107T120000Z.json
    refused 1 'is not a valid record' sbom clochette
  '';

  sbom_dirty = mkSbom "sbom-dirty" ''
    echo changed > flake.nix
    tabularium record clochette --allow-dirty -- true
    refused 2 'dirty tree' sbom clochette
  '';

  sbom_commit_missing = mkSbom "sbom-commit-missing" ''
    tabularium record clochette -- true
    rewrite '.predicate.gitCommit = "ffffffffffffffffffffffffffffffffffffffff"'
    refused 1 'is not in this clone' sbom clochette
  '';

  sbom_mismatch = mkSbom "sbom-mismatch" ''
    tabularium record clochette -- true
    FAKE_NIX_TOPLEVEL=/nix/store/11111111111111111111111111111111-nixos-system-clochette \
      refused 5 'the record says' sbom clochette
  '';

  sbom_closure_missing = mkSbom "sbom-closure-missing" ''
    tabularium record clochette -- true
    FAKE_NIX_MISSING=1 refused 6 'rerun with --build' sbom clochette
  '';

  sbom_build_forced = mkSbom "sbom-build-forced" ''
    tabularium record clochette -- true
    FAKE_NIX_MISSING=1 tabularium sbom clochette --build >stdout
    test -f "$(sbom_file clochette)"
    test -f $TMPDIR/nix-build.log
  '';

  sbom_build_flag_noop = mkSbom "sbom-build-flag-noop" ''
    tabularium record clochette -- true
    tabularium sbom clochette --build >stdout
    grep -qx 'components: 3' stdout
    grep -qx "export: $(sbom_file clochette)" stdout
  '';

  sbom_reuse = mkSbom "sbom-reuse" ''
    tabularium record clochette -- true
    tabularium sbom clochette >first
    rm $TMPDIR/nix-build.log
    tabularium sbom clochette >second
    cmp first second
    test ! -e $TMPDIR/nix-build.log
  '';

  sbom_usage = mkSbom "sbom-usage" ''
    tabularium record clochette -- true
    refused 64 'usage: tabularium' sbom
    refused 64 'usage: tabularium' sbom clochette --nope
  '';
}
