# shellcheck shell=bash
# tabularium: records what is deployed where, from the deploying machine.

usage() {
  cat >&2 <<'USAGE'
usage: tabularium record <host> [--allow-dirty] -- <command...>
       tabularium last <host>
       tabularium freshness
       tabularium sbom <host> [--build]
USAGE
  exit 64
}

# What the deploy was built from: HEAD plus any tracked change on top of it.
tree_state() {
  git rev-parse HEAD
  git diff --binary HEAD | sha256sum
}

store() {
  printf '%s/%s' "${TABULARIUM_STORE:-$HOME/.tabularium}" "$(basename "$(git rev-parse --show-toplevel)")"
}

# Written aside then hard-linked: the file appears whole or not at all, and ln
# refuses to replace one written meanwhile.
write_new() {
  local dir tmp
  dir=$(dirname "$1")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.new.XXXXXX")
  cat >"$tmp"
  if ! ln "$tmp" "$1" 2>/dev/null; then
    rm -f "$tmp"
    echo "tabularium: $1 already exists" >&2
    exit 3
  fi
  rm -f "$tmp"
}

record() {
  local host="${1:-}" allow_dirty=false
  [ -n "$host" ] && [ "$host" != "--" ] || usage
  shift
  if [ "${1:-}" = "--allow-dirty" ]; then
    allow_dirty=true
    shift
  fi
  [ "${1:-}" = "--" ] || usage
  shift
  [ "$#" -gt 0 ] || usage

  cd "$(git rev-parse --show-toplevel)"

  local dirty=false
  if ! git diff --quiet HEAD; then
    dirty=true
    if [ "$allow_dirty" = false ]; then
      echo "tabularium: working tree is dirty, refusing to deploy (use --allow-dirty to record it as dirty)" >&2
      exit 2
    fi
  fi

  local commit ts dir file
  commit=$(git rev-parse HEAD)
  ts="${TABULARIUM_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
  dir="$(store)/deployments/$host"
  file="$dir/$ts.json"
  if [ -e "$file" ]; then
    echo "tabularium: $file already exists" >&2
    exit 3
  fi

  # Evaluated before the deploy: an unknown host fails here, not after a
  # successful deploy, and the out path matches the recorded commit.
  local out_path before
  out_path=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.outPath")
  before=$(tree_state)

  # The deploy command keeps the terminal: sudo prompts must reach the user.
  local code=0
  "$@" || code=$?
  [ "$code" -eq 0 ] || exit "$code"

  if [ "$(tree_state)" != "$before" ]; then
    echo "tabularium: the tree changed during the deploy, $out_path cannot be tied to $commit; not recorded" >&2
    exit 4
  fi

  local nar_hash sha256
  nar_hash=$(nix path-info --json --json-format 2 "$out_path" | jq -r --arg p "${out_path#/nix/store/}" '.info[$p].narHash')
  sha256=$(printf '%s' "${nar_hash#sha256-}" | base64 -d | od -An -tx1 | tr -d ' \n')

  local json
  json=$(jq -n \
    --arg path "$out_path" --arg sha256 "$sha256" \
    --arg host "$host" --arg repo "$(basename "$PWD")" --arg commit "$commit" \
    --argjson dirty "$dirty" \
    --arg at "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" \
    '{
      "_type": "https://in-toto.io/Statement/v1",
      subject: [{name: $path, digest: {sha256: $sha256}}],
      predicateType: "https://github.com/gfriloux/tabularium/predicates/deployment/v0.1",
      predicate: {
        host: $host, repository: $repo, gitCommit: $commit,
        dirty: $dirty, deployedAt: $at, command: $ARGS.positional
      }
    }' --args -- "$@")
  printf '%s\n' "$json" | write_new "$file"
}

# Newest record of <host>, or nothing. Timestamps in file names sort lexically.
latest_record() {
  local dir
  dir="$(store)/deployments/$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.json' | sort | tail -n 1
}

last() {
  local host="${1:-}" latest
  [ -n "$host" ] || usage
  latest=$(latest_record "$host")
  if [ -z "$latest" ]; then
    echo "tabularium: no deployment recorded for $host" >&2
    exit 1
  fi
  if ! jq -er '.predicate | [.gitCommit, .deployedAt] + (if .dirty then ["dirty"] else [] end) | join(" ")' "$latest"; then
    echo "tabularium: $latest is not a valid record" >&2
    exit 1
  fi
}

gh_api() {
  local headers='Accept: application/vnd.github+json'
  # Headers on stdin keep the token out of the process list.
  [ -z "${GITHUB_TOKEN:-}" ] || headers+=$'\n'"Authorization: Bearer $GITHUB_TOKEN"
  printf '%s\n' "$headers" | curl -fsS --max-time 30 -H @- "https://api.github.com/$1"
}

# Lag of <to> behind <from>: commits from the API, else status from the dates alone.
lag() {
  if [ "$1" = "$3" ]; then
    echo '{"status":"up-to-date","days":0,"commits":0}'
    return
  fi
  local days json
  days=$((($4 - $2) / 86400))
  days=${days#-}
  if json=$(gh_api "repos/NixOS/nixpkgs/compare/$1...$3") &&
    jq -ce --argjson days "$days" '
      {ahead: "behind", behind: "ahead", identical: "up-to-date", diverged: "diverged"}[.status] as $s
      | select($s)
      | {status: $s, days: $days,
         commits: {ahead: .ahead_by, behind: .behind_by, identical: 0, diverged: .ahead_by}[.status]}' <<<"$json"; then
    return
  fi
  local status=behind
  [ "$4" -ge "$2" ] || status=ahead
  jq -nc --arg s "$status" --argjson days "$days" '{status: $s, days: $days, commits: null}'
}

# name, rev, lastModified, ref of each root input locked on github:nixos/nixpkgs.
nixpkgs_inputs() {
  git cat-file -e "$1:flake.lock" 2>/dev/null || return 0
  git show "$1:flake.lock" | jq -r '
    .nodes as $n
    | $n[.root].inputs // {} | to_entries[]
    | select(.value | type == "string")
    | .key as $k | $n[.value] as $node
    | select($node.locked.type == "github"
        and ($node.locked.owner | ascii_downcase) == "nixos"
        and $node.locked.repo == "nixpkgs")
    | [$k, $node.locked.rev, $node.locked.lastModified, $node.original.ref // ""] | @tsv'
}

freshness() {
  [ "$#" -eq 0 ] || usage
  cd "$(git rev-parse --show-toplevel)"

  local main
  if ! main=$(git rev-parse -q --verify 'refs/heads/main^{commit}'); then
    echo "tabularium: no main branch" >&2
    exit 1
  fi
  if ! git cat-file -e "$main:flake.lock" 2>/dev/null; then
    echo "tabularium: no flake.lock on main" >&2
    exit 1
  fi

  local ts file list refs
  ts="${TABULARIUM_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
  file="$(store)/freshness/$ts.json"
  list=$(nixpkgs_inputs "$main")
  # Upstream heads, and the release branches among them.
  refs=$(gh_api repos/NixOS/nixpkgs/git/matching-refs/heads/nixos-) || refs='[]'

  local releases
  releases=$(jq -c '[.[].ref | ltrimstr("refs/heads/") | select(test("^nixos-[0-9]{2}\\.[0-9]{2}$"))] | sort' <<<"$refs") || releases='[]'

  local inputs='{}' name rev modified branch head head_at json upstream release
  while IFS=$'\t' read -r name rev modified branch; do
    [ -n "$name" ] || continue
    upstream='{"rev":null,"status":"unavailable","days":null,"commits":null}'
    head=""
    release=$(jq -c --arg b "$branch" '
      if length > 0 and index($b) != null
      then {currentStable: .[-1], releasesBehind: (length - 1 - index($b))} else null end' <<<"$releases")
    if [ -n "$branch" ]; then
      head=$(jq -r --arg r "refs/heads/$branch" '.[] | select(.ref == $r) | .object.sha' <<<"$refs") || head=""
    fi
    if [ -n "$head" ]; then
      upstream=$(jq -nc --arg rev "$head" '{rev: $rev, status: "unavailable", days: null, commits: null}')
      if json=$(gh_api "repos/NixOS/nixpkgs/commits/$head") &&
        head_at=$(jq -er '.commit.committer.date | fromdateiso8601' <<<"$json"); then
        upstream=$(lag "$rev" "$modified" "$head" "$head_at" | jq -c --arg rev "$head" '{rev: $rev} + .')
      fi
    fi
    inputs=$(jq -c --arg n "$name" --arg branch "$branch" --arg rev "$rev" \
      --argjson modified "$modified" --argjson upstream "$upstream" --argjson release "$release" '
      .[$n] = {branch: (if $branch == "" then null else $branch end), rev: $rev,
               lastModified: $modified, release: $release, upstream: $upstream}' <<<"$inputs")
  done <<<"$list"

  local hosts='{}' names host record commit deployed host_inputs dname drev dmodified dbranch key
  local -A lags=()
  names=$(nix eval --json "git+file://$PWD?rev=$main#nixosConfigurations" --apply builtins.attrNames |
    jq -r '.[]') || names=""
  while read -r host; do
    [ -n "$host" ] || continue
    record=$(latest_record "$host")
    if [ -z "$record" ]; then
      hosts=$(jq -c --arg h "$host" '.[$h] = {status: "never-recorded"}' <<<"$hosts")
      continue
    fi
    commit=$(jq -r '.predicate.gitCommit // ""' "$record") || commit=""
    deployed=""
    [ -z "$commit" ] || deployed=$(nixpkgs_inputs "$commit")
    host_inputs='{}'
    while IFS=$'\t' read -r name rev modified branch; do
      [ -n "$name" ] || continue
      json='{"rev":null,"status":"unavailable","days":null,"commits":null}'
      while IFS=$'\t' read -r dname drev dmodified dbranch; do
        [ "$dname" = "$name" ] || continue
        if [ "$dbranch" != "$branch" ]; then
          json='{"status":"branch-changed","days":null,"commits":null}'
        else
          key="$drev...$rev"
          [ -n "${lags[$key]:-}" ] || lags[$key]=$(lag "$drev" "$dmodified" "$rev" "$modified")
          json=${lags[$key]}
        fi
        json=$(jq -c --arg rev "$drev" '{rev: $rev} + .' <<<"$json")
      done <<<"$deployed"
      host_inputs=$(jq -c --arg n "$name" --argjson lag "$json" '.[$n] = $lag' <<<"$host_inputs")
    done <<<"$list"
    hosts=$(jq -c --arg h "$host" --slurpfile r "$record" --argjson inputs "$host_inputs" '
      .[$h] = ($r[0].predicate | {status: "recorded", deployedCommit: .gitCommit,
        deployedAt: .deployedAt, dirty: .dirty, inputs: $inputs})' <<<"$hosts")
  done <<<"$names"

  local statement
  statement=$(jq -n \
    --arg blob "$(git rev-parse "$main:flake.lock")" --arg repo "$(basename "$PWD")" \
    --arg main "$main" --argjson inputs "$inputs" --argjson hosts "$hosts" \
    --arg at "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" \
    '{
      "_type": "https://in-toto.io/Statement/v1",
      subject: [{name: "flake.lock", digest: {gitBlob: $blob}}],
      predicateType: "https://github.com/gfriloux/tabularium/predicates/freshness/v0.1",
      predicate: {
        repository: $repo, mainCommit: $main, generatedAt: $at,
        inputs: $inputs, hosts: $hosts
      }
    }')
  printf '%s\n' "$statement" | write_new "$file"

  jq -r '
    def lag: if .status == "unavailable" or .status == "branch-changed" then .status
      else "\(.status) \(.days // "?")d \(.commits // "?")c" end;
    # Columns padded to their widest cell.
    def table: (transpose | map(map(length) | max + 2)) as $w
      | .[] | [range(length) as $i
          | if $i == length - 1 then .[$i] else .[$i] + " " * ($w[$i] - (.[$i] | length)) end]
      | join("");
    ([["input", "branch", "release", "main→upstream"]]
      + (.predicate.inputs | to_entries | map([.key, .value.branch // "-",
          (.value.release | if . then "\(.releasesBehind) behind (\(.currentStable))" else "-" end),
          (.value.upstream | lag)]))
      | table),
    (.predicate.hosts | select(. != {}) | "",
      ([["host", "input", "deployed→main"]]
        + (to_entries | map(.key as $h | .value
            | if .status == "never-recorded" then [[$h, "-", "never recorded"]]
              else (if .dirty then " dirty" else "" end) as $d
                | .inputs | to_entries | map([$h, .key, (.value | lag) + $d]) end)
          | add // [])
        | table))' <<<"$statement"
  echo
  echo "export: $file"
}

sbom_summary() {
  jq -r '.components // [] | (map(.purl // "" | select(. != "")) | length) as $purl
    | (map(.cpe // "" | select(. != "")) | length) as $cpe
    | (map(.licenses // [] | select(length > 0)) | length) as $licenses
    | "components: \(length)", "purl: \($purl)", "cpe: \($cpe)", "licenses: \($licenses)"' "$1"
  echo
  echo "export: $1"
}

# CycloneDX SBOM (bombon) of the toplevel <host> was last deployed with.
sbom() {
  local host="${1:-}" build=false
  [ -n "$host" ] || usage
  shift
  if [ "${1:-}" = "--build" ]; then
    build=true
    shift
  fi
  [ "$#" -eq 0 ] || usage

  cd "$(git rev-parse --show-toplevel)"

  local latest fields commit subject dirty file toplevel bom
  latest=$(latest_record "$host")
  if [ -z "$latest" ]; then
    echo "tabularium: no deployment recorded for $host" >&2
    exit 1
  fi
  if ! fields=$(jq -r '[.predicate.gitCommit, .subject[0].name, .predicate.dirty]
      | if map(type) == ["string", "string", "boolean"] then @tsv else error end' "$latest" 2>/dev/null) ||
    [ -z "$fields" ]; then
    echo "tabularium: $latest is not a valid record" >&2
    exit 1
  fi
  IFS=$'\t' read -r commit subject dirty <<<"$fields"

  # Keyed by commit: a clean commit always describes the same toplevel.
  file="$(store)/sbom/$host/$commit.cdx.json"
  if [ -e "$file" ]; then
    sbom_summary "$file"
    return
  fi

  if [ "$dirty" != false ]; then
    echo "tabularium: $host was deployed from a dirty tree, its commit does not describe it" >&2
    exit 2
  fi
  if ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "tabularium: commit $commit is not in this clone" >&2
    exit 1
  fi
  toplevel=$(nix eval --raw "git+file://$PWD?rev=$commit#nixosConfigurations.$host.config.system.build.toplevel.outPath")
  if [ "$toplevel" != "$subject" ]; then
    echo "tabularium: $host at $commit evaluates to $toplevel, the record says $subject" >&2
    exit 5
  fi
  # bombon reads the runtime closure: a missing toplevel means building the host.
  if [ "$build" = false ] && ! nix path-info --json --json-format 2 "$subject" >/dev/null 2>&1; then
    echo "tabularium: $subject is not in the local store; rerun with --build to build it" >&2
    exit 6
  fi

  bom=$(nix build --no-link --print-out-paths --impure --file "$TABULARIUM_SBOM_NIX" \
    --argstr repo "$PWD" --argstr rev "$commit" --argstr host "$host" \
    --argstr nixpkgs "$TABULARIUM_NIXPKGS" --argstr bombon "$TABULARIUM_BOMBON")
  write_new "$file" <"$bom"
  sbom_summary "$file"
}

case "${1:-}" in
  last)
    shift
    last "$@"
    ;;
  record)
    shift
    record "$@"
    ;;
  freshness)
    shift
    freshness "$@"
    ;;
  sbom)
    shift
    sbom "$@"
    ;;
  *) usage ;;
esac
