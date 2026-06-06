#!/usr/bin/env bash
# Fetch a GitHub user's PR activity in an org into structured JSON for CV bullet generation.
# Mechanical only: no analysis, no second model, no full diffs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: fetch-prs.sh --author <user> --org <org> [--mode authored-all|reviewed] [--out <dir>]

  --author <user>   GitHub username to fetch PRs for (required)
  --org <org>       GitHub org/owner to scope the search to (required)
  --mode <mode>     authored-all | reviewed. Omit to produce BOTH datasets.
  --out <dir>       Output directory (default: .cv-data)

Produces:
  authored-all -> <out>/prs-authored.json   (any-state PRs the author opened)
  reviewed     -> <out>/prs-reviewed.json    (author's merged PRs + PRs they reviewed)
USAGE
}

AUTHOR="" ORG="" MODE="" OUT=".cv-data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --org)    ORG="${2:-}"; shift 2 ;;
    --mode)   MODE="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$AUTHOR" || -z "$ORG" ]]; then
  echo "Error: --author and --org are required." >&2
  usage; exit 2
fi

if [[ -n "$MODE" && "$MODE" != "authored-all" && "$MODE" != "reviewed" ]]; then
  echo "Error: --mode must be 'authored-all' or 'reviewed'." >&2
  exit 2
fi

mkdir -p "$OUT"
echo "stub: author=$AUTHOR org=$ORG mode=${MODE:-both} out=$OUT" >&2
