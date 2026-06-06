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
  --out <dir>       Output base directory (default: .cv-data); files are written
                    under <out>/<org>/

Produces:
  authored-all -> <out>/<org>/prs-authored.json   (any-state PRs the author opened)
  reviewed     -> <out>/<org>/prs-reviewed.json    (author's merged PRs + PRs they reviewed)
USAGE
}

AUTHOR="" ORG="" MODE="" OUT=".cv-data"

# require_value FLAG VALUE — error out if VALUE is missing or looks like a flag
require_value() {
  if [[ -z "${2}" || "${2}" == -* ]]; then
    echo "Error: ${1} requires a value." >&2
    usage; exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --author) require_value "${1}" "${2:-}"; AUTHOR="${2}"; shift 2 ;;
    --org)    require_value "${1}" "${2:-}"; ORG="${2}"; shift 2 ;;
    --mode)   require_value "${1}" "${2:-}"; MODE="${2}"; shift 2 ;;
    --out)    require_value "${1}" "${2:-}"; OUT="${2}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: ${1}" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${AUTHOR}" || -z "${ORG}" ]]; then
  echo "Error: --author and --org are required." >&2
  usage; exit 2
fi

if [[ -n "${MODE}" && "${MODE}" != "authored-all" && "${MODE}" != "reviewed" ]]; then
  echo "Error: --mode must be 'authored-all' or 'reviewed'." >&2
  exit 2
fi

# fetch_search QUERY_STRING
# Pages a GraphQL `search(type: ISSUE)` over QUERY_STRING and prints a JSON array
# of PR nodes (with diffstat, labels, files, commits). Rate-limit aware.
fetch_search() {
  local query="${1}"
  local cursor="null"
  local has_next="true"
  local all="[]"

  # $q / $after are GraphQL variables, not shell — they must stay literal.
  # shellcheck disable=SC2016
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

  while [[ "${has_next}" == "true" ]]; do
    local resp
    if ! resp=$(gh api graphql -f query="${gql}" -f q="${query}" \
                  -F after="${cursor}" 2>/tmp/fetch_prs_err); then
      if grep -qiE 'rate limit|secondary' /tmp/fetch_prs_err; then
        echo "Rate limited; sleeping 60s then retrying..." >&2
        sleep 60
        continue
      fi
      cat /tmp/fetch_prs_err >&2
      return 1
    fi

    # gh api graphql exits 0 even when GitHub returns a 200 body carrying
    # `errors` (secondary rate limits surface this way). Catch that here so we
    # retry instead of silently collecting an empty/partial result.
    if jq -e '.errors' <<<"${resp}" >/dev/null 2>&1; then
      if jq -e '.errors[] | select(.type == "RATE_LIMITED")' <<<"${resp}" >/dev/null 2>&1; then
        echo "Rate limited (GraphQL); sleeping 60s then retrying..." >&2
        sleep 60
        continue
      fi
      jq -r '.errors[].message' <<<"${resp}" >&2
      return 1
    fi

    local nodes
    nodes=$(jq '.data.search.nodes' <<<"${resp}")
    all=$(jq -s '.[0] + .[1]' <(echo "${all}") <(echo "${nodes}"))

    has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"${resp}")
    cursor=$(jq -r '.data.search.pageInfo.endCursor' <<<"${resp}")
    [[ "${cursor}" == "null" ]] && break
  done

  echo "${all}"
}

# write_dataset MODE QUERY OUTFILE
# Fetches, normalizes to the flat per-PR schema, and writes the wrapped JSON.
write_dataset() {
  local mode="${1}" query="${2}" outfile="${3}"
  echo "Fetching mode=${mode} ..." >&2

  local raw normalized
  raw=$(fetch_search "${query}")

  normalized=$(jq '[ .[] | {
    number, title, body, url, state,
    repository: .repository.nameWithOwner,
    createdAt, mergedAt, closedAt,
    labels: [ .labels.nodes[].name ],
    additions, deletions, changedFiles,
    files:   [ .files.nodes[]   | {name: .path, additions, deletions} ],
    commits: [ .commits.nodes[] | {message: .commit.message} ]
  } ]' <<<"${raw}")

  local generated_at
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --arg generated_at "${generated_at}" \
    --arg mode "${mode}" \
    --arg author "${AUTHOR}" \
    --arg org "${ORG}" \
    --argjson prs "${normalized}" \
    '{generated_at: $generated_at, mode: $mode, author: $author, org: $org,
      pr_count: ($prs | length), prs: $prs}' > "${outfile}"

  local count
  count=$(jq '.pr_count' "${outfile}")
  echo "Wrote ${count} PRs -> ${outfile}" >&2
}

OUTDIR="${OUT}/${ORG}"
mkdir -p "${OUTDIR}"

run_authored() {
  write_dataset "authored-all" "is:pr author:${AUTHOR} org:${ORG}" "${OUTDIR}/prs-authored.json"
}
run_reviewed() {
  write_dataset "reviewed" "is:pr org:${ORG} ( author:${AUTHOR} is:merged OR reviewed-by:${AUTHOR} )" "${OUTDIR}/prs-reviewed.json"
}

case "${MODE}" in
  authored-all) run_authored ;;
  reviewed)     run_reviewed ;;
  "")           run_authored; run_reviewed ;;
  *)            echo "Error: unhandled mode '${MODE}'." >&2; exit 2 ;;
esac
