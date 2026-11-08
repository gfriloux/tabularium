{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  # sbom_file <host>: where the SBOM of <host> at HEAD is exported.
  mkSbom = name: script:
    mkTest name ''
      sbom_file() { echo "$TABULARIUM_STORE/nixos/sbom/$1/$(git rev-parse HEAD).cdx.json"; }
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
}
