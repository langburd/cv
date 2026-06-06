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

# fetch_search QUERY_STRING
# Pages a GraphQL `search(type: ISSUE)` over QUERY_STRING and prints a JSON array
# of PR nodes (with diffstat, labels, files, commits). Rate-limit aware.
fetch_search() {
  local query="$1"
  local cursor="null"
  local has_next="true"
  local all="[]"

  local gql='
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number title body url state
            createdAt mergedAt closedAt
            additions deletions changedFiles
            repository { nameWithOwner }
            labels(first: 20) { nodes { name } }
            files(first: 100) { nodes { path additions deletions } }
            commits(first: 100) { nodes { commit { message } } }
          }
        }
      }
    }'

  while [[ "$has_next" == "true" ]]; do
    local resp
    if ! resp=$(gh api graphql -f query="$gql" -f q="$query" \
                  -F after="$cursor" 2>/tmp/fetch_prs_err); then
      if grep -qiE 'rate limit|secondary' /tmp/fetch_prs_err; then
        echo "Rate limited; sleeping 60s then retrying..." >&2
        sleep 60
        continue
      fi
      cat /tmp/fetch_prs_err >&2
      return 1
    fi

    local nodes
    nodes=$(jq '.data.search.nodes' <<<"$resp")
    all=$(jq -s '.[0] + .[1]' <(echo "$all") <(echo "$nodes"))

    has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$resp")
    cursor=$(jq -r '.data.search.pageInfo.endCursor' <<<"$resp")
    [[ "$cursor" == "null" ]] && break
  done

  echo "$all"
}

mkdir -p "$OUT"
# TEMP smoke driver — remove in Task 4
fetch_search "is:pr author:$AUTHOR org:$ORG" | jq 'length'
