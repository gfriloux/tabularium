{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  # clochette deployed at nixpkgs A, then main moved to B three days later.
  behind = ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    c1=$(git rev-parse HEAD)
    lock nixpkgs ${B} 1259200 nixos-unstable
    commit_lock
    compare ${A}...${B} ahead 410 0
  '';
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
      and (.predicate.hosts | keys) == ["RogueLeader", "clochette", "exampleHost", "skitarii"]
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

  freshness_old_stable = mkFresh "freshness-old-stable" ''
    lock nixpkgs-stable ${A} 1000000 nixos-25.11
    commit_lock
    s() { printf '{"ref":"refs/heads/%s","object":{"sha":"%s","type":"commit"}}' "$1" "$2"; }
    printf '[%s,%s,%s,%s,%s]' "$(s nixos-25.05 cc)" "$(s nixos-25.11 ${B})" "$(s nixos-26.05 dd)" \
      "$(s nixos-26.05-small ee)" "$(s nixos-unstable ff)" >$gh/git/matching-refs/heads/nixos-
    commit_date ${B} 1970-01-15T13:46:40Z
    compare ${A}...${B} ahead 7 0
    tabularium freshness >stdout
    jq -e '
      .predicate.inputs["nixpkgs-stable"]
      | .release == {currentStable: "nixos-26.05", releasesBehind: 1}
      and .upstream == {rev: "${B}", status: "behind", days: 3, commits: 7}
    ' $export_file
    grep -q '1 behind (nixos-26.05)' stdout
  '';

  freshness_current_stable = mkFresh "freshness-current-stable" ''
    lock nixpkgs ${A} 1000000 nixos-26.05
    commit_lock
    s() { printf '{"ref":"refs/heads/%s","object":{"sha":"%s","type":"commit"}}' "$1" "$2"; }
    printf '[%s,%s,%s]' "$(s nixos-25.11 cc)" "$(s nixos-26.05 ${B})" "$(s nixos-unstable ff)" \
      >$gh/git/matching-refs/heads/nixos-
    tabularium freshness >stdout
    jq -e '.predicate.inputs.nixpkgs.release == {currentStable: "nixos-26.05", releasesBehind: 0}' $export_file
    grep -q '0 behind (nixos-26.05)' stdout
  '';

  freshness_host_behind = mkFresh "freshness-host-behind" ''
    ${behind}
    tabularium freshness >stdout
    jq -e --arg c1 "$c1" '.predicate.hosts.clochette == {
      status: "recorded", deployedCommit: $c1, dirty: false, deployedAt: "2026-11-07T18:30:00Z",
      inputs: {nixpkgs: {rev: "${A}", status: "behind", days: 3, commits: 410}}
    }' $export_file
    grep -qx 'clochette    nixpkgs  behind 3d 410c' stdout
    test "$(tail -n 1 stdout)" = "export: $export_file"
  '';

  freshness_host_offline = mkFresh "freshness-host-offline" ''
    ${behind}
    unset FAKE_GH
    tabularium freshness >stdout
    jq -e '.predicate.hosts.clochette.inputs.nixpkgs == {rev: "${A}", status: "behind", days: 3, commits: null}' $export_file
    grep -qx 'clochette    nixpkgs  behind 3d ?c' stdout
  '';

  # Offline on purpose: equal revs never need the compare API.
  freshness_host_up_to_date = mkFresh "freshness-host-up-to-date" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    unset FAKE_GH
    tabularium freshness >stdout
    jq -e '.predicate.hosts.clochette.inputs.nixpkgs == {rev: "${A}", status: "up-to-date", days: 0, commits: 0}' $export_file
    grep -qx 'clochette    nixpkgs  up-to-date 0d 0c' stdout
  '';

  freshness_host_ahead = mkFresh "freshness-host-ahead" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    git checkout -qb next
    lock nixpkgs ${B} 1259200 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    git checkout -q main
    compare ${B}...${A} behind 0 5
    tabularium freshness >stdout
    jq -e '.predicate.hosts.clochette.inputs.nixpkgs == {rev: "${B}", status: "ahead", days: 3, commits: 5}' $export_file
    grep -qx 'clochette    nixpkgs  ahead 3d 5c' stdout
  '';

  freshness_never_recorded = mkFresh "freshness-never-recorded" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    tabularium freshness >stdout
    jq -e '.predicate.hosts.skitarii == {status: "never-recorded"}' $export_file
    grep -qx 'skitarii     -        never recorded' stdout
  '';

  freshness_host_dirty = mkFresh "freshness-host-dirty" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    echo '{ }' >flake.nix
    tabularium record clochette --allow-dirty -- true
    git checkout -q flake.nix
    tabularium freshness >stdout
    jq -e '.predicate.hosts.clochette.dirty == true' $export_file
    grep -qx 'clochette    nixpkgs  up-to-date 0d 0c dirty' stdout
  '';

  freshness_branch_changed = mkFresh "freshness-branch-changed" ''
    lock nixpkgs ${A} 1000000 nixos-25.11
    commit_lock
    tabularium record clochette -- true
    lock nixpkgs ${B} 1259200 nixos-unstable
    commit_lock
    tabularium freshness >stdout
    jq -e '.predicate.hosts.clochette.inputs.nixpkgs == {rev: "${A}", status: "branch-changed", days: null, commits: null}' $export_file
    grep -qx 'clochette    nixpkgs  branch-changed' stdout
  '';

  freshness_deployed_commit_missing = mkFresh "freshness-deployed-commit-missing" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    r=$TABULARIUM_STORE/nixos/deployments/clochette/20261107T183000Z.json
    jq '.predicate.gitCommit = "0123456789012345678901234567890123456789"' $r >$r.new
    mv $r.new $r
    tabularium freshness >stdout
    jq -e '
      .predicate.hosts.clochette
      | .status == "recorded"
      and .deployedCommit == "0123456789012345678901234567890123456789"
      and .inputs.nixpkgs.status == "unavailable"
    ' $export_file
    grep -qx 'clochette    nixpkgs  unavailable' stdout
  '';

  freshness_input_missing_in_deployed = mkFresh "freshness-input-missing-in-deployed" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record clochette -- true
    lock nixpkgs-stable ${B} 1000000 nixos-25.11
    commit_lock
    tabularium freshness >stdout
    jq -e '
      .predicate.hosts.clochette.inputs
      | .["nixpkgs-stable"] == {rev: null, status: "unavailable", days: null, commits: null}
      and .nixpkgs == {rev: "${A}", status: "up-to-date", days: 0, commits: 0}
    ' $export_file
  '';

  freshness_mixed_case = mkFresh "freshness-mixed-case" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    tabularium record RogueLeader -- true
    tabularium freshness >stdout
    jq -e '.predicate.hosts.RogueLeader.status == "recorded"' $export_file
  '';

  freshness_hosts_eval_fails = mkFresh "freshness-hosts-eval-fails" ''
    lock nixpkgs ${A} 1000000 nixos-unstable
    commit_lock
    FAKE_NIX_EVAL_FAIL=1 tabularium freshness >stdout
    jq -e '.predicate.hosts == {}' $export_file
    test "$(tail -n 1 stdout)" = "export: $export_file"
  '';
}
