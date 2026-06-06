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

# Max consecutive sleep-and-retry attempts (rate limits or transient errors)
# before giving up. 5 covers a few back-to-back secondary-rate-limit windows
# (~5 min of 60s sleeps) without hanging indefinitely; raise it for very large
# orgs that rate-limit harder.
MAX_RETRIES=5
# GitHub's search API hard-caps any query at 1000 returned results.
SEARCH_RESULT_CAP=1000

# fetch_search QUERY_STRING
# Pages a GraphQL `search(type: ISSUE)` over QUERY_STRING and prints a JSON array
# of PR nodes (with diffstat, labels, files, commits). Rate-limit aware. Warns
# (on stderr) if the result set hits GitHub's 1000-result search cap.
fetch_search() {
  local query="${1}"
  local cursor="null"
  local has_next="true"
  local all="[]"
  local retries=0
  local issue_count=0

  # Per-call stderr capture; cleaned up on return, unique per process/run.
  local errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/fetch_prs_err.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '${errfile}'" RETURN

  # $q / $after are GraphQL variables, not shell — they must stay literal.
  # shellcheck disable=SC2016
  local gql='
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 50, after: $after) {
        issueCount
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
                  -F after="${cursor}" 2>"${errfile}"); then
      if grep -qiE 'rate limit|secondary' "${errfile}"; then
        if (( ++retries > MAX_RETRIES )); then
          echo "Error: gave up after ${MAX_RETRIES} rate-limit retries; try again later." >&2
          return 1
        fi
        echo "Rate limited; sleeping 60s then retrying (${retries}/${MAX_RETRIES})..." >&2
        sleep 60
        continue
      fi
      # Non-rate-limit failures (502, network blips) are often transient too;
      # retry up to the cap rather than aborting the whole fetch immediately.
      if (( ++retries > MAX_RETRIES )); then
        cat "${errfile}" >&2
        echo "Error: gave up after ${MAX_RETRIES} retries." >&2
        return 1
      fi
      echo "Request failed; sleeping 5s then retrying (${retries}/${MAX_RETRIES})..." >&2
      cat "${errfile}" >&2
      sleep 5
      continue
    fi

    # gh api graphql exits 0 even when GitHub returns a 200 body carrying
    # `errors` (secondary rate limits surface this way). Catch that here so we
    # retry instead of silently collecting an empty/partial result.
    if jq -e '.errors' <<<"${resp}" >/dev/null 2>&1; then
      if jq -e '.errors[] | select(.type == "RATE_LIMITED")' <<<"${resp}" >/dev/null 2>&1; then
        if (( ++retries > MAX_RETRIES )); then
          echo "Error: gave up after ${MAX_RETRIES} rate-limit retries; try again later." >&2
          return 1
        fi
        echo "Rate limited (GraphQL); sleeping 60s then retrying (${retries}/${MAX_RETRIES})..." >&2
        sleep 60
        continue
      fi
      jq -r '.errors[].message' <<<"${resp}" >&2
      return 1
    fi

    # A 200 body with no `errors` can still lack `.data.search` (malformed/partial).
    # Default missing nodes to [] so a bad page surfaces instead of silently
    # dropping data, and record issueCount to detect the 1000-result cap.
    retries=0
    issue_count=$(jq -r '.data.search.issueCount // 0' <<<"${resp}")

    local nodes merged
    nodes=$(jq '.data.search.nodes // []' <<<"${resp}")
    if ! merged=$(jq -s '.[0] + .[1]' <(printf '%s' "${all}") <(printf '%s' "${nodes}")); then
      echo "Error: failed to merge page into accumulator." >&2
      return 1
    fi
    all="${merged}"

    has_next=$(jq -r '.data.search.pageInfo.hasNextPage' <<<"${resp}")
    cursor=$(jq -r '.data.search.pageInfo.endCursor' <<<"${resp}")
    # An empty/null endCursor while hasNextPage is still true is an API anomaly:
    # surface it rather than silently re-paging from the start or truncating.
    if [[ "${has_next}" == "true" && ( -z "${cursor}" || "${cursor}" == "null" ) ]]; then
      echo "Error: API reported more pages but returned no cursor; aborting to avoid partial data." >&2
      return 1
    fi
  done

  # GitHub caps search at 1000 results: a larger match set is silently truncated.
  if (( issue_count >= SEARCH_RESULT_CAP )); then
    local collected
    collected=$(jq 'length' <<<"${all}")
    echo "Warning: query matched ${issue_count} results but GitHub search caps at ${SEARCH_RESULT_CAP}; collected ${collected}. Dataset is INCOMPLETE — narrow the query (e.g. by date range)." >&2
  fi

  echo "${all}"
}

# write_dataset MODE OUTFILE QUERY...
# Fetches each QUERY, concatenates the raw node sets, de-duplicates by PR url
# (a PR can match more than one query), normalizes to the flat per-PR schema,
# and writes the wrapped JSON.
write_dataset() {
  local mode="${1}" outfile="${2}"
  shift 2
  echo "Fetching mode=${mode} ..." >&2

  local raw="[]" query page merged
  for query in "$@"; do
    page=$(fetch_search "${query}")
    if ! merged=$(jq -s '.[0] + .[1]' <(printf '%s' "${raw}") <(printf '%s' "${page}")); then
      echo "Error: failed to merge query results." >&2
      return 1
    fi
    raw="${merged}"
  done

  # Dedupe by url: union queries (e.g. authored+reviewed) can return the same PR.
  raw=$(jq 'unique_by(.url)' <<<"${raw}")

  # `// empty`/`// []` defaults so a node missing an expected field can't make
  # jq throw and silently abort the dataset.
  local normalized
  if ! normalized=$(jq '[ .[] | {
    number, title, body, url, state,
    repository: (.repository.nameWithOwner // null),
    createdAt, mergedAt, closedAt,
    labels: [ (.labels.nodes // [])[].name ],
    additions, deletions, changedFiles,
    files:   [ (.files.nodes   // [])[] | {name: .path, additions, deletions} ],
    commits: [ (.commits.nodes // [])[] | {message: .commit.message} ]
  } ]' <<<"${raw}"); then
    echo "Error: failed to normalize PR data." >&2
    return 1
  fi

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
  write_dataset "authored-all" "${OUTDIR}/prs-authored.json" \
    "is:pr author:${AUTHOR} org:${ORG}"
}
run_reviewed() {
  # GitHub PR search has no parenthesized OR grouping, so the union of
  # "author's merged PRs" and "PRs they reviewed" is two separate searches,
  # merged and de-duplicated by write_dataset.
  write_dataset "reviewed" "${OUTDIR}/prs-reviewed.json" \
    "is:pr org:${ORG} author:${AUTHOR} is:merged" \
    "is:pr org:${ORG} reviewed-by:${AUTHOR}"
}

case "${MODE}" in
  authored-all) run_authored ;;
  reviewed)     run_reviewed ;;
  "")           run_authored; run_reviewed ;;
  *)            echo "Error: unhandled mode '${MODE}'." >&2; exit 2 ;;
esac
