{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  fakePath = "/nix/store/00000000000000000000000000000000-nixos-system-clochette";
  emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
in {
  record_clean_success = mkTest "record-clean-success" ''
    tabularium record clochette -- true
    test "$(records)" -eq 1
    f=$(find $TABULARIUM_STORE/nixos/deployments/clochette -name '*.json')
    jq -e --arg c "$(git rev-parse HEAD)" '
      ._type == "https://in-toto.io/Statement/v1"
      and .predicate.host == "clochette"
      and .predicate.gitCommit == $c
      and .predicate.dirty == false
      and .predicate.command == ["true"]
      and .subject[0].name == "${fakePath}"
      and .subject[0].digest.sha256 == "${emptySha256}"
    ' "$f"
  '';

  record_dirty_refused = mkTest "record-dirty-refused" ''
    echo changed > flake.nix
    set +e
    tabularium record clochette -- touch $TMPDIR/ran 2>err
    code=$?
    set -e
    test "$code" -eq 2
    grep -q dirty err
    test "$(records)" -eq 0
    test ! -e $TMPDIR/ran
  '';

  record_dirty_allowed = mkTest "record-dirty-allowed" ''
    echo changed > flake.nix
    tabularium record clochette --allow-dirty -- true
    jq -e '.predicate.dirty == true' $(find $TABULARIUM_STORE -name '*.json')
  '';

  record_command_fails = mkTest "record-command-fails" ''
    set +e
    tabularium record clochette -- sh -c 'exit 7'
    code=$?
    set -e
    test "$code" -eq 7
    test "$(records)" -eq 0
  '';

  record_untracked_ok = mkTest "record-untracked-ok" ''
    echo scratch > notes.txt
    tabularium record clochette -- true
    jq -e '.predicate.dirty == false' $(find $TABULARIUM_STORE -name '*.json')
  '';

  record_from_subdir = mkTest "record-from-subdir" ''
    mkdir sub && cd sub
    tabularium record clochette -- true
    jq -e --arg c "$(git rev-parse HEAD)" '.predicate.gitCommit == $c' \
      $TABULARIUM_STORE/nixos/deployments/clochette/*.json
  '';

  record_no_clobber = mkTest "record-no-clobber" ''
    export TABULARIUM_NOW=20261107T183000Z
    d=$TABULARIUM_STORE/nixos/deployments/clochette
    mkdir -p $d && echo original > $d/20261107T183000Z.json
    set +e
    tabularium record clochette -- true
    code=$?
    set -e
    test "$code" -eq 3
    test "$(cat $d/20261107T183000Z.json)" = original
  '';

  record_keeps_stdin = mkTest "record-keeps-stdin" ''
    echo secret | tabularium record clochette -- sh -c 'read x; test "$x" = secret'
  '';

  record_usage = mkTest "record-usage" ''
    set +e
    tabularium record clochette true; a=$?
    tabularium record; b=$?
    tabularium record -- true; c=$?
    set -e
    test "$a" -eq 64 && test "$b" -eq 64 && test "$c" -eq 64
    test "$(records)" -eq 0
  '';
}
