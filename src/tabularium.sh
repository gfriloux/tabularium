# shellcheck shell=bash
# tabularium: records what is deployed where, from the deploying machine.

usage() {
  cat >&2 <<'USAGE'
usage: tabularium record <host> [--allow-dirty] -- <command...>
       tabularium last <host>
USAGE
  exit 64
}

case "${1:-}" in
  *) usage ;;
esac
