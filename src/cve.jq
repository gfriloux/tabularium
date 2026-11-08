# Comparison of two states of a host ($from → $to): CVEs fixed, new and
# remaining in tiers, kernel counts apart, and bumps of important packages.
# Run as: jq -s -f cve.jq <from state file> <to state file>

def key: "\(.id)\u0000\(.package)";
def entry: {id, package, version, severity};
def ordered: sort_by([-(.severity | tonumber? // 0), .id]) | map(entry);
def tier: if (.sources | length) >= 2 then "solid" else "triage" end;
def tiers: {solid: map(select(tier == "solid")) | ordered,
            triage: map(select(tier == "triage")) | ordered};
def kernel: .package == "linux";

. as [$from, $to]
| if $from.status != "scanned" or $to.status != "scanned" then
  {status: "unavailable"}
else
  ($from.cves | map(select(kernel | not))) as $a
  | ($to.cves | map(select(kernel | not))) as $b
  | ($b | map(key)) as $bkeys
  | ($a | map(key)) as $akeys
  | ($to.patched | map(key)) as $patched
  | (($from.sources - $to.sources) + ($to.sources - $from.sources) | unique) as $missing
  # Seen only by a source missing on one side: its absence on that side means nothing.
  | def certain: (.sources - $missing) != [];
    ($a | map(select(key as $k | $bkeys | index($k) | not))) as $gone_all
  | ($b | map(select(key as $k | $akeys | index($k) | not))) as $new_all
  | ($gone_all | map(select(certain))) as $gone
  | (($from.important // []) | map({key: .name, value: .version}) | from_entries) as $before
  | {
      status: (if $missing == [] and ($from.warnings // []) + ($to.warnings // []) == []
               then "ok" else "degraded" end),
      missingSources: $missing,
      fixed: (($gone | map(select(key as $k | $patched | index($k) | not)) | tiers)
              + {patch: ($gone | map(select(key as $k | $patched | index($k))) | ordered)}),
      new: ($new_all | map(select(certain)) | tiers),
      uncertain: ($gone_all + $new_all | map(select(certain | not)) | ordered),
      remaining: ($b | map(select(key as $k | $akeys | index($k))) | tiers),
      kernel: {from: ($from.cves | map(select(kernel)) | length),
               to: ($to.cves | map(select(kernel)) | length)},
      bumps: (if $from.important == null or $to.important == null then null
              else [$to.important[] | select($before[.name] != null and $before[.name] != .version)
                    | {name, from: $before[.name], to: .version}] | sort_by(.name) end)
    }
end
