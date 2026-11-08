# tabularium status reads exports only: the tests write them by hand.
{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  S = "/nix/store/ddb38n9z26qmkh78my9sacgnaxd7cwi8-nixos-system-skitarii-26.11.20261020.02c087f";
  C = "653ca74b06a375f755a4dfb5a57822bcac494941";
  # A fixed CVE entry as cve.jq writes it.
  fixed = id: pkg: sev: ''{"id":"${id}","package":"${pkg}","version":"1.0","severity":"${sev}"}'';
  triage5 = builtins.concatStringsSep "," [
    (fixed "CVE-2026-94300" "bind" "8.1")
    (fixed "CVE-2026-19630" "bind" "7.5")
    (fixed "CVE-2026-96888" "bind" "7.5")
    (fixed "CVE-2026-97313" "bind" "7.5")
    (fixed "CVE-2026-111272" "libraw" "6.8")
  ];
  deploy6 = ''{"status":"ok","missingSources":[],"fixed":{"solid":[],"triage":[${triage5}],"patch":[${fixed "CVE-2025-46394" "busybox" "3.2"}]},"new":{"solid":[],"triage":[]},"remaining":{"solid":[],"triage":[]},"uncertain":[],"kernel":{"from":193,"to":193},"bumps":[{"name":"linux","from":"6.18.57","to":"6.18.60"}]}'';
  update0 = ''{"status":"ok","missingSources":[],"fixed":{"solid":[],"triage":[],"patch":[]},"new":{"solid":[],"triage":[]},"remaining":{"solid":[],"triage":[]},"uncertain":[],"kernel":{"from":193,"to":193},"bumps":[]}'';
  mkStatus = name: script:
    mkTest name ''
      st=$TABULARIUM_STORE/nixos
      iso() { local t=$1; echo "''${t:0:4}-''${t:4:2}-''${t:6:2}T''${t:9:2}:''${t:11:2}:''${t:13:2}Z"; }
      # rec <host> <ts> <commit> <subject>: a deployment record.
      rec() {
        mkdir -p $st/deployments/$1
        jq -n --arg h "$1" --arg at "$(iso $2)" --arg c "$3" --arg s "$4" '{
          "_type": "https://in-toto.io/Statement/v1", subject: [{name: $s, digest: {}}],
          predicateType: "https://github.com/gfriloux/tabularium/predicates/deployment/v0.1",
          predicate: {host: $h, repository: "nixos", gitCommit: $c, dirty: false, deployedAt: $at, command: ["true"]}}' \
          >$st/deployments/$1/$2.json
      }
      # fresh <ts> <main> <hosts json> [<inputs json>]: a freshness export.
      fresh() {
        mkdir -p $st/freshness
        jq -n --arg at "$(iso $1)" --arg m "$2" --argjson h "$3" --argjson i "''${4:-$inputs0}" \
          '{predicate: {repository: "nixos", generatedAt: $at, mainCommit: $m, inputs: $i, hosts: $h}}' >$st/freshness/$1.json
      }
      # cvex <host> <ts> <main> <deployed toplevel> <deploy comparison> [<update comparison>]: a cve export;
      # $states_extra is merged into its states.
      cvex() {
        mkdir -p $st/cve/$1
        jq -n --arg h "$1" --arg at "$(iso $2)" --arg m "$3" --arg t "$4" --argjson d "$5" --argjson u "''${6:-$update0}" '{
          predicateType: "https://github.com/gfriloux/tabularium/predicates/cve/v0.1",
          predicate: {host: $h, generatedAt: $at, mainCommit: $m,
            states: ({deployed: {status: "scanned", toplevel: $t}, main: {status: "scanned"}, update: {status: "scanned"}}
              + ($ENV.states_extra // "{}" | fromjson)),
            comparisons: {deploy: $d, update: $u}}}' >$st/cve/$1/$2.json
      }
      inputs0='{"nixpkgs":{"branch":"nixos-unstable","upstream":{"status":"up-to-date","days":0,"commits":0}}}'
      update0=${pkgs.lib.escapeShellArg update0}
      behind='{"skitarii":{"status":"recorded","inputs":{"nixpkgs":{"status":"behind","days":15,"commits":11301}}}}'
      main=$(git rev-parse main)
      ${script}
    '';
  # skitarii deployed and scanned, as on 2026-11-08.
  skitarii = ''
    rec skitarii 20261107T213427Z ${C} ${S}
    fresh 20261107T215211Z "$main" "$behind"
    cvex skitarii 20261108T102706Z "$main" ${S} ${pkgs.lib.escapeShellArg deploy6}
  '';
in {
  status_overview = mkStatus "status-overview" ''
    ${skitarii}
    tabularium status >stdout
    cat stdout
    grep -Eq '^skitarii +2026-11-07 +2026-10-20 +15 d, 11301 c +6 \(5 triage, 1 patch\) +0 +2026-11-08 10:27$' stdout
    grep -Eq '^nixpkgs \(main → upstream\): up-to-date \(nixos-unstable, checked 2026-11-07 21:52\)$' stdout
    grep -Eq '^skitarii, fixed by deploy:$' stdout
    grep -Eq '^  8\.1  CVE-2026-94300  bind 1\.0$' stdout
  '';

  status_never_scanned = mkStatus "status-never-scanned" ''
    rec clochette 20261107T213427Z ${C} /nix/store/00000000000000000000000000000000-nixos-system-clochette
    tabularium status >stdout
    grep -Eq '^clochette +2026-11-07 +\? +\? +\? +\? +never$' stdout
  '';

  status_stale_redeployed = mkStatus "status-stale-redeployed" ''
    ${skitarii}
    rec skitarii 20261108T120000Z ${C} /nix/store/11111111111111111111111111111111-nixos-system-skitarii-26.11.20261105.f9a75f4
    tabularium status >stdout
    grep -Eq '^skitarii .*stale \(redeployed since\)' stdout
    ! grep -q 'skitarii, fixed by deploy:' stdout
  '';

  status_main_moved = mkStatus "status-main-moved" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    cvex skitarii 20261108T102706Z ffffffffffffffffffffffffffffffffffffffff ${S} ${pkgs.lib.escapeShellArg deploy6}
    tabularium status >stdout
    grep -Eq '^skitarii .*\[main moved since scan\]$' stdout
  '';

  status_freshness_stale = mkStatus "status-freshness-stale" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    fresh 20261106T120000Z "$main" "$behind"
    tabularium status >stdout
    grep -Eq '^skitarii +2026-11-07 +2026-10-20 +stale +' stdout
  '';

  status_detail_cap = mkStatus "status-detail-cap" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    seven=$(jq -c '.fixed.triage += [${fixed "CVE-2026-1" "zlib" "2.0"}]' <<<${pkgs.lib.escapeShellArg deploy6})
    cvex skitarii 20261108T102706Z "$main" ${S} "$seven"
    tabularium status >stdout
    test "$(grep -Ec '^  [0-9.]+  CVE-' stdout)" -eq 5
    grep -qx '  … 2 more (tabularium status skitarii)' stdout
  '';

  status_unreadable_export = mkStatus "status-unreadable-export" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    mkdir -p $st/cve/skitarii && echo 'not json' >$st/cve/skitarii/20261108T102706Z.json
    tabularium status >stdout 2>err
    grep -q 'is unreadable, skipped' err
    grep -Eq '^skitarii .* \? +\? +never$' stdout
  '';

  status_overview_unavailable = mkStatus "status-overview-unavailable" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    cvex skitarii 20261108T102706Z "$main" ${S} '{"status":"unavailable"}'
    tabularium status >stdout
    grep -Eq '^skitarii +2026-11-07 +2026-10-20 +\? +\? +0 +2026-11-08 10:27$' stdout
  '';

  status_old_freshness = mkStatus "status-old-freshness" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    mkdir -p $st/freshness
    jq -n --argjson h "$behind" '{predicate: {hosts: $h, inputs: {}}}' >$st/freshness/20261107T215211Z.json
    tabularium status >stdout
    grep -Eq '^skitarii +2026-11-07 ' stdout
  '';

  status_never_recorded = mkStatus "status-never-recorded" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    fresh 20261107T215211Z "$main" '{"RogueLeader":{"status":"never-recorded"}}'
    tabularium status >stdout
    grep -Eq '^RogueLeader +never +- +- ' stdout
  '';

  status_no_main = mkStatus "status-no-main" ''
    ${skitarii}
    git branch -q -m dev
    tabularium status >stdout
    ! grep -q 'main moved' stdout
  '';

  status_empty = mkStatus "status-empty" ''
    set +e
    tabularium status 2>err
    code=$?
    set -e
    test "$code" -eq 1
  '';

  status_usage = mkStatus "status-usage" ''
    set +e
    tabularium status a b 2>/dev/null
    code=$?
    set -e
    test "$code" -eq 64
  '';

  status_host = mkStatus "status-host" ''
    ${skitarii}
    tabularium status skitarii >stdout
    cat stdout
    grep -qx 'skitarii' stdout
    grep -Eq '^  deployed +2026-11-07 \(commit 653ca74, nixpkgs 2026-10-20\)$' stdout
    grep -Eq '^  behind main +15 d, 11301 c$' stdout
    grep -Eq '^deployed → main: fixed 6 \(solid 0, triage 5, patch 1\), new 0, remaining 0, kernel 193 → 193$' stdout
    grep -qx '  fixed, triage:' stdout
    test "$(grep -Ec '^    [0-9.]+  CVE-' stdout)" -eq 6
    grep -qx '  linux 6.18.57 → 6.18.60' stdout
    grep -Eq '^main → update: ' stdout
  '';

  status_host_unavailable = mkStatus "status-host-unavailable" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    export states_extra='{"update":{"status":"skipped","reason":"upstream unavailable"}}'
    cvex skitarii 20261108T102706Z "$main" ${S} ${pkgs.lib.escapeShellArg deploy6} '{"status":"unavailable"}'
    tabularium status skitarii >stdout
    grep -qx 'main → update: unavailable (update: upstream unavailable)' stdout
  '';

  status_host_not_scanned = mkStatus "status-host-not-scanned" ''
    rec clochette 20261107T213427Z ${C} /nix/store/00000000000000000000000000000000-nixos-system-clochette
    tabularium status clochette >stdout
    grep -qx 'no CVE scan (tabularium cve clochette)' stdout
  '';

  status_host_unknown = mkStatus "status-host-unknown" ''
    ${skitarii}
    set +e
    tabularium status nope 2>err
    code=$?
    set -e
    test "$code" -eq 1
    grep -q 'no deployment recorded for nope' err
  '';

  # Real exports exceed the 128 KiB a single argument may hold.
  status_large_export = mkStatus "status-large-export" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    mkdir -p $st/cve/skitarii
    jq -n --arg m "$main" --arg t ${S} '[range(4000) | {id: "CVE-2026-\(.)", package: "pkg\(.)", version: "1.0", severity: "5.0"}] as $many
      | {predicate: {host: "skitarii", generatedAt: "2026-11-08T10:27:06Z", mainCommit: $m,
          states: {deployed: {status: "scanned", toplevel: $t}, main: {status: "scanned"}, update: {status: "scanned"}},
          comparisons: {deploy: {status: "ok", missingSources: [], fixed: {solid: [], triage: $many, patch: []},
            new: {solid: [], triage: []}, remaining: {solid: [], triage: $many}, uncertain: [], kernel: {from: 0, to: 0}, bumps: []}}}}' \
      >$st/cve/skitarii/20261108T102706Z.json
    tabularium status >stdout
    grep -Eq '^skitarii .* 4000 \(4000 triage\) ' stdout
  '';

  # A deployed state skipped by `cve --no-build` is unavailable, not stale.
  status_deployed_skipped = mkStatus "status-deployed-skipped" ''
    rec skitarii 20261107T213427Z ${C} ${S}
    export states_extra='{"deployed":{"status":"skipped","reason":"needs a local build of 3 derivations"}}'
    cvex skitarii 20261108T102706Z "$main" ${S} '{"status":"unavailable"}'
    tabularium status >stdout
    ! grep -q 'stale' stdout
    grep -Eq '^skitarii .* \? +0 +2026-11-08 10:27$' stdout
    tabularium status skitarii >detail
    grep -qx 'deployed → main: unavailable (deployed: needs a local build of 3 derivations)' detail
  '';

  # Odd files in the store: each is skipped with a warning, the rest is shown.
  status_odd_exports = mkStatus "status-odd-exports" ''
    ${skitarii}
    rec clochette 20261107T213427Z ${C} /nix/store/00000000000000000000000000000000-nixos-system-clochette
    mkdir -p $st/cve/clochette
    echo null >$st/cve/clochette/20261108T100000Z.json
    rec RogueLeader 20261107T213427Z ${C} ${S}
    mkdir -p $st/cve/RogueLeader
    printf '{}\n{}\n' >$st/cve/RogueLeader/20261108T100000Z.json
    tabularium status >stdout 2>err
    test "$(grep -c 'is unreadable, skipped' err)" -eq 2
    grep -Eq '^skitarii .* 6 \(5 triage, 1 patch\) ' stdout
    grep -Eq '^clochette .* never$' stdout
  '';
}
