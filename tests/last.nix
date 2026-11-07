{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
in {
  last_latest = mkTest "last-latest" ''
    TABULARIUM_NOW=20261107T100000Z tabularium record clochette -- true
    git commit -q --allow-empty -m second
    TABULARIUM_NOW=20261107T120000Z tabularium record clochette -- true
    got=$(tabularium last clochette)
    case "$got" in
      "$(git rev-parse HEAD) 2026-11-07T12:00:00Z"*) ;;
      *) echo "unexpected: $got" >&2; exit 1 ;;
    esac
  '';

  last_none = mkTest "last-none" ''
    set +e
    tabularium last skitarii 2>err
    code=$?
    set -e
    test "$code" -eq 1
    grep -q 'no deployment recorded for skitarii' err
  '';

  last_mixed_case = mkTest "last-mixed-case" ''
    tabularium record RogueLeader -- true
    tabularium last RogueLeader
    set +e
    tabularium last rogueleader 2>/dev/null
    code=$?
    set -e
    test "$code" -eq 1
  '';

  last_dirty_marker = mkTest "last-dirty-marker" ''
    echo changed > flake.nix
    tabularium record clochette --allow-dirty -- true
    tabularium last clochette | grep -q ' dirty$'
  '';
}
