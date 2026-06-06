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
                    under <out>/<org>/<author>/

Produces:
  authored-all -> <out>/<org>/<author>/prs-authored.json   (any-state PRs the author opened)
  reviewed     -> <out>/<org>/<author>/prs-reviewed.json    (author's merged PRs + PRs they reviewed)
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
# Per-PR sub-connection page sizes (see the `files`/`commits` fields in $gql).
# A PR returning exactly this many is assumed truncated — the script does not
# page sub-connections, so larger PRs lose files/commits beyond these limits.
FILES_PAGE=100
COMMITS_PAGE=100
# Accumulates human-readable reasons a dataset is incomplete; reset per dataset
# in write_dataset, appended by fetch_search/fetch_windowed, stamped into the
# JSON wrapper.
INCOMPLETE_REASONS=()

# Earliest date to search from when partitioning a query into date windows.
# GitHub launched in 2008; nothing predates this. Windowing starts here and
# runs to "today" so no PR is missed at either end.
SEARCH_EPOCH_START="2008-01-01"

# --- portable UTC date helpers (macOS BSD date vs GNU date) ----------------
# Detected once: BSD `date -j` takes -f/-v flags; GNU `date` takes -d/@epoch.
if date -j -f "%Y-%m-%d %H:%M:%S" "2008-01-01 00:00:00" "+%s" >/dev/null 2>&1; then
  DATE_BACKEND="bsd"
elif date -u -d "2008-01-01 00:00:00 UTC" "+%s" >/dev/null 2>&1; then
  DATE_BACKEND="gnu"
else
  echo "Error: neither BSD nor GNU 'date' epoch conversion works on this system." >&2
  exit 3
fi

# date_to_epoch YYYY-MM-DD -> seconds since epoch at UTC midnight of that day.
date_to_epoch() {
  if [[ "${DATE_BACKEND}" == "bsd" ]]; then
    date -u -j -f "%Y-%m-%d %H:%M:%S" "${1} 00:00:00" "+%s"
  else
    date -u -d "${1} 00:00:00 UTC" "+%s"
  fi
}

# epoch_to_date SECONDS -> YYYY-MM-DD in UTC.
epoch_to_date() {
  if [[ "${DATE_BACKEND}" == "bsd" ]]; then
    date -u -j -f "%s" "${1}" "+%Y-%m-%d"
  else
    date -u -d "@${1}" "+%Y-%m-%d"
  fi
}

# Seconds in one day; used to step window boundaries so adjacent windows don't
# overlap (GitHub's created: range is inclusive on both ends).
SECS_PER_DAY=86400

# minus_one_year YYYY-MM-DD -> the same calendar date one year earlier (UTC).
# Calendar-correct (handles leap years), unlike subtracting a fixed 365 days.
minus_one_year() {
  if [[ "${DATE_BACKEND}" == "bsd" ]]; then
    date -u -j -v-1y -f "%Y-%m-%d" "${1}" "+%Y-%m-%d"
  else
    date -u -d "${1} -1 year" "+%Y-%m-%d"
  fi
}

# count_matches QUERY_STRING -> prints issueCount for QUERY_STRING.
# One cheap issueCount-only query (no node payload, no paging) used to decide
# whether a query needs date windowing at all. Rate-limit aware via a short
# retry loop. On persistent failure prints 0 — the caller reads that as "count
# unknown", which forces full windowing with NO early exit (the safe path:
# walk every year to 2008 rather than risk stopping short of a total we never
# learned).
count_matches() {
  local query="${1}"
  local retries=0 resp count
  # shellcheck disable=SC2016
  local gql='query($q: String!) { search(query: $q, type: ISSUE) { issueCount } }'
  while :; do
    if resp=$(gh api graphql -f query="${gql}" -f q="${query}" 2>/dev/null) \
       && count=$(jq -e -r '.data.search.issueCount' <<<"${resp}" 2>/dev/null); then
      printf '%s' "${count}"
      return 0
    fi
    if (( ++retries > MAX_RETRIES )); then
      echo "Warning: could not get a result count; windowing the full range with no early exit." >&2
      printf '%s' "0"
      return 0
    fi
    sleep 5
  done
}

# fetch_search QUERY_STRING [COUNT_FILE]
# Pages a GraphQL `search(type: ISSUE)` over QUERY_STRING and prints a JSON array
# of PR nodes (with diffstat, labels, files, commits) to stdout. Rate-limit
# aware. If COUNT_FILE is given, writes the matched issueCount to it so the
# windowing caller can detect the 1000-result cap — fetch_search runs inside a
# command-substitution subshell, so a global variable would not survive back to
# the caller; a file is how the count crosses that boundary. fetch_search does
# NOT itself flag the dataset incomplete.
fetch_search() {
  local query="${1}"
  local count_file="${2:-}"
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
    # First page: pass no `after` so GraphQL sees null. Passing -F after="null"
    # sends the *string* "null", which is an invalid cursor, not GraphQL null.
    local -a after_arg=()
    if [[ "${cursor}" != "null" ]]; then
      after_arg=(-F "after=${cursor}")
    fi
    if ! resp=$(gh api graphql -f query="${gql}" -f q="${query}" \
                  "${after_arg[@]}" 2>"${errfile}"); then
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
      # GraphQL can return `errors` alongside usable `data` (a partial success:
      # e.g. one sub-field hit a node cap). Only abort when there is no usable
      # search payload; otherwise warn and keep the data we got.
      if jq -e '.data.search == null' <<<"${resp}" >/dev/null 2>&1; then
        jq -r '.errors[].message' <<<"${resp}" >&2
        return 1
      fi
      echo "Warning: GraphQL returned partial errors; continuing with available data:" >&2
      jq -r '.errors[].message' <<<"${resp}" >&2
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

  # Publish the matched count so fetch_windowed can decide whether this window
  # hit the 1000-result cap and needs splitting. Cap handling lives there.
  if [[ -n "${count_file}" ]]; then
    printf '%s' "${issue_count}" > "${count_file}"
  fi

  echo "${all}"
}

# WINDOW_OUT / WINDOW_COUNT are set by fetch_one_window (it can't print its
# result via $(...) without losing access to its own per-call retry state, and
# it returns both a JSON array and a count). Treated as the function's outputs.
WINDOW_OUT="[]"
WINDOW_COUNT=0

# fetch_one_window BASE_QUERY LO_EPOCH HI_EPOCH COUNT_FILE
# Fetches BASE_QUERY restricted to created:[LO..HI], recursively bisecting any
# sub-range that hits the 1000-result cap down to single days. Sets WINDOW_OUT
# to the merged JSON node array and WINDOW_COUNT to how many nodes it collected.
# A single day still over cap is unsplittable — flagged in INCOMPLETE_REASONS.
fetch_one_window() {
  local base_query="${1}" lo="${2}" hi="${3}" count_file="${4}"
  local since until query nodes win_count
  since=$(epoch_to_date "${lo}")
  until=$(epoch_to_date "${hi}")
  query="${base_query} created:${since}..${until}"

  nodes=$(fetch_search "${query}" "${count_file}")
  win_count=$(cat "${count_file}")

  if (( win_count >= SEARCH_RESULT_CAP )); then
    if (( hi - lo >= SECS_PER_DAY )); then
      # Over cap and wider than a day: bisect at a day-aligned midpoint. The two
      # halves cover disjoint days (upper starts the day after the split point).
      local mid mid_day mid_day_epoch next_epoch
      mid=$(( (lo + hi) / 2 ))
      mid_day=$(epoch_to_date "${mid}")
      mid_day_epoch=$(date_to_epoch "${mid_day}")
      if (( mid_day_epoch <= lo )); then
        mid_day_epoch=$(( lo + SECS_PER_DAY ))
      fi
      next_epoch=$(( mid_day_epoch + SECS_PER_DAY ))

      local acc="[]" acc_count=0 merged
      fetch_one_window "${base_query}" "${lo}" "${mid_day_epoch}" "${count_file}"
      merged=$(jq -s '.[0] + .[1]' <(printf '%s' "${acc}") <(printf '%s' "${WINDOW_OUT}"))
      acc="${merged}"; (( acc_count += WINDOW_COUNT )) || true
      if (( next_epoch <= hi )); then
        fetch_one_window "${base_query}" "${next_epoch}" "${hi}" "${count_file}"
        merged=$(jq -s '.[0] + .[1]' <(printf '%s' "${acc}") <(printf '%s' "${WINDOW_OUT}"))
        acc="${merged}"; (( acc_count += WINDOW_COUNT )) || true
      fi
      WINDOW_OUT="${acc}"; WINDOW_COUNT="${acc_count}"
      return 0
    fi
    # Single day still over cap: unsplittable. Keep what we got, flag overflow.
    echo "Warning: ${since} alone matched ${win_count} results (> ${SEARCH_RESULT_CAP} cap); that day's data is truncated." >&2
    INCOMPLETE_REASONS+=("${since} matched ${win_count} results in a single day, exceeding the ${SEARCH_RESULT_CAP}-result cap; that day is truncated")
  fi

  WINDOW_OUT="${nodes}"
  WINDOW_COUNT=$(jq 'length' <<<"${nodes}")
}

# fetch_windowed BASE_QUERY TOTAL
# Fetches BASE_QUERY one year at a time, walking newest -> oldest from today,
# and stops as soon as the collected node count reaches TOTAL (the issueCount
# probed up front). Because CV-relevant work skews recent, this typically skips
# the empty early years entirely. TOTAL == 0 means the count probe failed: no
# early exit, walk the whole range to SEARCH_EPOCH_START. Any year that hits the
# 1000-result cap is bisected down to days by fetch_one_window. Prints the
# merged JSON node array; de-duplication happens later in write_dataset.
fetch_windowed() {
  local base_query="${1}" total="${2}"

  # Count crosses the command-substitution subshell boundary via this file.
  local count_file
  count_file=$(mktemp "${TMPDIR:-/tmp}/fetch_prs_cnt.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '${count_file}'" RETURN

  local floor_epoch hi_date hi_epoch lo_date lo_epoch
  floor_epoch=$(date_to_epoch "${SEARCH_EPOCH_START}")

  local out="[]" collected=0 merged
  hi_date="${TODAY}"
  hi_epoch=$(date_to_epoch "${hi_date}")

  while (( hi_epoch >= floor_epoch )); do
    # Lower bound = one year before this window's upper bound, plus a day so
    # adjacent year windows don't overlap on the boundary date. Clamp to floor.
    lo_date=$(minus_one_year "${hi_date}")
    lo_epoch=$(date_to_epoch "${lo_date}")
    lo_epoch=$(( lo_epoch + SECS_PER_DAY ))
    if (( lo_epoch < floor_epoch )); then
      lo_epoch="${floor_epoch}"
    fi

    fetch_one_window "${base_query}" "${lo_epoch}" "${hi_epoch}" "${count_file}"
    merged=$(jq -s '.[0] + .[1]' <(printf '%s' "${out}") <(printf '%s' "${WINDOW_OUT}"))
    out="${merged}"
    (( collected += WINDOW_COUNT )) || true

    # Early exit: year windows are disjoint, so collected == unique count. Once
    # we've seen every matching PR there's no point walking back to 2008.
    # Only when TOTAL is known (> 0): total==0 means the up-front count probe
    # failed, so we can't trust an early stop and walk the full range instead.
    if (( total > 0 && collected >= total )); then
      break
    fi

    # Step the upper bound to the day before this window's lower bound.
    hi_epoch=$(( lo_epoch - SECS_PER_DAY ))
    hi_date=$(epoch_to_date "${hi_epoch}")
  done

  echo "${out}"
}

# write_dataset MODE OUTFILE QUERY...
# Fetches each QUERY, concatenates the raw node sets, de-duplicates by PR url
# (a PR can match more than one query), normalizes to the flat per-PR schema,
# and writes the wrapped JSON.
write_dataset() {
  local mode="${1}" outfile="${2}"
  shift 2
  echo "Fetching mode=${mode} ..." >&2

  # Reset per-dataset incompleteness tracking; fetch_windowed appends overflow
  # hits for any single day that exceeds the cap.
  INCOMPLETE_REASONS=()

  local raw="[]" query page merged count
  for query in "$@"; do
    # Cheap probe first: only partition into date windows when the query exceeds
    # GitHub's 1000-result cap. A single fetch_search is far faster otherwise.
    # count==0 means the probe failed (count unknown) OR the query genuinely
    # matches nothing — both are safe to window: a true-zero query just runs one
    # empty year window and early-exits immediately.
    count=$(count_matches "${query}")
    if (( count == 0 || count >= SEARCH_RESULT_CAP )); then
      echo "Query matched ${count} results; fetching by date windows (newest first)..." >&2
      page=$(fetch_windowed "${query}" "${count}")
    else
      page=$(fetch_search "${query}")
    fi
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

  # Sub-connection truncation: a PR with exactly FILES_PAGE files (or
  # COMMITS_PAGE commits) almost certainly had more that were dropped, since the
  # script does not page these connections. Flag it so the analyzing skill knows
  # those PRs' file/commit lists are partial.
  local files_trunc commits_trunc
  files_trunc=$(jq --argjson cap "${FILES_PAGE}" '[ .[] | select((.files | length) >= $cap) ] | length' <<<"${normalized}")
  commits_trunc=$(jq --argjson cap "${COMMITS_PAGE}" '[ .[] | select((.commits | length) >= $cap) ] | length' <<<"${normalized}")
  if (( files_trunc > 0 )); then
    echo "Warning: ${files_trunc} PR(s) hit the ${FILES_PAGE}-file cap; their file lists are truncated." >&2
    INCOMPLETE_REASONS+=("${files_trunc} PR(s) had their file list truncated at ${FILES_PAGE} files")
  fi
  if (( commits_trunc > 0 )); then
    echo "Warning: ${commits_trunc} PR(s) hit the ${COMMITS_PAGE}-commit cap; their commit lists are truncated." >&2
    INCOMPLETE_REASONS+=("${commits_trunc} PR(s) had their commit list truncated at ${COMMITS_PAGE} commits")
  fi

  local generated_at
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build the incomplete_reasons JSON array from the accumulated reasons.
  local reasons_json
  if (( ${#INCOMPLETE_REASONS[@]} > 0 )); then
    reasons_json=$(printf '%s\n' "${INCOMPLETE_REASONS[@]}" | jq -R . | jq -s .)
  else
    reasons_json="[]"
  fi

  # Stream $normalized via stdin rather than --argjson: a large PR set blows past
  # ARG_MAX as a command-line argument ("Argument list too long").
  printf '%s' "${normalized}" | jq \
    --arg generated_at "${generated_at}" \
    --arg mode "${mode}" \
    --arg author "${AUTHOR}" \
    --arg org "${ORG}" \
    --argjson incomplete_reasons "${reasons_json}" \
    '{generated_at: $generated_at, mode: $mode, author: $author, org: $org,
      incomplete: ($incomplete_reasons | length > 0),
      incomplete_reasons: $incomplete_reasons,
      pr_count: (. | length), prs: .}' > "${outfile}"

  local count
  count=$(jq '.pr_count' "${outfile}")
  echo "Wrote ${count} PRs -> ${outfile}" >&2
}

# Upper bound for date windowing. Captured once so every window in a run shares
# the same "now" (avoids a window boundary shifting mid-run across midnight UTC).
TODAY=$(date -u +%Y-%m-%d)

OUTDIR="${OUT}/${ORG}/${AUTHOR}"
mkdir -p "${OUTDIR}"

run_authored() {
  write_dataset "authored-all" "${OUTDIR}/prs-authored.json" \
    "is:pr author:${AUTHOR} org:${ORG}"
}
run_reviewed() {
  # "reviewed" = PRs the author participated in as a reviewer, NOT their own
  # work. Excluding `-author:${AUTHOR}` keeps this dataset disjoint from
  # prs-authored.json (otherwise self-authored PRs land in both files and get
  # double-counted across the "led" and "participated" narratives).
  write_dataset "reviewed" "${OUTDIR}/prs-reviewed.json" \
    "is:pr org:${ORG} reviewed-by:${AUTHOR} -author:${AUTHOR}"
}

case "${MODE}" in
  authored-all) run_authored ;;
  reviewed)     run_reviewed ;;
  "")           run_authored; run_reviewed ;;
  *)            echo "Error: unhandled mode '${MODE}'." >&2; exit 2 ;;
esac
