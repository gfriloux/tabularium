# Fleet status from the stored exports. Input: status_input's document.
# Run as: jq -r -L <src/jq> --arg host <name or ""> -f status.jq

def day: if . == null then null else .[0:10] end;
def minute: if . == null then null else .[0:10] + " " + .[11:16] end;
def table: (transpose | map(map(length) | max + 2)) as $w
  | .[] | [range(length) as $i
      | if $i == length - 1 then .[$i] else .[$i] + " " * ($w[$i] - (.[$i] | length)) end]
  | join("");
# Date of the nixpkgs a toplevel was built from: …-26.11.20261020.02c087f.
def nixpkgs_date: [capture("\\.(?<d>[0-9]{8})\\.[0-9a-f]+$")] | first.d // null
  | if . then "\(.[0:4])-\(.[4:6])-\(.[6:8])" else "?" end;
def lag: if . == null then "?"
  elif .status == "behind" then "\(.days // "?") d, \(.commits // "?") c"
  elif .status == "ahead" then "ahead \(.days // "?") d, \(.commits // "?") c"
  else .status // "?" end;
def fixed_count: [.fixed[] | length] | add // 0;
def fixed_text: if . == null or .status == "unavailable" then "?" else
  fixed_count as $n
  | ([("solid", "triage", "patch") as $k | (.fixed[$k] // []) | length | select(. > 0) | "\(.) \($k)"]
      | join(", ")) as $split
  | "\($n)" + (if $n > 0 then " (\($split))" else "" end)
    + (if .status == "degraded" then " [degraded]" else "" end)
    + (if (.uncertain // []) | length > 0 then " [+\(.uncertain | length) uncertain]" else "" end)
  end;
def by_severity: sort_by([-(.severity | tonumber? // 0), .id]);
def cve_line: "  \(.severity)  \(.id)  \(.package) \(.version)";

. as $in
| $in.main as $main
| $in.freshness.predicate as $f
| def moved($commit): $main != null and $commit != null and $commit != $main;
  # Facts about one host, shared by both views.
  def facts($h):
    $in.hosts[$h] as $x
    | $x.record.predicate as $r
    | $x.record.subject[0].name as $s
    | $x.cve.predicate as $c
    | {name: $h, record: $r, subject: $s, cve: $c,
       stale: ($c != null and $r != null and $c.states.deployed.toplevel != $s)};
  def row:
    . as $h
    | [ .name,
        (.record.deployedAt | day // "never"),
        (if .record == null then "-" else (.subject // "" | nixpkgs_date) end),
        (if .record == null then "-"
         elif $f == null or $f.hosts[$h.name] == null then "?"
         elif ($f.generatedAt // "") < .record.deployedAt then "stale"
         else $f.hosts[$h.name].inputs.nixpkgs | lag end),
        (if .cve == null then "?" elif .stale then "stale (redeployed since)"
         else .cve.comparisons.deploy | fixed_text end),
        (if .cve == null then "?" elif .stale then "-" else .cve.comparisons.update | fixed_text end),
        (if .cve == null then "never"
         else (.cve.generatedAt | minute // "?")
           + (if moved(.cve.mainCommit) then " [main moved since scan]" else "" end) end) ];

if $host == "" then
  ([["host", "deployed", "nixpkgs", "behind main", "CVE fixed by deploy", "by update", "scanned"]]
    + [$in.hosts | keys[] | facts(.) | row] | table),
  "",
  (if $f == null then "nixpkgs (main → upstream): ? (no freshness export)"
   else ($f.inputs // {}) | to_entries[]
     | "\(.key) (main → upstream): "
       + (if .value.upstream.status == "behind" then "behind " else "" end) + (.value.upstream | lag)
       + " (\(.value.branch // "?"), checked \($f.generatedAt | minute // "?"))"
       + (if moved($f.mainCommit) then " [main moved since]" else "" end)
   end),
  ($in.hosts | keys[] | facts(.)
    | select(.cve != null and (.stale | not) and .cve.comparisons.deploy.status != "unavailable")
    | .name as $name
    | [.cve.comparisons.deploy.fixed[][]] | by_severity
    | select(length > 0)
    | "", "\($name), fixed by deploy:", (.[0:5][] | cve_line),
      (if length > 5 then "  … \(length - 5) more (tabularium status \($name))" else empty end))
else
  empty
end
