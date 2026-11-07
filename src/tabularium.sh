# shellcheck shell=bash
# tabularium: records what is deployed where, from the deploying machine.

usage() {
  cat >&2 <<'USAGE'
usage: tabularium record <host> [--allow-dirty] -- <command...>
       tabularium last <host>
USAGE
  exit 64
}

store() {
  printf '%s/%s' "${TABULARIUM_STORE:-$HOME/.tabularium}" "$(basename "$(git rev-parse --show-toplevel)")"
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

  # The deploy command keeps the terminal: sudo prompts must reach the user.
  local code=0
  "$@" || code=$?
  [ "$code" -eq 0 ] || exit "$code"

  local out_path nar_hash sha256
  out_path=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.outPath")
  nar_hash=$(nix path-info --json --json-format 2 "$out_path" | jq -r --arg p "${out_path#/nix/store/}" '.info[$p].narHash')
  sha256=$(printf '%s' "${nar_hash#sha256-}" | base64 -d | od -An -tx1 | tr -d ' \n')

  mkdir -p "$dir"
  set -o noclobber
  jq -n \
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
    }' --args "$@" >"$file"
}

last() {
  local host="${1:-}" dir latest=""
  [ -n "$host" ] || usage
  dir="$(store)/deployments/$host"
  # Timestamps in file names sort lexically.
  if [ -d "$dir" ]; then
    latest=$(find "$dir" -maxdepth 1 -name '*.json' | sort | tail -n 1)
  fi
  if [ -z "$latest" ]; then
    echo "tabularium: no deployment recorded for $host" >&2
    exit 1
  fi
  jq -r '.predicate | [.gitCommit, .deployedAt] + (if .dirty then ["dirty"] else [] end) | join(" ")' "$latest"
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
  *) usage ;;
esac
