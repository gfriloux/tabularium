# Comparison of two states of a host ($from → $to): CVEs fixed, new and
# remaining in tiers, kernel counts apart, and bumps of important packages.
# Run as: jq -n --argjson from <state> --argjson to <state> -f cve.jq

def key: "\(.id)\u0000\(.package)";
def entry: {id, package, version, severity};
def ordered: sort_by([-(.severity | tonumber? // 0), .id]) | map(entry);
def tier: if (.sources | length) >= 2 then "solid" else "triage" end;
def tiers: {solid: map(select(tier == "solid")) | ordered,
            triage: map(select(tier == "triage")) | ordered};
def kernel: .package == "linux";

if $from.status != "scanned" or $to.status != "scanned" then
  {status: "unavailable"}
else
  ($from.cves | map(select(kernel | not))) as $a
  | ($to.cves | map(select(kernel | not))) as $b
  | ($b | map(key)) as $bkeys
  | ($a | map(key)) as $akeys
  | ($to.patched | map(key)) as $patched
  | ($a | map(select(key as $k | $bkeys | index($k) | not))) as $gone
  | (($from.sources - $to.sources) + ($to.sources - $from.sources) | unique) as $missing
  | ($from.important | map({key: .name, value: .version}) | from_entries) as $before
  | {
      status: (if $missing == [] then "ok" else "degraded" end),
      missingSources: $missing,
      fixed: (($gone | map(select(key as $k | $patched | index($k) | not)) | tiers)
              + {patch: ($gone | map(select(key as $k | $patched | index($k))) | ordered)}),
      new: ($b | map(select(key as $k | $akeys | index($k) | not)) | tiers),
      remaining: ($b | map(select(key as $k | $akeys | index($k))) | tiers),
      kernel: {from: ($from.cves | map(select(kernel)) | length),
               to: ($to.cves | map(select(kernel)) | length)},
      bumps: [$to.important[] | select($before[.name] != null and $before[.name] != .version)
              | {name, from: $before[.name], to: .version}] | sort_by(.name)
    }
end
