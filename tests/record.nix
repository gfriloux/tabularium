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

  record_command_with_options = mkTest "record-command-with-options" ''
    tabularium record clochette -- true --flake .#clochette -- x
    f=$(find $TABULARIUM_STORE/nixos/deployments/clochette -name '*.json')
    jq -e '.predicate.command == ["true", "--flake", ".#clochette", "--", "x"]' "$f"
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

  record_unknown_host = mkTest "record-unknown-host" ''
    set +e
    tabularium record rogueleader -- touch $TMPDIR/ran
    code=$?
    set -e
    test "$code" -ne 0
    test ! -e $TMPDIR/ran
    test "$(records)" -eq 0
  '';

  record_tree_moved = mkTest "record-tree-moved" ''
    set +e
    tabularium record clochette -- sh -c 'echo moved > flake.nix && git commit -qam moved' 2>err
    a=$?
    tabularium record clochette --allow-dirty -- sh -c 'echo again > flake.nix' 2>>err
    b=$?
    set -e
    test "$a" -eq 4 && test "$b" -eq 4
    grep -q 'changed during the deploy' err
    test "$(records)" -eq 0
  '';

  record_race_same_second = mkTest "record-race-same-second" ''
    export TABULARIUM_NOW=20261107T183000Z
    d=$TABULARIUM_STORE/nixos/deployments/clochette
    set +e
    tabularium record clochette -- sh -c "mkdir -p $d && echo other > $d/20261107T183000Z.json" 2>err
    code=$?
    set -e
    test "$code" -eq 3
    test "$(cat $d/20261107T183000Z.json)" = other
    test "$(find $d -type f | wc -l)" -eq 1
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

  # The toplevel is not in the local store (built elsewhere): no digest, no record.
  record_path_info_fails = mkTest "record-path-info-fails" ''
    set +e
    FAKE_NIX_MISSING=1 tabularium record clochette -- true 2>err
    code=$?
    set -e
    test "$code" -ne 0
    test "$(records)" -eq 0
  '';
}
