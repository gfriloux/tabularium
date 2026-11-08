# Lines shared by `cve` and `status <host>`: one summary line per comparison,
# optionally the fixed CVEs by tier, then the bumps of important packages.

def report_cve_line: "    \(.severity)  \(.id)  \(.package) \(.version)";

def comparison_lines($states; $comparisons; $detail):
  def line($label):
    if .status == "unavailable" then "\($label): unavailable (\(.why))"
    else "\($label): fixed \([.fixed[] | length] | add) (solid \(.fixed.solid | length), triage \(.fixed.triage | length), patch \(.fixed.patch | length)), new \(.new.solid + .new.triage | length), remaining \(.remaining.solid + .remaining.triage | length), kernel \(.kernel.from) → \(.kernel.to)"
      + (if .status == "degraded" then " [degraded: \(.missingSources | join(", "))]" else "" end)
    end;
  [["deploy", "deployed", "main"], ["update", "main", "update"]][]
  | . as [$c, $from, $to]
  | select($comparisons[$c])
  | $comparisons[$c]
    + {why: ([$from, $to] | map(select($states[.].status != "scanned") | "\(.): \($states[.].reason)") | join(", "))}
  | line("\($from) → \($to)"),
    (select(.status != "unavailable")
      | (if $detail then
           (("solid", "triage", "patch") as $k | (.fixed[$k] // []) | select(length > 0)
             | "  fixed, \($k):", (sort_by([-(.severity | tonumber? // 0), .id])[] | report_cve_line)),
           ((.uncertain // []) | select(length > 0) | "  uncertain:", (.[] | report_cve_line))
         else empty end),
        (if .bumps == null then "bumps \($from) → \($to): unknown"
         elif .bumps == [] then "bumps \($from) → \($to): none"
         else "bumps \($from) → \($to):", (.bumps[] | "  \(.name) \(.from) → \(.to)") end));
