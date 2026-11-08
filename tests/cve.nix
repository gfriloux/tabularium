{pkgs}: let
  inherit (import ./lib.nix {inherit pkgs;}) mkTest;
  A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  # Toplevel basenames: deployed (the fake's default) and main.
  D = "00000000000000000000000000000000-nixos-system-clochette";
  M = "22222222222222222222222222222222-nixos-system-clochette";
  U = "33333333333333333333333333333333-nixos-system-clochette";
  # A repository with a flake.lock on main, fixtures under $TMPDIR, then `script`.
  mkCve = name: script:
    mkTest name ''
      export FAKE_VULNX=$TMPDIR/vulnx FAKE_NIX_TOPLEVELS=$TMPDIR/top FAKE_NIX_IMPORTANT=$TMPDIR/imp
      export TABULARIUM_NOW=20261108T120000Z
      mkdir -p $FAKE_VULNX $FAKE_NIX_TOPLEVELS $FAKE_NIX_IMPORTANT
      export_file=$TABULARIUM_STORE/nixos/cve/clochette/20261108T120000Z.json
      # vulnx <basename> <csv rows…>: what vulnxscan reports for that toplevel.
      vulnx() {
        local b=$1
        shift
        echo '"vuln_id","url","package","version_local","severity","grype","osv","vulnix","sum"' >$FAKE_VULNX/$b.csv
        for row in "$@"; do echo "$row" >>$FAKE_VULNX/$b.csv; done
        touch $FAKE_VULNX/$b.log
      }
      # patched <basename> <cve> <package>: a log line of vulnxscan's patch detection.
      patched() { echo "INFO     $2 for '$3' is patched with: ['/nix/store/x-$2.patch']" >>$FAKE_VULNX/$1.log; }
      important() { echo "$2" >$FAKE_NIX_IMPORTANT/$1.json; }
      main_at() { echo "/nix/store/$2" >$FAKE_NIX_TOPLEVELS/$1; }
      # upstream <sha>: head of nixos-unstable on (fake) GitHub.
      upstream() {
        export FAKE_GH=$TMPDIR/gh
        mkdir -p $FAKE_GH/repos/NixOS/nixpkgs/git/matching-refs/heads
        printf '[{"ref":"refs/heads/nixos-unstable","object":{"sha":"%s","type":"commit"}}]' "$1" \
          >$FAKE_GH/repos/NixOS/nixpkgs/git/matching-refs/heads/nixos-unstable
      }
      lock nixpkgs ${A} 1000000 nixos-unstable
      git add flake.lock && git commit -qm lock
      ${script}
    '';
  # clochette deployed at the lock commit, main one commit ahead with its own toplevel.
  deployedThenMain = ''
    tabularium record clochette -- true
    git commit -q --allow-empty -m next
    main_at "$(git rev-parse main)" ${M}
  '';
in {
  cve_deploy_diff = mkCve "cve-deploy-diff" ''
    ${deployedThenMain}
    vulnx ${D} '"CVE-2026-1","u","bind","9.20.29",8.1,1,0,1,2' '"CVE-2026-2","u","curl","8.16.0",5.3,1,0,0,1'
    vulnx ${M} '"CVE-2026-2","u","curl","8.17.0",5.3,1,0,0,1'
    tabularium cve clochette >stdout
    jq -e '
      .predicateType == "https://github.com/gfriloux/tabularium/predicates/cve/v0.1"
      and .predicate.host == "clochette"
      and .predicate.states.deployed.status == "scanned"
      and .predicate.comparisons.deploy.fixed.solid[0].package == "bind"
      and (.subject | map(.name) | index("/nix/store/${M}")) != null
    ' $export_file
    grep -qx 'deployed → main: fixed 1 (solid 1, triage 0, patch 0), new 0, remaining 1, kernel 0 → 0' stdout
    grep -qx "export: $export_file" stdout
  '';

  cve_source_warning = mkCve "cve-source-warning" ''
    ${deployedThenMain}
    vulnx ${D} '"CVE-2026-1","u","bind","9.20.29",8.1,1,0,1,2'
    vulnx ${M}
    echo "WARNING  vulnix: database download failed" >>$FAKE_VULNX/${M}.log
    tabularium cve clochette >stdout
    jq -e '.predicate.states.main.sources == ["grype", "osv"]' $export_file
    grep -q '\[degraded: vulnix\]' stdout
  '';

  cve_patched = mkCve "cve-patched" ''
    ${deployedThenMain}
    vulnx ${D} '"CVE-2026-3","u","openssl","3.5.9",7.5,1,0,0,1'
    vulnx ${M}
    patched ${M} CVE-2026-3 openssl
    tabularium cve clochette >stdout
    jq -e '.predicate.comparisons.deploy.fixed.patch[0].id == "CVE-2026-3"' $export_file
    grep -q 'fixed 1 (solid 0, triage 0, patch 1)' stdout
  '';

  cve_bumps = mkCve "cve-bumps" ''
    ${deployedThenMain}
    vulnx ${D}
    vulnx ${M}
    important ${D} '[{"name":"bind","version":"9.20.29"}]'
    important ${M} '[{"name":"bind","version":"9.20.31"}]'
    tabularium cve clochette >stdout
    grep -qx 'bumps deployed → main:' stdout
    grep -qx '  bind 9.20.29 → 9.20.31' stdout
  '';

  cve_no_build_skips = mkCve "cve-no-build-skips" ''
    ${deployedThenMain}
    vulnx ${D}
    vulnx ${M}
    FAKE_NIX_TO_BUILD=12 tabularium cve clochette --no-build >stdout
    jq -e '.predicate.states.main.status == "skipped" and .predicate.comparisons.deploy == {status: "unavailable"}' $export_file
    grep -q 'deployed → main: unavailable (main: needs a local build of 12 derivations)' stdout
    test ! -e $TMPDIR/nix-realise.log
  '';

  cve_builds_by_default = mkCve "cve-builds-by-default" ''
    ${deployedThenMain}
    vulnx ${D}
    vulnx ${M}
    FAKE_NIX_TO_BUILD=12 tabularium cve clochette >stdout 2>err
    grep -q 'main: 12 derivations to build' err
    grep -q '${M}' $TMPDIR/nix-realise.log
  '';

  cve_dirty_absent_skipped = mkCve "cve-dirty-absent-skipped" ''
    echo changed > flake.nix
    tabularium record clochette --allow-dirty -- true
    git checkout -q flake.nix
    vulnx ${D}
    FAKE_NIX_MISSING=1 tabularium cve clochette >stdout
    jq -e '.predicate.states.deployed.status == "skipped" and (.predicate.states.deployed.reason | test("dirty"))' $export_file
  '';

  cve_no_record = mkCve "cve-no-record" ''
    tabularium record RogueLeader -- true
    set +e
    tabularium cve rogueleader 2>err
    code=$?
    set -e
    test "$code" -eq 1
    grep -q 'no deployment recorded for rogueleader' err
  '';

  cve_usage = mkCve "cve-usage" ''
    set +e
    tabularium cve 2>/dev/null
    a=$?
    tabularium cve clochette --nope 2>/dev/null
    b=$?
    set -e
    test "$a" -eq 64
    test "$b" -eq 64
  '';

  cve_update_diff = mkCve "cve-update-diff" ''
    ${deployedThenMain}
    upstream ${B}
    echo /nix/store/${U} >$FAKE_NIX_TOPLEVELS/update
    vulnx ${D}
    vulnx ${M} '"CVE-2026-1","u","bind","9.20.29",8.1,1,0,1,2'
    vulnx ${U}
    tabularium cve clochette >stdout
    jq -e '
      .predicate.comparisons.update.fixed.solid[0].package == "bind"
      and .predicate.states.update.nixpkgs == {branch: "nixos-unstable", from: "${A}", to: "${B}"}
    ' $export_file
    grep -q '^main → update: fixed 1 ' stdout
  '';

  cve_update_up_to_date = mkCve "cve-update-up-to-date" ''
    ${deployedThenMain}
    upstream ${A}
    vulnx ${D}
    vulnx ${M}
    tabularium cve clochette >stdout
    jq -e '.predicate.states.update.toplevel == .predicate.states.main.toplevel' $export_file
    test "$(wc -l <$TMPDIR/vulnxscan.log)" -eq 2
  '';

  cve_offline = mkCve "cve-offline" ''
    ${deployedThenMain}
    vulnx ${D}
    vulnx ${M}
    tabularium cve clochette >stdout
    jq -e '
      .predicate.states.update.status == "skipped"
      and .predicate.states.update.reason == "upstream unavailable"
      and .predicate.comparisons.deploy.status != "unavailable"
    ' $export_file
  '';

  cve_scan_fails = mkCve "cve-scan-fails" ''
    ${deployedThenMain}
    upstream ${A}
    vulnx ${D}
    tabularium cve clochette >stdout
    jq -e '
      .predicate.states.main.status == "failed"
      and .predicate.comparisons.deploy == {status: "unavailable"}
      and .predicate.comparisons.update == {status: "unavailable"}
    ' $export_file
  '';

  # A dirty record leaves the deployed config unknown: bumps are unknown, not "none".
  cve_bumps_unknown = mkCve "cve-bumps-unknown" ''
    echo changed > flake.nix
    tabularium record clochette --allow-dirty -- true
    git checkout -q flake.nix
    git commit -q --allow-empty -m next
    main_at "$(git rev-parse main)" ${M}
    vulnx ${D}
    vulnx ${M}
    important ${M} '[{"name":"bind","version":"9.20.31"}]'
    tabularium cve clochette >stdout
    jq -e '.predicate.comparisons.deploy.bumps == null' $export_file
    grep -qx 'bumps deployed → main: unknown' stdout
  '';

  # An unreadable vulnxscan report fails that state; the export is still written.
  cve_unreadable_report = mkCve "cve-unreadable-report" ''
    ${deployedThenMain}
    vulnx ${D}
    printf '"vuln_id","package"\n"a","b","c"\n' >$FAKE_VULNX/${M}.csv
    tabularium cve clochette >stdout
    jq -e '.predicate.states.main.status == "failed"' $export_file
  '';
}
