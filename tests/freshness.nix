{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  # Fake GitHub answers under $FAKE_GH, then `script`.
  mkFresh = name: script:
    mkTest name ''
      export FAKE_GH=$TMPDIR/gh TABULARIUM_NOW=20261107T183000Z
      gh=$FAKE_GH/repos/NixOS/nixpkgs
      mkdir -p $gh/git/matching-refs/heads $gh/commits $gh/compare
      export_file=$TABULARIUM_STORE/nixos/freshness/20261107T183000Z.json
      refs() { printf '[{"ref":"refs/heads/%s","object":{"sha":"%s","type":"commit"}}]' "$1" "$2" >$gh/git/matching-refs/heads/nixos-; }
      commit_date() { printf '{"sha":"%s","commit":{"committer":{"date":"%s"}}}' "$1" "$2" >$gh/commits/$1; }
      compare() { printf '{"status":"%s","ahead_by":%s,"behind_by":%s}' "$2" "$3" "$4" >"$gh/compare/$1"; }
      commit_lock() { git add flake.lock && git commit -qm lock; }
      ${script}
    '';
in {
  freshness_upstream_behind = mkFresh "freshness-upstream-behind" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    refs nixos-unstable ${B}
    commit_date ${B} 1970-01-15T13:46:40Z
    compare ${A}...${B} ahead 142 0
    tabularium freshness >stdout
    jq -e --arg blob "$(git rev-parse main:flake.lock)" --arg main "$(git rev-parse main)" '
      ._type == "https://in-toto.io/Statement/v1"
      and .predicateType == "https://github.com/gfriloux/tabularium/predicates/freshness/v0.1"
      and .subject == [{name: "flake.lock", digest: {gitBlob: $blob}}]
      and .predicate.repository == "nixos"
      and .predicate.mainCommit == $main
      and .predicate.generatedAt == "2026-11-07T18:30:00Z"
      and .predicate.hosts == {}
      and .predicate.inputs.nixpkgs.branch == "nixos-unstable"
      and .predicate.inputs.nixpkgs.rev == "${A}"
      and .predicate.inputs.nixpkgs.lastModified == 1000000
      and .predicate.inputs.nixpkgs.release == null
      and .predicate.inputs.nixpkgs.upstream == {rev: "${B}", status: "behind", days: 3, commits: 142}
    ' $export_file
    grep -q 'nixpkgs  nixos-unstable' stdout
    grep -q 'behind 3d 142c' stdout
    test "$(tail -n 1 stdout)" = "export: $export_file"
  '';

  freshness_upstream_identical = mkFresh "freshness-upstream-identical" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    refs nixos-unstable ${A}
    commit_date ${A} 1970-01-12T13:46:40Z
    compare ${A}...${A} identical 0 0
    tabularium freshness >stdout
    jq -e '.predicate.inputs.nixpkgs.upstream == {rev: "${A}", status: "up-to-date", days: 0, commits: 0}' $export_file
    grep -q 'up-to-date 0d 0c' stdout
  '';

  freshness_offline = mkFresh "freshness-offline" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    unset FAKE_GH
    tabularium freshness >stdout
    jq -e '.predicate.inputs.nixpkgs.upstream == {rev: null, status: "unavailable", days: null, commits: null}' $export_file
    grep -q unavailable stdout
  '';

  freshness_partial_api = mkFresh "freshness-partial-api" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    refs nixos-unstable ${B}
    commit_date ${B} 1970-01-15T13:46:40Z
    tabularium freshness >stdout
    jq -e '.predicate.inputs.nixpkgs.upstream == {rev: "${B}", status: "behind", days: 3, commits: null}' $export_file
    grep -q 'behind 3d ?c' stdout
  '';

  freshness_no_ref = mkFresh "freshness-no-ref" ''
    lock nixpkgs ${A} 1000000
    commit_lock
    refs nixos-unstable ${B}
    tabularium freshness >stdout
    jq -e '
      .predicate.inputs.nixpkgs.branch == null
      and .predicate.inputs.nixpkgs.upstream.status == "unavailable"
    ' $export_file
  '';

  freshness_no_main = mkFresh "freshness-no-main" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    git branch -m main master
    set +e
    tabularium freshness >stdout 2>err
    code=$?
    set -e
    test "$code" -eq 1
    grep -q 'no main branch' err
    test ! -e $TABULARIUM_STORE/nixos/freshness
  '';

  freshness_ignores_transitive = mkFresh "freshness-ignores-transitive" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    jq '.nodes.nixpkgs_2 = .nodes.nixpkgs' flake.lock >flake.lock.new
    mv flake.lock.new flake.lock
    commit_lock
    tabularium freshness >stdout
    jq -e '.predicate.inputs | keys == ["nixpkgs"]' $export_file
  '';
}
