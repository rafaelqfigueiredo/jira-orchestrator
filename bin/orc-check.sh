#!/usr/bin/env bash
# Self-check. Everything this repository claims about itself, verified.
#
# Run it after any change to bin/, and before trusting a live run.
set -uo pipefail
# shellcheck source=bin/orc-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/orc-lib.sh"

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$(( failures + 1 )); }

scripts() {
  find "$ORC_ROOT/bin" "$ORC_ROOT/golden" "$ORC_ROOT/fixtures" -name '*.sh' -type f 2>/dev/null | sort
}

# Code, not prose: the checks below look for real invocations, so a sentence in
# a comment describing the rule does not trip the rule. What is piped through
# here carries no prefix at all when it comes from a bare sed -n '...p', a
# line: prefix from grep -n on the one file every call site here actually
# greps, and a path:line: prefix only if grep were ever given more than one -
# so both halves of the prefix have to be optional, not just the filename.
code_only() { grep -vE '^([^:]*:)?([0-9]+:)?[[:space:]]*#'; }

# This script names the things it forbids, so it excludes itself from the scan.
other_scripts() { scripts | grep -v 'orc-check.sh'; }

# Fingerprinted before anything runs, so the assertion at the bottom is about
# the whole suite rather than about one command. Every sandbox in here is a
# mktemp directory, so nothing should ever reach examples/ - and that is a claim
# worth measuring rather than assuming, because the whole point of the directory
# is that nothing reads it.
examples_sum_before=$(find "$ORC_ROOT/examples" -type f 2>/dev/null | sort \
  | while IFS= read -r f; do printf '%s ' "${f#"$ORC_ROOT"/}"; _sha1 < "$f"; done | _sha1)

printf '\n== shellcheck ==\n'
if command -v shellcheck >/dev/null 2>&1; then
  out=$(scripts | xargs shellcheck -x -S style 2>&1)
  if [ -z "$out" ]; then pass "every script is shellcheck clean"; else fail "shellcheck findings"; printf '%s\n' "$out"; fi
else
  fail "shellcheck is not installed (brew install shellcheck)"
fi

printf '\n== the single write path ==\n'
# Claim: every request goes through jira_read/jira_write or a figma_* read, and
# every curl invocation lives in the one fenced region. Verified by line number
# rather than by trust.
lib="$ORC_ROOT/bin/orc-lib.sh"
begin=$(grep -n 'BEGIN SOLE-CURL-REGION' "$lib" | cut -d: -f1)
end=$(grep -n 'END SOLE-CURL-REGION' "$lib" | cut -d: -f1)
if [ -z "$begin" ] || [ -z "$end" ]; then
  fail "the SOLE-CURL-REGION markers are missing from orc-lib.sh"
else
  stray=$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*curl[[:space:]]' "$lib" \
    | awk -F: -v b="$begin" -v e="$end" '$1 < b || $1 > e')
  if [ -n "$stray" ]; then fail "curl outside the sole-curl region in orc-lib.sh"; printf '%s\n' "$stray"; else
    pass "curl appears only inside the fenced region (lines $begin-$end)"; fi
fi

# shellcheck disable=SC2046
outside=$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*curl[[:space:]]' $(other_scripts | grep -v 'orc-lib.sh') 2>/dev/null | code_only)
if [ -n "$outside" ]; then fail "curl found outside orc-lib.sh"; printf '%s\n' "$outside"; else
  pass "no other script runs curl at all"; fi

# shellcheck disable=SC2046
writers=$(grep -n 'jira_write ' $(other_scripts | grep -v 'orc-lib.sh') 2>/dev/null | code_only)
if [ -n "$writers" ]; then fail "a script calls jira_write directly instead of a named action"; printf '%s\n' "$writers"; else
  pass "scripts write only through the named actions in orc-lib.sh"; fi

printf '\n== defaults are safe ==\n'
# Run in a separate process rather than a subshell so nothing about this
# script's own environment can reach the guard being tested.
# The single quotes are deliberate: the body runs in the child shell, where $0
# is the library path passed after it.
# shellcheck disable=SC2016
guard() { env -u ORC_JIRA_MODE -u DRY_RUN "$@" bash -c '. "$0" >/dev/null 2>&1; orc_writes_are_live' "$lib"; }

if guard; then fail "writes are live with no configuration"; else
  pass "with no configuration, writes are not live"; fi
if guard ORC_JIRA_MODE=live; then fail "ORC_JIRA_MODE=live alone is enough to post"; else
  pass "live mode alone does not post; DRY_RUN=0 is also required"; fi
if guard ORC_JIRA_MODE=fixture DRY_RUN=0; then fail "DRY_RUN=0 alone is enough to post"; else
  pass "DRY_RUN=0 alone does not post; live mode is also required"; fi
if guard ORC_JIRA_MODE=live DRY_RUN=0; then
  pass "both switches together do enable writes, so the guard is not simply always off"
else
  fail "writes cannot be enabled at all; the guard is stuck closed"; fi

printf '\n== the environment beats config/.env ==\n'
if [ -f "$ORC_ROOT/config/.env" ]; then
  # shellcheck disable=SC2016
  actual=$(ORC_JIRA_MODE=dry-run bash -c '. "$0" >/dev/null 2>&1; printf %s "$ORC_JIRA_MODE"' "$lib")
  if [ "$actual" = "dry-run" ]; then pass "a mode given on the command line survives config/.env"; else
    fail "config/.env overrode a mode given on the command line (got '$actual')"; fi
else
  printf '  skip  no config/.env present to test precedence against\n'
fi

printf '\n== refinement is read-only against the target repo ==\n'
mutating=$(grep -nE 'git .*(commit|push|add |checkout|worktree|reset|clean|stash|merge|rebase|apply)' \
  "$ORC_ROOT/bin/orc-refine.sh" 2>/dev/null)
if [ -n "$mutating" ]; then fail "orc-refine.sh contains a state-changing git command"; printf '%s\n' "$mutating"; else
  pass "orc-refine.sh runs no state-changing git command"; fi
if grep -q 'refinement changed the target repository' "$ORC_ROOT/bin/orc-refine.sh"; then
  pass "the agent call is fenced by a before/after repository fingerprint"
else
  fail "the read-only assertion around the agent call is missing"
fi

printf '\n== no secrets ==\n'
if git -C "$ORC_ROOT" check-ignore -q config/.env 2>/dev/null; then
  pass "config/.env is gitignored"; else fail "config/.env is not gitignored"; fi
if [ -n "$(git -C "$ORC_ROOT" ls-files config/.env 2>/dev/null)" ]; then
  fail "config/.env is tracked by git"; else pass "config/.env is not tracked"; fi
if [ -n "$(git -C "$ORC_ROOT" ls-files state 2>/dev/null)" ]; then
  fail "state/ is tracked by git"; else pass "state/ is not tracked"; fi
# The trailing slash matters: the pattern is a directory one, and the directory
# does not exist until something has been cloned.
if git -C "$ORC_ROOT" check-ignore -q clones/ 2>/dev/null; then
  pass "clones/ is gitignored"; else fail "clones/ is not gitignored"; fi
if [ -n "$(git -C "$ORC_ROOT" ls-files clones 2>/dev/null)" ]; then
  fail "a clone is tracked by git"; else pass "no clone is tracked"; fi
if git -C "$ORC_ROOT" ls-files -z 2>/dev/null \
    | xargs -0 grep -ilE '(ATATT[A-Za-z0-9]|api[_-]?token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9]{16,})' 2>/dev/null \
    | grep -q .; then
  fail "something that looks like a credential is tracked"
else
  pass "no credential-shaped strings in tracked files"
fi

printf '\n== fixtures and the golden set agree ==\n'
keys_in() { for f in "$1"/*.json; do [ -e "$f" ] && basename "$f" .json; done | sort; }
fx=$(keys_in "$ORC_ROOT/fixtures/issues")
gx=$(keys_in "$ORC_ROOT/golden/expected")
if [ "$fx" = "$gx" ]; then pass "every fixture ticket has a golden expectation"; else
  fail "fixtures and expectations disagree"; diff <(printf '%s\n' "$fx") <(printf '%s\n' "$gx") || true; fi

# A generator that stamps the clock rewrites its output on every run, which
# turns `git status` into noise and makes a review diff meaningless.
if grep -n 'orc_now' "$ORC_ROOT/fixtures/build.sh" | code_only | grep -q .; then
  fail "fixtures/build.sh stamps wall-clock time, so a rebuild is never a no-op"
else
  pass "the fixture generator is reproducible: rebuilding changes nothing"
fi

while IFS=$'\t' read -r prompt tag; do
  [ -n "$tag" ] || continue
  [ -f "$ORC_ROOT/$prompt" ] || { fail "replay-map names a missing prompt: $prompt"; continue; }
  missing=""
  for k in $fx; do
    [ -f "$ORC_ROOT/fixtures/verdicts/$tag/$k.json" ] || missing="$missing $k"
  done
  if [ -n "$missing" ]; then fail "replay set '$tag' is missing:$missing"; else
    pass "replay set '$tag' covers every fixture ticket"; fi
done < "$ORC_ROOT/golden/replay-map.tsv"

printf '\n== comments are ADF ==\n'
doc=$(adf_new)
doc=$(adf_heading "$doc" 3 'check')
# Literal awkward text, on purpose: the point is that it survives into JSON
# without being expanded or breaking the payload.
# shellcheck disable=SC2016
doc=$(adf_para "$doc" 'a "quoted" {brace} $dollar line')
if adf_comment_body "$doc" | jq -e '.body.type == "doc" and .body.version == 1 and (.body.content | length) == 2 and (.body.content[0].type == "heading")' >/dev/null; then
  pass "the comment builder produces a well-formed ADF document"
else
  fail "the comment builder did not produce valid ADF"
fi
# The fold. Its rules are the published ADF schema's rather than this
# repository's, so they are asserted here rather than assumed: at least one
# child, a string title, no marks, and a child type the schema allows. An expand
# is a top-level block, so it is a sibling of what surrounds it - never a wrapper
# over the whole document, and never nested inside another expand.
inner=$(adf_new)
inner=$(adf_heading "$inner" 3 'Probable files')
# shellcheck disable=SC2016
inner=$(adf_bullets "$inner" 'app/models/case.rb
a "quoted" {brace} $dollar path')
folded=$(adf_expand "$doc" 'For the implementing agent' "$inner")
# shellcheck disable=SC2016
if adf_comment_body "$folded" | jq -e '
     (.body.content | length) == 3
     and .body.content[2].type == "expand"
     and (.body.content[2].attrs.title | type) == "string"
     and (.body.content[2].attrs.title | length) > 0
     and ((.body.content[2].marks // []) | length) == 0
     and (.body.content[2].content | length) >= 1
     and (([.body.content[2].content[].type]
            - ["paragraph","heading","bulletList","orderedList","codeBlock","rule"]) | length) == 0
     and (.body.content[2].content[1].content[1].content[0].content[0].text
            == "a \"quoted\" {brace} $dollar path")' >/dev/null; then
  pass "the fold is one top-level expand node with a title, legal children and awkward text intact"
else
  fail "adf_expand did not produce a valid expand node"
  adf_comment_body "$folded" | jq .
fi
if [ "$(adf_expand "$doc" 'nothing to fold' "$(adf_new)" | jq 'length')" \
     = "$(printf '%s' "$doc" | jq 'length')" ]; then
  pass "and a fold with nothing to put in it adds no node, which is what the schema's one-child minimum requires"
else
  fail "adf_expand emitted a fold with no content in it"
fi
if adf_comment_body "$folded" | adf_to_text | grep -q 'app/models/case.rb'; then
  pass "and a dry run prints what is inside the fold rather than stopping at its title"
else
  fail "adf_to_text does not descend into an expand, so a dry run would hide what was folded"
fi

# shellcheck disable=SC2046
if grep -n 'body["'"'"']*[[:space:]]*:[[:space:]]*"\$' $(other_scripts) 2>/dev/null | code_only | grep -q .; then
  fail "a comment body is being built as a plain string"
else
  pass "no comment is built as a plain string"
fi

printf '\n== the live write path ==\n'
# The one path that cannot be exercised in fixture mode, and the one whose
# failure is expensive. curl is replaced by a stub that records how it was
# called and answers 429 once, so this covers everything except the socket.
# The base URL points at the discard port, so a stub that failed to load
# reaches nothing.
livedir=$(mktemp -d)
mkdir -p "$livedir/bin" "$livedir/verdicts/baseline"
cat > "$livedir/bin/curl" <<'STUB'
#!/usr/bin/env bash
log="$STUB_LOG"; printf 'ARGV: %s\n' "$*" >> "$log"
out=""; hdr=""; method=""; cfg=""; body=""; prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;; -D) hdr="$a" ;; -X) method="$a" ;;
    --config) cfg="$a" ;; --data-binary) body="$a" ;;
  esac
  prev="$a"
done
[ -n "$cfg" ] && printf 'CFGPERM: %s\n' "$(stat -f %Lp "$cfg" 2>/dev/null || stat -c %a "$cfg" 2>/dev/null)" >> "$log"
[ -n "$body" ] && printf 'BODY: %s\n' "$body" >> "$log"
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
if [ "$method" != "GET" ] && [ "$n" = "0" ]; then
  echo 1 > "$STUB_COUNT"
  printf 'HTTP/1.1 429\r\nRetry-After: 1\r\n\r\n' > "$hdr"; : > "$out"
  printf '429'; exit 0
fi
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
case "$method" in
  GET) cat "$STUB_ISSUE" > "$out" ;;
  *)   printf '{"id":"1"}' > "$out" ;;
esac
printf '200'
STUB
chmod +x "$livedir/bin/curl"
printf '%s' '{"key":"ORC-STUB","fields":{"summary":"stub","description":"stub description","labels":[],"issuetype":{"name":"Bug"},"reporter":{"accountId":"acct-1"},"status":{"name":"To Do"},"updated":"2026-01-01T00:00:00.000+0000","comment":{"comments":[]}}}' > "$livedir/issue.json"
printf '%s' '{"verdict":"needs_input","one_line":"stub","questions":["Which surface?"],"files":[],"subsystems":[],"duplicate_of":null,"split_into":[],"acceptance_criteria":[],"not_verified":"everything","notes":"stub"}' > "$livedir/verdicts/baseline/ORC-STUB.json"

STUB_LOG="$livedir/calls.log" STUB_COUNT="$livedir/count" STUB_ISSUE="$livedir/issue.json" \
PATH="$livedir/bin:$PATH" ORC_JIRA_MODE=live DRY_RUN=0 \
JIRA_BASE_URL=http://127.0.0.1:9 JIRA_EMAIL=stub@example.com JIRA_API_TOKEN=stub-token-not-real \
ORC_REFINER=replay ORC_VERDICT_DIR="$livedir/verdicts" ORC_STATE_DIR="$livedir/state" \
ORC_REPO_SYNC=off \
  "$ORC_ROOT/bin/orc-refine.sh" ORC-STUB > "$livedir/run.log" 2>&1
# ORC_REPO_SYNC=off above is not incidental. This stub exists to watch what curl
# was handed; a fetch is nothing to do with that, and left on `auto` the check
# would clone every repository the real config names before reaching the thing it
# is measuring.
calls="$livedir/calls.log"

if [ ! -s "$calls" ]; then
  fail "the curl stub was never called, so the live path is unverified"
else
  if grep -q 'stub-token-not-real' "$calls"; then
    fail "the API token appears in curl's arguments, where the process table can see it"
  else
    pass "the API token never reaches curl's command line"
  fi
  if grep -q 'CFGPERM: 600' "$calls"; then
    pass "credentials are passed in a 0600 config file"
  else
    fail "the curl config file is not mode 600"; fi
  if grep -q 'waiting 1s' "$livedir/run.log"; then
    pass "a 429 is retried after the interval its Retry-After header names"
  else
    fail "the 429 retry did not happen"; cat "$livedir/run.log"; fi
  if grep 'BODY:' "$calls" | head -1 | grep -q '"type":"doc","version":1'; then
    pass "the comment sent on the live path is an ADF document"
  else
    fail "the live path sent something that is not ADF"; fi
  if grep -qE 'ARGV:.*-X (POST|PUT)' "$calls"; then
    pass "live mode with DRY_RUN=0 does send writes"
  else
    fail "live mode sent no write at all"; fi
fi
rm -rf "$livedir"

printf '\n== the poll pages on a cursor ==\n'
# /rest/api/3/search was removed rather than merely deprecated: it answers 410,
# which took every read down in dry-run and live at the same moment while fixture
# mode carried on working perfectly. That is the shape of break these checks are
# for - one the default mode structurally cannot see.
#
# The spelling first, because a revert to offset paging is a small diff that
# would pass everything below by never being run.
# shellcheck disable=SC2046
gone=$(grep -nE '/search\?' $(other_scripts) 2>/dev/null | code_only)
if [ -n "$gone" ]; then
  fail "a script asks for /search, which Jira removed and answers 410 to"; printf '%s\n' "$gone"
else
  pass "nothing asks for the removed /search endpoint"
fi
# shellcheck disable=SC2046
spellings=$(grep -nE '/search/jql' $(other_scripts) 2>/dev/null | code_only | cut -d: -f1 | sort -u)
if [ "$spellings" = "$ORC_ROOT/bin/orc-lib.sh" ]; then
  pass "the live endpoint is spelled once, in jira_search, and every read goes through it"
else
  fail "the search endpoint is spelled in more than one place"; printf '%s\n' "$spellings"
fi
# shellcheck disable=SC2046
offsets=$(grep -nE 'startAt=' $(other_scripts) 2>/dev/null | code_only)
if [ -n "$offsets" ]; then
  fail "a request still pages by offset; /search/jql has no startAt"; printf '%s\n' "$offsets"
else
  pass "no request pages by offset"
fi
# The cursor loop is spelled once for the same reason the endpoint is. Two loops
# would eventually disagree about the page that carries a token and no issues on
# it, and that is the page a wrong termination condition drops - so the reads
# that page go through jira_search_all and nothing writes a second loop.
# shellcheck disable=SC2046
cursors=$(grep -nE 'nextPageToken' $(other_scripts) 2>/dev/null | code_only | cut -d: -f1 | sort -u)
if [ "$cursors" = "$ORC_ROOT/bin/orc-lib.sh" ]; then
  pass "the cursor loop is spelled once, in jira_search_all, and every paging read goes through it"
else
  fail "a second cursor loop exists, so two answers to 'has the paging ended' can disagree"
  printf '%s\n' "$cursors"
fi
paging_readers=""
for r in bin/orc-jira-poll.sh bin/orc-reconcile.sh bin/orc-harvest.sh; do
  grep -q 'jira_search_all' "$ORC_ROOT/$r" || paging_readers="$paging_readers $r"
done
if [ -z "$paging_readers" ]; then
  pass "and the poll, the reconcile and the harvest all read their pages through it"
else
  fail "a read asks for one page and stops:$paging_readers"
fi

# And now the behaviour, because the greps above prove the word is there and
# nothing about what the loop does with it. curl is stubbed to serve three
# pages, the middle of which has a token and no issues on it at all - which the
# endpoint is documented to do, and which is the page that kills every
# termination condition except the right one. An offset loop, a loop that stops
# when a page comes back short, and a loop that stops when a count is reached
# all drop the third page here.
polldir=$(mktemp -d)
mkdir -p "$polldir/bin"
cat > "$polldir/bin/curl" <<'PSTUB'
#!/usr/bin/env bash
out=""; hdr=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$url" >> "$POLL_LOG"
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
case "$url" in
  *nextPageToken=tok-one*)
    printf '{"isLast":false,"nextPageToken":"tok-two","issues":[]}' > "$out" ;;
  *nextPageToken=tok-two*)
    printf '{"isLast":true,"issues":[{"id":"3","key":"ORC-203","fields":{"updated":"2026-08-16T10:15:00.000+0200"}}]}' > "$out" ;;
  *nextPageToken=*)
    printf '{"isLast":true,"issues":[]}' > "$out" ;;
  *)
    printf '%s' '{"isLast":false,"nextPageToken":"tok-one","issues":[
      {"id":"1","key":"ORC-201","fields":{"updated":"2026-08-14T09:12:00.000+0200"}},
      {"id":"2","key":"ORC-202","fields":{"updated":"2026-08-15T09:02:00.000+0200"}}]}' > "$out" ;;
esac
printf '200'
PSTUB
chmod +x "$polldir/bin/curl"

# poll <state-dir> -> the issue keys, one per line. The limit is a regression
# guard rather than a timing one: a loop that never terminates has to fail the
# check that was written to catch it rather than hang the suite it is in.
poll() {
  run_with_timeout 30 env \
    POLL_LOG="$polldir/urls.log" PATH="$polldir/bin:$PATH" \
    ORC_JIRA_MODE=dry-run DRY_RUN=1 JIRA_PROJECT=ORC \
    JIRA_BASE_URL=http://127.0.0.1:9 JIRA_EMAIL=stub@example.com \
    JIRA_API_TOKEN=stub-token-not-real ORC_STATE_DIR="$1" \
    "$ORC_ROOT/bin/orc-jira-poll.sh" 2>>"$polldir/err.log"
}

: > "$polldir/urls.log"; : > "$polldir/err.log"
keys=$(poll "$polldir/state"); prc=$?
urls=$(cat "$polldir/urls.log")
asked=$(printf '%s\n' "$urls" | grep -c . || true)
if [ "$prc" = "0" ]; then
  pass "the cursor loop terminates when a page comes back with no token"
else
  fail "the poll did not finish against a three-page cursor (rc=$prc)"; cat "$polldir/err.log"
fi
if [ "$(printf '%s\n' "$keys" | grep -c . || true)" = "3" ] \
   && printf '%s\n' "$keys" | grep -q '^ORC-203$'; then
  pass "and reads every page, including the one after a page with no issues on it"
else
  fail "the poll lost a page: an empty page with a token ended the loop"; printf '%s\n' "$keys"
fi
if [ "$asked" = "3" ]; then
  pass "and asks for exactly as many pages as there were"
else
  fail "the poll made $asked requests for a three-page result"; printf '%s\n' "$urls"
fi
# A cursor cannot be computed, only carried. A first request already holding one
# would mean it came from somewhere other than a response.
if printf '%s\n' "$urls" | sed -n 1p | grep -q 'nextPageToken'; then
  fail "the first request carried a page token, which nothing had returned yet"
else
  pass "the first page is asked for with no token"
fi
if printf '%s\n' "$urls" | sed -n 2p | grep -q 'nextPageToken=tok-one' \
   && printf '%s\n' "$urls" | sed -n 3p | grep -q 'nextPageToken=tok-two'; then
  pass "and each later page carries the token the page before it returned"
else
  fail "a later request did not carry the previous response's token"; printf '%s\n' "$urls"
fi
if printf '%s\n' "$urls" | grep -q 'fields=updated'; then
  pass "and names the field it reads, which /search/jql no longer returns by default"
else
  fail "the poll names no field, so the response is issue ids and nothing else"; printf '%s\n' "$urls"
fi

# The watermark is inclusive, and a change of paging model is where that gets
# lost: the loop no longer counts anything, so the minute comparison has to be
# shown to have survived. An issue updated in the same minute as the last poll is
# offered again rather than missed, because refinement is idempotent on ticket
# content and a miss costs a ticket.
if [ "$(cat "$polldir/state/.jira-watermark" 2>/dev/null)" = "2026-08-16 10:15" ]; then
  pass "the watermark is written from the last page of the cursor"
else
  fail "the watermark did not come from the last page"; cat "$polldir/state/.jira-watermark" 2>/dev/null
fi
: > "$polldir/urls.log"
again=$(poll "$polldir/state")
if printf '%s\n' "$again" | grep -q '^ORC-203$'; then
  pass "and the issue updated in that same minute is offered again rather than dropped"
else
  fail "an issue updated in the watermark's own minute was dropped"; printf '%s\n' "$again"
fi

# A poll that found nothing has not failed. The daemon reads a non-zero status
# from this script as "poll failed" and abandons the pass, so an empty result
# arriving as an error means a quiet project stops the whole loop - which is
# exactly what a watermark makes the normal case.
cat > "$polldir/bin/curl" <<'PSTUB'
#!/usr/bin/env bash
out=""; hdr=""; prev=""
for a in "$@"; do case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac; prev="$a"; done
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
printf '{"isLast":true,"issues":[]}' > "$out"
printf '200'
PSTUB
chmod +x "$polldir/bin/curl"
if poll "$polldir/quiet" >/dev/null; then
  pass "a poll that found nothing succeeds, so a quiet project does not read as a failure"
else
  fail "an empty result exits non-zero, which the daemon reports as a failed poll"
fi

# A cursor that does not move is the one way this loop can fail to terminate, and
# it is a server fault rather than a scale a page cap could be sized against. It
# has to be an error: a poll that spun would stop the daemon without ever saying
# why.
cat > "$polldir/bin/curl" <<'PSTUB'
#!/usr/bin/env bash
out=""; hdr=""; prev=""
for a in "$@"; do case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac; prev="$a"; done
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
printf '{"isLast":false,"nextPageToken":"stuck","issues":[]}' > "$out"
printf '200'
PSTUB
chmod +x "$polldir/bin/curl"
: > "$polldir/err.log"
poll "$polldir/stalled" >/dev/null; src=$?
if [ "$src" != "0" ] && grep -q 'stalled' "$polldir/err.log"; then
  pass "a cursor that never moves is a named error, not a loop that runs until it is killed"
else
  fail "the poll accepted a repeated page token (rc=$src)"; cat "$polldir/err.log"
fi
rm -rf "$polldir"

printf '\n== refinement is gated on a label, and only when one is named ==\n'
# The captain picks which cards get refined by putting a label on them. Two
# things have to be true for that to be safe: with no label named, nothing
# changes for an installation that never heard of the setting, and with one
# named, the narrowing happens in the JQL rather than in a filter over the
# results - an unlabelled card should cost no page of results and no read.
#
# The gate is also the one label this system reads and never writes, so that is
# asserted as code rather than left to the naming.
# shellcheck disable=SC2046
gate_writes=$(grep -nE 'jira_(add|remove)_label[^#]*LABEL_OPT_IN' $(other_scripts) 2>/dev/null | code_only)
if [ -n "$gate_writes" ]; then
  fail "something writes the opt-in label; it is read-only by design"; printf '%s\n' "$gate_writes"
else
  pass "nothing adds or removes the opt-in label: the set of cards in scope stays a human's"
fi

g=$(mktemp -d)
mkdir -p "$g/bin"
cat > "$g/bin/curl" <<'GSTUB'
#!/usr/bin/env bash
out=""; hdr=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$url" >> "$GATE_LOG"
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
printf '{"isLast":true,"issues":[]}' > "$out"
printf '200'
GSTUB
chmod +x "$g/bin/curl"

# The JQL the poll actually asked for, decoded far enough to read. gate_rc is
# set beside it rather than returned, because the caller wants both and a
# function that dies inside $( ) dies in a subshell.
gate_rc=0
# UNSET rather than an empty value, because the claim being tested is what
# happens when nobody has heard of the setting, and an empty assignment is
# somebody having heard of it.
with_label() {
  local label="$1"; shift
  if [ "$label" = "UNSET" ]; then
    env -u LABEL_OPT_IN "$@"
  else
    env LABEL_OPT_IN="$label" "$@"
  fi
}
gate_jql() {
  : > "$g/urls.log"
  with_label "$1" env GATE_LOG="$g/urls.log" PATH="$g/bin:$PATH" \
    ORC_JIRA_MODE=dry-run DRY_RUN=1 JIRA_PROJECT=ORC \
    JIRA_BASE_URL=http://127.0.0.1:9 JIRA_EMAIL=stub@example.com \
    JIRA_API_TOKEN=stub-token-not-real ORC_STATE_DIR="$g/state-$2" \
    "$ORC_ROOT/bin/orc-jira-poll.sh" >/dev/null 2>"$g/err-$2.log"
  gate_rc=$?
  # Only the jql= parameter, so a label that arrived in some other part of the
  # query would not be mistaken for one in the query itself.
  sed -n 1p "$g/urls.log" | sed -n 's/.*[?&]jql=\([^&]*\).*/\1/p' \
    | sed -e 's/%20/ /g' -e 's/%22/"/g' -e 's/%3D/=/g' -e 's/%3E/>/g'
}

if [ -f "$ORC_ROOT/config/.env" ] \
   && grep -qE '^[[:space:]]*LABEL_OPT_IN=[^[:space:]]' "$ORC_ROOT/config/.env"; then
  printf '  skip  config/.env names an opt-in label in this checkout, so the default cannot be measured here\n'
else
  jql=$(gate_jql UNSET off)
  if printf '%s' "$jql" | grep -q 'project = ORC' && ! printf '%s' "$jql" | grep -q 'labels'; then
    pass "with no label named, the poll asks the question it always asked: everything in the project that changed"
  else
    fail "the gate is on with nothing configured, so an existing installation would start ignoring tickets"
    printf '  %s\n' "$jql"
  fi
fi

jql=$(gate_jql refine-me on)
if printf '%s' "$jql" | grep -q 'labels = "refine-me"'; then
  pass "with one named, the JQL names it, so an unlabelled card costs no page of results"
else
  fail "the opt-in label is not in the JQL"; printf '  %s\n' "$jql"
fi
if printf '%s' "$jql" | grep -q 'updated >=' ; then
  pass "and the watermark is still in the same query, so the gate narrows the poll rather than replacing it"
else
  fail "the watermark clause went missing when the label was added"; printf '  %s\n' "$jql"
fi

# A report has to describe the query that was actually asked. An operator whose
# board is full and whose poll found nothing needs to be told which question was
# put, and a fixture run must not claim a narrowing it never asked for - the
# canned page it reads names `updated` and nothing else.
if grep -q 'labelled refine-me' "$g/err-on.log"; then
  pass "and the poll names the label it narrowed by, so an empty result is not a mystery"
else
  fail "the poll does not say which label it narrowed by"; cat "$g/err-on.log"
fi
fixture_said=$(with_label refine-me env ORC_JIRA_MODE=fixture ORC_STATE_DIR="$g/state-fx" \
  "$ORC_ROOT/bin/orc-jira-poll.sh" 2>&1 >/dev/null)
if printf '%s' "$fixture_said" | grep -q 'labelled'; then
  fail "a fixture run reports a narrowing it never asked for"; printf '%s\n' "$fixture_said"
else
  pass "and a fixture run, which reads a canned page, claims no narrowing it could not have done"
fi

# A Jira label holds no space, so a value with one is a typo. Unchecked it would
# not fail: it would ask a different question and answer it successfully, which
# is a filter nobody knows about.
gate_jql 'two words' bad >/dev/null
if [ "$gate_rc" != "0" ] && grep -q 'LABEL_OPT_IN' "$g/err-bad.log"; then
  pass "a label with a space in it is a named error rather than a quietly different query"
else
  fail "a label with a space was accepted (rc=$gate_rc)"; cat "$g/err-bad.log"
fi

# And the same rule where a key is named on a command line, because a gate that
# held for the daemon and not for the operator would be two behaviours from one
# setting. Two tickets, one carrying the label and one not.
gtag=$(awk -F'\t' '$1=="prompts/refine.md" {print $2}' "$ORC_ROOT/golden/replay-map.tsv")
mkdir -p "$g/fx/issues" "$g/fx/search" "$g/verdicts/$gtag"
: > "$g/none.yml"
printf '{"issues":[]}' > "$g/fx/search/open-issues.json"
for pair in 'ORC-GATE ["refine-me"]' 'ORC-SHUT []'; do
  gkey=${pair%% *}
  jq -nc --arg k "$gkey" --argjson l "${pair#* }" \
    '{key:$k,fields:{summary:"a card",description:"a description",labels:$l,
      issuetype:{name:"Bug"},reporter:{accountId:"acct-1"},status:{name:"To Do"},
      updated:"2026-01-01T00:00:00.000+0000",comment:{comments:[]}}}' > "$g/fx/issues/$gkey.json"
  jq -nc '{verdict:"needs_input",one_line:"a card",questions:["Which screen?"],
           files:[],subsystems:[],locality_basis:"none",terms_resolved:[],
           terms_unresolved:["card"],duplicate_of:null,split_into:[],
           acceptance_criteria:[],not_verified:"nothing",notes:"nothing"}' \
    > "$g/verdicts/$gtag/$gkey.json"
done
gate_refine() {
  with_label "$1" env ORC_JIRA_MODE=fixture ORC_REFINER=replay ORC_REPO_SYNC=off \
    ORC_PROJECTS_FILE="$g/none.yml" ORC_FIXTURE_DIR="$g/fx" \
    ORC_VERDICT_DIR="$g/verdicts" ORC_STATE_DIR="$g/rs-$3" \
    "$ORC_ROOT/bin/orc-refine.sh" --force "$2" >"$g/out-$3.log" 2>&1
  gate_rc=$?
}

gate_refine UNSET ORC-SHUT default
if [ "$gate_rc" = "0" ] && [ -s "$g/rs-default/.would-write.log" ]; then
  pass "with no label named, a card that carries none is refined exactly as before"
else
  fail "the default gate refused an unlabelled card (rc=$gate_rc)"; cat "$g/out-default.log"
fi
gate_refine refine-me ORC-SHUT shut
if [ "$gate_rc" = "3" ] && grep -q 'refine-me' "$g/out-shut.log" \
   && [ ! -f "$g/rs-shut/.would-write.log" ]; then
  pass "with one named, a card without it is left alone, named as nothing to do, and nothing is posted about it"
else
  fail "an unlabelled card was refined anyway, or refused without saying why (rc=$gate_rc)"
  cat "$g/out-shut.log"
fi
gate_refine refine-me ORC-GATE open
if [ "$gate_rc" = "0" ] && [ -s "$g/rs-open/.would-write.log" ]; then
  pass "and a card carrying it is refined, so the gate is not simply always shut"
else
  fail "a card carrying the opt-in label was not refined (rc=$gate_rc)"; cat "$g/out-open.log"
fi
# golden/run.sh and bin/orc-locality-score.sh judge fixture tickets that carry no
# labels at all. Gated, a label configured for the real board would turn every row
# of both reports into an error about a label.
judged=$(env LABEL_OPT_IN=refine-me ORC_JIRA_MODE=fixture ORC_REFINER=replay ORC_REPO_SYNC=off \
  ORC_PROJECTS_FILE="$g/none.yml" ORC_FIXTURE_DIR="$g/fx" ORC_VERDICT_DIR="$g/verdicts" \
  ORC_STATE_DIR="$g/rs-judge" \
  "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force ORC-SHUT 2>/dev/null)
if printf '%s' "$judged" | jq -e '.verdict == "needs_input"' >/dev/null 2>&1; then
  pass "and a --judge-only run is outside the gate, so a configured label does not empty the golden set"
else
  fail "--judge-only is gated, which turns every measurement of the prompt into a label error"
  printf '%s\n' "$judged" | head -5
fi
rm -rf "$g"

printf '\n== the projects config says what it must ==\n'
# config/projects.yml is source: reviewed, and the half of the split a human
# owns. A typo in it is a wrong answer everywhere downstream, so it is validated
# here rather than discovered during a run.
cfg_bad=""
for name in $(project_names); do
  if [ -n "$(project_field "$name" remote)" ] && [ -z "$(project_default_branch "$name")" ]; then
    cfg_bad="$cfg_bad
  $name has a remote but no default_branch, and it is never assumed"
  fi
  case "$(project_field "$name" verify)" in
    ''|local|unit-only) : ;;
    *) cfg_bad="$cfg_bad
  $name has verify: $(project_field "$name" verify), which is neither local nor unit-only" ;;
  esac
done
if [ -n "$cfg_bad" ]; then fail "config/projects.yml is not valid:$cfg_bad"; else
  pass "every project with a remote names its default_branch, and verify is one of two values"; fi
if [ -n "$(project_names)" ]; then
  pass "the config parses to at least one project ($(project_names | tr '\n' ' '))"
else
  fail "no project could be read out of config/projects.yml"; fi

printf '\n== the only write to a clone is a fast-forward ==\n'
# Section 6 says the orchestrator never writes to a target repository. It owns
# its clones now, so there is exactly one exception, it lives in one region of
# one script, and it is three commands that refuse rather than discard.
sync="$ORC_ROOT/bin/orc-repos-sync.sh"
# A git invocation with a state-changing subcommand somewhere on the line. The
# subcommand is not the first word - `git -C "$1" fetch` is the normal shape -
# so the verb is looked for anywhere before the next command separator.
MUTATING_GIT='(^|[^_[:alnum:]])git[[:space:]][^|;&#]*(commit|push|pull|fetch|clone|merge|rebase|reset|checkout|switch|restore|clean|stash|apply|worktree|update-ref|cherry-pick|revert|gc|prune)'
cbegin=$(grep -n 'BEGIN SOLE-CLONE-WRITE-REGION' "$sync" | cut -d: -f1)
cend=$(grep -n 'END SOLE-CLONE-WRITE-REGION' "$sync" | cut -d: -f1)
if [ -z "$cbegin" ] || [ -z "$cend" ]; then
  fail "the SOLE-CLONE-WRITE-REGION markers are missing from orc-repos-sync.sh"
else
  stray=$(grep -nE "$MUTATING_GIT" "$sync" | code_only \
    | awk -F: -v b="$cbegin" -v e="$cend" '$1 < b || $1 > e')
  if [ -n "$stray" ]; then fail "orc-repos-sync.sh changes a clone outside its write region"; printf '%s\n' "$stray"; else
    pass "every write to a clone is inside the region (lines $cbegin-$cend)"; fi

  inregion=$(sed -n "${cbegin},${cend}p" "$sync" | code_only | grep -cE "$MUTATING_GIT" | tr -d ' ')
  if [ "$inregion" = "3" ]; then
    pass "the region is still exactly three commands: clone, fetch, merge --ff-only"
  else
    fail "the write region holds $inregion git commands, not 3"
    sed -n "${cbegin},${cend}p" "$sync" | code_only | grep -nE "$MUTATING_GIT"
  fi

  forbidden=$(sed -n "${cbegin},${cend}p" "$sync" | code_only \
    | grep -nE 'git[^|;&#]*(reset|--force|-f |clean|stash|checkout|restore|rebase|pull)')
  if [ -n "$forbidden" ]; then
    fail "the write region contains something that can discard work"; printf '%s\n' "$forbidden"
  else
    pass "nothing in the write region can force, reset, stash, clean or discard"
  fi
fi

# shellcheck disable=SC2046
elsewhere=$(grep -nE "$MUTATING_GIT" $(other_scripts | grep -v 'orc-repos-sync.sh') 2>/dev/null | code_only)
if [ -n "$elsewhere" ]; then
  fail "a script other than orc-repos-sync.sh changes a git repository"; printf '%s\n' "$elsewhere"
else
  pass "no other script runs a state-changing git command at all"
fi

# shellcheck disable=SC2046
ghusers=$(grep -nE '(^|[^_[:alnum:]])gh[[:space:]]' $(other_scripts | grep -v 'orc-repos-discover.sh') 2>/dev/null | code_only)
if [ -n "$ghusers" ]; then
  fail "a script other than orc-repos-discover.sh calls gh"; printf '%s\n' "$ghusers"
else
  pass "gh is used only by discovery, and never for Jira"
fi

printf '\n== deleting a clone is a second kind of write, behind a second fence ==\n'
# Deliberately not a fourth line in the region above. That region's promise is
# that every command on it refuses rather than discards, and a removal cannot
# join a list defined by that property: rm is not a git command, so the region
# would go on passing its count of three while its own comment had become false.
# A separate fence, a separate guard, and the check that the two stay separate.
RECURSIVE_RM='(^|[^_[:alnum:]])rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]'
rbegin=$(grep -n 'BEGIN SOLE-CLONE-REMOVE-REGION' "$sync" | cut -d: -f1)
rend=$(grep -n 'END SOLE-CLONE-REMOVE-REGION' "$sync" | cut -d: -f1)
if [ -z "$rbegin" ] || [ -z "$rend" ]; then
  fail "the SOLE-CLONE-REMOVE-REGION markers are missing from orc-repos-sync.sh"
else
  strayrm=$(grep -nE "$RECURSIVE_RM" "$sync" | code_only \
    | awk -F: -v b="$rbegin" -v e="$rend" '$1 < b || $1 > e')
  if [ -n "$strayrm" ]; then
    fail "orc-repos-sync.sh removes a directory tree outside its remove region"
    printf '%s\n' "$strayrm"
  else
    pass "every removal of a clone is inside the remove region (lines $rbegin-$rend)"
  fi

  nrm=$(sed -n "${rbegin},${rend}p" "$sync" | code_only | grep -cE "$RECURSIVE_RM" | tr -d ' ')
  if [ "$nrm" = "1" ]; then
    pass "the region is still exactly one command, with every caller proving its own case"
  else
    fail "the remove region holds $nrm recursive removes, not 1"
    sed -n "${rbegin},${rend}p" "$sync" | code_only | grep -nE "$RECURSIVE_RM"
  fi

  if [ -n "$cbegin" ] && sed -n "${cbegin},${cend}p" "$sync" | code_only | grep -qE "$RECURSIVE_RM"; then
    fail "a removal was added to the fast-forward region, which promises it cannot discard"
  else
    pass "the fast-forward region contains no removal, so its promise is still true"
  fi
fi

# shellcheck disable=SC2046
rmelsewhere=$(grep -nE "$RECURSIVE_RM" $(other_scripts | grep -v 'orc-repos-sync.sh') 2>/dev/null | code_only)
if [ -n "$rmelsewhere" ]; then
  fail "a script other than orc-repos-sync.sh removes a directory tree"
  printf '%s\n' "$rmelsewhere"
else
  pass "no other script removes a directory tree at all"
fi

printf '\n== clones are fast-forwarded or left alone ==\n'
# Real git against a real remote on a file path: no network, no credentials, and
# no stubbing of the thing under test.
w=$(mktemp -d)
gitq() { git -C "$1" -c user.name=orc -c user.email=orc@example.invalid "${@:2}"; }
repos() {
  env ORC_PROJECTS_FILE="$w/projects.yml" ORC_STATE_DIR="$w/state" \
      ORC_CLONE_DIR="$w/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-repos-sync.sh" "$@" 2>&1
}
upstream_commit() {
  printf '%s\n' "$1" > "$w/seed/app.txt"
  gitq "$w/seed" commit --quiet -am "$1"
  gitq "$w/seed" push --quiet origin staging
}

git -c init.defaultBranch=staging init --quiet "$w/seed"
git -C "$w/seed" symbolic-ref HEAD refs/heads/staging
printf 'one\n' > "$w/seed/app.txt"
gitq "$w/seed" add app.txt
gitq "$w/seed" commit --quiet -m one
# A main branch that deliberately differs. A clone that assumed main would be
# reasoning against code nobody is shipping, which is the whole point of making
# default_branch explicit.
gitq "$w/seed" checkout --quiet -b main
printf 'main is not the branch we ship\n' > "$w/seed/app.txt"
gitq "$w/seed" commit --quiet -am main-only
gitq "$w/seed" checkout --quiet staging
git init --bare --quiet "$w/upstream.git"
gitq "$w/seed" remote add origin "$w/upstream.git"
gitq "$w/seed" push --quiet origin staging main
# The remote's own default is main, so nothing but the config can produce staging.
git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main

cat > "$w/projects.yml" <<YML
app:
  remote: $w/upstream.git
  default_branch: staging
  repo: $w/clones/app
  verify: unit-only
YML

out=$(repos --quiet)
if printf '%s' "$out" | grep -q 'cloned'; then pass "a missing clone is cloned"; else
  fail "the missing clone was not cloned"; printf '%s\n' "$out"; fi
if [ "$(git -C "$w/clones/app" symbolic-ref --short HEAD 2>/dev/null)" = "staging" ] \
   && grep -q '^one$' "$w/clones/app/app.txt" 2>/dev/null; then
  pass "it is on the configured default_branch, not the remote's main"
else
  fail "the clone did not land on the branch the config names"
  git -C "$w/clones/app" symbolic-ref --short HEAD 2>/dev/null || true
fi

upstream_commit two
out=$(repos --quiet)
if printf '%s' "$out" | grep -q 'advanced' && grep -q '^two$' "$w/clones/app/app.txt"; then
  pass "a clone that is behind is fast-forwarded"
else
  fail "the clone was not fast-forwarded"; printf '%s\n' "$out"; fi

printf 'work in progress, not committed\n' >> "$w/clones/app/app.txt"
before=$(git -C "$w/clones/app" rev-parse HEAD)
upstream_commit three
out=$(repos --quiet); rc=$?
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q 'STUCK'; then
  pass "a dirty clone is reported as STUCK and the run fails"
else
  fail "a dirty clone was not reported (exit $rc)"; printf '%s\n' "$out"; fi
if [ "$(git -C "$w/clones/app" rev-parse HEAD)" = "$before" ] \
   && grep -q 'work in progress' "$w/clones/app/app.txt"; then
  pass "the dirty clone was left exactly as it was found, edit included"
else
  fail "the dirty clone was modified; something discarded uncommitted work"; fi
gitq "$w/clones/app" checkout --quiet -- app.txt

out=$(repos --quiet)
if printf '%s' "$out" | grep -q 'advanced'; then
  pass "once it is clean again it fast-forwards normally"
else
  fail "a clean clone would not advance"; printf '%s\n' "$out"; fi

printf 'a local commit nobody pushed\n' >> "$w/clones/app/app.txt"
gitq "$w/clones/app" commit --quiet -am local-only
localsha=$(git -C "$w/clones/app" rev-parse HEAD)
upstream_commit four
out=$(repos --quiet)
if printf '%s' "$out" | grep -q 'STUCK' && printf '%s' "$out" | grep -q 'diverged'; then
  pass "a diverged clone is reported as diverged, not rebased or reset"
else
  fail "a diverged clone was not reported"; printf '%s\n' "$out"; fi
if [ "$(git -C "$w/clones/app" rev-parse HEAD)" = "$localsha" ]; then
  pass "the local commit is still there"
else
  fail "the local commit was lost"; fi

repos --quiet >/dev/null; out=$(repos --quiet)
if printf '%s' "$out" | grep -q 'STUCK 3 RUNS IN A ROW'; then
  pass "a repository stuck three runs running is impossible to miss"
else
  fail "repeated failure to advance is not escalated"; printf '%s\n' "$out"; fi

gitq "$w/clones/app" reset --quiet --hard origin/staging
upstream_commit five
before=$(git -C "$w/clones/app" rev-parse HEAD)
repos --status --quiet >/dev/null
if [ "$(git -C "$w/clones/app" rev-parse HEAD)" = "$before" ]; then
  pass "--status reports without touching anything"
else
  fail "--status moved the clone"; fi

printf '\n== a clone the config no longer names ==\n'
# Repositories were removed from the config and the sync re-run. The clones they
# left behind stayed on disk and nothing looked for them at all. One orphan per
# way a clone can be holding something that exists nowhere else, plus one holding
# nothing, against real git with no network and no credentials.
#
# Two things are proved here and they are not the same thing: that an orphan is
# reported, and that reporting it is all a sync does. The second is the one that
# matters, because a line leaving a YAML file must never be what triggers the
# largest discard in the codebase.
o=$(mktemp -d)
git -c init.defaultBranch=staging init --quiet "$o/seed"
git -C "$o/seed" symbolic-ref HEAD refs/heads/staging
printf 'one\n' > "$o/seed/app.txt"
gitq "$o/seed" add app.txt
gitq "$o/seed" commit --quiet -m one
git init --bare --quiet "$o/upstream.git"
gitq "$o/seed" remote add origin "$o/upstream.git"
gitq "$o/seed" push --quiet origin staging

cat > "$o/projects.yml" <<YML
kept:
  remote: $o/upstream.git
  default_branch: staging
  verify: unit-only
YML

orphrun() {
  env ORC_PROJECTS_FILE="$o/projects.yml" ORC_STATE_DIR="$o/state" \
      ORC_CLONE_DIR="$o/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-repos-sync.sh" "$@" 2>&1
}
orphrun --quiet >/dev/null

ORPHANS="clean dirty unpushed nobranch detached"
for n in $ORPHANS; do
  git clone --quiet --branch staging "$o/upstream.git" "$o/clones/$n" 2>/dev/null
done
printf 'an edit nobody committed\n' >> "$o/clones/dirty/app.txt"
printf 'a commit nobody pushed\n' >> "$o/clones/unpushed/app.txt"
gitq "$o/clones/unpushed" commit --quiet -am local-only
gitq "$o/clones/nobranch" checkout --quiet -b feature/never-pushed
# A detached HEAD holding the only copy of a commit: the branch that held it is
# deleted, so nothing but HEAD points at the work.
gitq "$o/clones/detached" checkout --quiet -b doomed
printf 'work on a branch about to vanish\n' >> "$o/clones/detached/app.txt"
gitq "$o/clones/detached" commit --quiet -am detached-work
gitq "$o/clones/detached" checkout --quiet --detach HEAD
gitq "$o/clones/detached" branch --quiet -D doomed

oout=$(orphrun --quiet); orc=$?
orow() { printf '%s' "$oout" | grep -E "^  $1 +ORPHANED "; }

if orow clean >/dev/null; then
  pass "a clone on disk that the config does not name is reported as ORPHANED"
else
  fail "an orphaned clone was not reported at all"; printf '%s\n' "$oout"; fi
if printf '%s' "$oout" | grep -q 'ORPHANED=5'; then
  pass "the summary line counts them, so the table does not have to be read to notice"
else
  fail "the summary line does not count orphans"; printf '%s\n' "$oout"; fi
if [ "$orc" = "0" ]; then
  pass "an orphan is not a failure, so it does not change the exit code"
else
  fail "an orphan made the run fail (exit $orc)"; fi

# The whole point. Not one of them may be gone, the provably safe one included.
gone=""
for n in $ORPHANS; do [ -d "$o/clones/$n" ] || gone="$gone $n"; done
if [ -z "$gone" ]; then
  pass "a bare sync removed none of them, not even the one it proved safe"
else
  fail "a bare sync deleted$gone; a sync must never discard"; fi

if orow clean | grep -q 'safe to remove'; then
  pass "a clean clone level with its remote is classified safe, with its size"
else
  fail "a clean orphan was not classified safe"; orow clean; fi
if orow clean | grep -qE '[0-9]+(\.[0-9])?[KMG]'; then
  pass "and the size is printed, because that is the reason to care"
else
  fail "the safe orphan was reported without its size"; orow clean; fi

# One assertion per way of holding something unique, each naming which it is: a
# report that says "unsafe" without saying why cannot be acted on.
check_unsafe() {
  if orow "$1" | grep -q 'UNSAFE' && orow "$1" | grep -qF "$2"; then
    pass "$3"
  else
    fail "$1 was not reported unsafe with the right reason ($2)"; orow "$1"; fi
}
check_unsafe dirty "uncommitted change" \
  "a clone with uncommitted changes is unsafe, and the reason says so"
check_unsafe unpushed "on a local branch and on no remote" \
  "a clone with an unpushed commit is unsafe, and the reason says so"
check_unsafe nobranch "branch feature/never-pushed exists on no remote" \
  "a branch that exists nowhere on the remote is unsafe, and it is named"
check_unsafe detached "detached HEAD" \
  "a detached HEAD holding unique work is unsafe, and the reason says so"

if printf '%s' "$oout" | grep -q 'orc-repos-sync.sh --prune'; then
  pass "the exact --prune command is printed rather than left to be worked out"
else
  fail "the report makes the operator work out the command"; printf '%s\n' "$oout"; fi

pout=$(orphrun --quiet --prune)
if [ ! -d "$o/clones/clean" ]; then
  pass "--prune removes the one that was proved safe"
else
  fail "--prune did not remove the safe orphan"; printf '%s\n' "$pout"; fi
survived=""
for n in dirty unpushed nobranch detached; do
  [ -d "$o/clones/$n" ] || survived="$survived $n"
done
if [ -z "$survived" ]; then
  pass "and refuses every one it could not prove, leaving them exactly where they were"
else
  fail "--prune deleted work it had not proved was safe:$survived"; fi
if grep -q 'an edit nobody committed' "$o/clones/dirty/app.txt" 2>/dev/null \
   && git -C "$o/clones/unpushed" log --oneline -1 2>/dev/null | grep -q 'local-only'; then
  pass "the uncommitted edit and the unpushed commit are both still there"
else
  fail "a prune reached work it had refused to remove"; fi
if [ -d "$o/clones/kept" ]; then
  pass "the clone the config does name is untouched by a prune"
else
  fail "--prune removed a clone the config names"; fi

if printf '%s' "$pout" | grep -qF "$o/clones/clean"; then
  pass "the prune report names what it removed"
else
  fail "the prune report does not say what it removed"; printf '%s\n' "$pout"; fi
missing_reason=""
for n in dirty unpushed nobranch detached; do
  printf '%s' "$pout" | grep -qF "$o/clones/$n" || missing_reason="$missing_reason $n"
done
if [ -z "$missing_reason" ] && printf '%s' "$pout" | grep -q 'uncommitted change'; then
  pass "and names every one it kept, with the reason it was kept"
else
  fail "the prune report is silent about what it kept:$missing_reason"; printf '%s\n' "$pout"; fi

# Orphan-ness is decided against the config and never against the names on the
# command line. A targeted sync that treated the unmentioned projects as orphans
# would offer to delete the whole clone tree on the next --prune.
cat > "$o/two.yml" <<YML
kept:
  remote: $o/upstream.git
  default_branch: staging
  verify: unit-only
alsokept:
  remote: $o/upstream.git
  default_branch: staging
  verify: unit-only
YML
tworun() {
  env ORC_PROJECTS_FILE="$o/two.yml" ORC_STATE_DIR="$o/tstate" \
      ORC_CLONE_DIR="$o/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-repos-sync.sh" "$@" 2>&1
}
tworun --quiet >/dev/null
tworun --quiet --prune kept >/dev/null
if [ -d "$o/clones/alsokept" ]; then
  pass "a project the config names but the command line did not is not an orphan"
else
  fail "a targeted --prune deleted a configured project that went unmentioned"; fi

bothout=$(orphrun --status --prune 2>&1)
if printf '%s' "$bothout" | grep -q 'pick one'; then
  pass "--status and --prune together are refused rather than quietly reconciled"
else
  fail "--status --prune was accepted, and one of the two was ignored"
  printf '%s\n' "$bothout"; fi

# A config emptied of every project is exactly when every clone is an orphan, and
# "nothing to sync" is the least useful thing that could be said at that point.
: > "$o/empty.yml"
eout=$(env ORC_PROJECTS_FILE="$o/empty.yml" ORC_STATE_DIR="$o/estate" \
  ORC_CLONE_DIR="$o/clones" ORC_REPO_SYNC_TTL=0 \
  "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet 2>&1)
if printf '%s' "$eout" | grep -q 'ORPHANED'; then
  pass "a config with no projects left still reports what is on disk"
else
  fail "an emptied config said nothing to sync and stopped there"; printf '%s\n' "$eout"; fi

rm -rf "$o"

printf '\n== a reset clears the caches and says what it cannot clear ==\n'
# Two caches, two different kinds of thing, and one command over both. What is
# actually being checked here is the third thing: that it tells the operator the
# truth on the way out. A reset that silently leaves the same tickets unjudgeable
# is worse than no reset command, because the next run reads as a broken refiner.
rs=$(mktemp -d)
mkdir -p "$rs/config" "$rs/.okf/subsystems" "$rs/state/.repos" "$rs/clones"
git -c init.defaultBranch=staging init --quiet "$rs/seed"
git -C "$rs/seed" symbolic-ref HEAD refs/heads/staging
printf 'one\n' > "$rs/seed/app.txt"
gitq "$rs/seed" add app.txt
gitq "$rs/seed" commit --quiet -m one
git init --bare --quiet "$rs/upstream.git"
gitq "$rs/seed" remote add origin "$rs/upstream.git"
gitq "$rs/seed" push --quiet origin staging

cat > "$rs/config/projects.yml" <<YML
kept:
  remote: $rs/upstream.git
  default_branch: staging
  verify: unit-only
YML
cat > "$rs/.okf/index.md" <<'MD'
---
okf_version: "0.2"
---
# Knowledge bundle
MD
cat > "$rs/.okf/subsystems/kept.md" <<'MD'
---
verified: 2026-01-01
---
# Kept
MD

reset_run() {
  env ORC_ROOT="$rs" ORC_PROJECTS_FILE="$rs/config/projects.yml" \
      ORC_STATE_DIR="$rs/state" ORC_CLONE_DIR="$rs/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-reset.sh" "$@" 2>&1
}
# The configured clone, so the tree holds something that is not an orphan and a
# run can be shown to leave it alone.
env ORC_ROOT="$rs" ORC_PROJECTS_FILE="$rs/config/projects.yml" \
    ORC_STATE_DIR="$rs/state" ORC_CLONE_DIR="$rs/clones" ORC_REPO_SYNC_TTL=0 \
    "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet >/dev/null 2>&1
# One orphan holding nothing, one holding the only copy of something.
git clone --quiet --branch staging "$rs/upstream.git" "$rs/clones/gone-clean" 2>/dev/null
git clone --quiet --branch staging "$rs/upstream.git" "$rs/clones/gone-dirty" 2>/dev/null
printf 'an edit nobody committed\n' >> "$rs/clones/gone-dirty/app.txt"

seed_state() {
  mkdir -p "$rs/state/.repos" "$rs/state/.bundle"
  printf 'phase=refined\n' > "$rs/state/ORC-1.meta"
  printf 'judged\n'        > "$rs/state/ORC-1.status"
  printf '0\n'             > "$rs/state/.jira-watermark"
  printf '1\n'             > "$rs/state/.repos/kept.fetched"
  printf 'x\n'             > "$rs/state/.bundle/announced"
}
bundle_sum() { find "$rs/.okf" -type f | sort | xargs cat 2>/dev/null | _sha1; }
state_count() { find "$rs/state" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }

# Static first, because the behaviour below is only trustworthy if this holds.
reset="$ORC_ROOT/bin/orc-reset.sh"
if grep -nE "$RECURSIVE_RM" "$reset" | code_only | grep -q .; then
  fail "bin/orc-reset.sh removes a directory tree; the one recursive remove has to stay alone"
  grep -nE "$RECURSIVE_RM" "$reset" | code_only
else
  pass "bin/orc-reset.sh removes no directory tree: flat files, then rmdir, which refuses rather than discards"
fi
if grep -qE -- '--prune' "$reset"; then
  pass "and every clone removal is delegated to the command that owns the fence"
else
  fail "bin/orc-reset.sh does not delegate to orc-repos-sync.sh --prune"
fi

seed_state
files_before=$(state_count)
sum_bundle=$(bundle_sum)
sum_cfg=$(_sha1 < "$rs/config/projects.yml")

dry=$(reset_run --dry-run)
if [ "$(state_count)" = "$files_before" ] \
   && [ -d "$rs/clones/gone-clean" ] && [ -d "$rs/clones/gone-dirty" ] \
   && [ -d "$rs/clones/kept" ]; then
  pass "a dry run removes nothing at all: $files_before state file(s) and every clone still there"
else
  fail "a dry run removed something"
  printf '%s\n' "$dry" | tail -20; fi
if printf '%s' "$dry" | grep -q 'gone-clean' && printf '%s' "$dry" | grep -q 'safe to remove'; then
  pass "and it still names the clone it would have removed, and how much that is"
else
  fail "a dry run did not say what it would remove"; printf '%s\n' "$dry" | head -20; fi
if printf '%s' "$dry" | grep -q 'gone-dirty' \
   && printf '%s' "$dry" | grep -q 'uncommitted change'; then
  pass "the clone holding uncommitted work is named as one it would refuse, with the reason"
else
  fail "the unsafe clone was not named with its reason"; printf '%s\n' "$dry" | head -30; fi
if printf '%s' "$dry" | grep -q 'WILL STILL NOT BE RE-JUDGED'; then
  pass "a dry run says what a reset cannot do, which is the half an operator gets wrong"
else
  fail "the dry run did not carry the report about the ticket markers"; fi

# The one thing under state/ nothing can rebuild. Every other file there is a
# cache of something Jira or git still holds; a verdict's list of the words
# refinement could not resolve is not, because the comment on the ticket
# deliberately carries none of it. So a reset has to say what it is about to make
# unrecoverable, and name the command that would have kept it.
jq -nc '{key:"ORC-9", prompt_version:"refine-reset", verdict:"needs_input",
         locality_basis:"search", terms_unresolved:["Recall"]}' \
  > "$rs/state/ORC-9.verdict.json"
warned=$(reset_run --dry-run)
if printf '%s' "$warned" | grep -q 'GAP RECORD IS ABOUT TO GO' \
   && printf '%s' "$warned" | grep -q 'ORC-9 (prompt refine-reset)' \
   && printf '%s' "$warned" | grep -q 'bin/orc-gap-loop.sh'; then
  pass "an unrecorded gap is named before anything is removed, with the command that would keep it"
else
  fail "the reset says nothing about the one thing in the cache that cannot be rebuilt"
  printf '%s\n' "$warned" | tail -30; fi
# And a reset does not quietly write that record itself: an operator asking for a
# clean slate did not ask for a file to appear.
mkdir -p "$rs/data"
: > "$rs/data/gaps.jsonl"
reset_run --dry-run >/dev/null 2>&1
if [ ! -s "$rs/data/gaps.jsonl" ]; then
  pass "and the reset writes nothing to that ledger on its way past"
else
  fail "the reset appended to the gap ledger"; cat "$rs/data/gaps.jsonl"; fi
rm -f "$rs/data/gaps.jsonl" "$rs/state/ORC-9.verdict.json"
rmdir "$rs/data" 2>/dev/null

# A confirmation that was not given. Nothing may go, and it must not be invented
# either: the answer comes from stdin or the run stops.
declined=$(printf 'no\n' | reset_run)
if [ "$(state_count)" = "$files_before" ] && [ -d "$rs/clones/gone-clean" ]; then
  pass "an answer that was not yes removes nothing"
else
  fail "a declined reset removed something"; printf '%s\n' "$declined" | tail -10; fi
noans=$(reset_run </dev/null)
if printf '%s' "$noans" | grep -q 'nothing on stdin'; then
  pass "and with nobody there to answer it says so rather than deciding for them"
else
  fail "a non-interactive reset invented a confirmation"; printf '%s\n' "$noans" | tail -10; fi

# The cache only. Every clone is left where it is, including the one it could
# have proved safe.
seed_state
sonly=$(reset_run --state-only --yes)
if [ -d "$rs/clones/gone-clean" ] && [ -d "$rs/clones/gone-dirty" ]; then
  pass "--state-only leaves every clone alone, the removable one included"
else
  fail "--state-only removed a clone"; printf '%s\n' "$sonly" | tail -20; fi
if [ "$(state_count)" = "0" ]; then
  pass "and it did clear the cache, so the flag is not simply doing nothing"
else
  fail "--state-only left $(state_count) file(s) in state/"; fi

seed_state
out=$(reset_run --yes)
rc=$?
if [ "$rc" = "0" ]; then
  pass "a reset that did what it printed exits 0"
else
  fail "the reset exited $rc"; printf '%s\n' "$out" | tail -20; fi
if [ ! -e "$rs/clones/gone-clean" ]; then
  pass "the clone proved to hold nothing that exists nowhere else is gone"
else
  fail "the safe orphan is still on disk"; fi
if [ -d "$rs/clones/gone-dirty" ] \
   && printf '%s' "$out" | grep -q 'gone-dirty' \
   && printf '%s' "$out" | grep -q 'uncommitted change'; then
  pass "the one holding uncommitted work is refused, still there, and named with the reason"
else
  fail "the unsafe orphan was removed, or refused without saying why"
  printf '%s\n' "$out" | tail -30; fi
if [ -d "$rs/clones/kept" ]; then
  pass "a clone the config still names is not an orphan and is left where it is"
else
  fail "the reset removed a configured clone"; fi
# state/ is enumerated again at the moment it is cleared, because --prune syncs
# on the way past and writes its stamps into the directory being cleared.
if [ "$(state_count)" = "0" ] && [ -d "$rs/state" ]; then
  pass "state/ ends empty, including what the prune itself wrote into it"
else
  fail "state/ still holds $(state_count) file(s)"
  find "$rs/state" -mindepth 1 -type f; fi
if [ -z "$(find "$rs/state" -mindepth 1 -type d 2>/dev/null)" ]; then
  pass "and its subdirectories went with it, by rmdir rather than by a tree remove"
else
  fail "a state subdirectory survived"; find "$rs/state" -mindepth 1 -type d; fi

# The half that is source. Neither of these is derived from anything a reset
# could rebuild, and discarding the bundle has its own command and its own much
# heavier consent.
if [ "$(bundle_sum)" = "$sum_bundle" ]; then
  pass ".okf/ is byte-identical after a reset, verified concept included"
else
  fail "the reset changed the bundle"; fi
if [ "$(_sha1 < "$rs/config/projects.yml")" = "$sum_cfg" ]; then
  pass "config/projects.yml is byte-identical after a reset"
else
  fail "the reset changed the projects config"; fi
if printf '%s' "$out" | grep -q 'orc-onboard.sh reset'; then
  pass "and it names the command that does discard the bundle, so that is not looked for here"
else
  fail "the reset did not say where discarding the bundle lives"; fi

if printf '%s' "$out" | grep -q 'WILL STILL NOT BE RE-JUDGED' \
   && printf '%s' "$out" | grep -q "$ORC_COMMENT_MARKER" \
   && printf '%s' "$out" | grep -q "$LABEL_READY"; then
  pass "the closing report says the same tickets will not be re-judged, and names the comment marker and the labels to remove by hand"
else
  fail "the reset did not tell the operator what a cleared cache does not clear"
  printf '%s\n' "$out" | tail -30; fi

rm -rf "$rs"

printf '\n== a remote that cannot be read is reported as what it is ==\n'
# The failure that cost the most time so far: ten repositories, one cause, and a
# reported detail of "clone failed: and the repository exists." - which is git's
# stderr with the informative line discarded and the generic advice kept. It
# reads like a missing repository and it was a missing ssh key.
a=$(mktemp -d)

# An ssh that fails exactly the way GitHub does when no key is usable. git adds
# its own three lines after this one, and those three are what used to be all
# anybody saw. No network and no credentials are involved.
cat > "$a/no-key-ssh" <<'SH'
#!/bin/sh
echo "git@github.com: Permission denied (publickey)." >&2
exit 255
SH
chmod +x "$a/no-key-ssh"

cat > "$a/projects.yml" <<'YML'
alpha:
  remote: git@github.com:example/alpha.git
  default_branch: staging
  verify: unit-only
beta:
  remote: git@github.com:example/beta.git
  default_branch: staging
  verify: unit-only
gamma:
  remote: git@github.com:example/gamma.git
  default_branch: staging
  verify: unit-only
YML

authrun() {
  env ORC_PROJECTS_FILE="$a/projects.yml" ORC_STATE_DIR="$a/state" \
      ORC_CLONE_DIR="$a/clones" ORC_REPO_SYNC_TTL=0 \
      GIT_SSH_COMMAND="$a/no-key-ssh" \
      "$ORC_ROOT/bin/orc-repos-sync.sh" "$@" 2>&1
}

cfg_sum_before=$(_sha1 < "$a/projects.yml")
aout=$(authrun --quiet)

if printf '%s' "$aout" | grep -q 'Permission denied (publickey)'; then
  pass "the reported detail is git's own first meaningful line"
else
  fail "git's real message did not reach the report"; printf '%s\n' "$aout"; fi

if printf '%s' "$aout" | grep -q 'and the repository exists'; then
  fail "the tail of git's stderr is still what gets reported"
else
  pass "the misleading tail is not reported in its place"; fi

if printf '%s' "$aout" | grep -qE '^  alpha +AUTH '; then
  pass "an authentication failure is its own outcome, not STUCK"
else
  fail "an authentication failure was not reported as one"; printf '%s\n' "$aout"; fi

if printf '%s' "$aout" | grep -q 'AUTH=3'; then
  pass "the summary line counts them as auth failures"
else
  fail "the summary line does not count auth failures"; printf '%s\n' "$aout"; fi

# Collapsed, because ten copies of one box bury the summary underneath them.
n_banner=$(printf '%s' "$aout" | grep -c 'AUTHENTICATION FAILED' | tr -d ' ')
if [ "$n_banner" = "1" ]; then
  pass "three repositories failing for one reason produce one report, not three"
else
  fail "identical failures were not collapsed ($n_banner reports for one cause)"; fi
if printf '%s' "$aout" | grep -q 'alpha' \
   && printf '%s' "$aout" | grep -q 'beta' \
   && printf '%s' "$aout" | grep -q 'gamma'; then
  pass "the one report still names every project it applies to"
else
  fail "the collapsed report lost the affected projects"; fi

if printf '%s' "$aout" | grep -q 'ssh' && printf '%s' "$aout" | grep -q 'protocol'; then
  pass "the protocol mismatch is named rather than left to be guessed"
else
  fail "nothing in the report names the protocol"; printf '%s\n' "$aout"; fi
if printf '%s' "$aout" | grep -q 'sed -i.bak' \
   && printf '%s' "$aout" | grep -q 'https://github.com/' \
   && printf '%s' "$aout" | grep -qF "$a/projects.yml"; then
  pass "the exact command to convert the config is printed, naming the config"
else
  fail "no conversion command was printed"; printf '%s\n' "$aout"; fi
if [ "$(_sha1 < "$a/projects.yml")" = "$cfg_sum_before" ]; then
  pass "the config is byte-identical afterwards: it advised, it did not rewrite"
else
  fail "the sync script rewrote config/projects.yml"; fi

# The .bak used to be advertised as a safety net. It is not one: it exists only
# because the sed macOS ships will not take an empty -i suffix, and an untracked
# copy of the config left in the working tree is a thing to commit by accident
# rather than protection against one. config/projects.yml is tracked, so git is
# the undo. So the suggested command deletes its own .bak, and the way to know
# that is to run exactly what was printed rather than to read it.
mkdir -p "$a/undo"
cp "$a/projects.yml" "$a/undo/projects.yml"
uout=$(env ORC_PROJECTS_FILE="$a/undo/projects.yml" ORC_STATE_DIR="$a/ustate" \
  ORC_CLONE_DIR="$a/uclones" ORC_REPO_SYNC_TTL=0 GIT_SSH_COMMAND="$a/no-key-ssh" \
  "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet 2>&1)
suggested=$(printf '%s' "$uout" | grep -F 'sed -i.bak' | head -1 | sed 's/^[[:space:]]*//')
if [ -n "$suggested" ]; then
  ( eval "$suggested" ) >/dev/null 2>&1
  if grep -q 'remote: https://github.com/example/alpha.git' "$a/undo/projects.yml"; then
    pass "running exactly what was printed converts the config as advertised"
  else
    fail "the suggested command did not convert the config"; printf '%s\n' "$suggested"; fi
  leftover=$(find "$a/undo" -name '*.bak' 2>/dev/null | tr '\n' ' ')
  if [ -z "$leftover" ]; then
    pass "and leaves no .bak behind, so nothing untracked is left to commit by mistake"
  else
    fail "the suggested command left a .bak in the working tree: $leftover"; fi
else
  fail "no conversion command was printed, so there was nothing to run"; printf '%s\n' "$uout"; fi

# Flattened first: the banner wraps prose at 76 columns, so any phrase in it can
# be split across two lines and a grep for one is a grep for a coincidence.
uflat=$(printf '%s' "$uout" | tr '\n' ' ' | tr -s ' ')
if printf '%s' "$uflat" | grep -q 'not a safety net'; then
  pass "the report no longer sells the .bak as a safety net"
else
  fail "the report still claims the .bak protects something"; printf '%s\n' "$uout"; fi
if printf '%s' "$uflat" | grep -q 'is tracked, so git is the undo'; then
  pass "and says what the real undo is, which is git"
else
  fail "the report does not say that the config is tracked and git is the undo"; fi

# This class of bug hides itself: the noise goes to stderr, and every check that
# captures stderr into a variable in order to grep it swallows the evidence.
if printf '%s' "$aout" | grep -qE 'No such file or directory|orc-repos-sync\.sh: line [0-9]+'; then
  fail "the run leaked a shell diagnostic of its own"; printf '%s\n' "$aout"
else
  pass "a first run against an empty cache emits no shell errors of its own"; fi

# Column widths from the content. A real project name ran to 24 characters while
# the format string said 16, so one long name pushed every column after it out of
# line and the table stopped being a table.
long_name="aaaaaaaaaa-bbbbbbbbbb-cccccccccc-dddddddd"
cat > "$a/wide.yml" <<YML
$long_name:
  remote: git@github.com:example/wide.git
  default_branch: staging
  verify: unit-only
tiny:
  remote: git@github.com:example/tiny.git
  default_branch: staging
  verify: unit-only
YML
wout=$(env ORC_PROJECTS_FILE="$a/wide.yml" ORC_STATE_DIR="$a/wstate" \
  ORC_CLONE_DIR="$a/wclones" ORC_REPO_SYNC_TTL=0 GIT_SSH_COMMAND="$a/no-key-ssh" \
  "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet 2>&1)
if [ "${#long_name}" = "41" ]; then : ; else fail "the alignment test name is not 41 characters"; fi
if printf '%s' "$wout" | grep -qF "  $long_name  "; then
  pass "a 41-character project name is printed in full"
else
  fail "a long project name was truncated"; printf '%s\n' "$wout"; fi
# Every table line's second column must begin at the same offset, header included.
align=$(printf '%s' "$wout" | awk '
  $2 == "OUTCOME" || $2 == "AUTH" || $2 == "STUCK" || $2 == "ok" \
    || $2 == "cloned" || $2 == "advanced" || $2 == "unmanaged" || $2 == "ORPHANED" {
      n++; at[index($0, $2 " ")] = 1
    }
  END { d = 0; for (k in at) d++; printf "%d %d", n, d }')
if [ "$align" = "3 1" ]; then
  pass "header and rows share one column offset, so the table stays aligned"
else
  fail "the table columns do not line up (rows/distinct offsets: $align)"; printf '%s\n' "$wout"; fi

# The stuck counter counts runs. It used to count invocations of this script, and
# the daemon syncs once per pass while refinement asks again per ticket, so a
# first pass over five tickets announced "STUCK 3 RUNS IN A ROW" before anything
# had happened twice.
cat > "$a/stuck.yml" <<YML
solo:
  remote: $a/nowhere.git
  default_branch: staging
  verify: unit-only
YML
long_clones="$a/clones-with-a-deliberately-long-name-so-a-62-column-cut-breaks-it"
stuckrun() {
  env ORC_PROJECTS_FILE="$a/stuck.yml" ORC_STATE_DIR="$1" \
      ORC_CLONE_DIR="$long_clones" ORC_REPO_SYNC_TTL=0 ORC_STUCK_RUN_WINDOW="$2" \
      "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet 2>&1
}

stuckrun "$a/s1" 300 >/dev/null
stuckrun "$a/s1" 300 >/dev/null
sout=$(stuckrun "$a/s1" 300)
if printf '%s' "$sout" | grep -q 'RUNS IN A ROW'; then
  fail "three invocations inside one run escalated as though they were three runs"
  printf '%s\n' "$sout"
else
  pass "repeated invocations inside one run do not escalate"; fi
if [ "$(cut -f1 < "$a/s1/.repos/solo.stuck" 2>/dev/null)" = "1" ]; then
  pass "and the recorded count is 1, because that is how many runs there were"
else
  fail "the recorded count is $(cut -f1 < "$a/s1/.repos/solo.stuck" 2>/dev/null), not 1"; fi
if printf '%s' "$sout" | grep -q 'STUCK: solo'; then
  pass "a first failure is still reported, just not as an emergency"
else
  fail "a first failure was not reported at all"; printf '%s\n' "$sout"; fi

stuckrun "$a/s2" 0 >/dev/null
stuckrun "$a/s2" 0 >/dev/null
sout=$(stuckrun "$a/s2" 0)
if printf '%s' "$sout" | grep -q 'STUCK 3 RUNS IN A ROW'; then
  pass "three genuine runs do still escalate, so the counter is not switched off"
else
  fail "repeated failure across runs is no longer escalated"; printf '%s\n' "$sout"; fi
if printf '%s' "$sout" | grep -qF "$long_clones/solo"; then
  pass "the escalated report prints the clone path whole, not cut mid-word"
else
  fail "the report truncated the path, which is the only actionable thing in it"
  printf '%s\n' "$sout"; fi

rm -rf "$a"

printf '\n== a slow run says so, and a wedged one does not run forever ==\n'
# The other half of the same defect. golden/run.sh ended the refinement call in
# 2>/dev/null, so a real run printed nothing for minutes and discarded anything
# the agent said - including a question it was waiting on an answer to. It looked
# frozen while working correctly.
# golden/run.sh is on this list because a wrapper that hides the refiner's stderr
# hides it just as completely as the call itself did. golden/diff.sh swallowed its
# own inner run, so an 85-minute two-sided comparison printed two lines: exactly
# the symptom this check was written for, one call site further out.
# shellcheck disable=SC2046
swallowed=$(grep -nE '(orc-refine\.sh|golden/run\.sh|claude )[^|;&#]*2>[[:space:]]*/dev/null' $(other_scripts) 2>/dev/null | code_only)
if [ -n "$swallowed" ]; then
  fail "a script still discards the refiner's stderr"; printf '%s\n' "$swallowed"
else
  pass "no script sends the refiner's or the agent's stderr to /dev/null"
fi
for f in bin/orc-refine.sh golden/run.sh; do
  if grep -q 'run_with_timeout' "$ORC_ROOT/$f"; then
    pass "$f puts a wall-clock limit on the call that can block"
  else
    fail "$f has no timeout, so one wedged call blocks the whole run"
  fi
done

# Which of the two fires matters. The inner limit names the agent and says how to
# raise it; the outer one can only say that the ticket did not finish. Raising
# either default without looking at the other is how they end up level, and then
# a slow agent is reported as a wedged refinement.
#
# The inner limit is per agent call, and one refinement makes more than one:
# the first read, and the adversarial re-read on a round about to become
# terminal. So the comparison is against the inner limit times the number of
# calls a refinement can make, read out of orc-refine.sh rather than written down
# twice - a second call added later without raising the outer limits fails here
# instead of turning a thinking agent into a wedged refinement.
inner=$(sed -n 's/.*ORC_AGENT_TIMEOUT:-\([0-9][0-9]*\)}.*/\1/p' "$ORC_ROOT/bin/orc-refine.sh")
calls=$(sed -n 's/^AGENT_CALLS_MAX=\([0-9][0-9]*\).*/\1/p' "$ORC_ROOT/bin/orc-refine.sh")
if [ -n "$calls" ] && [ "$calls" -ge 1 ]; then
  pass "bin/orc-refine.sh says how many agent calls one refinement can make (${calls})"
else
  fail "bin/orc-refine.sh does not say how many agent calls a refinement can make; the comparison below is guessing"
  calls=1
fi
for f in golden/run.sh bin/orc-locality-score.sh; do
  outer=$(sed -n 's/.*ORC_GOLDEN_TIMEOUT:-\([0-9][0-9]*\)}.*/\1/p' "$ORC_ROOT/$f")
  if [ -n "$inner" ] && [ -n "$outer" ] && [ "$outer" -gt $(( inner * calls )) ]; then
    pass "$f waits ${outer}s for a refinement that can make ${calls} agent call(s) of ${inner}s, so the inner one fires first"
  else
    fail "$f (${outer:-?}s) does not outlast ${calls} agent call(s) of ${inner:-?}s; a slow agent would be reported as a wedged refinement"
  fi
done
unset calls

# The real regression risk is stderr, so it is proved behaviourally rather than
# by reading the source: a stand-in refiner that fails loudly, run through the
# actual golden/run.sh, and the operator must be able to read what it said.
g=$(mktemp -d)
mkdir -p "$g/bin" "$g/golden/expected" "$g/prompts"
ln -s "$ORC_ROOT/bin/orc-lib.sh" "$g/bin/orc-lib.sh"
ln -s "$ORC_ROOT/golden/run.sh" "$g/golden/run.sh"
printf 'a prompt\n' > "$g/prompts/refine.md"
cat > "$g/golden/expected/TEST-1.json" <<'JSON'
{"key":"TEST-1","verdict":"ready","max_questions":0,"expect_files":[],"duplicate_of":null}
JSON

fake_refiner() { cat > "$g/bin/orc-refine.sh"; chmod +x "$g/bin/orc-refine.sh"; }
goldenrun() { env ORC_STATE_DIR="$g/state" "$g/golden/run.sh" "$@" 2>&1; }

fake_refiner <<'SH'
#!/bin/sh
echo "the agent could not start: NO_API_KEY_IN_ENVIRONMENT" >&2
exit 2
SH
gout=$(goldenrun)
if printf '%s' "$gout" | grep -q 'NO_API_KEY_IN_ENVIRONMENT'; then
  pass "stderr from a failing refiner reaches the operator"
else
  fail "the refiner's stderr was swallowed; a failing run says nothing"; printf '%s\n' "$gout"; fi
if printf '%s' "$gout" | grep -q 'TEST-1: refining'; then
  pass "each ticket announces itself before the call, so a slow run looks slow"
else
  fail "no per-ticket progress, so a slow run is indistinguishable from a hang"
  printf '%s\n' "$gout"; fi

# The harness replays canned verdicts against fixture tickets, so a fetch is
# something it can only get wrong: on a checkout whose config names real
# repositories, `auto` turns a prompt-agreement measurement into a clone of every
# one of them. Asked for with ORC_REPO_SYNC=on in the calling environment, so this
# proves the value is pinned rather than merely defaulted.
fake_refiner <<'SH'
#!/bin/sh
echo "SYNC=[${ORC_REPO_SYNC-unset}]" >&2
echo '{"verdict":"ready"}'
SH
gout=$(env ORC_STATE_DIR="$g/state" ORC_REPO_SYNC=on "$g/golden/run.sh" 2>&1)
if printf '%s' "$gout" | grep -q 'SYNC=\[off\]'; then
  pass "the golden harness pins the fetch off, even when asked for one"
else
  fail "golden/run.sh let refinement fetch; it replays fixtures and has no remote to read"
  printf '%s\n' "$gout" | grep 'SYNC=' ; fi

# The locality column is scored under replay and nowhere else. The expectations
# name paths in an invented product while the configured repositories are the real
# ones, so the canned verdict hits 2/2 because it was authored to and a real agent
# hits 0/2 because the paths exist nowhere - two numbers, neither about locality.
gout=$(env ORC_STATE_DIR="$g/state" "$g/golden/run.sh" --refiner claude 2>/dev/null)
if printf '%s' "$gout" | grep -q 'n/a' && ! printf '%s' "$gout" | grep -q 'locality:'; then
  pass "off replay the locality column says n/a, and the summary line leaves it out"
else
  fail "a refiner that cannot hit the expected paths is still scored against them"
  printf '%s\n' "$gout" | sed -n '/KEY/,$p'; fi
gout=$(env ORC_STATE_DIR="$g/state" "$g/golden/run.sh" 2>/dev/null)
if printf '%s' "$gout" | grep -q 'locality: '; then
  pass "and under replay it is still scored, because there the expectation is the harness's own"
else
  fail "the locality column went away for the one refiner it means something for"
  printf '%s\n' "$gout" | sed -n '/KEY/,$p'; fi

fake_refiner <<'SH'
#!/bin/sh
sleep 120
SH
gstart=$(orc_epoch)
gout=$(goldenrun --timeout 2)
gtook=$(( $(orc_epoch) - gstart ))
if [ "$gtook" -lt 60 ]; then
  pass "a wedged refiner is killed rather than waited on (gave up after ${gtook}s)"
else
  fail "a wedged refiner was not killed; the run blocked for ${gtook}s"; fi
if printf '%s' "$gout" | grep -q 'TEST-1: TIMEOUT'; then
  pass "the timeout names the ticket it gave up on"
else
  fail "the timeout does not say which ticket wedged"; printf '%s\n' "$gout"; fi
if printf '%s' "$gout" | grep -qE 'TIMEOUT after [0-9]+s'; then
  pass "and how long it waited, so the limit can be judged"
else
  fail "the timeout does not report the elapsed time"; printf '%s\n' "$gout"; fi

# And a killed call is counted as a timeout rather than as a wrong answer. Scored
# as disagreement, the next prompt change that adds a step of reasoning reads as a
# prompt regression, which is the opposite of what this harness is for.
gjson=$(env ORC_STATE_DIR="$g/state" "$g/golden/run.sh" --timeout 2 --json 2>/dev/null)
if printf '%s' "$gjson" \
     | jq -e '.summary.timeouts == 1 and .summary.answered == 0
              and .summary.verdict_agreement == 0' >/dev/null 2>&1; then
  pass "a killed ticket is counted in the timeout column and left out of the agreement figure"
else
  fail "a timeout is still scored as a verdict disagreement"; printf '%s\n' "$gjson" | head -3; fi
if printf '%s' "$gjson" | jq -e '.rows[0].timed_out == true' >/dev/null 2>&1; then
  pass "and the row says which ticket it was, for a caller as well as a reader"
else
  fail "the machine-readable half does not mark the row as a timeout"; fi

rm -rf "$g"

printf '\n== discovery proposes, it never writes the config ==\n'
cp "$ORC_ROOT/config/projects.yml" "$w/discover.yml"
sum_before=$(_sha1 < "$w/discover.yml")
disc=$(env ORC_PROJECTS_FILE="$w/discover.yml" ORC_STATE_DIR="$w/state" \
  "$ORC_ROOT/bin/orc-repos-discover.sh" --org example --offline 2>&1)
sum_after=$(_sha1 < "$w/discover.yml")
if [ "$sum_before" = "$sum_after" ]; then
  pass "the config is byte-identical after a discovery run"
else
  fail "discovery modified config/projects.yml"; fi
# One script writes the config, and it is the one whose whole job is the consent
# step. Everything else - discovery above all - stays a proposal.
CONFIG_WRITE='>[[:space:]]*"?\$?[A-Za-z_{]*(PROJECTS_FILE|projects\.yml)'
# shellcheck disable=SC2046
strayw=$(grep -nE "$CONFIG_WRITE" $(other_scripts | grep -v 'orc-onboard.sh') 2>/dev/null | code_only)
if [ -n "$strayw" ]; then
  fail "a script other than orc-onboard.sh writes the projects config"; printf '%s\n' "$strayw"
else
  pass "only orc-onboard.sh writes the projects config"
fi
if grep -nE "$CONFIG_WRITE" "$ORC_ROOT/bin/orc-repos-discover.sh" 2>/dev/null | code_only | grep -q .; then
  fail "discovery writes the projects config; it proposes and nothing else"
else
  pass "discovery still does not write the config at all"
fi
if printf '%s' "$disc" | grep -q 'default_branch: staging' \
   && printf '%s' "$disc" | grep -q 'default_branch: trunk'; then
  pass "the proposed default_branch is what each remote says, never assumed"
else
  fail "discovery did not read the default branch per repository"; printf '%s\n' "$disc"; fi
if printf '%s' "$disc" | grep -q 'legacy-portal:'; then
  fail "discovery proposed an archived repository"
else
  pass "archived repositories are not proposed"; fi
if printf '%s' "$disc" | grep -q 'ORC:'; then
  fail "discovery proposed a project the config already has, uncommented"
else
  pass "a project already in the config is not proposed as a live entry"; fi
if [ "$(printf '%s' "$disc" | grep -n 'api:' | cut -d: -f1)" -lt \
     "$(printf '%s' "$disc" | grep -n 'infra:' | cut -d: -f1)" ]; then
  pass "the proposal is ranked by recent activity"
else
  fail "the proposal is not ranked by recent activity"; fi

# A remote spelled in a protocol these credentials cannot use fails on every
# repository at once, for one reason, and the proposal is where that is decided.
# Offline it stays offline: no gh, no probe, and it says so instead of pretending
# it detected something.
if printf '%s' "$disc" | grep -q 'Remotes are proposed over'; then
  pass "the proposal states which protocol it chose"
else
  fail "the proposal does not say which protocol it chose"; printf '%s\n' "$disc"; fi
if printf '%s' "$disc" | grep -q 'because' && printf '%s' "$disc" | grep -q 'fixture'; then
  pass "and why, so the choice is visible rather than magic"
else
  fail "the proposal does not say why it chose that protocol"; printf '%s\n' "$disc"; fi
if printf '%s' "$disc" | grep -q 'remote: https://github.com/example/api.git' \
   && ! printf '%s' "$disc" | grep -q 'remote: git@'; then
  pass "every proposed remote is in the chosen protocol"
else
  fail "the proposed remotes are not in the protocol the proposal named"; printf '%s\n' "$disc"; fi

sshdisc=$(env ORC_PROJECTS_FILE="$w/discover.yml" ORC_STATE_DIR="$w/state" \
  "$ORC_ROOT/bin/orc-repos-discover.sh" --org example --offline --protocol ssh 2>&1)
if printf '%s' "$sshdisc" | grep -q 'remote: git@github.com:example/api.git' \
   && ! printf '%s' "$sshdisc" | grep -q 'remote: https://'; then
  pass "--protocol overrides the detection, in every remote it proposes"
else
  fail "--protocol did not change the proposed remotes"; printf '%s\n' "$sshdisc"; fi
if printf '%s' "$sshdisc" | grep -q 'proposed over ssh'; then
  pass "and the proposal says so, rather than describing the protocol it did not use"
else
  fail "the proposal names the wrong protocol"; printf '%s\n' "$sshdisc"; fi
if [ "$sum_before" = "$(_sha1 < "$w/discover.yml")" ]; then
  pass "still byte-identical: detecting a protocol is not a licence to write the config"
else
  fail "discovery modified the config while detecting a protocol"; fi

printf '\n== onboarding composes the steps, and the selection is the consent ==\n'
# A whole organisation on local paths: no network, no gh, no credentials, and the
# clones are real git clones of real repositories rather than stubs. This is the
# path the acceptance suite has to be able to reach, because a feature it cannot
# reach is a feature nobody can trust.
ob=$(mktemp -d)
obgit() { git -C "$1" -c user.name=orc -c user.email=orc@example.invalid "${@:2}"; }
ob_repo() {   # name branch
  local d="$ob/build/$1"
  mkdir -p "$d/app/models" "$d/config/locales"
  git -c init.defaultBranch="$2" init --quiet "$d"
  git -C "$d" symbolic-ref HEAD "refs/heads/$2"
  printf 'class Case < ApplicationRecord\nend\n' > "$d/app/models/case.rb"
  printf 'en:\n  case: Patient file\n' > "$d/config/locales/en.yml"
  obgit "$d" add -A
  obgit "$d" commit --quiet -m seed
  git clone --bare --quiet "$d" "$ob/remotes/$1.git"
  git -C "$ob/remotes/$1.git" symbolic-ref HEAD "refs/heads/$2"
}
mkdir -p "$ob/remotes" "$ob/fixtures/org" "$ob/config"
ob_repo alpha staging
ob_repo beta main
ob_repo gamma staging
ob_repo delta staging
# beta really is main and alpha really is staging, which is the whole point of
# reading the default branch per repository instead of assuming one.
cat > "$ob/fixtures/org/testorg.json" <<JSON
[
  {"name":"alpha","description":"the first one","url":"$ob/remotes/alpha.git","sshUrl":"$ob/remotes/alpha.git","defaultBranchRef":{"name":"staging"},"primaryLanguage":{"name":"Ruby"},"pushedAt":"2026-08-18T10:00:00Z","isArchived":false},
  {"name":"beta","description":"the second one","url":"$ob/remotes/beta.git","sshUrl":"$ob/remotes/beta.git","defaultBranchRef":{"name":"main"},"primaryLanguage":{"name":"Dart"},"pushedAt":"2026-08-17T10:00:00Z","isArchived":false},
  {"name":"gamma","description":"the third one","url":"$ob/remotes/gamma.git","sshUrl":"$ob/remotes/gamma.git","defaultBranchRef":{"name":"staging"},"primaryLanguage":{"name":"Go"},"pushedAt":"2026-08-16T10:00:00Z","isArchived":false},
  {"name":"delta","description":"the fourth one","url":"$ob/remotes/delta.git","sshUrl":"$ob/remotes/delta.git","defaultBranchRef":{"name":"staging"},"primaryLanguage":{"name":"Rust"},"pushedAt":"2026-08-14T10:00:00Z","isArchived":false},
  {"name":"retired","description":"archived","url":"$ob/remotes/retired.git","sshUrl":"$ob/remotes/retired.git","defaultBranchRef":{"name":"master"},"primaryLanguage":null,"pushedAt":"2024-01-01T00:00:00Z","isArchived":true},
  {"name":"emptyrepo","description":"never pushed to","url":"$ob/remotes/emptyrepo.git","sshUrl":"$ob/remotes/emptyrepo.git","defaultBranchRef":null,"primaryLanguage":null,"pushedAt":"2026-08-15T10:00:00Z","isArchived":false}
]
JSON

# ORC_ROOT is pointed at the fake world deliberately: the script resolves its
# three siblings from its own directory, so this proves it composes the real
# discovery, sync and drafting scripts rather than whatever ORC_ROOT happens to name.
onboard() {
  env ORC_ROOT="$ob" ORC_FIXTURE_DIR="$ob/fixtures" ORC_PROJECTS_FILE="$ob/config/projects.yml" \
      ORC_STATE_DIR="$ob/state" ORC_CLONE_DIR="$ob/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-onboard.sh" "$@" 2>&1
}
# The library's own parser, so the assertion reads the config the way the
# orchestrator will rather than by grepping for a shape.
# shellcheck disable=SC2016
ob_names() { env ORC_PROJECTS_FILE="$ob/config/projects.yml" bash -c '. "$0" >/dev/null 2>&1; project_names' "$lib"; }

ob1=$(onboard --org testorg --offline --select alpha,beta --yes)
ob1rc=$?
if [ "$ob1rc" = "0" ]; then
  pass "one command goes from an empty checkout to a drafted bundle, offline"
else
  fail "the onboarding run failed (exit $ob1rc)"; printf '%s\n' "$ob1" | tail -30; fi
if [ "$(ob_names | tr '\n' ' ')" = "alpha beta " ]; then
  pass "the config afterwards names exactly what was selected, and nothing else"
else
  fail "the config names '$(ob_names | tr '\n' ' ')' rather than the two selected"; fi
if [ -f "$ob/clones/alpha/app/models/case.rb" ] && [ -f "$ob/clones/beta/app/models/case.rb" ]; then
  pass "and both of them are cloned"
else
  fail "the selected repositories were not cloned"; fi
if [ -f "$ob/.okf/subsystems/alpha.md" ] && [ -f "$ob/.okf/subsystems/beta.md" ]; then
  pass "and the bundle is drafted from them"
else
  fail "no bundle was drafted"; printf '%s\n' "$ob1" | tail -20; fi
if [ -f "$ob/.okf/index.md" ] && grep -q 'okf_version' "$ob/.okf/index.md"; then
  pass "and its root index declares the OKF version, so it is a bundle rather than a folder"
else
  fail "the drafted bundle has no okf_version in its root index"; fi

# Everything discovery already knows, carried through rather than worked out again.
if printf '%s' "$ob1" | grep -qE '^  1 +alpha +staging' \
   && printf '%s' "$ob1" | grep -qE '^  2 +beta +main'; then
  pass "the selection list shows each repository's real default branch, not a guess"
else
  fail "the selection list did not carry discovery's per-repository default branch"
  printf '%s\n' "$ob1" | sed -n '1,20p'; fi
if printf '%s' "$ob1" | grep -q 'emptyrepo' \
   && printf '%s' "$ob1" | grep -q 'nothing to check out'; then
  pass "a repository with no default branch is listed as unselectable, with the reason"
else
  fail "the repository with no default branch was not carried through"; fi
if printf '%s' "$ob1" | grep -q 'retired'; then
  fail "an archived repository reached the selection list"
else
  pass "an archived repository never reaches the selection list"; fi
if printf '%s' "$ob1" | grep -q 'Remotes are proposed over'; then
  pass "and the protocol discovery chose is stated, in discovery's own words"
else
  fail "the protocol sentence was not carried through"; fi
if printf '%s' "$ob1" | grep -q 'nothing was asked of GitHub'; then
  pass "step 1 reports GitHub access through discovery, which is the only script that may ask"
else
  fail "the access step did not report through discovery"; fi
if printf '%s' "$ob1" | grep -qE '^  [0-9]+ +(alpha|beta|gamma) +.* the (first|second|third) one'; then
  pass "each row carries the description and language discovery annotated it with"
else
  fail "the annotations were dropped"; printf '%s\n' "$ob1" | sed -n '1,20p'; fi

# The consent step, proved rather than promised. What was printed is what landed,
# byte for byte, and nothing above it moved.
lines_before=$(wc -l < "$ob/config/projects.yml" | tr -d ' ')
cp "$ob/config/projects.yml" "$ob/before.yml"
ob2=$(onboard --org testorg --offline --select gamma --yes)
printf '%s\n' "$ob2" | awk '
  /^== 4\./ { on = 1; next }
  on && /^  -+$/ { r++; next }
  on && r == 1 { print }' > "$ob/shown"
tail -n +$(( lines_before + 1 )) "$ob/config/projects.yml" > "$ob/written"
if cmp -s "$ob/shown" "$ob/written"; then
  pass "the text shown before the write is byte-identical to the text written"
else
  fail "what was written differs from what the operator was shown"
  diff "$ob/shown" "$ob/written" | head -20; fi
if head -n "$lines_before" "$ob/config/projects.yml" | cmp -s - "$ob/before.yml"; then
  pass "and every byte that was already in the file is untouched: the write is an append"
else
  fail "the write changed something that was already in the config"; fi
if [ "$(ob_names | tr '\n' ' ')" = "alpha beta gamma " ]; then
  pass "the second run added exactly the one project selected, and dropped none"
else
  fail "the second run left the config naming '$(ob_names | tr '\n' ' ')'"; fi
# The bytes written are discovery's own, so the reviewed file cannot end up
# spelled differently from the proposal somebody read.
env ORC_PROJECTS_FILE="$ob/empty.yml" ORC_FIXTURE_DIR="$ob/fixtures" ORC_STATE_DIR="$ob/state" \
  "$ORC_ROOT/bin/orc-repos-discover.sh" --org testorg --offline > "$ob/proposal" 2>/dev/null
if grep -q 'remote: .*gamma.git' "$ob/written" \
   && grep -F -x -f "$ob/written" "$ob/proposal" | grep -q 'default_branch: staging'; then
  pass "and they are discovery's own lines, not re-rendered here"
else
  fail "the written block is not a copy of discovery's proposal"
  printf '%s\n' "--- written"; cat "$ob/written"; fi

# A selection of none writes nothing.
sum_before=$(_sha1 < "$ob/config/projects.yml")
onboard --org testorg --offline --select none --yes >/dev/null 2>&1
if [ "$sum_before" = "$(_sha1 < "$ob/config/projects.yml")" ]; then
  pass "selecting none leaves the config byte-identical"
else
  fail "a run that selected nothing still wrote to the config"; fi

# An entry a human edited is that human's. Discovery cannot know a subsystem join
# or that a suite is slow enough to want a container, and a run that rewrote the
# block would discard exactly the knowledge somebody added.
#
# Asserted while a write is genuinely happening - delta is still on offer. With
# nothing left to add the write branch never runs, and a check that passed because
# no code executed would be worse than no check.
ob_block() {
  awk -v want="$1" '
    /^[A-Za-z0-9_.\/-]+:[[:space:]]*$/ { cur = $0; sub(/:.*$/, "", cur); on = (cur == want) }
    on { print }' "$2"
}
awk '
  /^alpha:$/ { print; print "  subsystem: subsystems/alpha"; print "  verify: local"; next }
  { print }' "$ob/config/projects.yml" > "$ob/edited.yml"
cp "$ob/edited.yml" "$ob/config/projects.yml"
ob_block alpha "$ob/config/projects.yml" > "$ob/alpha.before"
ob4=$(onboard --org testorg --offline --select delta --yes)
ob_block alpha "$ob/config/projects.yml" > "$ob/alpha.after"
if [ -s "$ob/alpha.before" ] && cmp -s "$ob/alpha.before" "$ob/alpha.after"; then
  pass "a hand-edited entry survives a run that appends beside it, exactly as it was written"
else
  fail "a run rewrote an entry a human had edited"
  diff "$ob/alpha.before" "$ob/alpha.after"; fi
if grep -q '^delta:' "$ob/config/projects.yml"; then
  pass "and the project that run selected did land, so the write branch really executed"
else
  fail "the run wrote nothing, so the assertion above proved nothing"; fi
if printf '%s' "$ob4" | grep -q 'already in the config, left exactly as it is'; then
  pass "and the run says which projects it left alone, rather than silently skipping them"
else
  fail "the run did not report what it left alone"; fi

# Now everything the listing offers is configured, so there is nothing left to add.
sum_before=$(_sha1 < "$ob/config/projects.yml")
onboard --org testorg --offline --select all --yes >/dev/null 2>&1
if [ "$sum_before" = "$(_sha1 < "$ob/config/projects.yml")" ]; then
  pass "'all' adds nothing when the config already names everything on offer"
else
  fail "'all' re-added projects the config already had"; fi
if [ "$(ob_names | sort | uniq -d | tr -d ' \n')" = "" ]; then
  pass "no project appears twice, so a second run cannot shadow a reviewed entry"
else
  fail "running twice duplicated a project key: $(ob_names | sort | uniq -d | tr '\n' ' ')"; fi

# Nothing is invented when there is nobody to ask. Against a config with nothing
# in it, so there is genuinely a question to answer: with everything already
# configured the selection step is skipped and this would prove nothing.
onboard_fresh() {
  : > "$ob/fresh.yml"
  env ORC_ROOT="$ob" ORC_FIXTURE_DIR="$ob/fixtures" ORC_PROJECTS_FILE="$ob/fresh.yml" \
      ORC_STATE_DIR="$ob/state" ORC_CLONE_DIR="$ob/clones" ORC_REPO_SYNC_TTL=0 \
      "$ORC_ROOT/bin/orc-onboard.sh" "$@" 2>&1
}
noans=$(onboard_fresh --org testorg --offline </dev/null)
if printf '%s' "$noans" | grep -q 'pass --select'; then
  pass "with no answer available it names the flag that would have supplied one"
else
  fail "a non-interactive run without --select did not say what was missing"
  printf '%s\n' "$noans" | tail -5; fi
if printf '%s' "$(onboard_fresh --org testorg --offline --select nosuchrepo --yes)" \
    | grep -q 'not one of the repositories offered'; then
  pass "a selection naming something that was not offered is refused, not ignored"
else
  fail "an unknown selection was accepted"; fi
if [ ! -s "$ob/fresh.yml" ]; then
  pass "and neither refusal wrote a byte to the config it was pointed at"
else
  fail "a refused run wrote to the config"; cat "$ob/fresh.yml"; fi

printf '\n== a reset is loud in proportion to what it discards ==\n'
# The bundle now holds drafts and nothing else, and it is not in a git working
# tree. There is no undo either way, so the phrase is asked for even though
# nobody has verified anything.
nmd=$(find "$ob/.okf" -name '*.md' -type f | wc -l | tr -d ' ')
sum_bundle=$(find "$ob/.okf" -name '*.md' -type f | sort | xargs cat 2>/dev/null | _sha1)
rout=$(onboard reset --org testorg --offline --select none </dev/null)
if printf '%s' "$rout" | grep -q 'no undo at all'; then
  pass "a bundle outside a git working tree is reported as having no undo"
else
  fail "the reset did not notice there was no undo"; printf '%s\n' "$rout" | head -20; fi
if [ "$sum_bundle" = "$(find "$ob/.okf" -name '*.md' -type f | sort | xargs cat 2>/dev/null | _sha1)" ]; then
  pass "and it discarded nothing, because nobody answered"
else
  fail "the reset discarded the bundle without an answer"; fi
wrong=$(printf 'yes\n' | onboard reset --org testorg --offline --select none)
if [ "$sum_bundle" = "$(find "$ob/.okf" -name '*.md' -type f | sort | xargs cat 2>/dev/null | _sha1)" ] \
   && printf '%s' "$wrong" | grep -q 'nothing was discarded'; then
  pass "'yes' is not the phrase, so nothing is discarded"
else
  fail "a y/N-shaped answer was enough to discard a bundle"; fi
if printf '%s' "$rout" | grep -q "discard $nmd file"; then
  pass "the phrase names the count, so one copied out of an older run no longer fits"
else
  fail "the phrase does not name what is at stake"; printf '%s\n' "$rout" | grep -i discard; fi

# Now with git behind it, and with one concept a person has verified.
git -c init.defaultBranch=main init --quiet "$ob"
cat > "$ob/.okf/subsystems/alpha.md" <<'MD'
---
type: Subsystem
title: Alpha
description: Somebody read this one.
resource: https://github.com/testorg/alpha
verified:
  - by: human:someone
    at: 2026-08-18T09:00:00Z
---

# Alpha

Confirmed by a person.
MD
obgit "$ob" add -A >/dev/null 2>&1
obgit "$ob" commit --quiet -m seed >/dev/null 2>&1
nver=1
sum_bundle=$(find "$ob/.okf" -name '*.md' -type f | sort | xargs cat 2>/dev/null | _sha1)

# git is the undo, so it has to actually hold what is about to go.
printf 'scratch\n' > "$ob/.okf/uncommitted.md"
refuse=$(onboard reset --org testorg --offline --select none </dev/null)
if printf '%s' "$refuse" | grep -q 'GIT DOES NOT HOLD ALL OF THIS YET' \
   && printf '%s' "$refuse" | grep -q 'uncommitted.md'; then
  pass "a bundle holding a file git has never seen is refused, and the file is named"
else
  fail "the reset offered to discard a file with no undo"; printf '%s\n' "$refuse" | head -20; fi
if [ -f "$ob/.okf/uncommitted.md" ]; then
  pass "and nothing was removed while it refused"
else
  fail "the refusal still removed something"; fi
rm -f "$ob/.okf/uncommitted.md"

rout=$(onboard reset --org testorg --offline --select none </dev/null)
if printf '%s' "$rout" | grep -q "$nver of them carrying a verified: date" \
   && printf '%s' "$rout" | grep -q 'subsystems/alpha.md' \
   && printf '%s' "$rout" | grep -q 'human:someone'; then
  pass "a verified concept is counted, named, and credited to whoever checked it"
else
  fail "the reset did not say what verification it was about to destroy"
  printf '%s\n' "$rout" | head -25; fi
if printf '%s' "$rout" | grep -q "discard $nver concept verified by a person"; then
  pass "and the phrase to type names that count rather than asking for a yes"
else
  fail "the phrase does not name the verified count"; printf '%s\n' "$rout" | grep -i discard; fi
if printf '%s' "$rout" | grep -q 'git is the undo'; then
  pass "and it says where the undo is, because there is one this time"
else
  fail "the reset did not say what the undo was"; fi
if [ "$sum_bundle" = "$(find "$ob/.okf" -name '*.md' -type f | sort | xargs cat 2>/dev/null | _sha1)" ]; then
  pass "still nothing discarded: no answer, no removal"
else
  fail "the bundle went without an answer"; fi

# There is no flag that answers it. That is the point of the phrase.
if printf '%s' "$(onboard reset --org testorg --offline --select none --yes </dev/null)" \
    | grep -q 'reset has no flag that answers this'; then
  pass "--yes does not answer it; the reset confirmation has no flag at all"
else
  fail "--yes reached the reset confirmation"; fi

# And with the phrase, it goes - and comes back drafted.
done_out=$(printf 'discard %s concept verified by a person\n' "$nver" \
  | onboard reset --org testorg --offline --select none)
if [ ! -f "$ob/.okf/uncommitted.md" ] && ! grep -q 'Confirmed by a person' "$ob/.okf/subsystems/alpha.md" 2>/dev/null; then
  pass "the phrase discards the verified concept, which is what a reset is for"
else
  fail "the verified concept survived a confirmed reset"; fi
if grep -q 'generated:' "$ob/.okf/subsystems/alpha.md" 2>/dev/null \
   && ! grep -q '^verified:' "$ob/.okf/subsystems/alpha.md" 2>/dev/null; then
  pass "and what came back is drafted and unverified, because a draft is not a reading"
else
  fail "the re-drafted concept is not a draft"; head -12 "$ob/.okf/subsystems/alpha.md" 2>/dev/null; fi
if printf '%s' "$done_out" | grep -q 'okf_version' || grep -q 'okf_version' "$ob/.okf/index.md"; then
  pass "and the emptied bundle still declares its OKF version"
else
  fail "the reset left a bundle with no okf_version"; fi

# Nothing verified and git behind it: say so and get on with it. Loudness scales
# with what is at stake, and a ceremony over a rebuildable draft is not loudness.
obgit "$ob" add -A >/dev/null 2>&1
obgit "$ob" commit --quiet -m drafted >/dev/null 2>&1
quiet_rc=0
quiet_out=$(onboard reset --org testorg --offline --select none </dev/null) || quiet_rc=$?
if [ "$quiet_rc" = "0" ] && printf '%s' "$quiet_out" | grep -q 'without asking'; then
  pass "with nothing verified and git behind it, a reset says so and proceeds"
else
  fail "a reset of unverified drafts still demanded a typed phrase"
  printf '%s\n' "$quiet_out" | head -20; fi

# One reader for "has a person checked this", shared by the refusal and the discard.
# shellcheck disable=SC2046
if [ "$(grep -lE '^concept_is_verified\(\)' $(scripts) | wc -l | tr -d ' ')" = "1" ] \
   && grep -qE '^concept_is_verified\(\)' "$lib"; then
  pass "concept_is_verified is defined once, in orc-lib.sh, so a refusal and a discard cannot disagree"
else
  fail "concept_is_verified is defined more than once"
  # shellcheck disable=SC2046
  grep -lE '^concept_is_verified\(\)' $(scripts); fi

rm -rf "$ob"

printf '\n== refinement fetches first, and names what it read ==\n'
# Two clones of one upstream: one the orchestrator can use, one it must not.
cat > "$w/refine.yml" <<YML
good:
  remote: $w/upstream.git
  default_branch: staging
  repo: $w/clones/good
  verify: unit-only

dirty:
  remote: $w/upstream.git
  default_branch: staging
  repo: $w/clones/dirty
  verify: unit-only
YML
refine_env() {
  env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$1" ORC_CLONE_DIR="$w/clones" \
      ORC_REPO_SYNC_TTL=0 ORC_JIRA_MODE=fixture ORC_REFINER=replay \
      ORC_REPO_SYNC="$2" "$ORC_ROOT/bin/orc-refine.sh" --force "$3"
}
env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/state" ORC_CLONE_DIR="$w/clones" \
    ORC_REPO_SYNC_TTL=0 "$ORC_ROOT/bin/orc-repos-sync.sh" --quiet >/dev/null 2>&1

# The failure that matters most: the clone is a commit behind, and refinement is
# asked to reason about it anyway.
upstream_commit six
goodsha_stale=$(git -C "$w/clones/good" rev-parse HEAD | cut -c1-12)
refine_env "$w/s1" on ORC-101 >/dev/null 2>&1
goodsha_fresh=$(git -C "$w/clones/good" rev-parse HEAD | cut -c1-12)
if [ "$goodsha_fresh" != "$goodsha_stale" ] && grep -q '^six$' "$w/clones/good/app.txt"; then
  pass "refinement fetches and fast-forwards before it reasons"
else
  fail "refinement reasoned against a checkout it never refreshed"; fi

# --judge-only prints the verdict and nothing else, whatever the sync had to say.
# The golden harness parses that stream, so a report leaking onto it turns every
# ticket into an ERROR row.
judged=$(env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/s0" ORC_CLONE_DIR="$w/clones" \
  ORC_REPO_SYNC_TTL=0 ORC_JIRA_MODE=fixture ORC_REFINER=replay ORC_REPO_SYNC=on \
  "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force ORC-101 2>/dev/null)
if printf '%s' "$judged" | jq -e '.verdict == "ready" and (.reasoned_against | length) == 2' >/dev/null 2>&1; then
  pass "--judge-only still prints nothing but the verdict, sync report included"
else
  fail "something other than the verdict reached stdout"; printf '%s\n' "$judged" | head -5; fi

comment_of() { sed -n "/WOULD POST   \/issue\/$2\/comment/,/+-- raw/p" "$1/.would-write.log"; }
body=$(comment_of "$w/s1" ORC-101)
if printf '%s' "$body" | grep -q "$goodsha_fresh"; then
  pass "the comment names the exact commit the search was done at"
else
  fail "the reasoned-against commit is not in the comment"; printf '%s\n' "$body"; fi
if [ "$(grep '^reasoned_against=' "$w/s1/ORC-101.meta" | grep -c "$goodsha_fresh")" = "1" ] \
   && jq -e --arg s "$goodsha_fresh" \
        '.reasoned_against | map(select(startswith("good ") and contains($s))) | length == 1' \
        "$w/s1/ORC-101.verdict.json" >/dev/null; then
  pass "the verdict record carries the repository and the commit too"
else
  fail "the verdict record does not name what it was reasoned against"; fi

printf 'uncommitted\n' >> "$w/clones/dirty/app.txt"
refine_env "$w/s2" off ORC-101 >/dev/null 2>&1
body=$(comment_of "$w/s2" ORC-101)
if printf '%s' "$body" | grep -q 'dirty STALE, not searched'; then
  pass "a stale clone is reported on the ticket rather than silently used"
else
  fail "a stale clone was used without saying so"; printf '%s\n' "$body"; fi
if printf '%s' "$body" | grep -q "uncommitted change"; then
  pass "the report says why it was stale, so the fix is obvious"
else
  fail "the stale report does not say what is wrong"; fi

# The repository context block the refiner is actually handed. Every one of the
# five real entries went without a `subsystem:` join for as long as the block
# existed, so refinement was told the bundle described none of them - and the
# paragraph that tells it to route through the bundle is emitted only when at
# least one join is set, so it never printed either. The mapping and the
# instruction to use it went missing together, on every ticket, while
# .okf/subsystems/ held a concept for all five. A stand-in agent that keeps what
# it was given is the only way to see the block from outside.
mkdir -p "$w/fakebin"
cat > "$w/fakebin/claude" <<'SH'
#!/bin/sh
cat > "$ORC_CHECK_AGENT_INPUT"
jq -nc --arg r '{"verdict":"needs_input","confidence":"low","one_line":"x","subsystems":[],"files":[],"locality_basis":"none","terms_resolved":[],"terms_unresolved":["x"],"questions":["Which screen do you mean?"],"duplicate_of":null,"split_into":[],"acceptance_criteria":[],"not_verified":"nothing","notes":"nothing"}' '{result:$r}'
SH
chmod +x "$w/fakebin/claude"
sed 's|^  repo: '"$w"'/clones/good$|  repo: '"$w"'/clones/good\n  subsystem: subsystems/good|' "$w/refine.yml" > "$w/refine-joined.yml"
handed_to_agent() {
  env ORC_PROJECTS_FILE="$1" ORC_STATE_DIR="$w/s-ctx" ORC_CLONE_DIR="$w/clones" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      ORC_CHECK_AGENT_INPUT="$w/agent-input.txt" PATH="$w/fakebin:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force ORC-101 >/dev/null 2>&1
  cat "$w/agent-input.txt" 2>/dev/null
}
if grep -q 'subsystem: subsystems/good' "$w/refine-joined.yml"; then
  ctx=$(handed_to_agent "$w/refine-joined.yml")
  if printf '%s' "$ctx" | grep -q 'subsystems/good'; then
    pass "a repository with a subsystem: join is handed to the refiner naming its concept"
  else
    fail "the join in the config never reached the refiner"; printf '%s\n' "$ctx" | sed -n '/Repositories to search/,/Provenance/p'; fi
  if printf '%s' "$ctx" | grep -q 'Resolve the ticket to a concept first'; then
    pass "and the paragraph telling it to route through the bundle is printed"
  else
    fail "the routing instruction is missing even though a join is set"; fi
  ctx=$(handed_to_agent "$w/refine.yml")
  if printf '%s' "$ctx" | grep -q '(not in the bundle)'; then
    pass "a repository with no join is still named as one the bundle does not describe"
  else
    fail "a repository with no join is not reported as absent from the bundle"; fi
else
  fail "the check could not build a config carrying a subsystem: join"
fi
# The config this repository ships with is the one that was wrong: five
# repositories, a concept in the bundle for every one of them, and not one join.
# A repository the bundle does not describe is a different thing and stays legal -
# refinement saying so is the correct output rather than a guess - so the rule is
# about the pair, checked in both directions.
join_bad=""
for _p in $(project_names); do
  _remote=$(project_field "$_p" remote)
  [ -n "$_remote" ] || continue
  _join=$(project_field "$_p" subsystem)
  _claim=$(concept_claiming_repo "$ORC_ROOT/.okf" "$_remote")
  if [ -z "$_join" ] && [ -n "$_claim" ]; then
    join_bad="$join_bad
  $_p is the repository $_claim describes, and nothing joins them"
  fi
  if [ -n "$_join" ] && [ ! -f "$ORC_ROOT/.okf/$_join.md" ]; then
    join_bad="$join_bad
  $_p joins $_join, and the bundle has no such concept"
  fi
done
unset _p _remote _join _claim
if [ -n "$join_bad" ]; then
  fail "config/projects.yml and the bundle do not point at each other:$join_bad"
else
  pass "every repository the bundle describes is joined to its concept in the config"
fi

printf '\n== a needs_input comment is free of engineering detail ==\n'
# Jira is the product management tool. A reporter, a support agent or a clinician
# reads these comments, and anything answerable by reading the code is the
# refiner's job rather than a question. The located files and the commit are for
# the implementing agent, so they belong on a ready ticket and nowhere else.
CODE_SHAPED='([A-Za-z0-9_-]+/)+[A-Za-z0-9_-]+\.[a-z]{2,4}|\.(rb|ts|tsx|jsx|vue|py|erb|scss|sql|yml|yaml)([^A-Za-z]|$)|::|(^|[^A-Za-z0-9])(app|src|lib|spec|config|test)/|[a-z][a-z0-9]*_[a-z0-9_]+|[A-Za-z][a-z0-9]+[A-Z][A-Za-z0-9]*'
# Code shape is only half of it. A comment can pass the regex above cleanly and
# still be addressed to nobody in the room: "the knowledge bundle describes no
# repository with a verified concept" is every word of it English, and a
# clinician reads it and learns that this comment was not written for them. So
# the orchestrator's own nouns are a second scanner.
ORCHESTRATOR_WORDS='(^|[^A-Za-z])(bundles?|concepts?|repository|repositories|commits?|branch(es)?|prompts?|refiners?|verdicts?|subsystems?)([^A-Za-z]|$)'
# Two of those nouns are also ordinary product verbs, and the list is tuned
# rather than shortened: a check that fired on "we prompt the patient to update"
# would be switched off within a week, and then the leak it was written for goes
# past with it. The verb senses are struck out first and the nouns stay on the
# list. "branching" and "committed" are not matched at all, which is the same
# tuning done with a word boundary.
strike_verb_senses() {
  sed -E -e 's/[Pp]rompt(s|ed|ing)?[[:space:]]+(the|a|an|them|him|her|you|your|users?|patients?|doctors?|reporters?)[[:space:]]*/ /g' \
         -e 's/[Cc]ommit(s|ted|ment|ments)?[[:space:]]+to[[:space:]]*/ /g'
}
# The marker line is the orchestrator's own provenance, not prose aimed at the
# reporter, and the raw payload below the rendered text is JSON. Neither is part
# of what a person reads.
reader_sees() { grep -v "$ORC_COMMENT_MARKER" | sed '/+-- raw/,$d'; }
scan_for_code()   { reader_sees | grep -oE "$CODE_SHAPED"; }
scan_for_jargon() { reader_sees | strike_verb_senses | grep -oiE "$ORCHESTRATOR_WORDS"; }
scan_for_both()   { local text; text=$(cat)
                    printf '%s\n' "$text" | scan_for_code
                    printf '%s\n' "$text" | scan_for_jargon; }
if printf '  | probably src/features/case/FollowUpDecision.vue\n' | scan_for_code | grep -q .; then
  pass "the scanner does catch a file path, so it is not simply always quiet"
else
  fail "the code-shape scanner matches nothing; the check below proves nothing"; fi
if printf '  | the bundle names no concept, so the repository was read at that commit\n' \
     | scan_for_jargon | grep -q .; then
  pass "and the vocabulary scanner catches the orchestrator's own nouns"
else
  fail "the vocabulary scanner matches nothing; the check below proves nothing"; fi
if printf '%s\n' '  | We prompt the patient to update the app, and we commit to a date for it.' \
     '  | The doctor sees a branching questionnaire; nothing is committed until they send it.' \
     | scan_for_jargon | grep -q .; then
  fail "the vocabulary scanner fires on ordinary product prose; tune it, do not drop the words"
  printf '%s\n' '  | We prompt the patient to update the app, and we commit to a date for it.' | scan_for_jargon
else
  pass "and it stays quiet on product prose that happens to use those words as verbs"
fi

for k in ORC-102 ORC-103 ORC-105 ORC-104 ORC-106; do
  refine_env "$w/s3-$k" off "$k" >/dev/null 2>&1
done
offenders=""
for k in ORC-102 ORC-103 ORC-105 ORC-104 ORC-106; do
  hits=$(comment_of "$w/s3-$k" "$k" | scan_for_both | sort -u | tr '\n' ' ')
  [ -n "$hits" ] && offenders="$offenders
  $k: $hits"
done
if [ -n "$offenders" ]; then
  fail "a comment that asks a human for product judgment is not in the product's words:$offenders"
else
  pass "no file path, no code identifier, no orchestrator noun, in any comment that is not 'ready'"
fi
for k in ORC-102 ORC-103 ORC-105 ORC-104 ORC-106; do
  if comment_of "$w/s3-$k" "$k" | grep -qE 'Probable files|Subsystems|Reasoned against'; then
    fail "$k: the locality section is on a comment addressed to the reporter"
  fi
done
if comment_of "$w/s1" ORC-101 | grep -q 'Probable files'; then
  pass "a ready ticket still carries the locality the implementing agent needs"
else
  fail "the ready comment lost its locality"; fi
for k in ORC-102 ORC-105; do
  if jq -e '.files | length >= 0' "$w/s3-$k/$k.verdict.json" >/dev/null 2>&1; then :; else
    fail "$k: the verdict record is missing its files list"; fi
done
if jq -e '.files | length > 0' "$w/s3-ORC-102/ORC-102.verdict.json" >/dev/null 2>&1; then
  pass "the locality is still recorded in state/ for the next phase to read"
else
  fail "the locality was dropped from the verdict record as well as the comment"; fi

printf '\n== the split-ready terminal signal ==\n'
# An oversized card cannot legitimately return ready as one ticket, so a
# refine/answer/sign loop against it ends in needs_input on every round -
# indistinguishable, until now, from an ordinary needs_input still holding open
# questions. verdict_split_ready() is the one place that combination is
# decided: needs_input, questions empty, split_into not. Computed rather than
# asked of the refiner, so it cannot disagree with the two arrays it summarises.
sr_case() {
  jq -nc --arg v "$1" --argjson q "$2" --argjson s "$3" \
    '{verdict:$v, questions:$q, split_into:$s}'
}
if verdict_split_ready "$(sr_case needs_input '[]' '[{"title":"a","description":"b"}]')"; then
  pass "needs_input, no questions, a split proposed: recognised as split-ready"
else
  fail "the exact terminal combination was not recognised as split-ready"; fi
if verdict_split_ready "$(sr_case needs_input '["Which surface?"]' '[{"title":"a","description":"b"}]')"; then
  fail "a needs_input with an open question was read as split-ready"
else
  pass "an open question still on the list is never split-ready, split proposed or not"; fi
if verdict_split_ready "$(sr_case needs_input '[]' '[]')"; then
  fail "needs_input with no split proposed at all was read as split-ready"
else
  pass "no split proposed at all is an ordinary needs_input, not the terminal state"; fi
if verdict_split_ready "$(sr_case ready '[]' '[]')"; then
  fail "a ready verdict was read as split-ready"
else
  pass "split-ready is never true off a verdict other than needs_input"; fi
if verdict_split_ready "$(sr_case duplicate '[]' '[{"title":"a","description":"b"}]')"; then
  fail "a duplicate verdict was read as split-ready"
else
  pass "split-ready is never true off a duplicate verdict, split_into aside"; fi

# The three fixture tickets already exercised above cover every ordinary shape:
# ORC-102 asks real questions and proposes no split, ORC-105 asks a real
# question alongside a split, ORC-101 is ready. None of the three is the
# terminal signal, and this task must not make them look like it is.
meta_field() { grep "^$3=" "$1/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2-; }
for k in ORC-102 ORC-105; do
  if [ "$(meta_field "$w/s3-$k" "$k" split_ready)" = "no" ] && \
     jq -e '.split_ready == false' "$w/s3-$k/$k.verdict.json" >/dev/null 2>&1; then :; else
    fail "$k: still has open questions but was recorded as split-ready"; fi
done
orc105_body=$(comment_of "$w/s3-ORC-105" ORC-105)
# ORC-105 has an open question and a non-empty split_into in the same round -
# exactly the shape that used to render a split proposal that could contradict
# the next round's. Not split-ready, so no split section at all: only the
# heading, the one-liner and the questions.
if printf '%s' "$orc105_body" | grep -q "This reads as more than one ticket"; then
  fail "ORC-105 still shows a split proposal even though it still has an open question"
else
  pass "ORC-105 shows no split proposal while it still has an open question"; fi
if printf '%s' "$orc105_body" | grep -q "nothing left to ask, only the split remains"; then
  fail "ORC-105 was announced as split-ready despite an open question"; fi
if printf '%s' "$orc105_body" | grep -qF "Rename Recheck to Follow-up"; then
  fail "ORC-105's split bullet list leaked into the comment despite an open question"
else
  pass "ORC-105's split bullet list is withheld while it still has an open question"; fi
if [ "$(meta_field "$w/s1" ORC-101 split_ready)" = "no" ]; then
  pass "a ready ticket is never recorded as split-ready"
else
  fail "a ready verdict was recorded as split-ready"; fi

# The terminal case itself: every blocking question answered, only the split
# left. A stand-in agent produces it directly, the same way the repository
# context check above stands one in for the join it needs to see.
mkdir -p "$w/fakebin-splitready"
cat > "$w/fakebin-splitready/claude" <<'SH'
#!/bin/sh
cat > /dev/null
jq -nc --arg r '{"verdict":"needs_input","confidence":"high","one_line":"Four small deliverables filed as one ticket.","subsystems":[],"files":[],"locality_basis":"bundle","terms_resolved":[],"terms_unresolved":[],"questions":[],"duplicate_of":null,"split_into":[{"title":"Rename the button label","description":"Rename the button label across the app, in every language it is translated into."},{"title":"Add the field to the export","description":"Add the new field to the CSV export."}],"acceptance_criteria":[],"not_verified":"nothing","notes":""}' '{result:$r}'
SH
chmod +x "$w/fakebin-splitready/claude"
env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/s-splitready" ORC_CLONE_DIR="$w/clones" \
    ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
    PATH="$w/fakebin-splitready:$PATH" \
    "$ORC_ROOT/bin/orc-refine.sh" --force ORC-101 >/dev/null 2>&1
sr_body=$(comment_of "$w/s-splitready" ORC-101)
if printf '%s' "$sr_body" | grep -q "nothing left to ask, only the split remains"; then
  pass "the terminal state gets its own heading on the ticket"
else
  fail "a card with every question answered still reads as an ordinary needs_input"; printf '%s\n' "$sr_body"; fi
if printf '%s' "$sr_body" | grep -q "Every question here is answered"; then
  pass "and the split paragraph says so, not the ordinary 'reads as more than one ticket' line"
else
  fail "the split paragraph did not announce the terminal state"; fi
if printf '%s' "$sr_body" | grep -q "This reads as more than one ticket"; then
  fail "the ordinary split wording leaked into the terminal-state comment"; fi
if printf '%s' "$sr_body" | grep -q "Answering these in the description"; then
  fail "a card with no questions still printed the questions preamble"; fi
if [ "$(meta_field "$w/s-splitready" ORC-101 split_ready)" = "yes" ]; then
  pass "the terminal state is recorded in state/ as split_ready=yes, cheap to check without re-reading the comment"
else
  fail "split_ready was not recorded in state/ for the terminal case"; fi
if jq -e '.split_ready == true' "$w/s-splitready/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "the verdict record carries split_ready too"
else
  fail "split_ready is missing from the verdict record"; fi
if [ "$(meta_field "$w/s-splitready" ORC-101 verdict)" = "needs_input" ]; then
  pass "the terminal state is still a needs_input verdict: same label, same reporter hand-back, only the wording changes"
else
  fail "the terminal state stopped being a needs_input verdict"; fi

printf '\n== a term the ticket does not say becomes a question ==\n'
# The discount was the end of the story and should have been the beginning of
# one: a term the refiner recorded that the ticket does not say is a meaning it
# supplied and nobody gave, which is the plainest evidence there is that the
# ticket is ambiguous on that word. Struck from the trust record and asked about,
# not one or the other - and on a needs_input verdict only, because that is the
# comment that carries questions and hands the ticket back.
#
# Stand-in agents again, for the same reason the terminal-signal case above uses
# one: no canned fixture verdict asserts an ungrounded term, and one written to
# would have to be maintained in step with a fixture ticket's own words.
off_ask_run() {
  local name="$1" verdict="$2"
  mkdir -p "$w/fakebin-$name"
  printf '%s' "$verdict" > "$w/fakebin-$name/verdict.json"
  cat > "$w/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$w/fakebin-$name/verdict.json"
SH
  chmod +x "$w/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/s-$name" ORC_CLONE_DIR="$w/clones" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$w/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force ORC-101 >/dev/null 2>&1
}
# ORC-101 says nothing about a tier and nothing about a claimed-at column. One of
# those two is a word a reporter can be asked about and the other is this run's
# own bookkeeping, which is the whole of the filter. "tier two" is left
# unresolved rather than resolved this round on purpose: a term this round both
# resolved and promoted in the same breath is its own bug, covered on its own
# below, and conflating the two here would make this section's fixture prove
# that bug rather than the promotion filter.
off_v='{"verdict":"needs_input","confidence":"medium","one_line":"A claimed authorisation blocks the unlock.","subsystems":[],"files":[],"locality_basis":"bundle","terms_resolved":[{"term":"authorisation_claimed_at","concept":"domain/product-vocabulary"}],"terms_unresolved":["tier two"],"questions":["Which starting state should the unlock be offered in?"],"duplicate_of":null,"split_into":[],"acceptance_criteria":[],"not_verified":"nothing","notes":""}'
off_ask_run offask "$off_v"
oa_body=$(comment_of "$w/s-offask" ORC-101)
if printf '%s' "$oa_body" | grep -qF 'read as being about "tier two"'; then
  pass "a term the ticket does not say is asked about on the ticket, not only discounted in the record"
else
  fail "an ungrounded term was discounted and never asked about"; printf '%s\n' "$oa_body"; fi
if printf '%s' "$oa_body" | grep -qF 'Which starting state should the unlock be offered in?'; then
  pass "and the refiner's own questions are still asked beside it"
else
  fail "promoting the discounted term displaced the refiner's own questions"; fi
if printf '%s' "$oa_body" | grep -q 'authorisation_claimed_at'; then
  fail "a code identifier the refiner recorded was quoted onto the comment a reporter reads"
else
  pass "a code-shaped discount is not asked about: there is no reporter question in an identifier"; fi
if printf '%s' "$oa_body" | scan_for_both | grep -q .; then
  fail "the promoted question does not meet the bar the rest of the comment is held to"
  printf '%s' "$oa_body" | scan_for_both | sort -u
else
  pass "the promoted question passes the same code and jargon scan as every other comment"; fi
if jq -e '.terms_off_ticket == ["authorisation_claimed_at","tier two"] and .terms_off_asked == ["tier two"]' \
     "$w/s-offask/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "the discount is unchanged in the record, and what was asked is recorded beside it"
else
  fail "the record does not carry both the discount and what was promoted from it"
  jq -c '{terms_off_ticket, terms_off_asked}' "$w/s-offask/ORC-101.verdict.json" 2>/dev/null || true; fi
if [ "$(meta_field "$w/s-offask" ORC-101 terms_off_asked_count)" = "1" ] \
   && [ "$(meta_field "$w/s-offask" ORC-101 question_count)" = "2" ]; then
  pass "the meta record counts what the ticket was actually asked, and the promoted part separately"
else
  fail "the counts in state/ do not say what the ticket was asked"
  grep -E '^(question_count|terms_off_asked_count)=' "$w/s-offask/ORC-101.meta" 2>/dev/null || true; fi

# The refiner doing what the prompt now asks of it: the term is still recorded
# ungrounded, and it asked about it in its own words. Asking again underneath
# would be the same question twice on one comment.
own_v=$(printf '%s' "$off_v" | jq -c '.questions = ["What does tier two cover here - a deposit band, or something else?"]')
off_ask_run offasked "$own_v"
own_body=$(comment_of "$w/s-offasked" ORC-101)
if printf '%s' "$own_body" | grep -q 'read as being about'; then
  fail "a term the refiner already asked about was asked again underneath its own question"
  printf '%s\n' "$own_body"
else
  pass "a term the refiner asked about itself is not asked a second time"; fi
if jq -e '.terms_off_ticket == ["authorisation_claimed_at","tier two"] and .terms_off_asked == []' \
     "$w/s-offasked/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and it is still discounted, because asking about a word is not grounding it in the ticket"
else
  fail "asking about the term changed the discount"; fi

# The interaction that made this worth getting right. A card announced as having
# nothing left to ask, whose reading nobody confirmed, proposes a split drawn
# around that reading - and the split is the one thing on the comment a reporter
# is expected to act on rather than answer.
term_v=$(printf '%s' "$off_v" | jq -c '.questions = [] | .split_into = [{"title":"Unlock the claimed authorisation","description":"Let the unlock be offered when the authorisation is already claimed."},{"title":"Label the export column","description":"Rename the column in the export."}]')
off_ask_run offsplit "$term_v"
sp_body=$(comment_of "$w/s-offsplit" ORC-101)
if printf '%s' "$sp_body" | grep -qF 'read as being about "tier two"'; then
  pass "a card with no questions of its own still asks about the term nobody grounded"
else
  fail "the promoted question was dropped on a card whose own question list was empty"
  printf '%s\n' "$sp_body"; fi
if printf '%s' "$sp_body" | grep -q "nothing left to ask, only the split remains"; then
  fail "a card was announced as having nothing left to ask while an ungrounded term was being asked about"
else
  pass "an open promoted question is not the terminal state, whatever the refiner's own list says"; fi
if printf '%s' "$sp_body" | grep -qF 'Label the export column'; then
  fail "a split proposal drawn around an unconfirmed reading was shown to the reporter"
else
  pass "and the split proposal is withheld, the same as on any other round with a question open"; fi
if [ "$(meta_field "$w/s-offsplit" ORC-101 split_ready)" = "no" ] \
   && jq -e '.split_ready == false' "$w/s-offsplit/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and split_ready says no in both places, so a report reads the same thing the comment says"
else
  fail "split_ready still says yes on a card with a promoted question open"; fi

# The two verdicts that are left. A ready comment carries no question list at
# all, and adding one would be this harness overruling a verdict rather than
# reporting on it; a duplicate is being closed against another ticket, and a
# question about this one's words belongs on whichever survives. Both still
# discount, and both still record.
ready_v=$(printf '%s' "$off_v" | jq -c '.verdict = "ready" | .questions = [] | .acceptance_criteria = ["The unlock is offered."]')
off_ask_run offready "$ready_v"
if comment_of "$w/s-offready" ORC-101 | grep -q 'read as being about'; then
  fail "a ready comment grew a question, which means a verdict was overruled here rather than reported"
else
  pass "a ready verdict is reported, not overruled: no question is added to its comment"; fi
if jq -e '.terms_off_ticket == ["authorisation_claimed_at","tier two"] and .terms_off_asked == []' \
     "$w/s-offready/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the discount is still recorded there, which is what it always did"
else
  fail "a ready verdict lost the off-ticket audit"; fi
dup_v=$(printf '%s' "$off_v" | jq -c '.verdict = "duplicate" | .duplicate_of = "ORC-102" | .questions = []')
off_ask_run offdup "$dup_v"
if comment_of "$w/s-offdup" ORC-101 | grep -q 'read as being about'; then
  fail "a duplicate comment asks about a word on a ticket that is being closed"
else
  pass "a duplicate is not asked about either: the surviving ticket is where that question belongs"; fi

# The filter, at the unit it is written at. Two tests rather than one, and the
# second is what keeps the promoted question inside the scanner above: every
# shape that scanner catches carries one of that punctuation's characters,
# except CamelCase, which is what the code-shape rule catches.
oa_probe=$(printf '%s\n' "tier two" "Ménière" follow_up FollowUpDecision "app/models/case.rb" "case.list" "a::b")
oa_got=$(terms_off_to_ask "$oa_probe" "" | tr '\n' ' ')
if [ "$oa_got" = "tier two Ménière " ]; then
  pass "only a word a reporter could be asked about is promoted, and an accented one still is"
else
  fail "the promotion filter let something through or dropped a reporter's own word: $oa_got"; fi
if [ -z "$(terms_off_to_ask "tier two" "we already asked about the Tier Two rentals" | tr -d '[:space:]')" ]; then
  pass "the already-asked test folds case and spacing, the same as every other term comparison"
else
  fail "a term already asked about in a different case was promoted again"; fi

# A term this round both resolved and promoted in the same breath: a real
# epic's round 2 read domain/reporter-answers.md, correctly cited it in that
# round's own terms_resolved, and the same round's terms_off_asked promoted the
# identical term as a question anyway. The promotion never looked at that
# round's own terms_resolved before firing. bin/orc-refine.sh now folds
# resolved_this_round into the "asked" text terms_off_to_ask is checked
# against, so this never reaches the unit level as a two-argument call - it is
# a property of the caller, not of terms_off_to_ask alone, and is proven
# through a real refinement the same way the rest of this section is.
sameround_v=$(printf '%s' "$off_v" | jq -c '
  .terms_unresolved = [] | .terms_resolved += [{"term":"tier two","concept":"domain/product-vocabulary"}]')
off_ask_run offsameround "$sameround_v"
if comment_of "$w/s-offsameround" ORC-101 | grep -qF 'read as being about "tier two"'; then
  fail "a term resolved and promoted in the same round was asked about anyway"
  comment_of "$w/s-offsameround" ORC-101
else
  pass "a term this round's own terms_resolved already answered is not promoted as a question in the same round"; fi
if jq -e '.terms_off_asked == []' "$w/s-offsameround/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the record shows nothing was promoted, not merely that the comment omits it"
else
  fail "the record still lists the resolved term as promoted"
  jq -c '.terms_off_asked' "$w/s-offsameround/ORC-101.verdict.json" 2>/dev/null || true; fi

printf '\n== a new member of a set the code enumerates is a finding with a path behind it ==\n'
# The gap class that reading the ticket harder cannot close. A card that adds one
# more of something the product enumerates elsewhere carries work it never
# mentions, and the word for that work is not in the ticket - it was not in five
# thousand characters of the real epic this was found on by hand, after three
# refinement rounds and three further independent samples had all missed it.
#
# So it is read out of the code, and everything below is about what that
# mechanical reading may and may not conclude. The fixture fleet is the same one
# golden/run.sh uses, through the same script, because two spellings of a fixture
# fleet is two fleets.
ig_repos="$w/ig-repos"
ig_projects=$("$ORC_ROOT/fixtures/repos.sh" "$ig_repos" 2>/dev/null)
if [ -n "$ig_projects" ] && [ -f "$ig_projects" ] && is_git_repo "$ig_repos/api"; then
  pass "the fixture fleet materialises, so this check and golden/run.sh read the same repositories"
else
  fail "fixtures/repos.sh produced no readable fleet; nothing below proves anything"; fi
# The fence on the one script in here that makes a repository. It is not
# orc-repos-sync.sh, so the rails above have to keep passing untouched, and they
# do because there is nothing in here for them to catch: one git command, and it
# is the one that cannot move or discard anything.
ig_git=$(grep -nE '(^|[^_[:alnum:]])git[[:space:]]' "$ORC_ROOT/fixtures/repos.sh" | code_only)
if [ "$(printf '%s' "$ig_git" | grep -c .)" = "1" ] && printf '%s' "$ig_git" | grep -q 'init'; then
  pass "fixtures/repos.sh runs exactly one git command, and it is init"
else
  fail "fixtures/repos.sh runs a git command other than init"; printf '%s\n' "$ig_git"; fi
if grep -nE '(^|[^_[:alnum:]])rm[[:space:]]' "$ORC_ROOT/fixtures/repos.sh" | code_only | grep -q .; then
  fail "fixtures/repos.sh removes something; its destination is a cache and nothing here may remove"
else
  pass "and it removes nothing at all: the destination is a cache, and bin/orc-reset.sh is what clears it"; fi
ig_list=$(printf 'api\t%s/api\ndashboard\t%s/dashboard\n' "$ig_repos" "$ig_repos")

# The declarations, at the unit they are read at. An enum is the one declaration
# in the code that says these are all the members there are, which is why it is
# the unit and a frozen constant is not.
ig_sets=$(enum_sets_of "$ig_repos/api")
if printf '%s' "$ig_sets" | grep -q '^case_type	first_visit,reopened,second_opinion	app/models/medical_case.rb$'; then
  pass "an enum is read as a set: its key, every member, and the file that declares it"
else
  fail "the enum reader did not find the fixture set"; printf '%s\n' "$ig_sets"; fi
if [ "$(printf '%s' "$ig_sets" | grep -c .)" -ge 3 ]; then
  pass "and a model declaring two enums contributes both, rather than the first one overwriting the second"
else
  fail "a second enum in the same model was lost"; printf '%s\n' "$ig_sets"; fi
if [ -z "$(_set_head_noun status)" ] && [ "$(_set_head_noun case_type)" = "case" ]; then
  pass "a set is a set of the noun in front of its classifier, and a bare classifier names no noun at all"
else
  fail "the head noun rule is wrong: case_type=$(_set_head_noun case_type) status=$(_set_head_noun status)"; fi

# The places. Naming two members is a listing; naming the key beside a grouping
# verb is the same thing written as a query; naming one member is a branch, and
# every codebase has hundreds.
ig_sites=$(enumeration_sites "$ig_repos/api" case_type first_visit,reopened,second_opinion app/models/medical_case.rb)
if printf '%s' "$ig_sites" | grep -q 'app/reports/case_statistics.rb' \
   && printf '%s' "$ig_sites" | grep -q 'app/exports/monthly_case_export.rb'; then
  pass "a report that groups by the key and an export that lists the members are both places that enumerate it"
else
  fail "the enumeration sites were not found"; printf '%s\n' "$ig_sites"; fi
if printf '%s' "$ig_sites" | grep -q 'app/models/medical_case.rb'; then
  fail "the declaring model was reported as a place that enumerates the set; that file is the ticket's own work"
else
  pass "the declaring model is never one of the places, because that file is the ticket's own work"; fi
if enumeration_sites "$ig_repos/dashboard" case_type first_visit,reopened,second_opinion "" | grep -q 'caseHeader.vue'; then
  fail "a file naming one member was counted as a place that enumerates the set"
else
  pass "a file naming one member is not a place: that is a branch, not a listing"; fi

# Precision, which is the half worth the most. A finding that fires on a ticket
# not of this shape is worse than no feature, because the question reaches a
# reporter. Every golden ticket but ORC-107 is not of this shape, and none of
# them may produce one - ORC-109 included, which is the fixture the standing
# sweep is measured on and would measure the wrong thing if the detector that
# already ships fired on it too.
ig_false=""
for k in ORC-101 ORC-102 ORC-103 ORC-104 ORC-105 ORC-106 ORC-108 ORC-109; do
  ig_txt="$(jq -r '.fields.summary' "$FIXTURE_DIR/issues/$k.json")
$(description_text "$(cat "$FIXTURE_DIR/issues/$k.json")")"
  [ -z "$(integration_gaps "$ig_txt" "$ig_list")" ] || ig_false="$ig_false $k"
done
if [ -z "$ig_false" ]; then
  pass "no golden ticket that does not extend a set produces a finding, ORC-106's 'Allergy panel' included"
else
  fail "a finding was produced for a ticket that extends nothing:$ig_false"; fi

# And the ticket that does. Every filter has to pass at once: the set is
# declared, the ticket names members it already has, the ticket names something
# in the same shape it does not have, and there are places outside the model.
ig_txt="$(jq -r '.fields.summary' "$FIXTURE_DIR/issues/ORC-107.json")
$(description_text "$(cat "$FIXTURE_DIR/issues/ORC-107.json")")"
ig_found=$(integration_gaps "$ig_txt" "$ig_list")
if [ "$(printf '%s' "$ig_found" | cut -d"$ORC_INTEGRATION_FS" -f3)" = "recall case" ]; then
  pass "ORC-107's new case type is found, in the ticket's own spelling rather than the fold's"
else
  fail "the finding on ORC-107 is not the member the ticket adds"; printf '%s\n' "$ig_found" | cat -v; fi
if [ "$(printf '%s' "$ig_found" | grep -c .)" = "1" ]; then
  pass "and one finding rather than one per place, because the places are the payload of a single ask"
else
  fail "ORC-107 produced more than one finding"; printf '%s\n' "$ig_found" | cat -v; fi

# A phrase said once is not what a ticket is introducing. Without this floor, "a
# closed case" in passing would be a new kind of case, and that question would
# reach a reporter.
ig_once="Doctors cannot close a case. A reopened case closes fine, but a stuck case does not."
if [ -z "$(integration_gaps "$ig_once" "$ig_list")" ]; then
  pass "a candidate said once is not a finding: a ticket introducing something repeats it"
else
  fail "a phrase mentioned once became a finding"; fi
# A member the set already has is the ticket talking about that member.
ig_peer="Reopened cases are broken. Every reopened case shows the wrong closure, and a first-visit case does not."
if [ -z "$(integration_gaps "$ig_peer" "$ig_list")" ]; then
  pass "a ticket that only names members the set already has extends nothing"
else
  fail "a ticket about existing members produced a finding"; printf '%s\n' "$(integration_gaps "$ig_peer" "$ig_list")" | cat -v; fi
# The set has to be the one the ticket is talking about, and a member it already
# has is the only mechanical evidence of that.
ig_nopeer="Clinics want a recall case, opened by the doctor. A recall case is created from the case being closed."
if [ -z "$(integration_gaps "$ig_nopeer" "$ig_list")" ]; then
  pass "a ticket naming no member the set already has is not evidence that this is the set it means"
else
  fail "a finding was produced with nothing tying the ticket to that set"; fi
# Test four of the question bar, done mechanically. This is the property the real
# miss had, and it is what stops the question being asked about something the
# ticket has already dealt with.
ig_named="$ig_txt

The case statistics, the monthly case export and the clinic overview all need the new kind added."
if [ -z "$(integration_gaps "$ig_named" "$ig_list")" ]; then
  pass "a place the ticket already names is not a place it forgot, so there is nothing left to ask"
else
  fail "a place the ticket names by itself was still reported as a gap"
  printf '%s\n' "$(integration_gaps "$ig_named" "$ig_list")" | cat -v; fi

# A set nothing outside its own model enumerates has no integration work to
# report, whatever else is true of the ticket.
mkdir -p "$w/ig-lonely/app/models"
cat > "$w/ig-lonely/app/models/medical_case.rb" <<'RB'
class MedicalCase < ApplicationRecord
  enum :case_type, [:first_visit, :reopened, :second_opinion]
end
RB
if [ -z "$(integration_gaps "$ig_txt" "$(printf 'lonely\t%s\n' "$w/ig-lonely")")" ]; then
  pass "a set enumerated nowhere but its own model produces no finding: there is no other place to name"
else
  fail "a finding was reported with no place behind it"; fi

# On the ticket. A stand-in agent again, for the reason the terminal-signal check
# uses one: no canned fixture verdict is authored against this, and one that was
# would be a fixture measuring whoever wrote it.
ig_run() {
  local name="$1" verdict="$2" k="${3:-ORC-107}"
  mkdir -p "$w/fakebin-$name"
  printf '%s' "$verdict" > "$w/fakebin-$name/verdict.json"
  cat > "$w/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$w/fakebin-$name/verdict.json"
SH
  chmod +x "$w/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$ig_projects" ORC_STATE_DIR="$w/s-$name" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$w/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$k" >/dev/null 2>&1
}
ig_v='{"verdict":"needs_input","confidence":"high","one_line":"Doctors should be able to open a recall case after treatment.","subsystems":["subsystems/api"],"files":["app/models/medical_case.rb"],"locality_basis":"search","terms_resolved":[],"terms_unresolved":["recall case"],"questions":["Who may open a recall case - only the doctor who closed the original case, or any doctor at the clinic?"],"duplicate_of":null,"split_into":[],"acceptance_criteria":["A doctor closing a case can open a recall case from it."],"rewritten_description":null,"not_verified":"nothing","notes":""}'
ig_run ig "$ig_v"
ig_body=$(comment_of "$w/s-ig" ORC-107)
if printf '%s' "$ig_body" | grep -qF 'as a new case type'; then
  pass "the ticket is asked where the new member belongs, in the product's own words"
else
  fail "the finding never reached the ticket"; printf '%s\n' "$ig_body"; fi
if printf '%s' "$ig_body" | grep -qF 'the case statistics'; then
  pass "and the question names the places, so the person answering knows what they are deciding about"
else
  fail "the question does not name the places it came from"; printf '%s\n' "$ig_body"; fi
if printf '%s' "$ig_body" | grep -qF 'Who may open a recall case'; then
  pass "and the refiner's own question is still asked beside it"
else
  fail "promoting the finding displaced the refiner's own questions"; fi
if printf '%s' "$ig_body" | grep -qE 'case_type|case_statistics|\.rb|app/'; then
  fail "a path or an identifier was quoted onto the comment a reporter reads"
  printf '%s\n' "$ig_body" | grep -E 'case_type|\.rb|app/'
else
  pass "no path and no identifier: the places are named the way a reporter would name them"; fi
if printf '%s' "$ig_body" | scan_for_both | grep -q .; then
  fail "the promoted question does not meet the bar the rest of the comment is held to"
  printf '%s' "$ig_body" | scan_for_both | sort -u
else
  pass "the promoted question passes the same code and jargon scan as every other comment"; fi
if jq -e '(.integration_gaps | length) == 1
          and (.integration_gaps[0].member == "recall case")
          and (.integration_gaps[0].sites | length) == 3
          and (.integration_gaps[0].sites | map(.path) | any(endswith("case_statistics.rb")))
          and (.integration_asked == ["recall case"])' \
     "$w/s-ig/ORC-107.verdict.json" >/dev/null 2>&1; then
  pass "the record carries the finding with the paths behind it, and what was asked beside it"
else
  fail "the verdict record does not carry the finding"
  jq -c '{integration_gaps, integration_asked}' "$w/s-ig/ORC-107.verdict.json" 2>/dev/null || true; fi
if [ "$(meta_field "$w/s-ig" ORC-107 integration_gap_count)" = "1" ] \
   && [ "$(meta_field "$w/s-ig" ORC-107 integration_asked_count)" = "1" ] \
   && [ "$(meta_field "$w/s-ig" ORC-107 question_count)" = "2" ]; then
  pass "and state/ counts what the ticket was actually asked, with the promoted part separable"
else
  fail "the counts in state/ do not say what the ticket was asked"
  grep -E '^(question_count|integration_)' "$w/s-ig/ORC-107.meta" 2>/dev/null || true; fi

# The refiner doing what the prompt now asks of it. Its question is the better
# one - it can say what the new member is for, where this one can only say where
# the existing members already are - so asking again underneath would be the same
# question twice on one comment.
ig_own=$(printf '%s' "$ig_v" | jq -c '.questions = ["Should recall cases be counted in the clinic monthly figures alongside first visits and reopened cases?"]')
ig_run igown "$ig_own"
if comment_of "$w/s-igown" ORC-107 | grep -qF 'as a new case type'; then
  fail "a finding the refiner already asked about was asked again underneath its own question"
  comment_of "$w/s-igown" ORC-107
else
  pass "a finding the refiner asked about itself is not asked a second time"; fi
if jq -e '(.integration_gaps | length) == 1 and (.integration_asked == [])' \
     "$w/s-igown/ORC-107.verdict.json" >/dev/null 2>&1; then
  pass "and it is still recorded, because a finding found and not asked is not a finding never found"
else
  fail "the record lost the finding when the refiner asked about it itself"; fi

# The already-asked test, at the unit it is written at. Both ways of being wrong
# were weighed: a wrong yes drops a real question, which is the failure this whole
# finding exists to fix, and a wrong no asks something similar twice on one
# comment. Both of these are real questions a refiner produced against ORC-107.
ig_rec=$(printf 'case type\002case_type\002recall case\002first_visit,reopened\002case statistics|api|app/reports/case_statistics.rb')
if [ -z "$(integration_to_ask "$ig_rec" "Should recall cases be counted as their own kind in the clinic's monthly figures, in the accounting export, and on the clinic overview?")" ] \
   && [ -z "$(integration_to_ask "$ig_rec" "Should a recall case appear as its own line in the clinic's monthly figures, or should it be counted there with first visits?")" ]; then
  pass "a refiner asking where the new member is counted is recognised, so the comment does not carry the question twice"
else
  fail "a refiner's own question about the set was not recognised, and would be asked again underneath"; fi
if [ -n "$(integration_to_ask "$ig_rec" "Should a recall case be listed on the patient's case list in the app?")" ]; then
  pass "and a question about one screen is not that question: naming the member near the word 'listed' does not cover the set"
else
  fail "a question about a single screen suppressed the finding, which is the expensive way to be wrong"; fi

# The terminal state. A card announced as having nothing left to ask, whose split
# is drawn around a set nobody has said where the new member belongs in, is a
# split drawn around the wrong scope.
ig_split=$(printf '%s' "$ig_v" | jq -c '.questions = [] | .split_into = [{"title":"Open a recall case from a closed case","description":"The doctor-facing half."},{"title":"Show the recall case in the app","description":"The patient-facing half."}]')
ig_run igsplit "$ig_split"
ig_sp=$(comment_of "$w/s-igsplit" ORC-107)
if printf '%s' "$ig_sp" | grep -qF 'as a new case type'; then
  pass "a card with no questions of its own still asks where the new member belongs"
else
  fail "the finding was dropped on a card whose own question list was empty"; printf '%s\n' "$ig_sp"; fi
if printf '%s' "$ig_sp" | grep -q "nothing left to ask, only the split remains"; then
  fail "a card was announced as having nothing left to ask while this was still open"
else
  pass "an open integration question is not the terminal state, whatever the refiner's own list says"; fi
if printf '%s' "$ig_sp" | grep -qF 'Show the recall case in the app'; then
  fail "a split drawn around a scope nobody has decided was shown to the reporter"
else
  pass "and the split proposal is withheld, the same as on any other round with a question open"; fi
if [ "$(meta_field "$w/s-igsplit" ORC-107 split_ready)" = "no" ]; then
  pass "and split_ready says no, so a report reads the same thing the comment says"
else
  fail "split_ready still says yes with an integration question open"; fi

# A ready comment. No question is added there - that would be this harness
# overruling a verdict rather than reporting on it - and the places go in the
# engineering fold instead, where a path is what the audience came for.
ig_ready=$(printf '%s' "$ig_v" | jq -c '.verdict = "ready" | .questions = [] | .acceptance_criteria = ["A doctor closing a case can open a recall case from it."] | .rewritten_description = "On the dashboard, a doctor closing a case can open a recall case from it."')
ig_run igready "$ig_ready"
ig_rb=$(comment_of "$w/s-igready" ORC-107)
if printf '%s' "$ig_rb" | grep -qF 'should this one be listed there too?'; then
  fail "a ready comment grew a question, which means a verdict was overruled here rather than reported"
else
  pass "a ready verdict is reported, not overruled: no question is added to its comment"; fi
if printf '%s' "$ig_rb" | grep -qF 'app/reports/case_statistics.rb - enumerates every case type'; then
  pass "and the places are named with their paths in the fold, for the agent that picks the ticket up"
else
  fail "a ready comment carries the finding nowhere at all"; printf '%s\n' "$ig_rb"; fi
if [ "$(printf '%s' "$ig_rb" | grep -n 'For the implementing agent' | cut -d: -f1)" \
     -lt "$(printf '%s' "$ig_rb" | grep -n 'case_statistics.rb' | cut -d: -f1)" ]; then
  pass "and it is inside the fold rather than in front of the summary a person came for"
else
  fail "the places landed outside the engineering fold"; fi

# A duplicate is being closed against another ticket, and a question about this
# one's set belongs on whichever survives. It still records.
ig_dup=$(printf '%s' "$ig_v" | jq -c '.verdict = "duplicate" | .duplicate_of = "ORC-101" | .questions = []')
ig_run igdup "$ig_dup"
if comment_of "$w/s-igdup" ORC-107 | grep -qF 'as a new case type'; then
  fail "a duplicate comment asks about a set on a ticket that is being closed"
else
  pass "a duplicate is not asked either: the surviving ticket is where that question belongs"; fi
if jq -e '(.integration_gaps | length) == 1 and (.integration_asked == [])' \
     "$w/s-igdup/ORC-107.verdict.json" >/dev/null 2>&1; then
  pass "and the finding is still recorded there, which is what a report reads"
else
  fail "a duplicate verdict lost the finding"; fi

# A run with no repository to read finds nothing and says nothing, rather than
# guessing from the ticket alone. That is the whole shape of this feature: it is
# a reading of the code, and with no code there is no reading.
ig_run ignorepo "$ig_v"
igno=$(env ORC_PROJECTS_FILE="$ORC_ROOT/config/projects.yml" ORC_STATE_DIR="$w/s-ignorepo2" \
  ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
  PATH="$w/fakebin-ignorepo:$PATH" \
  "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force ORC-107 2>/dev/null)
if printf '%s' "$igno" | jq -e '.integration_gaps == [] and .integration_asked == []' >/dev/null 2>&1; then
  pass "with no repository to search there is no finding, because there was nothing to read"
else
  fail "a finding was produced with no repository searched"; printf '%s\n' "$igno" | jq -c '{integration_gaps}'; fi

# The other half. Every comment scanned above was rendered from a verdict a human
# hand-wrote against this bar, so it proves the scanners run and nothing whatever
# about what an agent says. This runs the same scan over the solved set, through
# the same comment builder.
#
# How much that proves depends on which set is there, and the two are not
# equivalent - so this says which it did rather than reporting one number for
# both. Pointed at an installation's own ORC_SOLVED_DIR, these are recordings:
# what the agent actually said, which is the guarantee, because a guarantee
# proved only against text written to pass it is not yet a guarantee. Pointed at
# the shipped example set, they are authored fixtures, and this degrades to a
# second run of the weaker proof above.
#
# That weakening is the cost of the real tickets living outside the tree, and it
# is worth naming rather than hiding: the strong form is one environment variable
# away, and an installation that scores its own tickets already has the
# recordings this wants.
solved_root="${ORC_SOLVED_DIR:-$ORC_ROOT/fixtures/solved}"
rec="$solved_root/verdicts"
if [ -n "${ORC_SOLVED_DIR:-}" ]; then rec_kind="recorded real"; else rec_kind="authored example"; fi
tag=$(awk -F'\t' '$1=="prompts/refine.md" {print $2}' "$ORC_ROOT/golden/replay-map.tsv")
recorded=$(find "$rec" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
if [ -z "$recorded" ] || [ -z "$tag" ]; then
  fail "there are no solved-set verdicts to scan, so the guarantee is untested against anything but the canned verdicts"
else
  mkdir -p "$w/rec/$tag"
  cp "$rec"/*.json "$w/rec/$tag/"
  offenders=""
  scanned=0
  for f in $recorded; do
    k=$(basename "$f" .json)
    # A ready comment carries the file list and the commit by design, and its
    # audience is the implementing agent. This bar is the other audience's.
    [ "$(jq -r '.verdict // ""' "$f")" = "ready" ] && continue
    env ORC_JIRA_MODE=fixture ORC_REFINER=replay ORC_REPO_SYNC=off \
        ORC_FIXTURE_DIR="$solved_root" ORC_VERDICT_DIR="$w/rec" \
        ORC_STATE_DIR="$w/rec-state" \
        "$ORC_ROOT/bin/orc-refine.sh" --force "$k" >/dev/null 2>&1
    scanned=$(( scanned + 1 ))
    hits=$(comment_of "$w/rec-state" "$k" | scan_for_both | sort -u | tr '\n' ' ')
    [ -n "$hits" ] && offenders="$offenders
  $k: $hits"
  done
  if [ "$scanned" = "0" ]; then
    fail "every solved-set verdict is 'ready', so nothing exercised the reporter's bar"
  elif [ -n "$offenders" ]; then
    fail "a $rec_kind verdict says this to a reporter:$offenders"
  else
    pass "$scanned $rec_kind verdict(s) hold to the same bar as the canned ones"
    [ -n "${ORC_SOLVED_DIR:-}" ] || printf '        (authored, so this repeats the proof above rather than testing agent output.\n        Set ORC_SOLVED_DIR to your own recordings for the guarantee.)\n'
  fi
fi

printf '\n== a ready comment folds the engineering half ==\n'
# A ready comment has both audiences at once. The implementing agent came for the
# files, the subsystems and the commit; the person who opened the card came for
# the sentence saying what the ticket is, and flat, that sentence lost - three
# headings of paths stood above it. So the engineering half is behind an expand.
#
# What is checked here is the split rather than the wording: which half is
# visible, which half is folded, that nothing moved out of the payload on the way
# there, and that the marker line reconcile reads is still where reconcile reads
# it. $w/s1 is the ready comment the section above already produced against two
# real clones, so the commits in it are real ones.
comment_json_of() {
  awk -v key="$2" '
    index($0, "WOULD POST   /issue/" key "/comment") { in_block = 1; next }
    !in_block { next }
    /^  \+-- raw/ { raw = 1; next }
    /^  \+-----/ { if (raw) exit; next }
    raw { sub(/^  \| /, ""); print }
  ' "$1/.would-write.log"
}
ready_json=$(comment_json_of "$w/s1" ORC-101)
# Two folds now, and which is which is decided by what is in them rather than by
# a title, so renaming either one leaves this assertion true: the description
# fold is the one that says the ticket has not been changed, the engineering
# fold is the one holding the paths. The order is asserted because it is a
# decision - the rewritten ticket is for both audiences and the paths are for
# one, so the half everybody reads comes first.
if printf '%s' "$ready_json" | jq -e '
     .body.type == "doc" and .body.version == 1
     and ([.body.content[] | select(.type == "expand")] | length) == 2' >/dev/null 2>&1; then
  pass "the ready comment is one well-formed ADF document with two folds in it"
else
  fail "the ready comment is not well-formed ADF carrying both folds"
  printf '%s\n' "$ready_json" | head -30
fi
if printf '%s' "$ready_json" | jq -e '
     [.body.content[] | select(.type == "expand")] as $folds
     | ($folds | all(
         ((.attrs.title | type) == "string") and ((.attrs.title | length) > 0)
         and (((.marks // []) | length) == 0)
         and ((.content | length) >= 1)
         and ((([.content[].type]
                 - ["paragraph","heading","bulletList","orderedList","codeBlock","rule"]) | length) == 0)))' \
   >/dev/null 2>&1; then
  pass "and every fold names its audience in a title and holds only nodes the schema allows there"
else
  fail "a fold in the ready comment is not a valid expand node"
fi
if printf '%s' "$ready_json" | jq -e '
     [.body.content[] | select(.type == "expand")] as $folds
     | (($folds[0] | tostring) | contains("The ticket has not been changed"))
     and (($folds[1] | tostring) | contains("FollowUpDecision.vue"))' >/dev/null 2>&1; then
  pass "the rewritten ticket is the first fold and the engineering half the second, which is the order both audiences are served in"
else
  fail "the two folds on a ready comment are in the wrong order, or one of them is missing"
fi
if printf '%s' "$ready_json" | jq -e '
     ([.body.content[].type] | index("expand")) as $i
     | $i != null and $i > 0
     and (.body.content[-2].type == "rule")
     and (.body.content[-1].content[0].marks[0].type == "em")' >/dev/null 2>&1; then
  pass "and it sits below the prose, with the ruled marker line still outside it"
else
  fail "the fold is in the wrong place, or the marker line went inside it"
fi
# Exactly how reconcile looks for its own footprints. A fold that swallowed the
# marker would leave every ready ticket looking unjudged after a state wipe.
if printf '%s' "$ready_json" | jq -e --arg m "$ORC_COMMENT_MARKER" \
     '[.body | tostring | select(contains($m))] | length > 0' >/dev/null 2>&1; then
  pass "and reconcile can still find the marker in it, which is what makes state/ disposable"
else
  fail "the marker is no longer findable the way bin/orc-reconcile.sh looks for it"
fi

visible=$(printf '%s' "$ready_json" | jq -c '{content: [.body.content[] | select(.type != "expand")]}' | adf_to_text)
in_fold=$(printf '%s' "$ready_json" | jq -c '{content: [.body.content[] | select(.type == "expand")]}' | adf_to_text)
if printf '%s' "$visible" | grep -q 'Refinement: ready' \
   && printf '%s' "$visible" | grep -q 'Acceptance criteria' \
   && printf '%s' "$visible" | grep -q 'Not verified:'; then
  pass "the summary, the criteria and the not-verified caveat are what a person sees without opening anything"
else
  fail "the visible half lost the summary, the criteria or the caveat"; printf '%s\n' "$visible"
fi
leaked=""
for heading in 'Probable files' 'Subsystems' 'Reasoned against'; do
  printf '%s' "$visible" | grep -q "$heading" && leaked="$leaked
  the '$heading' heading is still above the fold"
done
# Every path, subsystem and commit the run recorded, checked one by one against
# the visible half. The headings could be renamed and this would still hold.
while IFS= read -r detail; do
  [ -n "$detail" ] || continue
  printf '%s' "$visible" | grep -qF "$detail" && leaked="$leaked
  $detail"
  printf '%s' "$in_fold" | grep -qF "$detail" || leaked="$leaked
  $detail is in neither half, so the comment lost it"
done <<< "$(jq -r '(.files // [])[], (.subsystems // [])[], (.reasoned_against // [])[]' \
             "$w/s1/ORC-101.verdict.json")"
if [ -n "$leaked" ]; then
  fail "engineering detail is above the fold, or missing from it:$leaked"
else
  pass "every file, subsystem and commit the run recorded is inside the fold and none of it above"
fi

printf '\n== a settled card carries its description, rewritten ==\n'
# The loop asks, the reporter answers in a comment, and the description stays
# exactly as filed - three rounds against a real epic ended on the same
# ticket-rev they started on. So the settled card carries the description as it
# now reads, folded, and the two states that count as settled are a ready
# verdict and the split-ready terminal one. Everything else is a card with an
# answer still outstanding or a card being closed.
#
# Stand-in agents, for the same reason the split-ready section above uses one:
# what is being checked is which state renders it and what the rendering is held
# to, and a canned fixture cannot be made to volunteer the field on a verdict
# the contract says should not carry it.
# The one mechanical link between the two halves. The harness reads a field name
# the prompt has to ask for, and a prompt edit that dropped it would leave every
# settled card silently unrewritten - nothing else here would notice, because an
# absent rewrite renders as no fold at all by design.
if grep -q '"rewritten_description"' "$ORC_ROOT/prompts/refine.md"; then
  pass "the output contract asks for rewritten_description"
else
  fail "prompts/refine.md does not ask for rewritten_description, so nothing will ever fill the fold"; fi

# ORC-101's own description as it would read settled, and it carries the two
# strings that ticket states exactly - the "Open follow-up" control and the
# "waiting for authorisation" tooltip. Written that way rather than about some
# other product because the rewrite is now checked against the ticket it is a
# rewrite of: a stand-in rewrite naming neither of those strings is a dropped
# string, and would be withheld here for the right reason.
desc_text='A doctor cannot open a follow-up whose authorisation has already been claimed. On the examination tab the "Open follow-up" control stays disabled and its tooltip still reads "waiting for authorisation", so the case cannot be worked on at all.

It should be enabled, and activating it should open the follow-up for examination.

Done when:

- A doctor on a case whose follow-up authorisation is claimed can open the follow-up from the examination tab.
- A doctor on a case whose authorisation is not claimed still sees the control disabled with the existing tooltip.'
desc_run() {
  local name="$1" verdict="$2"
  mkdir -p "$w/fakebin-$name"
  printf '%s' "$verdict" > "$w/fakebin-$name/verdict.json"
  cat > "$w/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$w/fakebin-$name/verdict.json"
SH
  chmod +x "$w/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/s-$name" ORC_CLONE_DIR="$w/clones" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$w/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force ORC-101 >/dev/null 2>&1
}
# One base verdict, and every case below is it with two or three fields moved.
# The rewrite is present on all of them, including the ones that must not show
# it: what is being asserted there is that the harness withholds it, not that a
# stand-in agent can be talked out of producing it.
desc_base=$(jq -nc --arg d "$desc_text" '{verdict:"needs_input",confidence:"high",
  one_line:"Two small deliverables filed as one ticket.",subsystems:[],files:[],
  locality_basis:"bundle",terms_resolved:[],terms_unresolved:[],questions:[],
  duplicate_of:null,
  split_into:[{title:"Close a released rental",description:"Let a clerk close a rental whose deposit is already released."},
              {title:"Label the export column",description:"Rename the column in the export people download."}],
  acceptance_criteria:[],rewritten_description:$d,not_verified:"nothing",notes:""}')

# The fold, and the JSON it is built out of. adf_to_text renders an expand's
# children flat beneath its title, so a scan of the whole comment cannot say
# which fold a line came out of - and one of the claims here is about a fold on
# a ready comment, where every other line is deliberately exempt from the bar.
desc_fold_json() {
  comment_json_of "$1" ORC-101 \
    | jq -c '[.body.content[]? | select(.type == "expand")
              | select((. | tostring) | contains("The ticket has not been changed"))][0] // empty'
}
desc_fold_text() { desc_fold_json "$1" | jq -c '{content: [.]}' | adf_to_text; }

desc_run descterm "$desc_base"
if [ -n "$(desc_fold_json "$w/s-descterm")" ]; then
  pass "the terminal state carries the ticket rewritten, folded"
else
  fail "a card with nothing left to ask but the split does not carry its rewritten description"
  comment_of "$w/s-descterm" ORC-101; fi
if desc_fold_text "$w/s-descterm" | grep -q 'cannot open a follow-up whose authorisation'; then
  pass "and what is in the fold is the description itself, not a report about it"
else
  fail "the fold does not hold the rewritten description"; fi
if [ "$(meta_field "$w/s-descterm" ORC-101 description_rewritten)" = "yes" ]; then
  pass "and the run records that a rewrite was produced, which is the figure that says whether the prompt half works"
else
  fail "the rewrite is not recorded in state/"; fi

# A card with an answer still outstanding. The refiner volunteered the field
# against its own contract, and the harness renders nothing: a description
# rewritten around this round's reading is exactly what the next round could
# contradict, and that is the reason the split proposal beside it is withheld too.
desc_open=$(printf '%s' "$desc_base" | jq -c '.questions = ["Which rentals should the express return be offered for?"]')
desc_run descopen "$desc_open"
if [ -z "$(desc_fold_json "$w/s-descopen")" ]; then
  pass "a needs_input with a question still open shows no rewritten description, whatever the refiner volunteered"
else
  fail "a card with an open question was given a settled description"
  comment_of "$w/s-descopen" ORC-101; fi
if [ "$(meta_field "$w/s-descopen" ORC-101 description_rewritten)" = "yes" ]; then
  pass "and it is still recorded, so a rewrite written and thrown away is visible rather than silent"
else
  fail "a volunteered rewrite on an unsettled card left no trace"; fi

# A duplicate is closed against another ticket, and rewriting the text of a card
# nobody will open again is work aimed at nobody.
desc_dup=$(printf '%s' "$desc_base" | jq -c '.verdict = "duplicate" | .duplicate_of = "ORC-102" | .split_into = []')
desc_run descdup "$desc_dup"
if [ -z "$(desc_fold_json "$w/s-descdup")" ]; then
  pass "a duplicate carries no rewritten description either"
else
  fail "a ticket being closed as a duplicate was handed a rewritten description"; fi

# The bar. On a ready comment every other line may name code by design, and this
# one may not: it is text a person is going to paste onto the card, where
# everybody reads it. $w/s1 is the ready comment produced further up, so this
# scans a fold that a real render actually produced.
for pair in "s1:ready" "s-descterm:terminal"; do
  st=${pair%%:*}; what=${pair##*:}
  hits=$(desc_fold_text "$w/$st" | scan_for_both | sort -u | tr '\n' ' ')
  if [ -z "$hits" ]; then
    pass "the rewritten description on a $what comment passes the same code and jargon scan as a reporter's own comment"
  else
    fail "the rewritten description on a $what comment is not in the product's words: $hits"; fi
done
unset pair st what

# It is a proposal. The first line inside the fold says the ticket has not been
# changed, because a fold titled "rewritten", read from the outside, could be
# taken for something that already happened.
if desc_fold_text "$w/s-descterm" | grep -q 'The ticket has not been changed'; then
  pass "the fold says plainly that nothing on the ticket was changed"
else
  fail "nothing in the fold says the card itself is untouched"; fi
# And it is a proposal in fact, not only in wording: the description field is
# never written. Every payload in the log is checked for the key rather than the
# word, because the word is in the fold's own first line - and the paths a
# refinement is allowed to write to are listed rather than the ones it is not,
# so a fifth write added later fails here rather than going past unnoticed.
desc_writes=""
for st in s1 s-descterm s-descopen s-descdup; do
  [ -f "$w/$st/.would-write.log" ] || continue
  grep -oE '"description"[[:space:]]*:' "$w/$st/.would-write.log" | grep -q . \
    && desc_writes="$desc_writes $st"
  grep -oE 'WOULD (PUT|POST|DELETE) +[^ ]+' "$w/$st/.would-write.log" \
    | grep -vE '(/issue/[A-Z]+-[0-9]+(/comment|/assignee)?|/issueLink)$' | grep -q . \
    && desc_writes="$desc_writes $st(unexpected write)"
done
unset st
if [ -z "$desc_writes" ]; then
  pass "and no write anywhere in a refinement carries a description field: the text is offered, never applied"
else
  fail "refinement wrote to the ticket's description, or wrote something it has no business writing:$desc_writes"; fi

# An expand may not hold another expand, and the converter this fold is built
# with cannot produce one - asserted rather than trusted, because the rewrite is
# the first thing in this system whose inner document comes from the agent.
if desc_fold_json "$w/s-descterm" | jq -e '
     ((.content | length) >= 1)
     and ((([.content[].type]
             - ["paragraph","heading","bulletList","orderedList","codeBlock","rule"]) | length) == 0)
     and (([.content | .. | objects | select(.type == "expand")] | length) == 0)' >/dev/null 2>&1; then
  pass "the fold holds only nodes the schema allows there, and no expand inside an expand"
else
  fail "the rewritten description built an expand the schema does not allow"
  desc_fold_json "$w/s-descterm"; fi

# Nothing in, nothing added - the same rule adf_bullets and adf_expand already
# follow. A settled card whose refiner produced no rewrite gets no empty fold.
desc_none=$(printf '%s' "$desc_base" | jq -c '.rewritten_description = null')
desc_run descnone "$desc_none"
if [ -z "$(desc_fold_json "$w/s-descnone")" ] \
   && comment_of "$w/s-descnone" ORC-101 | grep -q 'nothing left to ask'; then
  pass "a settled card whose refiner produced no rewrite gets no empty fold, and the rest of the comment is unchanged"
else
  fail "an absent rewrite left an empty fold on the comment"
  comment_of "$w/s-descnone" ORC-101; fi
if [ "$(meta_field "$w/s-descnone" ORC-101 description_rewritten)" = "no" ]; then
  pass "and state/ says so, which is how a settled card with no rewrite gets counted rather than overlooked"
else
  fail "a settled card with no rewrite was recorded as having one"; fi

printf '\n== the rewritten description keeps the ticket'"'"'s own copy ==\n'
# Paraphrasing a specification is what that field is for. Paraphrasing the copy
# inside one destroys it: on a card whose description states a dozen strings
# exactly, almost all of them come back as descriptions of themselves - a banner
# becomes "a warning before the return is started", a button label becomes "a
# button letting a clerk unlock one by hand". Read as prose that is better;
# pasted onto the card, which is the one thing the fold asks for, it is a
# deletion.
#
# So the strings are extracted from the ticket mechanically, their absence is
# reported, and a non-empty list withholds the fold - the same act split_into
# already performs, on the same argument: this is not a report a reader weighs,
# it is text somebody is invited to paste over the description.
#
# The prompt carries the other half of both defects, and the one mechanical link
# to it is asserted here the way the field name itself already is: a prompt edit
# that dropped the rule would leave the harness withholding rewrites and nothing
# telling the refiner why.
if grep -q 'carry through unchanged, quoted' "$ORC_ROOT/prompts/refine.md"; then
  pass "the prompt tells the refiner to carry the ticket's exact words through, quoted and untranslated"
else
  fail "prompts/refine.md no longer asks for the ticket's own copy to be kept, so the harness would withhold rewrites nobody was told how to write"; fi
if grep -q 'the ticket'"'"'s own structure for a long one' "$ORC_ROOT/prompts/refine.md"; then
  pass "and to keep a long, sectioned ticket's own sections rather than flattening it into prose"
else
  fail "prompts/refine.md no longer inverts the prose default for a sectioned or multi-surface ticket"; fi

rf=$(mktemp -d)
mkdir -p "$rf/fixtures/issues" "$rf/fixtures/search"
printf '{"issues":[]}' > "$rf/fixtures/search/open-issues.json"
: > "$rf/projects.yml"

# A sectioned, multi-surface card in the invented rental product, carrying copy
# the way a real one does: four quoted strings and one unquoted line carrying a
# letter outside ASCII, so both sources this reads are exercised by the same
# ticket. The accented line stands in for copy the ticket did not put quotation
# marks round, because a letter outside ASCII is the only tell the extractor has
# for one.
rf_desc='## App

A customer whose booking follows on from an earlier one sees the banner "Heads up: this booking is a follow-on!" above the return form, and the button underneath it reads "Unlock follow-on booking".

## Depot dashboard

The booking list shows the status "Another follow-on booking can be started" once the return is closed, instead of the ordinary closed status.

## Pushes

Push title: "Your follow-on booking has been refunded". Body: Finish the payment at the Örebro counter.

## Rental agreement wording

The paragraph the customer is sent keeps the wording it has today.'
# And the card this capability must not touch: short, one surface, no copy in it
# at all.
rf_short='A depot clerk cannot close a booking once its deposit has been released. The control stays disabled, and it should be enabled.'
rf_issue() {
  jq -n --arg k "$1" --arg s "$2" --arg d "$3" \
    '{key:$k, fields:{summary:$s, description:$d, labels:[],
      issuetype:{name:"Story"}, reporter:{accountId:"acct-1"},
      status:{name:"To Do"}, updated:"2026-01-01T00:00:00.000+0000",
      comment:{comments:[]}}}' > "$rf/fixtures/issues/$1.json"
}
rf_issue RF-1 "Follow-on bookings" "$rf_desc"
rf_issue RF-2 "Close a released booking" "$rf_short"

# --- the extraction and the comparison, at the unit they are written at
rf_want='Heads up: this booking is a follow-on!
Unlock follow-on booking
Another follow-on booking can be started
Your follow-on booking has been refunded
Finish the payment at the Örebro counter'
rf_got=$(ticket_verbatim_copy "$rf_desc")
if [ "$rf_got" = "$rf_want" ]; then
  pass "every string the ticket states exactly is read out of it: four quoted spans and one unquoted line carrying a letter outside ASCII"
else
  fail "the ticket's own copy was not read out of it as expected"
  printf '   got:\n%s\n   want:\n%s\n' "$rf_got" "$rf_want"; fi
if [ -z "$(ticket_verbatim_copy "$rf_short")" ]; then
  pass "and a card with no copy in it nominates nothing, so this capability never touches one"
else
  fail "a card with no copy in it nominated something"; ticket_verbatim_copy "$rf_short"; fi

# The gate. A description written in the language its copy is in would otherwise
# nominate its own prose, and requiring a paragraph verbatim would withhold
# every rewrite of the ticket that held it - which is the failure that switches
# a feature off. So a foreign run counts as copy only while it is the minority,
# and once most of the card's own sentences read as foreign runs only the quoted
# spans are read. That is also the named bound: an unquoted string in the
# ticket's own language is invisible.
rf_foreign='The clerk at the Ångström depot sees a warning before the booking starts. Zoë Håkansson signs the handover afterwards. The return must be closed at the Åsgård counter first. The button reads "Unlock follow-on booking".'
if [ "$(ticket_verbatim_copy "$rf_foreign")" = "Unlock follow-on booking" ]; then
  pass "a card written in the language of its own copy nominates its quoted spans and not its prose"
else
  fail "a card written in another language nominated its own prose as copy"
  ticket_verbatim_copy "$rf_foreign"; fi

# The line this whole rule was corrected on: a specification bullet holding a
# parenthetical and a mapping arrow, which no rewrite would ever carry through
# character for character. It was nominated because the arrow is a byte outside
# ASCII and "another language" had been spelled as "a byte outside ASCII" - so an
# em dash, a euro sign or a bullet in a plain English sentence did the same.
# Beside it, the two strings on that same card which are copy and have to stay
# nominated.
rf_spec='## Packages

The follow-on booking is offered in two packages.
- new advantages (only 2 and new wording + pricing) → new packages
- the banner reads "Heads up: this booking is a follow-on!" above the form
- the unlock button reads "Unlock follow-on booking"

Clerks can switch between the original booking and the follow-on one.'
rf_spec_got=$(ticket_verbatim_copy "$rf_spec")
if ! printf '%s\n' "$rf_spec_got" | grep -q 'new advantages'; then
  pass "a specification bullet is not copy: a leading list marker and a mapping arrow are the description's own structure, not a string anybody reproduces"
else
  fail "a specification bullet was nominated as a string the rewrite has to carry through"
  printf '%s\n' "$rf_spec_got"; fi
if printf '%s\n' "$rf_spec_got" | grep -qF 'Heads up: this booking is a follow-on!' \
   && printf '%s\n' "$rf_spec_got" | grep -qxF 'Unlock follow-on booking'; then
  pass "and the real copy on that same card is still nominated, colon and all, which is what the narrowing may not cost"
else
  fail "narrowing what counts as copy lost the strings that are copy"
  printf '%s\n' "$rf_spec_got"; fi
# The structural half, which the language rule alone would not have caught. A
# card writes its specification as bullets in whatever language it is in, and a
# bullet holding a letter outside ASCII is a run of text in another language by
# every test above - and it is no more copy than the plain ASCII one was.
rf_spec_accented='- The status changes after the Örebro return → follow-on
The booking list is what a clerk reads afterwards.
Nothing about the deposit changes.'
if [ -z "$(ticket_verbatim_copy "$rf_spec_accented")" ]; then
  pass "and a specification bullet in that other language is refused on the same two tells, not on the language it is in"
else
  fail "a bulleted specification line was nominated because of the language it is written in"
  ticket_verbatim_copy "$rf_spec_accented"; fi

# The root cause rather than the one sentence it was found on. A symbol says
# nothing about which language a sentence is in, so an ordinary English
# statement carrying one is not a run of text in another language.
rf_symbols='The rush fee is 19 € on top of the daily rate.
The clerk — who owns the depot — is the one who closes it.
Returns are counted per depot • per month, and nothing else changes.
A clerk opens the booking from the depot dashboard.
The deposit is released when the return is closed.
The booking list keeps the order it has today.
Nothing about the rental agreement wording changes.'
if [ -z "$(ticket_verbatim_copy "$rf_symbols")" ]; then
  pass "a euro sign, an em dash or a bullet in an English sentence is a symbol rather than another language, so none of it is nominated"
else
  fail "a symbol outside ASCII still reads as another language"
  ticket_verbatim_copy "$rf_symbols"; fi
# And a letter outside ASCII still does, which is the half that has to keep
# working: the narrowing is about symbols, not about languages.
rf_letters='Finish the payment at the Örebro counter
The clerk closes the booking from the depot dashboard.
Nothing else about the return changes.'
if [ "$(ticket_verbatim_copy "$rf_letters")" = "Finish the payment at the Örebro counter" ]; then
  pass "and a letter outside ASCII still marks a run of text as another language, which is the source this reads"
else
  fail "narrowing the language test switched the language test off"
  ticket_verbatim_copy "$rf_letters"; fi

# An identifier is not copy. The rewritten description may not name one at all,
# so a check that demanded one be carried through would be demanding the field
# fail the scan it is held to - the two rules have to point the same way.
rf_ids='Read "app/models/booking.rb" and the "monthly_deposit_count" column, and see "FollowUpDecision" for the rest.'
if [ -z "$(ticket_verbatim_copy "$rf_ids")" ]; then
  pass "a quoted path, column or class name is never nominated: an identifier is code, not copy"
else
  fail "an identifier was nominated as copy the rewrite has to carry"; ticket_verbatim_copy "$rf_ids"; fi

# A faithful rewrite, and the same rewrite with one string restated as prose.
rf_kept='## App

A customer whose booking follows on from an earlier one sees the banner "Heads up: this booking is a follow-on!" above the return form, with a button reading "Unlock follow-on booking" underneath it.

## Depot dashboard

Once the return is closed, the booking list shows "Another follow-on booking can be started" in place of the ordinary closed status.

## Pushes

The customer is sent a push titled "Your follow-on booking has been refunded" when the refund lands, and one reading "Finish the payment at the Örebro counter" while the payment is still outstanding.

## Rental agreement wording

The paragraph the customer is sent is unchanged.'
rf_lost=$(printf '%s' "$rf_kept" | sed 's/"Unlock follow-on booking"/a button letting a clerk unlock it by hand/')
if [ -z "$(rewrite_dropped "$rf_got" "$rf_kept")" ]; then
  pass "a rewrite that carries every string through is clean, however freely it rewords the sentences around them"
else
  fail "a faithful rewrite was reported as dropping something"; rewrite_dropped "$rf_got" "$rf_kept"; fi
if [ "$(rewrite_dropped "$rf_got" "$rf_lost")" = "Unlock follow-on booking" ]; then
  pass "and a rewrite that restates one of them as prose is reported, naming the string it lost"
else
  fail "a restated string was not reported, or the wrong one was"
  rewrite_dropped "$rf_got" "$rf_lost"; fi
# Folded, so the comparison is about the words rather than about the quotation
# marks round them - the same fold every other text comparison in orc-lib.sh
# goes through, rather than a second spelling of it.
rf_requoted=$(printf '%s' "$rf_kept" | sed 's/"Unlock follow-on booking"/„unlock follow-on booking“,/')
if [ -z "$(rewrite_dropped "$rf_got" "$rf_requoted")" ]; then
  pass "a different quotation mark, a different case or a comma after it is not a dropped string"
else
  fail "the comparison is about punctuation rather than about the words"
  rewrite_dropped "$rf_got" "$rf_requoted"; fi

# --- and end to end, through the real comment builder
#
# Stand-in agents, for the reason every other section of this kind uses one: no
# canned fixture verdict is authored against this, and one that was would be a
# fixture measuring whoever wrote it.
rf_run() {
  local name="$1" verdict="$2" key="$3"
  mkdir -p "$rf/fakebin-$name"
  printf '%s' "$verdict" > "$rf/fakebin-$name/verdict.json"
  cat > "$rf/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$rf/fakebin-$name/verdict.json"
SH
  chmod +x "$rf/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$rf/projects.yml" ORC_STATE_DIR="$rf/state-$name" ORC_CLONE_DIR="$rf/clones" \
      ORC_FIXTURE_DIR="$rf/fixtures" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$rf/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$key" >/dev/null 2>&1
}
rf_fold_json() {
  comment_json_of "$1" "$2" \
    | jq -c '[.body.content[]? | select(.type == "expand")
              | select((. | tostring) | contains("The ticket has not been changed"))][0] // empty'
}
rf_verdict() {
  jq -nc --arg d "$1" '{verdict:"ready",confidence:"high",
    one_line:"A booking that follows on from an earlier one needs its own banner, status and pushes.",
    subsystems:[],files:[],locality_basis:"none",terms_resolved:[],terms_unresolved:[],
    questions:[],duplicate_of:null,split_into:[],
    acceptance_criteria:["The banner, the button, the status and both pushes read as the ticket states them."],
    rewritten_description:$d,not_verified:"nothing",notes:""}'
}

rf_run kept "$(rf_verdict "$rf_kept")" RF-1
if [ -n "$(rf_fold_json "$rf/state-kept" RF-1)" ]; then
  pass "a rewrite carrying every string through is offered to copy across, as it always was"
else
  fail "a faithful rewrite was withheld"; comment_of "$rf/state-kept" RF-1; fi
if [ "$(meta_field "$rf/state-kept" RF-1 rewrite_verbatim_count)" = "5" ] \
   && [ "$(meta_field "$rf/state-kept" RF-1 rewrite_dropped_count)" = "0" ] \
   && [ "$(meta_field "$rf/state-kept" RF-1 rewrite_annotated)" = "no" ]; then
  pass "and state/ counts what the ticket stated exactly and that none of it was lost, which is what tells a clean rewrite from a card with no copy in it"
else
  fail "the counts in state/ do not say what happened to the ticket's own copy"
  grep -E '^rewrite_' "$rf/state-kept/RF-1.meta" 2>/dev/null || true; fi
if jq -e '(.rewrite_verbatim | length) == 5 and .rewrite_dropped == [] and .rewrite_annotated == false' \
     "$rf/state-kept/RF-1.verdict.json" >/dev/null 2>&1; then
  pass "and the verdict record carries both lists, the same way it carries a finding and what was done about it"
else
  fail "the verdict record does not carry the copy audit"
  jq -c '{rewrite_verbatim, rewrite_dropped, rewrite_annotated}' "$rf/state-kept/RF-1.verdict.json" 2>/dev/null || true; fi

# The sectioned rewrite, through the real builder. Seven dense paragraphs about
# four surfaces is the problem this field exists to solve arriving in a new
# shape, so a card with its own sections keeps them - and what that has to be
# is real heading nodes in the fold, in the ticket's own order, with no fold
# inside the fold and nothing that fails the bar the field is held to.
rf_kept_fold=$(rf_fold_json "$rf/state-kept" RF-1)
if printf '%s' "$rf_kept_fold" | jq -e '
     [.content[] | select(.type == "heading") | .content[0].text]
       == ["App","Depot dashboard","Pushes","Rental agreement wording"]' >/dev/null 2>&1; then
  pass "a sectioned ticket's rewrite keeps its sections, as headings, in the ticket's own order"
else
  fail "the sections of a sectioned rewrite did not survive into the fold"
  printf '%s\n' "$rf_kept_fold" | jq -c '[.content[].type]' 2>/dev/null || true; fi
if printf '%s' "$rf_kept_fold" | jq -e '
     ((.content | length) >= 1)
     and ((([.content[].type]
             - ["paragraph","heading","bulletList","orderedList","codeBlock","rule"]) | length) == 0)
     and (([.content | .. | objects | select(.type == "expand")] | length) == 0)' >/dev/null 2>&1; then
  pass "and the fold still holds only nodes the schema allows there, with no expand inside an expand"
else
  fail "a sectioned rewrite broke the fold"; printf '%s\n' "$rf_kept_fold"; fi
rf_hits=$(printf '%s' "$rf_kept_fold" | jq -c '{content: [.]}' | adf_to_text | scan_for_both | sort -u | tr '\n' ' ')
if [ -z "$rf_hits" ]; then
  pass "and a sectioned rewrite quoting the product's own copy passes the same code and jargon scan as any other: a UI string is the product's words"
else
  fail "the sectioned rewrite is not in the product's words: $rf_hits"; fi

# The defect itself. One string restated, and the rewrite is offered with that
# string named on it - never withheld. Withholding was the first answer and it
# ended a real terminal round with no description on the card at all, which is
# the failure this section now guards from both sides: a settled round always
# offers one, and a rewrite that dropped a string never reaches a reporter
# unchallenged.
rf_run lost "$(rf_verdict "$rf_lost")" RF-1
rf_lost_body=$(comment_of "$rf/state-lost" RF-1)
rf_lost_fold=$(rf_fold_json "$rf/state-lost" RF-1)
if [ -n "$rf_lost_fold" ] \
   && printf '%s' "$rf_lost_fold" | jq -e '(. | tostring) | contains("unlock it by hand")' >/dev/null 2>&1; then
  pass "a settled card is offered a rewritten description even when a string went missing: there is always something to copy across"
else
  fail "a settled round offered no rewritten description at all"
  printf '%s\n' "$rf_lost_body"; fi
if printf '%s' "$rf_lost_fold" | jq -e '
     ([.content[] | select(.type == "bulletList")
        | .. | objects | select(.type == "text") | .text]
       | index("Unlock follow-on booking")) != null
     and ((.content[0].content[0].text) | contains("put these back before you copy it across"))' >/dev/null 2>&1; then
  pass "and the string it lost is named in the ticket's own spelling, above the text, so putting it back is a copy rather than a translation"
else
  fail "a rewrite that dropped one of the ticket's strings reached the reporter unchallenged"
  printf '%s\n' "$rf_lost_fold"; fi
# The title, because that is the half of a fold somebody reads before deciding
# to skip it - which was the whole objection withholding had been chosen on.
if printf '%s' "$rf_lost_fold" | jq -e '.attrs.title | contains("put back")' >/dev/null 2>&1 \
   && printf '%s' "$rf_kept_fold" | jq -e '(.attrs.title | contains("put back")) | not' >/dev/null 2>&1; then
  pass "and the fold says so in its own title, while a clean one still says only what it always said"
else
  fail "the caveat is only inside the fold, where a reader has already decided not to look"
  printf '%s' "$rf_lost_fold" | jq -c '.attrs' 2>/dev/null || true; fi
if [ "$(meta_field "$rf/state-lost" RF-1 rewrite_dropped_count)" = "1" ] \
   && [ "$(meta_field "$rf/state-lost" RF-1 rewrite_annotated)" = "yes" ] \
   && [ "$(meta_field "$rf/state-lost" RF-1 description_rewritten)" = "yes" ]; then
  pass "and it is reported rather than repaired: the rewrite is recorded as produced, the loss is counted, and what was done about it is its own figure"
else
  fail "an annotated rewrite left the wrong trace in state/"
  grep -E '^(rewrite_|description_rewritten)' "$rf/state-lost/RF-1.meta" 2>/dev/null || true; fi
if jq -e '.rewrite_dropped == ["Unlock follow-on booking"] and .rewrite_annotated == true
          and (.rewritten_description | contains("unlock it by hand"))' \
     "$rf/state-lost/RF-1.verdict.json" >/dev/null 2>&1; then
  pass "and the record names the string that went missing while keeping the refiner's own text exactly as it wrote it"
else
  fail "the record either lost the finding or rewrote the refiner's text"
  jq -c '{rewrite_dropped, rewrite_annotated}' "$rf/state-lost/RF-1.verdict.json" 2>/dev/null || true; fi
# The caveat is on a comment held to the reporter bar, and it names strings the
# extractor chose - so it is scanned like everything else there. It cannot leak
# an identifier for a reason the extractor already guarantees: a code-shaped
# candidate was refused before it could ever be reported as dropped.
rf_lost_hits=$(printf '%s' "$rf_lost_fold" | jq -c '{content: [.]}' | adf_to_text | scan_for_both | sort -u | tr '\n' ' ')
if [ -z "$rf_lost_hits" ]; then
  pass "and naming the lost wording keeps the fold inside the same code and jargon bar as any other comment"
else
  fail "the caveat put engineering detail on a reporter's comment: $rf_lost_hits"; fi
# Nothing else about the verdict moves. One paragraph is added; the card is
# still ready, still labelled, and still says what it is about.
if printf '%s' "$rf_lost_body" | grep -q 'Refinement: ready' \
   && printf '%s' "$rf_lost_body" | grep -qF 'needs its own banner' \
   && grep -q 'agent-ready' "$rf/state-lost/.would-write.log" 2>/dev/null; then
  pass "and nothing else on the card changes: the verdict, the label and the summary are exactly what they were"
else
  fail "annotating the fold changed the verdict this run reached"
  printf '%s\n' "$rf_lost_body"; fi

# The other settled verdict, because there are two and they must not disagree
# about this. A split-ready round is as settled as a card proposing a split will
# get, and the rewritten whole is what somebody carves the slices out of - so a
# lost string annotates it there too rather than leaving the person doing the
# carving with nothing.
rf_split=$(rf_verdict "$rf_lost" | jq -c '.verdict = "needs_input" | .questions = []
  | .split_into = [{title:"Follow-on booking banner",description:"The banner, the button and the status on the app side."},
                   {title:"Follow-on booking pushes",description:"Both pushes and their wording."}]')
rf_run split "$rf_split" RF-1
rf_split_fold=$(rf_fold_json "$rf/state-split" RF-1)
if [ -n "$rf_split_fold" ] \
   && printf '%s' "$rf_split_fold" | jq -e '.attrs.title | contains("put back")' >/dev/null 2>&1 \
   && [ "$(meta_field "$rf/state-split" RF-1 rewrite_annotated)" = "yes" ] \
   && [ "$(meta_field "$rf/state-split" RF-1 split_ready)" = "yes" ]; then
  pass "a split-ready round is offered its rewrite with the same caveat, because that is the text the slices get carved out of"
else
  fail "the two settled verdicts disagree about whether a rewrite is offered"
  comment_of "$rf/state-split" RF-1; fi

# A card with an answer still outstanding was never going to show the rewrite,
# so there is nothing to annotate - and the finding is recorded anyway, because a
# finding found and not acted on is a different fact from one never found.
rf_open=$(rf_verdict "$rf_lost" | jq -c '.verdict = "needs_input" | .questions = ["Which bookings should the banner be shown for?"]')
rf_run open "$rf_open" RF-1
if [ -z "$(rf_fold_json "$rf/state-open" RF-1)" ] \
   && [ "$(meta_field "$rf/state-open" RF-1 rewrite_dropped_count)" = "1" ] \
   && [ "$(meta_field "$rf/state-open" RF-1 rewrite_annotated)" = "no" ]; then
  pass "on an unsettled round the loss is still recorded, and nothing is reported as acted on, because nothing was going to be shown"
else
  fail "an unsettled round confused a rewrite it never renders with one it annotated"
  grep -E '^rewrite_' "$rf/state-open/RF-1.meta" 2>/dev/null || true; fi

# And the short single-surface card, which is the regression case: it behaves
# exactly as it did before either half of this existed. No copy to keep, plain
# paragraphs, and no heading manufactured for a card that has no sections.
rf_short_rewrite='On the depot dashboard a clerk cannot close a booking once its deposit has been released, because the control stays disabled.

It should be enabled, and closing the booking from it should finish the return the same way closing it earlier does.'
rf_run short "$(rf_verdict "$rf_short_rewrite" | jq -c '.one_line = "A released deposit leaves the close control disabled."')" RF-2
rf_short_fold=$(rf_fold_json "$rf/state-short" RF-2)
if [ -n "$rf_short_fold" ] \
   && [ "$(meta_field "$rf/state-short" RF-2 rewrite_verbatim_count)" = "0" ] \
   && [ "$(meta_field "$rf/state-short" RF-2 rewrite_annotated)" = "no" ]; then
  pass "a short ticket with no copy in it is offered its rewrite exactly as it always was"
else
  fail "a card this capability has nothing to say about was affected by it"
  grep -E '^rewrite_' "$rf/state-short/RF-2.meta" 2>/dev/null || true; fi
if printf '%s' "$rf_short_fold" | jq -e '
     ([.content[].type] | unique) == ["paragraph"]' >/dev/null 2>&1; then
  pass "and it is still plain paragraphs: nothing manufactures a section for a card that has none"
else
  fail "a short single-surface rewrite came back structured"
  printf '%s\n' "$rf_short_fold" | jq -c '[.content[].type]' 2>/dev/null || true; fi

rm -rf "$rf"

printf '\n== the rewritten description says everything the ticket said ==\n'
#
# The layer over the copy check. Copy fidelity is about characters: a label, a
# warning, a status wording. This is about content, and the same real run lost
# requirements the copy check structurally cannot see - a bullet asking for tabs
# between two records so that one can be switched to while the other stays read
# only is plain unquoted English, so it is never nominated as copy, and it went
# missing with nothing to say so.
#
# The bar leans the other way from the copy one on purpose. A rewrite is meant
# to reword, it legitimately merges two overlapping sentences, and it
# legitimately drops an ambiguity somebody has since answered - so a reworded
# survivor reported as lost is the failure that gets a check switched off, and
# half a statement's content words surviving anywhere in the rewrite is read as
# the statement surviving. That is asserted in both directions here: what must
# be reported, and the four shapes that must not be.
if grep -q "the ticket's whole content plus the clarifications" "$ORC_ROOT/prompts/refine.md"; then
  pass "the prompt asks for the ticket's whole content with the answers folded in, rather than a shorter restatement of it"
else
  fail "prompts/refine.md no longer defines the rewrite as a superset of the description, so the harness would be counting a loss the refiner was never told to avoid"; fi
if grep -q 'never shorter' "$ORC_ROOT/prompts/refine.md"; then
  pass "and it no longer instructs compression, which was half the defect"
else
  fail "prompts/refine.md still asks the rewrite to be as short as the ticket needs"; fi

# --- the unit, on the shapes a Jira description actually comes in
#
# Prose only, with no bullet anywhere in it: the unit is a sentence-sized
# fragment rather than a `- ` line, because a description may be bullets, may be
# prose, or may mix the two.
rc_prose='Clerks need to work on a follow-on booking from inside the booking it follows on from. Add tabs for the original booking and the follow-on so that a clerk can switch between them, and the original booking is view only. For a second follow-on, show the accessories from the first follow-on. Prefill the pickup depot, which a clerk may still change, and changing it changes the return window too. The clerk is sent a push once the follow-on booking has been paid for.'
rc_prose_full='A clerk works on a follow-on booking from inside the booking it follows on from. The booking opens with tabs for the original booking and the follow-on, so the clerk can switch between them; the original booking is view only. On a second follow-on the accessories from the first follow-on are shown. The pickup depot is prefilled and the clerk may change it, and changing it also changes the return window. The clerk is sent a push once the follow-on booking has been paid for.'
if [ -z "$(rewrite_uncovered "$rc_prose" "$rc_prose_full")" ]; then
  pass "a prose-only description with no bullet in it segments into statements and reads as wholly carried through"
else
  fail "a faithful rewrite of a prose-only description was reported as losing something"
  rewrite_uncovered "$rc_prose" "$rc_prose_full"; fi

# The defect. One requirement in plain unquoted English simply stops existing,
# and the finding names it in the ticket's own words - which is what a reader
# has to be shown, because the finding is that this sentence is gone.
rc_prose_lost='A clerk works on a follow-on booking from inside the booking it follows on from. On a second follow-on the accessories from the first follow-on are shown. The pickup depot is prefilled and the clerk may change it, and changing it also changes the return window. The clerk is sent a push once the follow-on booking has been paid for.'
rc_got=$(rewrite_uncovered "$rc_prose" "$rc_prose_lost")
if [ "$rc_got" = "Add tabs for the original booking and the follow-on so that a clerk can switch between them, and the original booking is view only" ]; then
  pass "a rewrite that drops a plain unquoted English requirement is reported, naming the statement it lost"
else
  fail "a dropped requirement was not reported, or the wrong statement was named"
  printf '   got: %s\n' "$rc_got"; fi

# Every statement reworded and none lost. This is the case that decides whether
# the check survives contact with a real rewrite, because rewording is what the
# field is for. The sentences are rebuilt, the verbs and the connectives all
# change, and the product's own nouns stay - which is not the fixture being
# written around the check but the prompt's own rule, since that field is held
# to the product's words on every verdict. It is also the named bound: a rewrite
# that renamed a clerk an agent and an original booking a parent booking would
# be reported here, and no folded word overlap can tell that apart from the
# statement having gone.
rc_prose_reworded='A clerk works on a follow-on booking from inside the booking it follows on from. Tabs sit at the top for the original booking and the follow-on, and the clerk moves between them; the original booking is view only. Where a follow-on is itself the second one, the accessories from the first follow-on are listed. The pickup depot arrives prefilled, the clerk may still change it, and changing it changes the return window with it. Once the follow-on booking has been paid for, a push goes to the clerk.'
if [ -z "$(rewrite_uncovered "$rc_prose" "$rc_prose_reworded")" ]; then
  pass "a rewrite that rewords every statement but keeps them all is clean, which is the case that decides whether this check survives a real rewrite"
else
  fail "a reworded rewrite was reported as a loss, which is the failure that gets a check switched off"
  rewrite_uncovered "$rc_prose" "$rc_prose_reworded"; fi

# Two overlapping statements merged into one that says both. A rewrite is
# allowed to do that, and a check that called it a loss would be counting good
# prose as a defect.
rc_overlap='The express return control stays disabled once the deposit is released. A depot clerk cannot close the booking while the express return control is disabled. A released deposit should not block the return.'
rc_merged='On the depot dashboard the express return control stays disabled once the deposit has been released, so a depot clerk cannot close the booking. A released deposit should not block the return.'
if [ -z "$(rewrite_uncovered "$rc_overlap" "$rc_merged")" ]; then
  pass "two overlapping statements merged into one sentence that says both is not reported as a loss"
else
  fail "a legitimate merge was reported as a dropped statement"
  rewrite_uncovered "$rc_overlap" "$rc_merged"; fi

# Bullets and prose in one description, which is the shape a real card is
# usually in - and a colon-terminated lead-in, which is a label for the list
# under it rather than a statement of its own.
rc_mixed='A depot clerk closes a booking from the express return control.

The following is missing today:
- the control stays disabled once the deposit is released
- the booking list shows no reason why it is disabled
- a clerk holding the depot manager role cannot override it either

Closing the booking should finish the return the same way it does before the deposit is released.'
rc_mixed_full='A depot clerk closes a booking from the express return control.

Today the control stays disabled once the deposit is released, the booking list shows no reason why it is disabled, and even a clerk holding the depot manager role cannot override it.

Closing the booking should finish the return the same way it does before the deposit is released.'
if [ -z "$(rewrite_uncovered "$rc_mixed" "$rc_mixed_full")" ]; then
  pass "a description mixing bullets with prose segments the same way, and its lead-in is a label rather than a statement to account for"
else
  fail "a mixed bullet-and-prose description was misread"
  rewrite_uncovered "$rc_mixed" "$rc_mixed_full"; fi
rc_mixed_lost=$(rewrite_uncovered "$rc_mixed" 'A depot clerk closes a booking from the express return control. Today the control stays disabled once the deposit is released. Closing the booking should finish the return the same way it does before the deposit is released.')
if [ "$(printf '%s\n' "$rc_mixed_lost" | grep -c .)" = "2" ] \
   && printf '%s' "$rc_mixed_lost" | grep -q 'shows no reason' \
   && printf '%s' "$rc_mixed_lost" | grep -q 'depot manager role'; then
  pass "and two dropped bullets out of three are reported while the one that survived is not"
else
  fail "the bullets a rewrite dropped were not reported as expected"
  printf '%s\n' "$rc_mixed_lost"; fi

# A heading and an identifier are not statements this can hold a rewrite to.
# A heading is a name for the section under it rather than a statement of its
# own, and the section's content is what reports a section that really did go
# missing; a fragment naming a path is dropped outright, because the rewritten
# description may not name one at all and a check demanding it be carried
# through would be demanding the field fail its own scan.
rc_structural='## App

See app/services/bookings/create_follow_up.rb for how a booking is created today.

## Depot dashboard'
if [ -z "$(rewrite_uncovered "$rc_structural" 'A booking that follows on from an earlier one is created the same way any other is.')" ]; then
  pass "a heading is not a statement and a fragment naming a path is never one either: the field may not name an identifier at all"
else
  fail "a heading or an identifier was held against a rewrite"
  rewrite_uncovered "$rc_structural" 'A booking that follows on from an earlier one is created the same way any other is.'; fi

# --- and end to end, through a real refinement
#
# Stand-in agents, for the reason every section of this kind uses one: no canned
# fixture verdict is authored against this, and one that was would be a fixture
# measuring whoever wrote it.
rc=$(mktemp -d)
mkdir -p "$rc/fixtures/issues" "$rc/fixtures/search"
printf '{"issues":[]}' > "$rc/fixtures/search/open-issues.json"
: > "$rc/projects.yml"
jq -n --arg d "$rc_mixed" \
  '{key:"RC-1", fields:{summary:"Express return on a released deposit", description:$d,
    labels:[], issuetype:{name:"Story"}, reporter:{accountId:"acct-1"},
    status:{name:"To Do"}, updated:"2026-01-01T00:00:00.000+0000",
    comment:{comments:[]}}}' > "$rc/fixtures/issues/RC-1.json"
rc_run() {
  local name="$1" rewrite="$2"
  mkdir -p "$rc/fakebin-$name"
  jq -nc --arg d "$rewrite" '{verdict:"ready",confidence:"high",
    one_line:"A released deposit leaves the express return control disabled.",
    subsystems:[],files:[],locality_basis:"none",terms_resolved:[],terms_unresolved:[],
    questions:[],duplicate_of:null,split_into:[],
    acceptance_criteria:["The control is enabled once the deposit is released."],
    rewritten_description:$d,not_verified:"nothing",notes:""}' > "$rc/fakebin-$name/verdict.json"
  cat > "$rc/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$rc/fakebin-$name/verdict.json"
SH
  chmod +x "$rc/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$rc/projects.yml" ORC_STATE_DIR="$rc/state-$name" ORC_CLONE_DIR="$rc/clones" \
      ORC_FIXTURE_DIR="$rc/fixtures" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$rc/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force RC-1 >/dev/null 2>&1
}
rc_fold_json() {
  comment_json_of "$1" RC-1 \
    | jq -c '[.body.content[]? | select(.type == "expand")
              | select((. | tostring) | contains("The ticket has not been changed"))][0] // empty'
}

rc_run full "$rc_mixed_full"
if [ "$(meta_field "$rc/state-full" RC-1 rewrite_uncovered_count)" = "0" ] \
   && jq -e '.rewrite_uncovered == []' "$rc/state-full/RC-1.verdict.json" >/dev/null 2>&1; then
  pass "a rewrite that carries every statement through records nothing uncovered, in state/ and on the verdict alike"
else
  fail "a complete rewrite was recorded as having lost something"
  grep -E '^rewrite_' "$rc/state-full/RC-1.meta" 2>/dev/null || true; fi

rc_run lossy 'A depot clerk closes a booking from the express return control. Today the control stays disabled once the deposit is released. Closing the booking should finish the return the same way it does before the deposit is released.'
if [ "$(meta_field "$rc/state-lossy" RC-1 rewrite_uncovered_count)" = "2" ]; then
  pass "and a rewrite that summarised the ticket instead of restating it is counted, beside the copy figures rather than instead of them"
else
  fail "a summarising rewrite was not counted in state/"
  grep -E '^rewrite_' "$rc/state-lossy/RC-1.meta" 2>/dev/null || true; fi
if jq -e '(.rewrite_uncovered | length) == 2
          and ((.rewrite_uncovered | join(" ")) | contains("shows no reason"))
          and (.rewrite_dropped == [])' \
     "$rc/state-lossy/RC-1.verdict.json" >/dev/null 2>&1; then
  pass "and the verdict record names the statements themselves, which is what a report reads and what a later threshold would be set from"
else
  fail "the verdict record does not carry the uncovered statements"
  jq -c '{rewrite_uncovered, rewrite_dropped}' "$rc/state-lossy/RC-1.verdict.json" 2>/dev/null || true; fi
# The consequence, which is the decision this capability had to make: recorded
# and nothing else. The copy check annotates the fold because "these characters
# are gone" is exact and pasting the rewrite would take them with it; this bar is
# a proxy on prose the field is meant to reword, and a caveat printed over a
# reworded survivor is the failure that switches a feature off - so the fold is
# offered unannotated, the verdict stands and no question is added.
rc_lossy_body=$(comment_of "$rc/state-lossy" RC-1)
if [ -n "$(rc_fold_json "$rc/state-lossy")" ] \
   && [ "$(meta_field "$rc/state-lossy" RC-1 rewrite_annotated)" = "no" ] \
   && printf '%s' "$rc_lossy_body" | grep -q 'Refinement: ready' \
   && ! printf '%s' "$rc_lossy_body" | grep -qF 'shows no reason'; then
  pass "an uncovered statement is recorded and nothing else: the fold is still offered, the verdict stands, and the finding is not put on the comment"
else
  fail "a content-coverage finding changed the comment or the verdict"
  printf '%s\n' "$rc_lossy_body"; fi
if ! grep -q 'rewrite_uncovered' "$ORC_ROOT/bin/orc-refine.sh" \
   || grep -n 'rewrite_uncovered' "$ORC_ROOT/bin/orc-refine.sh" | grep -q 'annotated=true'; then
  fail "the coverage finding reaches the comment, which is not the consequence this was given"
else
  pass "and nothing anywhere lets it annotate or withhold the fold, which is the one lever a fuzzy bar may not reach for"; fi
# And the shape the two were first given cannot come back: nothing withholds the
# fold at all, so no combination of an exact finding and a fuzzy one composes to
# a settled card carrying neither.
if ! grep -n 'rewrite_withheld' "$ORC_ROOT/bin/orc-refine.sh" | code_only | grep -q .; then
  pass "and no path in a refinement withholds a rewritten description, so a settled card always has one to offer"
else
  fail "a rewritten description is still withheld somewhere, which is the failure this replaced"
  grep -n 'rewrite_withheld' "$ORC_ROOT/bin/orc-refine.sh" | code_only; fi

# A description of one or two statements has no "rest of the ticket" to read a
# subject out of, so the ubiquitous-word rule stands down there rather than
# reading every word of a one-sentence card as its subject and judging nothing.
rc_two='A depot clerk cannot close a booking once its deposit is released. The booking list shows no reason why the control is disabled.'
if [ -z "$(rewrite_uncovered "$rc_two" 'A depot clerk cannot close a booking once its deposit has been released, and the booking list shows no reason why the control is disabled.')" ] \
   && [ "$(rewrite_uncovered "$rc_two" 'A depot clerk cannot close a booking once its deposit has been released.')" \
        = "The booking list shows no reason why the control is disabled" ]; then
  pass "a two-statement card is still judged: below three statements nothing is read as the ticket's subject, so a short card does not go unchecked"
else
  fail "a short description was either unjudged or misjudged"
  rewrite_uncovered "$rc_two" 'A depot clerk cannot close a booking once its deposit has been released.'; fi

rm -rf "$rc"

printf '\n== a round about to be terminal is read again, adversarially ==\n'
# The first pass enumerates what it still wants to know, and a sentence with no
# gap in it passes that question cleanly while parsing two ways. Four independent
# single-round samples of one real card asked 1, 4, 4 and 8 questions, and the
# one-question sample asserted a meaning the ticket never gave. So a round about
# to become terminal is read a second time under a different question - what in
# this text admits two readings that would produce different software - and two
# reads disagreeing about whether anything is left to ask is itself the finding.
#
# Stand-in agents again, and here they have to answer two different calls. They
# tell them apart by what they were asked, which also asserts that the second
# call really carries the second prompt rather than a copy of the first.
if grep -q '"misreadings"' "$ORC_ROOT/prompts/misread.md"; then
  pass "the second prompt asks for misreadings, so there is something for the second call to return"
else
  fail "prompts/misread.md does not ask for misreadings; the second call would return nothing usable"; fi

# The gate, at the unit it is written at.
mis_ready='{"verdict":"ready","questions":[],"split_into":[]}'
mis_open='{"verdict":"needs_input","questions":["Which surface?"],"split_into":[]}'
mis_term='{"verdict":"needs_input","questions":[],"split_into":[{"title":"a","description":"b"}]}'
mis_dup='{"verdict":"duplicate","questions":[],"split_into":[],"duplicate_of":"ORC-102"}'
if verdict_is_terminal_shape "$mis_ready" && verdict_is_terminal_shape "$mis_term"; then
  pass "a ready verdict and the split-ready combination are both rounds about to become terminal"
else
  fail "a round about to become terminal was not recognised as one, so it would never be read again"; fi
if verdict_is_terminal_shape "$mis_open" || verdict_is_terminal_shape "$mis_dup"; then
  fail "a round with an open question, or a card being closed, would be read a second time for nothing"
else
  pass "a round with a question still open, and a duplicate, are left alone: another round is coming anyway"; fi
if [ "$(misread_questions '{"misreadings":[{"question":"Which one?"},{"question":""},{"quote":"x"}]}' | grep -c .)" = "1" ]; then
  pass "an entry with no question in it renders no bullet, and the rest are taken as the refiner wrote them"
else
  fail "the second read's questions are not read out of its findings as written"; fi

# The two calls, and a stand-in that answers each of them differently.
mis_run() {
  local name="$1" first="$2" second="$3" k="${4:-ORC-101}" fail_second="${5:-0}"
  mkdir -p "$w/fakebin-$name"
  printf '%s' "$first"  > "$w/fakebin-$name/first.json"
  printf '%s' "$second" > "$w/fakebin-$name/second.json"
  printf '%s' "$fail_second" > "$w/fakebin-$name/fail-second"
  cat > "$w/fakebin-$name/claude" <<SH
#!/bin/sh
in=\$(cat)
if printf '%s' "\$in" | grep -q 'Second pass: the adversarial re-read'; then
  echo second >> "$w/fakebin-$name/which.log"
  printf '%s' "\$in" > "$w/fakebin-$name/second-input.txt"
  [ "\$(cat "$w/fakebin-$name/fail-second")" = "1" ] && { echo "the agent fell over" >&2; exit 2; }
  jq -Rsc '{result: .}' < "$w/fakebin-$name/second.json"
else
  echo first >> "$w/fakebin-$name/which.log"
  jq -Rsc '{result: .}' < "$w/fakebin-$name/first.json"
fi
SH
  chmod +x "$w/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$w/refine.yml" ORC_STATE_DIR="$w/s-$name" ORC_CLONE_DIR="$w/clones" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$w/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$k" > "$w/fakebin-$name/run.log" 2>&1
}
mis_seconds() { grep -c '^second$' "$w/fakebin-$1/which.log" 2>/dev/null | tr -d ' '; }

# Carries ORC-101's own two exact strings, for the reason desc_text above does:
# a rewrite that dropped one of them would be withheld, and the assertions below
# are about what the second read withholds rather than about that.
mis_desc='A doctor cannot open a follow-up whose authorisation has already been claimed: the "Open follow-up" control stays disabled and its tooltip reads "waiting for authorisation".'
mis_first_ready=$(jq -nc --arg d "$mis_desc" '{verdict:"ready",confidence:"high",
  one_line:"The express return stays disabled after the deposit is released.",
  subsystems:["subsystems/api"],files:["app/services/returns.rb"],locality_basis:"search",
  terms_resolved:[],terms_unresolved:[],questions:[],duplicate_of:null,split_into:[],
  acceptance_criteria:["A clerk can close a rental whose deposit is released."],
  rewritten_description:$d,not_verified:"I could not read the customer app code in app/mobile.",
  notes:"The dashboard reads the wrong field from the API response."}')
mis_agree='{"misreadings":[]}'
mis_finding='{"misreadings":[{"quote":"only for released rentals, extended manually, or weekend rentals with an on-site check","reading_taken":"one group - released rentals that were also extended by hand","reading_missed":"three groups, any one of which qualifies","different_software":"the second reading shows the control on every released rental","question":"Should the express return show for every released rental, for any rental extended by hand, and for weekend rentals with an on-site check - or only for released rentals that were also extended by hand?"}]}'

# The gate again, this time by counting calls rather than by reading a predicate.
mis_first_open=$(printf '%s' "$mis_first_ready" | jq -c '.verdict = "needs_input"
  | .questions = ["Which rentals should the express return be offered for?"]
  | .rewritten_description = null')
mis_run gateopen "$mis_first_open" "$mis_finding"
if [ "$(mis_seconds gateopen)" = "0" ]; then
  pass "a round with a question still open is never read a second time: it is going back to the reporter anyway"
else
  fail "an ordinary needs_input round paid for a second agent call it had no use for"; fi
mis_first_dup=$(printf '%s' "$mis_first_ready" | jq -c '.verdict = "duplicate" | .duplicate_of = "ORC-102" | .rewritten_description = null')
mis_run gatedup "$mis_first_dup" "$mis_finding"
if [ "$(mis_seconds gatedup)" = "0" ]; then
  pass "and a card being closed as a duplicate is not read again either"
else
  fail "a duplicate paid for a second agent call about a card nobody will open"; fi

# The two reads agreeing. This is the case that decides whether the pass is worth
# keeping, so what it must prove is that it costs a call and changes nothing.
mis_run agree "$mis_first_ready" "$mis_agree"
if [ "$(mis_seconds agree)" = "1" ]; then
  pass "a round about to become terminal is read a second time, exactly once"
else
  fail "the second read did not happen on a round that was about to become terminal"; fi
if grep -q 'Second pass: the adversarial re-read' "$w/fakebin-agree/second-input.txt" \
   && grep -q 'What the first read concluded' "$w/fakebin-agree/second-input.txt" \
   && grep -q 'The express return stays disabled after the deposit is released' "$w/fakebin-agree/second-input.txt"; then
  pass "and it is handed the first read's own conclusion, which is the reading it is trying to find an alternative to"
else
  fail "the second call did not carry the first read's conclusion, so it is a second guess rather than a re-read"; fi
if grep -q 'Ticket under refinement' "$w/fakebin-agree/second-input.txt" \
   && grep -q 'The question bar' "$w/fakebin-agree/second-input.txt"; then
  pass "and the same ticket and the same bar, so what differs between the two answers is the question each was asked"
else
  fail "the second call was given a different context from the first"; fi
mis_agree_body=$(comment_of "$w/s-agree" ORC-101)
if [ "$(meta_field "$w/s-agree" ORC-101 verdict)" = "ready" ] \
   && [ "$(meta_field "$w/s-agree" ORC-101 misread_ran)" = "yes" ] \
   && [ "$(meta_field "$w/s-agree" ORC-101 misread_disagreed)" = "no" ] \
   && [ "$(meta_field "$w/s-agree" ORC-101 misread_question_count)" = "0" ]; then
  pass "two reads that agree leave the verdict alone, and the run records that the second one ran and found nothing"
else
  fail "an agreeing second read changed the round, or left no record of having run"
  grep -E '^(verdict|misread)' "$w/s-agree/ORC-101.meta" 2>/dev/null || true; fi
if printf '%s' "$mis_agree_body" | grep -q 'Probable files' \
   && printf '%s' "$mis_agree_body" | grep -q 'Refinement: ready'; then
  pass "and the ready comment is exactly the comment it would have been"
else
  fail "an agreeing second read changed the comment"; printf '%s\n' "$mis_agree_body"; fi
if jq -e '.misread.ran == true and .misread.disagreed == false and (.misread.findings | length) == 0
          and .misread.status == "answered" and (.misread.prompt_version | startswith("misread-"))
          and .verdict == "ready" and .verdict_first_read == "ready"' \
     "$w/s-agree/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the verdict record says which prompt read it a second time and what that read found"
else
  fail "the verdict record does not carry what the second read did"
  jq -c '{verdict, verdict_first_read, misread}' "$w/s-agree/ORC-101.verdict.json" 2>/dev/null || true; fi

# The two reads disagreeing, on a card the first one called ready. Nothing picks
# a winner: the question is asked and the cautious side is taken.
mis_run flip "$mis_first_ready" "$mis_finding"
mis_flip_body=$(comment_of "$w/s-flip" ORC-101)
if [ "$(meta_field "$w/s-flip" ORC-101 verdict)" = "needs_input" ] \
   && [ "$(meta_field "$w/s-flip" ORC-101 verdict_first_read)" = "ready" ] \
   && [ "$(meta_field "$w/s-flip" ORC-101 misread_disagreed)" = "yes" ]; then
  pass "a card the first read called ready goes back to the reporter when the second finds a reading that would build something else"
else
  fail "a disagreement between the two reads was resolved by believing the first one"
  grep -E '^(verdict|misread)' "$w/s-flip/ORC-101.meta" 2>/dev/null || true; fi
if printf '%s' "$mis_flip_body" | grep -qF 'Should the express return show for every released rental'; then
  pass "and the question the second read wrote is on the ticket, in its own words"
else
  fail "the second read's finding never reached the ticket"; printf '%s\n' "$mis_flip_body"; fi
if printf '%s' "$mis_flip_body" | grep -q 'Refinement: this needs a little more' \
   && ! printf '%s' "$mis_flip_body" | grep -q 'Refinement: ready'; then
  pass "and the comment is a needs_input comment, not a ready one with a question stapled to it"
else
  fail "the comment still reads as a ready verdict"; printf '%s\n' "$mis_flip_body"; fi
if printf '%s' "$mis_flip_body" | grep -qE 'Probable files|Subsystems|Reasoned against'; then
  fail "the engineering fold stayed on a comment that is now addressed to the reporter"
else
  pass "and the engineering fold goes with the verdict, because its audience went with it"; fi
if grep -qF "\"$LABEL_NEEDS_INPUT\"" "$w/s-flip/.would-write.log" 2>/dev/null \
   && ! grep -qF "\"$LABEL_READY\"" "$w/s-flip/.would-write.log"; then
  pass "the label follows the acted verdict rather than the first read's, and the ready one is never applied"
else
  fail "the ticket was labelled for a verdict this run did not act on"
  grep 'WOULD' "$w/s-flip/.would-write.log" 2>/dev/null || true; fi
if grep -qF "\"$LABEL_READY\"" "$w/s-agree/.would-write.log" 2>/dev/null; then
  pass "and the card the second read agreed with is still labelled ready, so the check above is not simply always quiet"
else
  fail "an agreeing second read cost a ready card its label"; fi
if grep -q '/assignee' "$w/s-flip/.would-write.log" 2>/dev/null; then
  pass "and the card is handed back to the person who filed it, the way every other needs_input card is"
else
  fail "a card sent back by the second read was never assigned to its reporter"; fi
# The un-terminate path, which is the interaction with everything that shipped
# beside this: an open question withholds the rewritten description, and it has
# to withhold this one too.
if [ -z "$(desc_fold_json "$w/s-flip")" ]; then
  pass "and a card with a reading nobody has confirmed carries no settled description"
else
  fail "a card whose reading is in question was handed a description written around one of the two readings"; fi
if [ -n "$(desc_fold_json "$w/s-agree")" ]; then
  pass "while the card the second read agreed with still carries it, so the withholding is the disagreement and not the pass"
else
  fail "the second read withheld the rewritten description even when it found nothing"; fi
# The prose the first read wrote under the one verdict that lets it name code.
if printf '%s' "$mis_flip_body" | grep -q 'app/mobile' \
   || printf '%s' "$mis_flip_body" | grep -q 'the wrong field from the API response'; then
  fail "prose written for an implementing agent was reprinted on a comment addressed to the reporter"
  printf '%s\n' "$mis_flip_body"
else
  pass "and the notes and the caveat the first read wrote for an implementing agent are withheld, not re-addressed"; fi
if printf '%s' "$mis_flip_body" | scan_for_both | grep -q .; then
  fail "the comment a disagreement produces does not meet the bar the rest of them are held to"
  printf '%s' "$mis_flip_body" | scan_for_both | sort -u
else
  pass "the whole comment passes the same code and jargon scan as every other comment a reporter reads"; fi
if jq -e '.verdict == "needs_input" and .verdict_first_read == "ready"
          and .misread.disagreed == true and (.misread.findings | length) == 1
          and (.misread.findings[0].reading_missed | length) > 0' \
     "$w/s-flip/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the record carries both verdicts and the finding, so nothing about the disagreement is lost"
else
  fail "the record does not carry the disagreement"
  jq -c '{verdict, verdict_first_read, misread}' "$w/s-flip/ORC-101.verdict.json" 2>/dev/null || true; fi

# The same disagreement on the other terminal shape. A split drawn around a
# sentence nobody has said which way to read is a split drawn around the wrong
# scope, and the proposal is the one thing on the comment a reporter is expected
# to act on rather than answer.
mis_first_split=$(printf '%s' "$mis_first_ready" | jq -c '.verdict = "needs_input" | .questions = []
  | .split_into = [{title:"Close a released rental",description:"The clerk-facing half."},
                   {title:"Label the export column",description:"The export half."}]')
mis_run splitagree "$mis_first_split" "$mis_agree"
if comment_of "$w/s-splitagree" ORC-101 | grep -q 'nothing left to ask, only the split remains'; then
  pass "a split-ready card the second read agreed with still reaches the terminal state"
else
  fail "the second read stopped a card reaching the terminal state without finding anything"
  comment_of "$w/s-splitagree" ORC-101; fi
mis_run splitflip "$mis_first_split" "$mis_finding"
mis_sf_body=$(comment_of "$w/s-splitflip" ORC-101)
if [ "$(mis_seconds splitflip)" = "1" ]; then
  pass "a split-ready round is read a second time too"
else
  fail "the split-ready terminal shape was never read again"; fi
if [ "$(meta_field "$w/s-splitflip" ORC-101 split_ready)" = "no" ]; then
  pass "and a misreading found there un-terminates the round"
else
  fail "a card with a reading nobody confirmed was still announced as having nothing left to ask"; fi
if printf '%s' "$mis_sf_body" | grep -q 'nothing left to ask, only the split remains'; then
  fail "the terminal heading survived a disagreement"; printf '%s\n' "$mis_sf_body"; fi
if printf '%s' "$mis_sf_body" | grep -qF 'Close a released rental'; then
  fail "the split proposal was shown on a card whose scope is in question"
else
  pass "and the split proposal is withheld, because it would be drawn around a reading nobody has confirmed"; fi
if printf '%s' "$mis_sf_body" | grep -qF 'Should the express return show for every released rental'; then
  pass "and the question is what the comment asks instead"
else
  fail "the finding never reached the ticket"; printf '%s\n' "$mis_sf_body"; fi

# A round the harness had already un-terminated. It is going back to the reporter
# whatever the second read says, so it does not earn one. Unresolved rather
# than resolved this round: a term this round both resolved and promoted in
# the same breath is a different bug, covered on its own where terms_off_to_ask
# is tested, and using it here would test that instead of this gate.
mis_first_offterm=$(printf '%s' "$mis_first_split" | jq -c '.terms_unresolved = ["tier two"]')
mis_run gateoff "$mis_first_offterm" "$mis_finding"
if [ "$(mis_seconds gateoff)" = "0" ]; then
  pass "a round a promoted term has already un-terminated does not pay for a second read on top"
else
  fail "a card already going back to the reporter was read a second time for nothing"; fi
if jq -e '.misread.status | contains("already un-terminated")' "$w/s-gateoff/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the record says which of the reasons it was, because a pass that ran and agreed is a third thing again"
else
  fail "the record does not say why the second read was skipped"
  jq -c '.misread' "$w/s-gateoff/ORC-101.verdict.json" 2>/dev/null || true; fi

# A second read that does not answer is an error, never a disagreement and never
# an agreement - the same rule golden/run.sh follows for a killed call. The first
# read is still a verdict, and a comment handing the card back with no question
# on it would be the worst of the three outcomes.
mis_run broken "$mis_first_ready" "$mis_agree" ORC-101 1
if [ "$(meta_field "$w/s-broken" ORC-101 verdict)" = "ready" ] \
   && [ "$(meta_field "$w/s-broken" ORC-101 misread_disagreed)" = "no" ] \
   && [ "$(meta_field "$w/s-broken" ORC-101 misread_ran)" = "yes" ]; then
  pass "a second read that fell over leaves the round as the first one judged it"
else
  fail "a failed second read was counted as a verdict"
  grep -E '^(verdict|misread)' "$w/s-broken/ORC-101.meta" 2>/dev/null || true; fi
if jq -e '.misread.status | startswith("error")' "$w/s-broken/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and it is recorded as an error, which is a different fact from having agreed"
else
  fail "a second read that never answered is recorded as though it had"
  jq -c '.misread' "$w/s-broken/ORC-101.verdict.json" 2>/dev/null || true; fi

# The two promotions still compose with it. A flipped card is a needs_input card,
# so a term the ticket does not say is asked about on it the same way it would be
# on any other - and a term the second read already named is not asked twice.
# Unresolved rather than resolved this round, for the same reason as above.
mis_first_tier=$(printf '%s' "$mis_first_ready" | jq -c '.terms_unresolved = ["tier two"]')
mis_run fliptier "$mis_first_tier" "$mis_finding"
if comment_of "$w/s-fliptier" ORC-101 | grep -qF 'read as being about "tier two"'; then
  pass "a card the second read sent back is a needs_input card, so what a needs_input card asks is asked on it"
else
  fail "the promotions stopped working on a card the second read un-terminated"
  comment_of "$w/s-fliptier" ORC-101; fi

# Fixture mode is how this is demonstrated at all, and it stays exactly as it
# was: a canned second opinion is a canned agreement, which measures nothing.
if grep -q 'not run: only the real refiner has a second read' "$w/s3-ORC-102/ORC-102.verdict.json" 2>/dev/null \
   || jq -e '.misread.ran == false' "$w/s3-ORC-102/ORC-102.verdict.json" >/dev/null 2>&1; then
  pass "replay makes no second call, so fixture mode still runs with no network and no credentials"
else
  fail "fixture mode reached for an agent it does not have"
  jq -c '.misread' "$w/s3-ORC-102/ORC-102.verdict.json" 2>/dev/null || true; fi

# No new write, and no write of any kind that a refinement is not already allowed
# to make. The paths are listed rather than denied, so a fifth one added later
# fails here instead of going past.
mis_writes=""
for st in s-agree s-flip s-splitflip s-broken s-fliptier; do
  [ -f "$w/$st/.would-write.log" ] || continue
  grep -oE 'WOULD (PUT|POST|DELETE) +[^ ]+' "$w/$st/.would-write.log" \
    | grep -vE '(/issue/[A-Z]+-[0-9]+(/comment|/assignee)?|/issueLink)$' | grep -q . \
    && mis_writes="$mis_writes $st"
  grep -oE '"description"[[:space:]]*:' "$w/$st/.would-write.log" | grep -q . \
    && mis_writes="$mis_writes $st(description)"
done
unset st
if [ -z "$mis_writes" ]; then
  pass "and a second read adds no write: the comment, the label and the assignee are still all a refinement touches"
else
  fail "the second read wrote something a refinement has no business writing:$mis_writes"; fi

printf '\n== a needs_input round always has something to act on ==\n'
# Round 3 of a live six-round run on a real epic looked like a missed terminal
# state: verdict needs_input, questions empty, six slices proposed, a rewritten
# description present - the exact shape verdict_split_ready names - and
# split_ready recorded as false. It was not a missed terminal state. The same
# record said misread.disagreed with one finding and already_settled_count 0, so
# the adversarial re-read had found a real second reading of the eligibility
# sentence, and a standing question un-terminates the round by design. What made
# it read as a stall is that nothing on the verdict record said what the ticket
# was actually asked: `questions` is the refiner's own array, three of the four
# sources are promoted by the harness, and a report reading the record therefore
# saw zero questions on a round that asked one.
#
# So the record now carries the list the comment carries, and the one shape that
# really cannot advance the loop is named rather than posted.
r3_slices='[{"title":"Open a follow-up from a finished rental","description":"The control and the eligibility rule, which ships and reverts on its own."},
{"title":"Carry the deposit across","description":"The deposit the follow-up inherits."},
{"title":"The two new packages","description":"The packages a follow-up can be booked on."},
{"title":"Warn before the check","description":"The warning a clerk sees before starting the check."},
{"title":"Count follow-ups in the monthly figures","description":"The reports that group rentals by kind."},
{"title":"The clerk letter wording","description":"The wording the letter uses for a follow-up."}]'
r3_first=$(printf '%s' "$mis_first_ready" \
  | jq -c --argjson s "$r3_slices" '.verdict = "needs_input" | .confidence = "medium" | .split_into = $s')

# The disagreeing case, which is what actually happened. The round is correctly
# not terminal, and the assertion the original diagnosis could not make is that
# the question reaches the reporter.
mis_run r3open "$r3_first" "$mis_finding"
r3_open_body=$(comment_of "$w/s-r3open" ORC-101)
if [ "$(meta_field "$w/s-r3open" ORC-101 split_ready)" = "no" ] \
   && [ "$(meta_field "$w/s-r3open" ORC-101 misread_disagreed)" = "yes" ] \
   && [ "$(meta_field "$w/s-r3open" ORC-101 question_count)" = "1" ]; then
  pass "a terminal-shaped round the second read disagreed with is not terminal, and it asks exactly the question the second read wrote"
else
  fail "a second-read disagreement either failed to un-terminate the round or asked nothing"
  grep -E '^(verdict|split_ready|question_count|misread)' "$w/s-r3open/ORC-101.meta" 2>/dev/null || true; fi
if printf '%s' "$r3_open_body" | grep -q 'Should the express return show for every released rental'; then
  pass "and that question is on the comment the reporter reads, so the round is not a stall"
else
  fail "the round was treated as still open while the reporter was asked nothing"
  printf '%s\n' "$r3_open_body"; fi
if printf '%s' "$r3_open_body" | grep -q 'only the split remains' \
   || printf '%s' "$r3_open_body" | grep -q 'Every question here is answered'; then
  fail "a round with a standing question announced itself as terminal"
else
  pass "and the split proposal is still withheld while that question stands, as it was before"; fi
if jq -e '.round_stuck == false and (.questions | length) == 0 and (.questions_asked | length) == 1' \
     "$w/s-r3open/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "the verdict record says what the ticket was asked, so an empty questions array is no longer read as an empty comment"
else
  fail "the verdict record still cannot tell a promoted question from a round that asked nothing"
  jq -c '{questions, questions_asked, round_stuck, split_ready}' "$w/s-r3open/ORC-101.verdict.json" 2>/dev/null || true; fi

# The same first read with an agreeing second read: nothing un-terminates it, so
# the shape is recognised as terminal exactly as it always was.
mis_run r3term "$r3_first" "$mis_agree"
r3_term_body=$(comment_of "$w/s-r3term" ORC-101)
if [ "$(meta_field "$w/s-r3term" ORC-101 split_ready)" = "yes" ] \
   && printf '%s' "$r3_term_body" | grep -q 'nothing left to ask, only the split remains' \
   && printf '%s' "$r3_term_body" | grep -q 'Open a follow-up from a finished rental'; then
  pass "with nothing standing against it, that same shape is terminal and its six slices are proposed"
else
  fail "a terminal-shaped round nothing un-terminated was not recognised as terminal"
  printf '%s\n' "$r3_term_body"; fi
if jq -e '.round_stuck == false and (.questions_asked | length) == 0' \
     "$w/s-r3term/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and a terminal round asking nothing is not a stuck round: there is a split to run"
else
  fail "the terminal state was recorded as a stall"
  jq -c '{questions_asked, round_stuck, split_ready}' "$w/s-r3term/ORC-101.verdict.json" 2>/dev/null || true; fi

# The predicate itself, at the three points that decide it. Read directly, the
# way verdict_split_ready and integration_gaps are, because bin/orc-refine.sh is
# not the only thing that will ever want to ask.
if round_is_stuck needs_input false "" \
   && ! round_is_stuck needs_input true "" \
   && ! round_is_stuck needs_input false "Which rentals is this for?" \
   && ! round_is_stuck ready false "" \
   && ! round_is_stuck duplicate false ""; then
  pass "the stall is only a needs_input round that is neither terminal nor asking anything"
else
  fail "round_is_stuck does not name the one shape it exists to name"; fi
if round_is_stuck needs_input false '
'; then
  pass "and a question list that is nothing but a newline is still asking nothing"
else
  fail "a blank question list was read as a question"; fi

# The stall itself. Nothing about it is postable: there is no question for the
# reporter and no split for them to run, so the label would say the card is
# waiting on them while the comment asks them nothing.
mis_stuck=$(printf '%s' "$mis_first_ready" | jq -c '.verdict = "needs_input"
  | .questions = [] | .split_into = [] | .rewritten_description = null')
mis_run stuck "$mis_stuck" "$mis_agree"; mis_stuck_rc=$?
if [ "$(mis_seconds stuck)" = "0" ]; then
  pass "a round with nothing to ask and nothing to split is not terminal-shaped, so it does not pay for a second read either"
else
  fail "a stalled round bought an agent call it had no use for"; fi
if [ ! -f "$w/s-stuck/.would-write.log" ] || ! grep -q 'WOULD ' "$w/s-stuck/.would-write.log"; then
  pass "and nothing is written to the ticket: no comment asking nothing, no label, no hand-back to a reporter who has nothing to answer"
else
  fail "a comment that could not be acted on was still posted"
  grep -oE 'WOULD [A-Z]+ +[^ ]+' "$w/s-stuck/.would-write.log" | sort -u; fi
if [ "$mis_stuck_rc" != "0" ] \
   && grep -q 'nothing to ask and nothing to split' "$w/fakebin-stuck/run.log"; then
  pass "it is loud instead: the run fails and names the cause, which is what bin/orc-daemon.sh counts and reports"
else
  fail "a stalled round was silent, so nothing would ever tell an operator the loop had stopped moving"
  tail -3 "$w/fakebin-stuck/run.log" 2>/dev/null || true; fi
if jq -e '.round_stuck == true and .verdict == "needs_input" and (.questions_asked | length) == 0' \
     "$w/s-stuck/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the finding is on the verdict record, the way integration_gaps and contradiction_gaps are"
else
  fail "a stalled round left no record of having happened"
  jq -c '{verdict, questions_asked, round_stuck}' "$w/s-stuck/ORC-101.verdict.json" 2>/dev/null || true; fi
if [ ! -f "$w/s-stuck/ORC-101.meta" ]; then
  pass "nothing records it as refined, so the next pass judges the ticket again rather than treating a round that produced nothing as a verdict"
else
  fail "a round that posted nothing was recorded as a refinement"
  cat "$w/s-stuck/ORC-101.meta"; fi

# Every case that already worked still works, and every one of the four question
# sources reaches the record - so nothing reading it has to guess again.
if [ "$(meta_field "$w/s-r3open" ORC-101 round_stuck)" = "no" ] \
   && [ "$(meta_field "$w/s-r3term" ORC-101 round_stuck)" = "no" ] \
   && [ "$(meta_field "$w/s-splitready" ORC-101 round_stuck)" = "no" ] \
   && [ "$(meta_field "$w/s-offask" ORC-101 round_stuck)" = "no" ] \
   && [ "$(meta_field "$w/s-agree" ORC-101 round_stuck)" = "no" ] \
   && [ "$(meta_field "$w/s1" ORC-101 round_stuck)" = "no" ]; then
  pass "no round that already had something to act on is called a stall, ready and terminal ones included"
else
  fail "the stall check fired on a round that was asking or proposing something"; fi
if jq -e '(.questions_asked | length) == 2
          and (.questions_asked[0] | contains("Which starting state"))
          and (.questions_asked[1] | contains("tier two"))' \
     "$w/s-offask/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "a promoted term is on the asked list beside the refiner's own question, in the order the comment carries them"
else
  fail "the record does not name a promoted question the comment asked"
  jq -c '.questions_asked' "$w/s-offask/ORC-101.verdict.json" 2>/dev/null || true; fi
if jq -e '(.questions_asked | length) == 0 and .round_stuck == false' \
     "$w/s-splitready/ORC-101.verdict.json" >/dev/null 2>&1; then
  pass "and the terminal-state fixture that predates all of this reads the same through the new fields"
else
  fail "the existing terminal-state case changed shape"
  jq -c '{questions_asked, round_stuck}' "$w/s-splitready/ORC-101.verdict.json" 2>/dev/null || true; fi
# The same listed-rather-than-denied write check the second read gets, over the
# rounds this section added.
r3_writes=""
for st in s-r3open s-r3term s-stuck; do
  [ -f "$w/$st/.would-write.log" ] || continue
  grep -oE 'WOULD (PUT|POST|DELETE) +[^ ]+' "$w/$st/.would-write.log" \
    | grep -vE '(/issue/[A-Z]+-[0-9]+(/comment|/assignee)?|/issueLink)$' | grep -q . \
    && r3_writes="$r3_writes $st"
  grep -oE '"description"[[:space:]]*:' "$w/$st/.would-write.log" | grep -q . \
    && r3_writes="$r3_writes $st(description)"
done
unset st
if [ -z "$r3_writes" ]; then
  pass "and none of these rounds writes anything a refinement is not already allowed to write"
else
  fail "one of these rounds wrote something a refinement has no business writing:$r3_writes"; fi

printf '\n== cross-round memory: a settled point is not asked or read again ==\n'
# terms_off_to_ask and misread_to_ask both used to check a promotion only
# against what THIS round already asked - never against a prior one. A dress
# rehearsal against four real tickets, run to completion with real
# orc-refine.sh and orc-harvest.sh calls and a mocked reporter answering every
# round in character, hit exactly that gap on both mechanisms and nothing
# else: all four ran out their 8-round cap without ever reaching a terminal
# verdict. This is the real thing end to end: a real round 1, a real
# bin/orc-harvest.sh reading a real reporter reply out of a real comment
# thread, and a real round 2 - not a hand-authored state/*.answers.json,
# because the point of the fix is that the memory comes from what
# bin/orc-harvest.sh actually matched, and a fixture authored to look like
# that output would not prove this reads the real thing.
crm=$(mktemp -d)
mkdir -p "$crm/fx/issues" "$crm/fx/search" "$crm/bin1" "$crm/bin2" "$crm/state"
: > "$crm/projects.yml"
printf '{"issues":[]}' > "$crm/fx/search/open-issues.json"

# The raw ADF body a round actually posted, read back out of the write-preview
# log the same way a reader would, rather than reconstructed from what the
# test expects it to be - see _write_preview in orc-lib.sh for the "+-- raw"
# separator this depends on.
crm_posted_comment() {
  awk -v pat="WOULD POST   /issue/$2/comment" '
    $0 ~ pat { on = 1 }
    on && /\+-- raw/ { raw = 1; next }
    raw && /^  \+----/ { exit }
    raw { sub(/^  \| ?/, ""); print }
  ' "$1/.would-write.log"
}
# A reporter's reply, as a plain paragraph - the shape harvest's "the only
# question there was" rule matches without needing an ordered list at all.
crm_reply() {
  local id="$1" at="$2" text="$3" content
  content=$(adf_para "$(adf_new)" "$text")
  jq -nc --argjson c "$content" --arg i "$id" --arg t "$at" '{
    id: $i, created: $t, updated: $t,
    author: {accountId: "acct-reporter", displayName: "Reporter"},
    body: {type: "doc", version: 1, content: $c}}'
}
# Splice a round's own posted comment plus a reply into the fixture ticket, so
# the NEXT round's jira_read sees the history a real ticket would carry.
# Fixture-mode jira_write never touches the fixture file itself - it only logs
# a preview - so this is standing in for what a live Jira thread would already
# hold by the time round 2 ran.
crm_set_history() {
  local key="$1" state_dir="$2" reply_text="$3" posted
  posted=$(crm_posted_comment "$state_dir" "$key" | jq -c --arg t "2026-08-16T11:00:00.000+0200" \
    '. + {id: "9001", created: $t, updated: $t,
          author: {accountId: "orc-service-account", displayName: "Orchestrator"}}')
  jq --argjson c1 "$posted" --argjson c2 "$(crm_reply 9002 2026-08-16T12:00:00.000+0200 "$reply_text")" \
    '.fields.comment.comments = [$c1, $c2] | .fields.comment.total = 2' \
    "$crm/fx/issues/$key.json" > "$crm/fx/issues/$key.json.tmp" \
    && mv "$crm/fx/issues/$key.json.tmp" "$crm/fx/issues/$key.json"
}
crm_run() {  # <bin-dir> <key>
  env ORC_PROJECTS_FILE="$crm/projects.yml" ORC_FIXTURE_DIR="$crm/fx" ORC_STATE_DIR="$crm/state" \
      ORC_CLONE_DIR="$crm/clones" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$crm/$1:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$2" >/dev/null 2>&1
}
crm_harvest() {  # <key>
  env ORC_FIXTURE_DIR="$crm/fx" ORC_STATE_DIR="$crm/state" ORC_PROJECTS_FILE="$crm/projects.yml" \
      ORC_CLONE_DIR="$crm/clones" ORC_GAP_LEDGER="$crm/no-ledger.jsonl" \
      "$ORC_ROOT/bin/orc-harvest.sh" --key "$1" >/dev/null 2>&1
}

# --- the off-ticket term promotion, across a real round 1 and round 2 -------

jq -n '{id:"1", key:"CRM-1", fields:{
  summary:"Show the deposit on the dashboard",
  description:"Add a field on the depot dashboard showing the deposit amount held for a rental.",
  labels:[], status:{name:"Open"}, updated:"2026-08-16T10:00:00.000+0200",
  comment:{comments:[], total:0}}}' > "$crm/fx/issues/CRM-1.json"

cat > "$crm/bin1/claude" <<'SH'
#!/bin/sh
cat >/dev/null
jq -Rsc '{result: .}' <<'JSON'
{"verdict":"needs_input","questions":[],"terms_resolved":[],
 "terms_unresolved":["Handover sheet"],"split_into":[],"duplicate_of":null,
 "notes":"","not_verified":"","acceptance_criteria":[]}
JSON
SH
chmod +x "$crm/bin1/claude"
crm_run bin1 CRM-1
if grep -qF 'read as being about "Handover sheet"' "$crm/state/.would-write.log"; then
  pass "round 1 promotes a term the ticket does not say, same as before this change"
else
  fail "round 1 never promoted the off-ticket term; the rest of this section proves nothing"
  cat "$crm/state/.would-write.log"; fi

crm_set_history CRM-1 "$crm/state" "The handover sheet is the form a clerk fills in when a rental goes out."
rm -f "$crm/state/.would-write.log"
crm_harvest CRM-1
if jq -e '.answers[0].question | test("Handover sheet")' "$crm/state/CRM-1.answers.json" >/dev/null 2>&1; then
  pass "and a real bin/orc-harvest.sh run matches the reporter's reply to it, from the ticket's own comment thread"
else
  fail "the reply was never matched to the promoted question"
  cat "$crm/state/CRM-1.answers.json" 2>/dev/null; fi

# Round 2: the same refiner, still paraphrasing the ticket as being about the
# same term it was told about last time - the "verbatim, rounds later" shape
# the dress rehearsal actually hit, not a new paraphrase.
cat > "$crm/bin2/claude" <<'SH'
#!/bin/sh
cat >/dev/null
jq -Rsc '{result: .}' <<'JSON'
{"verdict":"needs_input","questions":[],"terms_resolved":[],
 "terms_unresolved":["Handover sheet"],"split_into":[],"duplicate_of":null,
 "notes":"","not_verified":"","acceptance_criteria":[]}
JSON
SH
chmod +x "$crm/bin2/claude"
crm_run bin2 CRM-1
if grep -qF 'read as being about "Handover sheet"' "$crm/state/.would-write.log"; then
  fail "a term promoted and answered in round 1 was promoted again in round 2"
  cat "$crm/state/.would-write.log"
else
  pass "a term promoted and answered in round 1 is not promoted again in round 2, even though round 2's refiner still paraphrases the ticket the same way"
fi

# The control: a genuinely new off-ticket term alongside the settled one is
# still promoted, so this is a memory of what was answered, not a switch that
# went off for the whole ticket.
cat > "$crm/bin2/claude" <<'SH'
#!/bin/sh
cat >/dev/null
jq -Rsc '{result: .}' <<'JSON'
{"verdict":"needs_input","questions":[],"terms_resolved":[],
 "terms_unresolved":["Handover sheet","Damage waiver"],"split_into":[],"duplicate_of":null,
 "notes":"","not_verified":"","acceptance_criteria":[]}
JSON
SH
rm -f "$crm/state/.would-write.log"
crm_run bin2 CRM-1
if grep -qF 'read as being about "Damage waiver"' "$crm/state/.would-write.log" \
   && ! grep -qF 'read as being about "Handover sheet"' "$crm/state/.would-write.log"; then
  pass "and a genuinely new off-ticket term is still promoted alongside it - the settled one is excluded by name, not by silencing the mechanism"
else
  fail "a new off-ticket term was not promoted, or the settled one leaked back in"
  cat "$crm/state/.would-write.log"; fi

# --- the adversarial re-read, across a real round 1 and round 2 -------------

jq -n '{id:"1", key:"CRM-2", fields:{
  summary:"Raise the weekly rental rate",
  description:"Raise the weekly rate from 29 to 34.",
  labels:[], status:{name:"Open"}, updated:"2026-08-16T10:00:00.000+0200",
  comment:{comments:[], total:0}}}' > "$crm/fx/issues/CRM-2.json"

CRM_MISQ='Should customers already subscribed at 29 euros keep paying 29 euros, or does the new 34 euro price apply to their existing subscription too?'
crm_ready_json='{"verdict":"ready","confidence":"high","one_line":"Raise the weekly rate to 34.",
 "acceptance_criteria":["The weekly rate is 34."],"subsystems":[],"files":[],
 "locality_basis":"none","terms_resolved":[],"terms_unresolved":[],"questions":[],
 "duplicate_of":null,"split_into":[],"rewritten_description":null,"not_verified":"","notes":""}'

cat > "$crm/bin1/claude" <<SH
#!/bin/sh
in=\$(cat)
if printf '%s' "\$in" | grep -q 'Second pass: the adversarial re-read'; then
  jq -Rsc '{result: .}' <<'JSON'
{"misreadings":[{"quote":"the new price applies","reading_taken":"only new customers",
  "reading_missed":"existing customers too",
  "different_software":"whether existing subscribers get grandfathered",
  "question":"$CRM_MISQ"}]}
JSON
else
  printf '%s' '$crm_ready_json' | jq -Rsc '{result: .}'
fi
SH
chmod +x "$crm/bin1/claude"
rm -f "$crm/state/.would-write.log"
crm_run bin1 CRM-2
if jq -e '.verdict == "needs_input" and .verdict_first_read == "ready" and .misread.disagreed == true' \
     "$crm/state/CRM-2.verdict.json" >/dev/null 2>&1; then
  pass "round 1's second read finds a real disagreement and sends the card back, same as before this change"
else
  fail "round 1 never raised the disagreement; the rest of this section proves nothing"
  jq -c '{verdict,verdict_first_read,misread}' "$crm/state/CRM-2.verdict.json" 2>/dev/null || true; fi

crm_set_history CRM-2 "$crm/state" "Existing subscribers keep paying 29 euros, only new subscribers pay 34."
rm -f "$crm/state/.would-write.log"
crm_harvest CRM-2
if jq -e '.answers[0].question | test("29 euros")' "$crm/state/CRM-2.answers.json" >/dev/null 2>&1; then
  pass "and a real bin/orc-harvest.sh run matches the reporter's reply to the misread question, the same as any other"
else
  fail "the reply was never matched to the misread question"
  cat "$crm/state/CRM-2.answers.json" 2>/dev/null; fi

# Round 2: the first read reaches the identical conclusion again, so the
# second read runs again - and re-derives the identical disagreement, word for
# word, the shape the dress rehearsal actually hit.
cat > "$crm/bin2/claude" <<SH
#!/bin/sh
in=\$(cat)
if printf '%s' "\$in" | grep -q 'Second pass: the adversarial re-read'; then
  jq -Rsc '{result: .}' <<'JSON'
{"misreadings":[{"quote":"the new price applies","reading_taken":"only new customers",
  "reading_missed":"existing customers too",
  "different_software":"whether existing subscribers get grandfathered",
  "question":"$CRM_MISQ"}]}
JSON
else
  printf '%s' '$crm_ready_json' | jq -Rsc '{result: .}'
fi
SH
chmod +x "$crm/bin2/claude"
crm_run bin2 CRM-2
if jq -e '.verdict == "ready" and .misread.disagreed == false and .misread.already_settled_count == 1' \
     "$crm/state/CRM-2.verdict.json" >/dev/null 2>&1; then
  pass "a misreading raised and answered in round 1 is not independently re-raised in round 2 for the same underlying disagreement"
else
  fail "the second read re-raised a disagreement the reporter had already settled"
  jq -c '{verdict,misread}' "$crm/state/CRM-2.verdict.json" 2>/dev/null || true; fi
if ! grep -qF "$CRM_MISQ" "$crm/state/.would-write.log"; then
  pass "and the settled question is not on the comment either"
else
  fail "a settled misreading still reached the comment"; fi

# The control: a genuinely different disagreement on the same ticket still
# sends the card back. Nothing about round 2 blanket-suppresses the pass -
# only the one disagreement that was already asked and answered.
cat > "$crm/bin2/claude" <<'SH'
#!/bin/sh
in=$(cat)
if printf '%s' "$in" | grep -q 'Second pass: the adversarial re-read'; then
  jq -Rsc '{result: .}' <<'JSON'
{"misreadings":[{"quote":"weekly rate","reading_taken":"the online rate only",
  "reading_missed":"the phone-booking rate too",
  "different_software":"whether phone bookings also change price",
  "question":"Does the phone-booking desk quote the new weekly rate too, or only the online checkout?"}]}
JSON
else
  jq -Rsc '{result: .}' <<'JSON'
{"verdict":"ready","confidence":"high","one_line":"Raise the weekly rate to 34.",
 "acceptance_criteria":["The weekly rate is 34."],"subsystems":[],"files":[],
 "locality_basis":"none","terms_resolved":[],"terms_unresolved":[],"questions":[],
 "duplicate_of":null,"split_into":[],"rewritten_description":null,"not_verified":"","notes":""}
JSON
fi
SH
crm_run bin2 CRM-2
if jq -e '.verdict == "needs_input" and .misread.disagreed == true and .misread.already_settled_count == 0' \
     "$crm/state/CRM-2.verdict.json" >/dev/null 2>&1; then
  pass "and a genuinely new disagreement on the same ticket is still raised"
else
  fail "a genuinely new disagreement was suppressed along with the settled one"
  jq -c '{verdict,misread}' "$crm/state/CRM-2.verdict.json" 2>/dev/null || true; fi

# misread_to_ask has to survive rewording, not only an exact repeat: the real
# second read is not guaranteed to phrase a re-derived disagreement identically
# every time, and the overlap bar in misread_already_asked is what is supposed
# to catch that. Checked directly against the two functions, because
# reproducing a specific rewording through a real agent call is not
# reproducible the way a fixture needs to be.
crm_reworded='{"misreadings":[{"question":"Should customers who already subscribed at 29 euros keep paying 29 euros, or does the new 34 euro price apply to their existing subscription as well?"}]}'
if [ "$(misread_to_ask "$crm_reworded" "$CRM_MISQ" | jq '.misreadings | length')" = "0" ]; then
  pass "and a reworded re-derivation of the same disagreement is caught too, not only a verbatim repeat"
else
  fail "misread_to_ask only catches a verbatim repeat of a settled disagreement"
  misread_to_ask "$crm_reworded" "$CRM_MISQ"; fi

# The other half of that bar, and the one it used to get wrong. The overlap
# test was handed the concatenation of every prior answered question at once,
# so by round five or six of a real ticket it was asking whether half the
# candidate's words appeared anywhere in a bag of several hundred - which a
# brand-new question about a brand-new subject clears by coincidence. Three
# live reproductions across two tickets, and on the most recent one it threw
# away three real findings from the round that decided the card was finished.
#
# So the questions below are a dense card's worth of history in the product's
# own words rather than toy strings, because the failure is a property of
# volume: none of these seven priors is anywhere near the candidate on its own,
# and together they say almost every word it says.
crm_history='Should the weekend rate replace the day rate on the depot dashboard, or should both rates be shown beside each other?
Should a weekend rental that was extended by hand keep the weekend rate, or move on to the week rate?
Who is allowed to release a deposit early - only the depot manager, or any member of the depot staff?
Should weekend rentals be counted in the depot monthly figures alongside day rentals and week rentals?
If the customer card is declined while the booking is being made, should the booking still be created with the deposit outstanding, or should nothing be booked at all?
When a weekend booking is cancelled, should the deposit be released straight away, or held until the vehicle is back at the depot?
Should the express return be offered on every weekend rental, or only on the ones a depot manager has released early?'
crm_new_subject='{"misreadings":[{"question":"Should the depot manager be told when a weekend booking is made with the deposit outstanding, or should the depot dashboard show it?"}]}'
if [ "$(misread_to_ask "$crm_new_subject" "$crm_history" | jq '.misreadings | length')" = "1" ]; then
  pass "and a genuinely new question is not swallowed by the accumulated vocabulary of seven prior ones"
else
  fail "a new disagreement was suppressed by the union of prior questions, none of which asked it"
  misread_to_ask "$crm_new_subject" "$crm_history"; fi

# The same seven, minus the six that are not about this: a candidate really is
# compared with one prior question at a time, so a settled one still catches
# its own re-derivation out of the same history.
crm_settled_in_history='{"misreadings":[{"question":"Should a weekend rental somebody extended by hand stay on the weekend rate, or should it move on to the week rate?"}]}'
if [ "$(misread_to_ask "$crm_settled_in_history" "$crm_history" | jq '.misreadings | length')" = "0" ]; then
  pass "and one settled question inside that same history still catches its own re-derivation"
else
  fail "per-question comparison stopped catching a settled disagreement it used to catch"
  misread_to_ask "$crm_settled_in_history" "$crm_history"; fi

# Every question this system asks is an interrogative held to one bar, so any
# two of them share "should", "that", "only", "been", "after". Counted as
# content words those are the words two questions are most likely to have in
# common and the last ones that say anything about whether they are the same
# question. This pair shares ten of the candidate's seventeen words outright -
# enough to suppress it if function words counted - and four once they do not:
# deposit, depot, vehicle and checked, which are simply what this card is
# about. The questions are different ones. Who may release the deposit early is
# not who gets told once it has been released.
crm_register_prior='Should the depot manager be able to release the deposit before the vehicle is back at the depot, or should that only happen after it has been checked in?'
crm_register_new='{"misreadings":[{"question":"Should the customer also be told that the deposit has been released, or should that only be shown to the depot staff who checked the vehicle in?"}]}'
if [ "$(misread_to_ask "$crm_register_new" "$crm_register_prior" | jq '.misreadings | length')" = "1" ]; then
  pass "and two questions sharing nothing but the interrogative register and the card's own nouns are not the same question"
else
  fail "the question register and the ticket's own vocabulary were enough to suppress a different question"
  misread_to_ask "$crm_register_new" "$crm_register_prior"; fi

# The degenerate end of that: strip the register and the ticket's nouns out of
# a question and there can be nothing left. Nothing left is no evidence either
# way, and no evidence is not a reason to drop a finding.
crm_no_content='{"misreadings":[{"question":"Should it be the same, or should it not?"}]}'
if [ "$(misread_to_ask "$crm_no_content" "$crm_register_prior" | jq '.misreadings | length')" = "1" ]; then
  pass "and a question with no content words left after the register is taken out suppresses nothing"
else
  fail "a question made entirely of function words suppressed a finding"; fi

printf '\n== new activity re-opens the round, and the system does not re-trigger on itself ==\n'
# Refinement used to key its skip on the summary and the description alone, so a
# reporter answering every question asked of them moved nothing it was watching:
# the poll surfaced the ticket, bin/orc-harvest.sh matched the reply, and this
# skipped it as unchanged. The dress rehearsal on a real epic only reached its
# terminal state because every round was driven with --force.
#
# So the skip is keyed on two things now, and both halves are asserted: a card
# nobody has touched must still skip - that guard is what stops the daemon
# re-judging the whole board every pass - and a card carrying somebody else's new
# comment must judge again. The hard one is in between: a round ends by posting a
# question comment, so a rule that counted any new comment would re-trigger on
# its own footprint for ever.
#
# Nothing here passes --force, which is the whole point: --force is what the loop
# needed before and must not be what makes these pass.
rtg=$(mktemp -d)
mkdir -p "$rtg/fx/issues" "$rtg/fx/search" "$rtg/bin" "$rtg/state"
: > "$rtg/projects.yml"
printf '{"issues":[]}' > "$rtg/fx/search/open-issues.json"
printf '{"issues":[{"key":"RTG-1"}]}' > "$rtg/fx/search/project-issues.json"

RTG_Q='Should the deposit be shown in euros, or in the currency the renter paid in?'
RTG_A='Always in euros, whatever the renter paid in.'

cat > "$rtg/bin/claude" <<SH
#!/bin/sh
cat > "$rtg/last-prompt.txt"
jq -Rsc '{result: .}' <<'JSON'
{"verdict":"needs_input","confidence":"medium","one_line":"Show the deposit on the depot dashboard.",
 "acceptance_criteria":[],"subsystems":[],"files":[],"locality_basis":"none",
 "terms_resolved":[],"terms_unresolved":[],"questions":["$RTG_Q"],
 "duplicate_of":null,"split_into":[],"rewritten_description":null,"not_verified":"","notes":""}
JSON
SH
chmod +x "$rtg/bin/claude"

rtg_ticket() {  # <description>
  jq -n --arg d "$1" '{id:"1", key:"RTG-1", fields:{
    summary:"Show the deposit on the depot dashboard",
    description:$d, labels:[], reporter:{accountId:"acct-reporter"},
    status:{name:"Open"}, updated:"2026-08-16T10:00:00.000+0200",
    comment:{comments:[], total:0}}}' > "$rtg/fx/issues/RTG-1.json"
}
# No --force anywhere. The status is the answer: 0 judged, 3 nothing to do.
rtg_run() {
  rm -f "$rtg/state/.would-write.log" "$rtg/last-prompt.txt"
  env ORC_PROJECTS_FILE="$rtg/projects.yml" ORC_FIXTURE_DIR="$rtg/fx" ORC_STATE_DIR="$rtg/state" \
      ORC_CLONE_DIR="$rtg/clones" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$rtg/bin:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" "$@" RTG-1 >/dev/null 2>&1
}
rtg_harvest() {
  env ORC_FIXTURE_DIR="$rtg/fx" ORC_STATE_DIR="$rtg/state" ORC_PROJECTS_FILE="$rtg/projects.yml" \
      ORC_CLONE_DIR="$rtg/clones" ORC_GAP_LEDGER="$rtg/no-ledger.jsonl" \
      "$ORC_ROOT/bin/orc-harvest.sh" --key RTG-1 >/dev/null 2>&1
}
# Read in a subshell so the sandbox's state directory cannot outlive the call.
# shellcheck disable=SC2034  # read by meta_get in orc-lib.sh, which this sources
rtg_seen() { ( STATE_DIR="$rtg/state"; meta_get RTG-1 comment_seen ); }
rtg_reconcile() {
  env ORC_PROJECTS_FILE="$rtg/projects.yml" ORC_FIXTURE_DIR="$rtg/fx" ORC_STATE_DIR="$rtg/state" \
      ORC_CLONE_DIR="$rtg/clones" ORC_JIRA_MODE=fixture \
      "$ORC_ROOT/bin/orc-reconcile.sh" >/dev/null 2>&1
}
# The thread as a live ticket would carry it: this system's own comment, read
# back out of the write-preview log rather than reconstructed, plus whatever a
# person said. Fixture-mode jira_write never touches the fixture file, so this
# stands in for what Jira would already hold by the time the next round ran.
# The comment ids and timestamps are the fixture's, because the whole question
# under test is which comment is the newest one somebody else wrote.
#
# Read out of the log of the run that posted it, so it has to be captured while
# that log is still there - a run that skips writes nothing to read.
rtg_capture_ours() {  # <id> <created>
  crm_posted_comment "$rtg/state" RTG-1 \
    | jq -c --arg i "$1" --arg t "$2" '. + {id: $i, created: $t, updated: $t,
        author: {accountId: "orc-service-account", displayName: "Orchestrator"}}'
}
rtg_set_thread() {  # <compact-json-comment>...
  local arr="[]" c
  for c in "$@"; do arr=$(printf '%s' "$arr" | jq -c --argjson c "$c" '. + [$c]'); done
  jq --argjson a "$arr" '.fields.comment.comments = $a | .fields.comment.total = ($a | length)' \
    "$rtg/fx/issues/RTG-1.json" > "$rtg/fx/issues/RTG-1.json.tmp" \
    && mv "$rtg/fx/issues/RTG-1.json.tmp" "$rtg/fx/issues/RTG-1.json"
}

# Round 1: a card nobody has judged is judged, and the run records what it saw.
rtg_ticket 'Add a field on the depot dashboard showing the deposit held for a rental.'
rtg_run; rtg_1=$?
if [ "$rtg_1" = "0" ] && grep -qF "$RTG_Q" "$rtg/state/.would-write.log"; then
  pass "round 1 judges an unjudged card and asks its question"
else
  fail "round 1 never judged the card; the rest of this section proves nothing (status $rtg_1)"
  cat "$rtg/state/.would-write.log" 2>/dev/null; fi

# The guard that must not be softened: nothing has happened, so nothing happens.
rtg_run; rtg_2=$?
if [ "$rtg_2" = "3" ] && [ ! -f "$rtg/state/.would-write.log" ]; then
  pass "an unchanged card with no new comment still skips, and posts nothing"
else
  fail "an unchanged card was judged again (status $rtg_2); the daemon would re-judge the whole board every pass"
  cat "$rtg/state/.would-write.log" 2>/dev/null; fi

# The trigger that already worked, still working: the ticket's own text moving.
rtg_ticket 'Add a field on the depot dashboard showing the deposit held for a rental, in the depot currency.'
rtg_run; rtg_3=$?
rtg_ours=$(rtg_capture_ours 9002 2026-08-16T12:00:00.000+0200)
if [ "$rtg_3" = "0" ] && [ -n "$rtg_ours" ]; then
  pass "a card whose description changed still re-judges, exactly as it did before"
else
  fail "a description edit no longer re-opens the round (status $rtg_3)"; fi

# THE INFINITE-LOOP GUARD. The only new comment on the ticket is the question
# comment the round above posted. Counted as activity, that round would re-trigger
# itself, post another comment, and never stop - so this is asserted hard: the
# status, the absence of a post, and that it holds however many passes run.
rtg_set_thread "$rtg_ours"
rtg_loop_bad=0
for rtg_pass in 1 2 3; do
  rtg_run
  [ "$?" = "3" ] && [ ! -f "$rtg/state/.would-write.log" ] || rtg_loop_bad=$rtg_pass
done
unset rtg_pass
if [ "$rtg_loop_bad" = "0" ]; then
  pass "a card whose only new comment is the orchestrator's own question comment does NOT re-judge, on three passes running"
else
  fail "the orchestrator re-triggered on its own comment (pass $rtg_loop_bad): this is the infinite loop"
  cat "$rtg/state/.would-write.log" 2>/dev/null; fi

# And now the bug this whole section is about: the reporter answers.
rtg_reply=$(crm_reply 9003 2026-08-16T13:00:00.000+0200 "$RTG_A")
rtg_set_thread "$rtg_ours" "$rtg_reply"
# The harvest runs first, as bin/orc-cycle.sh runs it, so the settled answer is
# on disk before the round it triggers reads it.
rtg_harvest
if jq -e --arg a "$RTG_A" '[.answers[]? | select(.answer == $a)] | length == 1' \
     "$rtg/state/RTG-1.answers.json" >/dev/null 2>&1; then
  pass "and a real bin/orc-harvest.sh run matches the reply to the question it answers"
else
  fail "the reply was never matched, so the settled-context assertion below would prove nothing"
  cat "$rtg/state/RTG-1.answers.json" 2>/dev/null; fi

rtg_run; rtg_4=$?
if [ "$rtg_4" = "0" ] && grep -qF "$RTG_Q" "$rtg/state/.would-write.log"; then
  pass "a card carrying a new reporter comment re-judges, with no --force anywhere"
else
  fail "a reporter's reply still does not re-open the round (status $rtg_4): the loop cannot advance"
  cat "$rtg/state/.would-write.log" 2>/dev/null; fi

# The round it triggered has to arrive already knowing what the reply said, or
# the newly-opened round asks the question that opened it. prior_qa_ctx reads
# answered_qa_for, which reads what the harvest above matched.
if grep -qF 'Settled: already asked and answered on an earlier round' "$rtg/last-prompt.txt" \
   && grep -qF "$RTG_A" "$rtg/last-prompt.txt" && grep -qF "$RTG_Q" "$rtg/last-prompt.txt"; then
  pass "and the triggered round reaches the refiner with that reply already in its settled context"
else
  fail "the triggered round did not carry the answer that triggered it; it would re-ask what was just answered"
  grep -c . "$rtg/last-prompt.txt" 2>/dev/null; fi
rtg_ours_2=$(rtg_capture_ours 9004 2026-08-16T14:00:00.000+0200)

# It advances rather than spins: having judged that reply, the same reply is not
# a reason to judge again.
rtg_run; rtg_5=$?
if [ "$rtg_5" = "3" ]; then
  pass "and the same reply does not re-open the round a second time"
else
  fail "the reply re-opens the round on every pass (status $rtg_5)"; fi

# state/ is a cache, so bin/orc-reconcile.sh has to rebuild this or the loop
# strands after bin/orc-reset.sh: rebuilt too eagerly and every replied-to ticket
# in the project is re-judged, rebuilt too late and a reply nobody has answered is
# swallowed. The thread now holds the comment the triggered round posted, which is
# what makes the position readable.
rtg_set_thread "$rtg_ours" "$rtg_reply" "$rtg_ours_2"
rtg_run; rtg_6=$?
rtg_seen_before=$(rtg_seen)
rm -rf "$rtg/state"
rtg_reconcile
rtg_seen_after=$(rtg_seen)
if [ "$rtg_6" = "3" ] && [ "$rtg_seen_before" = "9003" ] && [ "$rtg_seen_after" = "9003" ]; then
  pass "bin/orc-reconcile.sh rebuilds the recorded comment from the ticket's own thread, so state/ stays a cache"
else
  fail "the field the skip is keyed on does not survive a wipe (before='$rtg_seen_before' after='$rtg_seen_after' status $rtg_6)"; fi
rtg_run; rtg_7=$?
if [ "$rtg_7" = "3" ]; then
  pass "and a reconciled card with an answered reply still skips rather than being judged all over again"
else
  fail "the first pass after a reset re-judges every ticket anybody has ever replied to (status $rtg_7)"; fi

# --force is what the loop needed before this and must go on meaning what it
# meant: judge again, unchanged or not.
rtg_run --force; rtg_8=$?
if [ "$rtg_8" = "0" ] && grep -qF "$RTG_Q" "$rtg/state/.would-write.log"; then
  pass "--force still re-judges a card that would otherwise skip"
else
  fail "--force stopped working (status $rtg_8)"; fi

# The opt-in gate is about whether a card is in scope at all, which no amount of
# activity answers. Asked with a reply sitting unanswered on the ticket, because
# that is the one case where the two rules could be confused for each other.
rm -f "$rtg/state/RTG-1.meta"
rtg_gated=$(env LABEL_OPT_IN=refine-me ORC_PROJECTS_FILE="$rtg/projects.yml" ORC_FIXTURE_DIR="$rtg/fx" \
     ORC_STATE_DIR="$rtg/state" ORC_CLONE_DIR="$rtg/clones" ORC_REPO_SYNC=off \
     ORC_JIRA_MODE=fixture ORC_REFINER=claude PATH="$rtg/bin:$PATH" \
     "$ORC_ROOT/bin/orc-refine.sh" RTG-1 2>&1)
if printf '%s' "$rtg_gated" | grep -q 'not labelled refine-me'; then
  pass "and a card nobody labelled is still out of scope, however much activity it carries"
else
  fail "new activity walked past the opt-in gate"
  printf '%s\n' "$rtg_gated"; fi
rm -rf "$rtg"

printf '\n== the standing sweep, and the silence that keeps it usable ==\n'
# Six categories of gap that nothing in the ticket points at - failure states,
# empty states, permissions and roles, zero one many, existing data at launch,
# reversibility - run against every card on the first read. The question bar is a
# filter on questions already thought of; the sweep is how the ones with no
# anchor in the text get thought of at all.
#
# It is entirely prompt-side, and that is a decision rather than an omission:
# each of the six was examined for a mechanical tell in the repositories, and
# none of them earned a detector of its own.
#
# So what is asserted here is the silence, which is the design claim and the
# thing that can break. Six categories against every card is an invitation to ask
# six mediocre questions, and a comment carrying six of which two matter teaches
# the person answering it to skim - at which point the two go past with the four.
for sweep_cat in 'Failure states' 'Empty states' 'Permissions and roles' 'Zero, one, many' 'Existing data at launch' 'Reversibility'; do
  if grep -qF "**$sweep_cat.**" "$ORC_ROOT/prompts/refine.md"; then
    pass "the sweep names the category: $sweep_cat"
  else
    fail "prompts/refine.md does not name '$sweep_cat', so the sweep runs a category short"; fi
done
unset sweep_cat

# The mechanical half of "no output of its own". A field per category would be
# filled - a record that can flatter itself measures nothing - and six filled
# fields is six questions looking for a reason to be asked. The keys are read out
# of the contract itself and compared with the documented set, so a field added
# for this or for anything else fails here rather than reaching a comment.
sweep_keys=$(awk '/^```$/ { n++; next } n == 1' "$ORC_ROOT/prompts/refine.md" \
  | grep -oE '^  "[a-z_]+"' | tr -d ' "' | sort | tr '\n' ' ')
sweep_want='acceptance_criteria confidence duplicate_of files locality_basis not_verified notes one_line questions rewritten_description split_into subsystems terms_resolved terms_unresolved verdict '
if [ "$sweep_keys" = "$sweep_want" ]; then
  pass "and it added no field to the output contract: a question it produces is a question like any other"
else
  fail "the refiner's output contract is not the documented one; the sweep must add no field of its own"
  printf '   got:  %s\n   want: %s\n' "$sweep_keys" "$sweep_want"; fi

# A card with no genuine gap in any category, which is the normal card. The
# refiner returns a settled round and asks nothing, and nothing anywhere adds a
# question to it or a word about a category. This is the assertion the whole
# design rests on: there is no sweep machinery, so a category that finds nothing
# structurally cannot cost a comment a line. The run is the agreeing one above,
# because a round nobody asked anything on is exactly what that stand-in returns.
sweep_quiet=$(comment_of "$w/s-agree" ORC-101)
if [ "$(meta_field "$w/s-agree" ORC-101 question_count)" = "0" ] \
   && ! printf '%s' "$sweep_quiet" | grep -qiE 'sweep|failure state|empty state|reversib|existing data|permissions and roles|category'; then
  pass "a card with no gap in any category is asked nothing, and no category is named anywhere on its comment"
else
  fail "the sweep left something on a comment that had nothing to say"
  printf '%s\n' "$sweep_quiet"; fi

# And the card that does have one. A sweep question arrives in `questions` like
# any other, so what has to be true is that it needs no new machinery: it is
# rendered in the refiner's own list, it un-terminates the round exactly as an
# ordinary question does - no split proposal and no rewritten description - and
# it earns no second read, because the card is going back to the reporter anyway.
sweep_q='If the payment is declined half way through starting the booking, should the booking still be created, or should nothing be booked at all?'
sweep_first=$(jq -nc --arg q "$sweep_q" --argjson base "$mis_first_ready" \
  '$base + {verdict: "needs_input", questions: [$q], rewritten_description: null,
            split_into: [{title: "Take the deposit", description: "It ships and reverts on its own."}]}')
mis_run sweepasks "$sweep_first" "$mis_finding"
sweep_body=$(comment_of "$w/s-sweepasks" ORC-101)
if printf '%s' "$sweep_body" | grep -qF "$sweep_q"; then
  pass "a question the sweep produced reaches the ticket in the refiner's own words, in the ordinary list"
else
  fail "a sweep question never reached the comment"; printf '%s\n' "$sweep_body"; fi
if [ "$(meta_field "$w/s-sweepasks" ORC-101 split_ready)" = "no" ] \
   && ! printf '%s' "$sweep_body" | grep -q 'ready to be split into' \
   && ! printf '%s' "$sweep_body" | grep -q 'rewritten with every answer folded in'; then
  pass "and it un-terminates the round like any other question: no split proposal, no rewritten description"
else
  fail "a card with an open sweep question was still handed on as settled"
  printf '%s\n' "$sweep_body"; fi
if [ "$(mis_seconds sweepasks)" = "0" ]; then
  pass "and it costs no second read: a card already going back to the reporter is not read again for it"
else
  fail "a round the sweep had already un-terminated paid for a second agent call"; fi

rm -rf "$w"

printf '\n== the bundle is drafted from the repositories, and never over a human ==\n'
# Two real repositories on real branches, no network and no credentials, so the
# drafter is exercised the way it actually runs rather than against a stub.
b=$(mktemp -d)
bok() {
  env ORC_PROJECTS_FILE="$b/projects.yml" ORC_STATE_DIR="$b/state" \
      ORC_CLONE_DIR="$b/clones" \
      "$ORC_ROOT/bin/orc-okf-draft.sh" --bundle "$b/okf" "$@" 2>&1
}
bhash() { find "$b/okf" -type f | sort | while IFS= read -r f; do printf '%s ' "$f"; _sha1 < "$f"; done | _sha1; }

mkdir -p "$b/clones/api/app/models" "$b/clones/api/app/controllers" "$b/clones/api/config/locales" \
         "$b/clones/api/db/migrate" \
         "$b/clones/web/pages" "$b/clones/web/store" "$b/clones/web/locales" "$b/okf"
cat > "$b/clones/api/Gemfile" <<'RB'
source "https://rubygems.org"
RB
: > "$b/clones/api/config/application.rb"
# One model carrying all four of the things the drafter reads out of code: an
# enum, a frozen constant with a comment above it, a scope that filters a term
# out, and (below) the schema constraint and the migration that go with them.
cat > "$b/clones/api/app/models/medical_case.rb" <<'RB'
class MedicalCase < ApplicationRecord
  enum :status, {
    pending: 0,
    waiting_for_images: 1,
    closed: 2
  }

  # A follow-up is offered only for these, and unlocked by hand.
  FOLLOW_UP_TREATMENTS = %w[biopsy smear lab_control].freeze

  scope :without_legacy_aftercares, -> { where(parent_case_id: nil) }
end
RB
cat > "$b/clones/api/db/schema.rb" <<'RB'
ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
  create_table "medical_cases", force: :cascade do |t|
    t.string "status", null: false
    t.bigint "main_case_id", null: false
    t.bigint "started_case_id"
    t.datetime "created_at", null: false
    t.index ["main_case_id"], name: "index_medical_cases_on_unclaimed", unique: true, where: "(started_case_id IS NULL)"
  end
end
RB
cat > "$b/clones/api/db/migrate/20200101000000_create_aftercares.rb" <<'RB'
class CreateAftercares < ActiveRecord::Migration[6.0]
  def change
    create_table :aftercares
  end
end
RB
: > "$b/clones/api/app/controllers/cases_controller.rb"
# Two strings, and the second is there for the gap loop below: `Nudge` is
# said by both catalogues under a key that names nothing the code declares, so
# the dictionary's rule cannot resolve it and it never reaches
# product-vocabulary.md. That is what makes it a word the bundle does not explain
# while the evidence still corroborates that the product says it.
cat > "$b/clones/api/config/locales/en.yml" <<'YML'
en:
  medical_cases:
    title: Patient file
  notifications:
    reminder: Nudge
YML
: > "$b/clones/web/nuxt.config.js"
cat > "$b/clones/web/pages/index.vue" <<'VUE'
<script>
export default { data: () => ({ status: 'waiting_for_images', kind: 'medical_case' }) }
</script>
VUE
: > "$b/clones/web/store/index.js"
cat > "$b/clones/web/locales/en.js" <<'JS'
export default {
  medical_cases: {
    title: 'Patient file'
  },
  notifications: {
    reminder: 'Nudge'
  }
}
JS
for r in api web; do
  git -c init.defaultBranch=staging init --quiet "$b/clones/$r"
done
gitq "$b/clones/api" add db/migrate
env GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" \
  git -C "$b/clones/api" commit --quiet -m "create aftercares" >/dev/null 2>&1
for r in api web; do
  gitq "$b/clones/$r" add -A
  gitq "$b/clones/$r" commit --quiet -m seed
done
cat > "$b/projects.yml" <<YML
api:
  repo: $b/clones/api
  default_branch: staging
web:
  repo: $b/clones/web
  default_branch: staging
YML

fp_before=$(for r in api web; do git -C "$b/clones/$r" rev-parse HEAD; git -C "$b/clones/$r" status --porcelain; done | _sha1)
first=$(bok --quiet)
fp_after=$(for r in api web; do git -C "$b/clones/$r" rev-parse HEAD; git -C "$b/clones/$r" status --porcelain; done | _sha1)

if [ "$fp_before" = "$fp_after" ]; then
  pass "drafting reads the repositories and changes nothing in them"
else
  fail "the drafter moved a repository it was only supposed to read"; fi

if [ -f "$b/okf/subsystems/api.md" ] && [ -f "$b/okf/subsystems/web.md" ]; then
  pass "one subsystem concept per configured repository"
else
  fail "a configured repository got no concept"; printf '%s\n' "$first"; fi

# The negative half is the point of the concept, so it is checked rather than
# assumed: a concept that only lists what a repository has cannot stop a wrong
# file list, and that is the whole reason for drafting one.
if grep -q 'What it does not own' "$b/okf/subsystems/web.md" \
   && grep -q 'the domain records and their migrations | api' "$b/okf/subsystems/web.md"; then
  pass "a concept says what its repository does not own, and names the one that does"
else
  fail "the drafted concept has no negative half"; sed -n '/does not own/,/^#/p' "$b/okf/subsystems/web.md"; fi

if grep -q 'waiting_for_images' "$b/okf/domain/domain-rules.md" 2>/dev/null; then
  pass "the drafted rules carry the enumerated values the code declares"
else
  fail "the drafted rules did not pick up an enum the code declares"; fi

# The whole point of the vocabulary concept: a word a person would write in a
# ticket, resolved to something worth grepping for. Both catalogues say
# "Patient file" under a key that spells medical_case, and neither of those two
# facts is interesting on its own.
# shellcheck disable=SC2016  # a markdown code span, not a variable
if grep -qE '^\| Patient file \| en \| `medical_cases?`' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; then
  pass "a product phrase both catalogues say resolves to the code key it is filed under"
else
  fail "the vocabulary draft did not resolve a phrase the catalogues corroborate"
  sed -n '/^| Product phrase/,/^$/p' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; fi
if grep -q 'en.yml' "$b/okf/domain/product-vocabulary.md" 2>/dev/null \
   && grep -q 'en.js' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; then
  pass "and it names both catalogue files it read, in their own spelling"
else
  fail "the vocabulary draft does not say which catalogues it read"; fi

printf '\n== the gap loop ranks what refinement could not resolve, and proposes ==\n'
# Same sandbox, because the whole point is that the gap loop drafts through the
# drafter rather than beside it: the concept it produces is swept by every
# check below that reads a drafted concept, and it has to be in this bundle for
# that to mean anything.
gapf="$b/gaps.jsonl"
gok() {
  env ORC_PROJECTS_FILE="$b/projects.yml" ORC_STATE_DIR="$b/state" \
      ORC_CLONE_DIR="$b/clones" ORC_GAP_LEDGER="$gapf" \
      "$ORC_ROOT/bin/orc-gap-loop.sh" --bundle "$b/okf" "$@" 2>&1
}
gapconcept="$b/okf/domain/open-vocabulary.md"

# The folding rule exists twice - once for a verdict's dozen terms and once for an
# awk over tens of thousands of catalogue strings - so something has to compare
# them. Two spellings of one rule are only safe while they are checked against
# each other.
folddis=""
while IFS= read -r probe; do
  [ -n "$probe" ] || continue
  a=$(printf '%s' "$probe" | _terms_fold)
  c=$(printf '%s\n' "$probe" | awk "$ORC_FOLD_AWK"'{ print orc_fold($0) }')
  [ "$a" = "$c" ] || folddis="$folddis
  '$probe' -> shell '$a' vs awk '$c'"
done <<'PROBES'
Follow-up case
FOLLOW_UP
Ménière
waiting_for_images
Pre-existing conditions
  leading and trailing
MedicalCase::FollowUp
Recall-file
PROBES
if [ -z "$folddis" ]; then
  pass "the shell and awk spellings of the folding rule agree on every probe"
else
  fail "the two foldings disagree, so a term matches in one place and not the other:$folddis"; fi

# The figure the README and the script header both quote, read out of the
# recordings rather than trusted. A documented count that the data contradicts is
# the failure bin/orc-locality-score.sh already exists to avoid, and re-recording
# under a new prompt is exactly when it would rot.
solved_terms=$(jq -r '(.terms_unresolved // [])[]' "$ORC_ROOT"/fixtures/solved/verdicts/*.json 2>/dev/null)
n_solved=$(printf '%s\n' "$solved_terms" | grep -c . | tr -d ' ')
n_solved_distinct=$(printf '%s\n' "$solved_terms" | awk "$ORC_FOLD_AWK"'NF { print orc_fold($0) }' \
  | sort -u | grep -c . | tr -d ' ')
undocumented=""
for doc in README.md bin/orc-gap-loop.sh; do
  grep -q "$n_solved_distinct" "$ORC_ROOT/$doc" || undocumented="$undocumented $doc"
done
if [ "$n_solved" = "$n_solved_distinct" ] && [ -z "$undocumented" ]; then
  pass "the recordings hold $n_solved unresolved term(s), all distinct, and every document that quotes that figure says $n_solved_distinct"
else
  fail "the documented gap figure is not what the recordings hold: $n_solved term(s), $n_solved_distinct distinct, missing from:$undocumented"; fi
# And the reason the default basis proposes nothing against them, stated as a
# fact about the data rather than as a guess about the loop.
if [ "$(jq -r '.locality_basis' "$ORC_ROOT"/fixtures/solved/verdicts/*.json 2>/dev/null | sort -u)" = "both" ]; then
  pass "every recording localised through the bundle, so --basis search,none matching none of them is the data rather than a bug"
else
  fail "a recording no longer localises through both; the documented reason the default basis is empty is stale"
  jq -r '"\(.key // "?") \(.locality_basis)"' "$ORC_ROOT"/fixtures/solved/verdicts/*.json; fi

# Four verdict records, written the way orc-refine.sh writes them. Two tickets
# say the same five words, so recurrence is real rather than one ticket repeating
# itself, and each of those five is stopped by a different rule or by none; two
# tickets localised through the bundle, which the default basis leaves out.
#
# Those two share a word, so the basis is a flag that changes the answer rather
# than one that only changes a count: Rebooking clears the bar under --basis
# any and is not in the table at all under the default. That is what gives the
# hint round-trip below something to be wrong about - a printed command that
# dropped the basis would come back with a different proposal.
mkverdict() {
  local key="$1" basis="$2"; shift 2
  jq -nc --arg k "$key" --arg b "$basis" \
    --argjson t "$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{key:$k, verdict:"needs_input", prompt_version:"refine-checkfix", locality_basis:$b,
      terms_unresolved:$t}' > "$b/state/$key.verdict.json"
}
mkverdict GAP-1 search "Nudge" "Recall" "Patient file" "waiting for images" "medical_case" \
                       "four words in a row here" "a term one ticket said"
mkverdict GAP-2 none   "Nudge" "Recall" "Patient file" "waiting for images" "medical_case" \
                       "four words in a row here"
mkverdict GAP-3 both   "a word only a bundle run saw" "Rebooking"
mkverdict GAP-4 both   "Rebooking"

fp_bundle() { find "$b/okf" -type f | sort | while IFS= read -r f; do printf '%s ' "$f"; _sha1 < "$f"; done | _sha1; }

before_gap=$(fp_bundle)
proposal=$(gok)

# Ranked by how many tickets said the word, not by how many times it was said.
# A word one ticket repeated five times is still one ticket's word.
if printf '%s' "$proposal" | grep -qE '^  Nudge +2 +2 +proposed'; then
  pass "a word two tickets used is ranked by tickets and proposed"
else
  fail "the recurring word was not proposed"; printf '%s\n' "$proposal" | sed -n '/TERM/,/^  ---/p'; fi
if printf '%s' "$proposal" | grep -qE '^  a term one ticket said +1 +1 +1 ticket only'; then
  pass "and a word one ticket said is excluded with that named as the reason"
else
  fail "the recurrence bar did not fire, or did not say why"
  printf '%s\n' "$proposal" | sed -n '/TERM/,/^  ---/p'; fi

# The three other ways past the bar are shut, and each says which one shut it.
# A loop that dropped these silently would read as having found nothing.
if printf '%s' "$proposal" | grep -q 'medical_case .*code-shaped'; then
  pass "a code-shaped term is excluded: an identifier is already an answer to a question nobody asked"
else
  fail "a snake_case term was not excluded as code-shaped"; fi
if printf '%s' "$proposal" | grep -q 'four words in a row here .*a sentence rather than a name'; then
  pass "a four-word term is excluded as a sentence rather than a name"
else
  fail "the word-count bar did not fire"; fi
# The one that matters most. product-vocabulary.md resolves "Patient file" and
# domain-rules.md carries waiting_for_images, so both are answered already, and a
# row for either would be a second answer to a question the bundle has settled.
if printf '%s' "$proposal" | grep -q 'Patient file .*the bundle already says it' \
   && printf '%s' "$proposal" | grep -q 'waiting for images .*the bundle already says it'; then
  pass "a word the bundle already says is excluded, folded spelling included, so no second answer is drafted"
else
  fail "a word already in the bundle was proposed again"
  printf '%s\n' "$proposal" | sed -n '/TERM/,/^  ---/p'; fi

if printf '%s' "$proposal" | grep -q 'Left out by --basis search,none: both: 2'; then
  pass "and what the basis filter left out is counted rather than silently dropped"
else
  fail "the basis filter did not say what it excluded"; fi

# Proposes, and a person consents. Without --draft nothing in the bundle moves,
# and the report still says exactly what would have been written.
if [ "$before_gap" = "$(fp_bundle)" ]; then
  pass "a run without --draft writes nothing into the bundle at all"
else
  fail "the gap loop wrote to the bundle with no --draft"; fi
if printf '%s' "$proposal" | grep -q 'domain/open-vocabulary.md .*would draft'; then
  pass "and it names the concept it would have drafted, through the drafter's own report"
else
  fail "the proposal did not say what it would draft"; printf '%s\n' "$proposal" | tail -40; fi
# Told to run the drafter, an operator would run it without --gap-terms and be
# told nothing had moved. A diagnostic that misleads is worse than none.
if printf '%s' "$proposal" | grep -q 'bin/orc-gap-loop.sh --draft'; then
  pass "the drift line names the command that would actually draft it"
else
  fail "the drift line sends the operator to a command that would draft nothing"; fi

# A hint is a thing somebody pastes, so it has to reproduce the run that printed
# it. This is the failure being checked for: a --basis any report found terms past
# the bar and printed `bin/orc-gap-loop.sh --draft`, which reran under the default
# basis, found nothing and drafted nothing.
#
# Run rather than read. A hint asserted by grep is a hint nobody tested: the
# command goes through /bin/sh, from the repository root, in the same environment
# as the run that printed it, because that is what a paste is.
run_hint() {
  ( cd "$ORC_ROOT" || exit 1
    env ORC_PROJECTS_FILE="$b/projects.yml" ORC_STATE_DIR="$b/state" \
        ORC_CLONE_DIR="$b/clones" ORC_GAP_LEDGER="$gapf" /bin/sh -c "$1" 2>&1 )
}
# Every self-naming command line in a report, not only the one that was reported
# broken: a flag added later has to be carried by all of them, and a check that
# named one hint would go stale the first time a second was written.
hint_lines() { printf '%s\n' "$1" | sed -n 's/^ *\(bin\/orc-gap-loop\.sh .*\)$/\1/p'; }

rt=$(gok --basis any --min-tickets 2)
rt_hints=$(hint_lines "$rt")
rt_bare=$(printf '%s\n' "$rt_hints" | grep -vc -- '--basis any .*--min-tickets 2' | tr -d ' ')
if [ "$(printf '%s\n' "$rt_hints" | grep -c .)" -ge 2 ] && [ "$rt_bare" = "0" ]; then
  pass "every command a report prints carries the flags that run was given"
else
  fail "a printed command dropped a flag the run was given, so it reproduces a different run"
  printf '%s\n' "$rt_hints"; fi

# The proposal the printed --terms command comes back with is the proposal the
# report it was printed under proposed. Rebooking is in that set only because
# --basis any was passed, so a hint that dropped it comes back two terms short.
rt_expected=$(printf '%s\n' "$rt" \
  | sed -n 's/^  \(.*[^ ]\) \{1,\}[0-9]\{1,\} \{1,\}[0-9]\{1,\} \{1,\}proposed$/\1/p' | sort)
rt_actual=$(run_hint "$(hint_lines "$rt" | grep -- '--terms' | head -1)" | sort)
if [ -n "$rt_expected" ] && [ "$rt_expected" = "$rt_actual" ] \
   && printf '%s\n' "$rt_expected" | grep -q Rebooking; then
  pass "and pasting the --terms command it prints reproduces that report's own proposal"
else
  fail "the printed --terms command does not reproduce the proposal it was printed under"
  printf '  proposed: %s\n  the hint came back with: %s\n' "$(printf '%s' "$rt_expected" | tr '\n' ',')" \
    "$(printf '%s' "$rt_actual" | tr '\n' ',')"; fi

# The other direction, and the one an operator meets first: a default-basis report
# says what the filter left out and offers the command that counts it. Pasted, it
# has to find the term the default basis hid.
rt_widen=$(run_hint "$(hint_lines "$proposal" | grep -- '--basis any' | head -1)")
rt_widened=$(printf '%s\n' "$rt_widen" \
  | sed -n 's/^  \(.*[^ ]\) \{1,\}[0-9]\{1,\} \{1,\}[0-9]\{1,\} \{1,\}proposed$/\1/p' | sort)
if [ "$rt_widened" = "$rt_expected" ]; then
  pass "and the command the basis line offers widens the basis it was printed under"
else
  fail "the command offered for the runs the basis filter left out proposes something else"
  printf '  offered: %s\n  --basis any proposes: %s\n' "$(printf '%s' "$rt_widened" | tr '\n' ',')" \
    "$(printf '%s' "$rt_expected" | tr '\n' ',')"; fi

# A bar an operator can set to one is not a bar.
lowered=$(gok --min-tickets 1 2>&1)
if printf '%s' "$lowered" | grep -q 'may be raised and not lowered'; then
  pass "the recurrence bar can be raised and refuses to be lowered"
else
  fail "--min-tickets 1 was accepted"; printf '%s\n' "$lowered" | tail -5; fi

drafted=$(gok --draft)
if [ -f "$gapconcept" ]; then
  pass "--draft writes the concept"
else
  fail "--draft drafted nothing"; printf '%s\n' "$drafted" | tail -40; fi

# One drafting path. Two things that write concepts would disagree eventually,
# and then nobody could say which produced what - so the file the gap loop
# produced has to carry the drafter's producer and no other.
if [ "$(grep -c 'process:orc-okf-draft' "$gapconcept" 2>/dev/null)" = "1" ] \
   && ! grep -q 'process:orc-gap-loop' "$gapconcept" 2>/dev/null; then
  pass "and it was written by the one thing that drafts concepts, not by a second path"
else
  fail "the gap concept names a producer that is not the drafter"
  grep -n 'process:' "$gapconcept" 2>/dev/null; fi
if grep -qE '^generated:' "$gapconcept" 2>/dev/null && ! grep -qE '^verified:' "$gapconcept" 2>/dev/null; then
  pass "it carries generated: and does not claim verified:, which is what makes it a lead"
else
  fail "the gap concept's provenance claims more than it has"; fi

# Evidence decides what a row says, and never how often the word came up. Both
# of these recur exactly as often as each other.
# shellcheck disable=SC2016  # a markdown code span, not a substitution
if grep -q 'Nudge | 2 | 2 repositories say the word (api, web), under `notifications.reminder`' "$gapconcept" 2>/dev/null; then
  pass "a word both catalogues say is reported as corroborated, with the repositories and the key named"
else
  fail "the corroborated word's row does not name its evidence"
  sed -n '/^| Word/,/^$/p' "$gapconcept" 2>/dev/null; fi
if grep -q 'Recall | 2 | No configured repository says it at all' "$gapconcept" 2>/dev/null; then
  pass "and a word no repository says is said to be unestablished rather than resolved"
else
  fail "a word with no evidence was given a meaning"
  sed -n '/^| Word/,/^$/p' "$gapconcept" 2>/dev/null; fi
# Neither of the two rows resolves, and the concept says so where the numbers are
# rather than leaving a reader to count. A table of questions that read as answers
# is the failure this whole line exists to prevent.
if grep -q 'Of the 2 words on it, 0 resolve' "$gapconcept" 2>/dev/null; then
  pass "the concept counts how many of its own rows resolve, in the overview"
else
  fail "the concept does not say how much of itself is an answer"; fi

# The self-poisoning shape: the concept is in the bundle, so a second run would
# find every word it drafted already said there and re-draft the file empty.
second=$(gok --draft)
if grep -q 'Nudge' "$gapconcept" 2>/dev/null \
   && printf '%s' "$second" | grep -q 'domain/open-vocabulary.md *unchanged'; then
  pass "a second run is a no-op: the concept does not count as the bundle already saying its own words"
else
  fail "the gap concept was rewritten by its own output"; printf '%s\n' "$second" | tail -30; fi

# A concept a human verified is theirs, and there is no flag here that overrules
# that. The edit below is what a person's review looks like: a date, and a row
# they changed.
awk '{ print } /^status: draft$/ { print "verified:"; print "  by: person:checkfix"; print "  at: 2026-01-01" }' \
  "$gapconcept" | sed 's/| Nudge | 2 |/| Nudge (checked) | 2 |/' > "$b/verified-gap"
cp "$b/verified-gap" "$gapconcept"
sum_verified=$(_sha1 < "$gapconcept")
overruled=$(gok --draft)
if [ "$(_sha1 < "$gapconcept")" = "$sum_verified" ]; then
  pass "a verified gap concept is left byte-identical, its edited row included"
else
  fail "the gap loop wrote over a concept a human had verified"
  diff <(cat "$b/verified-gap") "$gapconcept" | head -20; fi
if printf '%s' "$overruled" | grep -q 'domain/open-vocabulary.md *SKIPPED'; then
  pass "and it is reported as skipped rather than passed over in silence"
else
  fail "the refusal was silent"; printf '%s\n' "$overruled" | tail -30; fi
if grep -nE -- '--force|--overwrite|--replace' "$ORC_ROOT/bin/orc-gap-loop.sh" | code_only | grep -q .; then
  fail "bin/orc-gap-loop.sh has a flag that could overrule that refusal"
else
  pass "and there is no flag on the gap loop that could overrule it"
fi
# Back to a draft, so the sweeps further down read a drafted concept rather than
# a hand-verified one. Removed and re-drafted rather than unpicked: the loop
# excludes the concept it owns from its own reading, so what it drafts a second
# time is what it drafted the first time.
rm -f "$gapconcept"
gok --draft >/dev/null 2>&1

# The record. terms_unresolved is in state/ and nowhere else, and reconcile
# cannot rebuild it from a comment that deliberately carries no term list - so a
# loop reading history needs a record outside the cache, and a reset has to say
# what it is about to make unrecoverable.
if [ -f "$gapf" ] && [ "$(grep -c . "$gapf")" = "4" ]; then
  pass "every recorded run is copied into a ledger outside state/, one line each"
else
  fail "the ledger did not record the runs"; ls -l "$gapf" 2>/dev/null; fi
rm -f "$b"/state/GAP-*.verdict.json
survives=$(gok)
if printf '%s' "$survives" | grep -qE '^  Nudge +2 +2'; then
  pass "and the ranking still holds after the cache the observations came from is gone"
else
  fail "clearing state/ lost the ranking the ledger was supposed to keep"
  printf '%s\n' "$survives" | sed -n '/TERM/,/^  ---/p'; fi

# "state/ is disposable" is true for the phase and the verdict name, which
# reconcile rebuilds from labels, and false for the rest of the verdict record -
# locality, files, subsystems, terms_resolved and terms_unresolved - which a
# needs_input or duplicate comment carries none of by design. The README is where
# that exception is written down, so that is what is checked.
# shellcheck disable=SC2016  # markdown code spans, not variables
if grep -qF 'disposable for the phase and the verdict name' "$ORC_ROOT/README.md" \
   && grep -qF 'locality, files, subsystems and `terms_resolved` are exactly as' "$ORC_ROOT/README.md"; then
  pass "README.md names the verdict-record exception to \"state/ is disposable\""
else
  fail "README.md no longer names locality/files/subsystems/terms_resolved as unrebuildable after a state/ wipe"
fi

# A comment above a constant is the only written explanation of a domain decision
# there is, and paraphrasing it would be this script deciding what the domain
# means. So it is quoted, and the check is byte-for-byte.
if grep -qF 'A follow-up is offered only for these, and unlocked by hand.' \
     "$b/okf/domain/domain-rules.md" 2>/dev/null; then
  pass "a constant's comment is quoted verbatim rather than paraphrased"
else
  fail "the comment above a constant did not survive into the draft"; fi
# shellcheck disable=SC2016  # markdown code spans, not variables
if grep -q 'At most one row per `main_case_id` where `(started_case_id IS NULL)`' \
     "$b/okf/domain/domain-rules.md" 2>/dev/null; then
  pass "a partial unique index is drafted as the rule it is, not as a line of schema"
else
  fail "the partial unique index did not become a rule"
  sed -n '/Where the schema is the rule/,$p' "$b/okf/domain/domain-rules.md" 2>/dev/null; fi
if grep -q 'Refuses to exist without:.*main_case_id' "$b/okf/domain/domain-rules.md" 2>/dev/null; then
  pass "and the required columns of that same table come with it"
else
  fail "the required columns of a ruled table were dropped"; fi

# The ambiguity that decides a verdict: one word, two meanings, and a draft that
# picks either one is worse than no draft. Nomination is somebody's deliberate
# act - a scope that excludes the term - never an inference from a date.
if grep -q 'not live' "$b/okf/domain/product-vocabulary.md" 2>/dev/null \
   && grep -q 'without_legacy_aftercares' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; then
  pass "a term live code filters out is reported as not established, and the filter is named"
else
  fail "the retirement signal in the fixture was not reported"
  sed -n '/not live/,$p' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; fi
if grep -q '2020-01-01' "$b/okf/domain/product-vocabulary.md" 2>/dev/null; then
  pass "with the date of the last commit that touched it, which is the cold measurement"
else
  fail "the retirement row does not say how cold the term is"; fi
if grep -q "which meaning the reporter had in mind" "$b/okf/domain/product-vocabulary.md" 2>/dev/null; then
  pass "and it says plainly that it cannot say which meaning was meant"
else
  fail "the retirement section asserts a meaning instead of naming the hole"; fi

# Every concept says what it could not work out. A drafted concept that reads as
# complete is the failure mode this replaced: it fills the space with paths, and
# a reader cannot tell a fact from a gap.
holeless=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -q 'could not determine' "$f" || holeless="$holeless ${f#"$b/okf/"}"
done <<< "$(grep -rl 'process:orc-okf-draft' "$b/okf" 2>/dev/null | grep -v 'index\.md' | sort)"
if [ -z "$holeless" ]; then
  pass "every drafted concept names what it could not determine"
else
  fail "a drafted concept reads as complete:$holeless"; fi

# Nothing in a concept names a commit. Drift is decided by re-rendering and
# comparing bytes, so a sha in a concept means every push to any repository marks
# every concept stale while nothing about its meaning moved.
apihead=$(git -C "$b/clones/api" rev-parse HEAD)
pinned=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qF "${apihead:0:12}" "$f" && pinned="$pinned ${f#"$b/okf/"}(sha)"
  grep -qE '(commit|at) [0-9a-f]{7,40}([^0-9a-z]|$)' "$f" && pinned="$pinned ${f#"$b/okf/"}(prose)"
done <<< "$(grep -rl 'process:orc-okf-draft' "$b/okf" 2>/dev/null | sort)"
if [ -z "$pinned" ]; then
  pass "no drafted concept pins a commit, so a push cannot make one stale"
else
  fail "a drafted concept names a commit:$pinned"; fi

# A source has to be fetchable by somebody who is not this machine. The defect:
# resource: "every path named below, as it exists in mobile at bf45e1c1" - a
# sentence describing what was read, which nobody can follow. A URL and a path
# have no spaces in them; a sentence always does.
prose=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in *" "*) prose="$prose
  ${f#"$b/okf/"}: $r" ;; esac
  done <<< "$(awk '/^sources:/ { ins = 1; next } ins && /^[^ ]/ { exit } ins && /^    resource:/ {
                     r = $0; sub(/^    resource:[[:space:]]*/, "", r); gsub(/^"|"$/, "", r); print r }' "$f")"
done <<< "$(grep -rl 'process:orc-okf-draft' "$b/okf" 2>/dev/null | sort)"
if [ -z "$prose" ]; then
  pass "every drafted source resource is an address rather than a sentence about one"
else
  fail "a drafted source cannot be followed:$prose"; fi

drafts=$(grep -rl 'process:orc-okf-draft' "$b/okf" 2>/dev/null | sort)
if [ -n "$drafts" ]; then
  pass "the drafts say who produced them, in §7's spelling ($(printf '%s' "$drafts" | grep -c .) concept(s))"
else
  fail "nothing in the bundle says it was drafted"; fi

bad=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  fm=$(awk 'NR == 1 && $0 == "---" { inf = 1; next } inf && $0 == "---" { exit } inf' "$f")
  printf '%s' "$fm" | grep -qE '^sources:'   || bad="$bad
  ${f#"$b/okf/"} has no sources:"
  printf '%s' "$fm" | grep -qE '^generated:' || bad="$bad
  ${f#"$b/okf/"} has no generated:"
  printf '%s' "$fm" | grep -qE '^verified:'  && bad="$bad
  ${f#"$b/okf/"} claims to be verified, and nothing drafted may"
done <<< "$drafts"
if [ -n "$bad" ]; then fail "a drafted concept's provenance is wrong:$bad"; else
  pass "every draft carries sources: and generated:, and not one claims verified:"; fi

# A source nothing cites is provenance theatre, so the join is checked in the
# direction lint cannot see from here.
uncited=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -q "\[^$id\]" "$f" || uncited="$uncited ${f#"$b/okf/"}:$id"
  done <<< "$(awk '/^sources:/ { ins = 1; next } ins && /^[^ ]/ { exit } ins && /^  - id:/ { print $3 }' "$f")"
done <<< "$drafts"
if [ -n "$uncited" ]; then fail "a drafted source is never cited in the body:$uncited"; else
  pass "every drafted source is cited by a footnote in the body it supports"; fi

before=$(bhash)
second=$(bok --quiet)
if [ "$before" = "$(bhash)" ]; then
  pass "a second run changes nothing: same evidence, same file, same generated date"
else
  fail "the second run rewrote the bundle"; printf '%s\n' "$second"; fi
if printf '%s' "$second" | grep -q 'drafted=0 updated=0'; then
  pass "and it says so, rather than reporting work it did not do"
else
  fail "the second run reported drafting or updating"; printf '%s\n' "$second"; fi

if bok --check --quiet >/dev/null 2>&1; then
  pass "--check agrees the bundle is what the repositories say"
else
  fail "--check reports drift against a bundle it just wrote"; fi

# The reason the commit pinning went. A repository advances by a commit that
# touches no domain constant, no enum, no schema constraint and no string: every
# concept means exactly what it meant before, so every concept must report
# unchanged. When a sha was in the frontmatter this was drift on all of them, and
# --check said so on every push until nobody read it.
: > "$b/clones/api/app/controllers/reports_controller.rb"
gitq "$b/clones/api" add -A
gitq "$b/clones/api" commit --quiet -m "a commit that changes no meaning"
before=$(bhash)
if bok --check --quiet >/dev/null 2>&1; then
  pass "a commit that moves no evidence is not drift"
else
  fail "--check calls an unrelated commit drift"; bok --check --quiet | sed -n '/would/p'; fi
quiet_run=$(bok --quiet)
if [ "$before" = "$(bhash)" ]; then
  pass "and a rerun rewrites nothing, so the generated dates hold"
else
  fail "an unrelated commit rewrote the bundle"; printf '%s\n' "$quiet_run"; fi

# The other direction, because a check that cannot fail is not a check: move one
# string in one catalogue and the vocabulary concept has to notice.
printf '    subtitle: Kurzfall\n' >> "$b/clones/api/config/locales/de.yml"
gitq "$b/clones/api" add -A
gitq "$b/clones/api" commit --quiet -m "a commit that changes a string"
if bok --check --quiet >/dev/null 2>&1; then
  fail "a catalogue change is not reported as drift"
else
  pass "and a catalogue change is drift, so the stability above is not just blindness"
fi
gitq "$b/clones/api" revert --no-edit --quiet HEAD >/dev/null
bok --quiet >/dev/null 2>&1

printf '\n== a reporter answer becomes a drafted row, never a verified one ==\n'
# Four Jira tickets, built through the same ADF builders refinement posts with,
# so what the harvest reads is the shape a real comment arrives in rather than a
# shape written to be readable by the thing being tested.
h=$(mktemp -d)
mkdir -p "$h/fx/issues" "$h/fx/search" "$h/state" "$h/hokf/domain" "$h/hokf/subsystems"
: > "$h/projects.yml"

hq() {   # <created> <question…> -> the orchestrator's own comment
  local at="$1" doc; shift
  doc=$(adf_new)
  doc=$(adf_heading "$doc" 3 "Refinement: this needs a little more before an agent can pick it up")
  doc=$(adf_para "$doc" "Answering these in the description is enough to unblock it:")
  doc=$(adf_ordered "$doc" "$(printf '%s\n' "$@")")
  doc=$(adf_para_em "$doc" "$ORC_COMMENT_MARKER prompt=refine-check ticket-rev=abc123def456")
  jq -nc --argjson c "$doc" --arg t "$at" '{id:"1", created:$t, updated:$t,
    author:{accountId:"orc-service-account", displayName:"Orchestrator"},
    body:{type:"doc", version:1, content:$c}}'
}
hp() {   # <id> <created> <who> <paragraph…> -> somebody's reply, as paragraphs
  local id="$1" at="$2" who="$3" doc t; shift 3
  doc=$(adf_new)
  for t in "$@"; do doc=$(adf_para "$doc" "$t"); done
  jq -nc --argjson c "$doc" --arg i "$id" --arg t "$at" --arg w "$who" '{id:$i, created:$t, updated:$t,
    author:{accountId:("acct-" + $w), displayName:$w}, body:{type:"doc", version:1, content:$c}}'
}
hl() {   # <id> <created> <who> <item…> -> somebody's reply, as a numbered list
  local id="$1" at="$2" who="$3" doc; shift 3
  doc=$(adf_ordered "$(adf_new)" "$(printf '%s\n' "$@")")
  jq -nc --argjson c "$doc" --arg i "$id" --arg t "$at" --arg w "$who" '{id:$i, created:$t, updated:$t,
    author:{accountId:("acct-" + $w), displayName:$w}, body:{type:"doc", version:1, content:$c}}'
}
hreask() {   # <id> <created> <question…> -> the orchestrator's own ask-again comment
  local id="$1" at="$2" doc; shift 2
  doc=$(adf_new)
  doc=$(adf_heading "$doc" 3 "Refinement: still not clear")
  doc=$(adf_para "$doc" "Your last reply didn't make this clear enough to act on. Could you answer directly:")
  doc=$(adf_ordered "$doc" "$(printf '%s\n' "$@")")
  doc=$(adf_para_em "$doc" "$ORC_COMMENT_MARKER prompt=refine-check ticket-rev=abc123def456 reask=1")
  jq -nc --argjson c "$doc" --arg i "$id" --arg t "$at" '{id:$i, created:$t, updated:$t,
    author:{accountId:"orc-service-account", displayName:"Orchestrator"},
    body:{type:"doc", version:1, content:$c}}'
}
hissue() {  # <key> <comment-json…>
  local key="$1"; shift
  jq -n --arg k "$key" --argjson c "$(printf '%s\n' "$@" | jq -sc .)" '{
    id:"1", key:$k, fields:{summary:("about " + $k), labels:["needs-refinement"],
    updated:"2026-08-16T10:15:00.000+0200", comment:{comments:$c, total:($c|length)}}}' \
    > "$h/fx/issues/$key.json"
}
hissue_desc() {  # <key> <description> <comment-json…>
  local key="$1" desc="$2"; shift 2
  jq -n --arg k "$key" --arg d "$desc" --argjson c "$(printf '%s\n' "$@" | jq -sc .)" '{
    id:"1", key:$k, fields:{summary:("about " + $k), description:$d, labels:["needs-refinement"],
    updated:"2026-08-16T10:15:00.000+0200", comment:{comments:$c, total:($c|length)}}}' \
    > "$h/fx/issues/$key.json"
}

# HARV-1 is the whole matching table in one ticket: a comment that predates the
# question, a three-item list against three questions, a "Re 1:" that disagrees
# with the first of them, and a number nobody asked.
hissue HARV-1 \
  "$(hp 100 2026-08-14T07:00:00.000+0200 "Ute Berg" "This started this morning and it is bad.")" \
  "$(hq 2026-08-14T08:00:00.000+0200 \
      "Which case list do you mean: the one a doctor opens, or the one support works from?" \
      "What does broken look like on the screen?" \
      "Since when, and did anything change on your side?")" \
  "$(hl 101 2026-08-14T09:00:00.000+0200 "Tomas Weber" \
      "The one a doctor opens after logging in." \
      "A spinner and then nothing at all." \
      "Since Tuesday morning.")" \
  "$(hp 102 2026-08-14T10:00:00.000+0200 "Alina Roth" \
      "Re 1: the support queue, not the doctor one.")" \
  "$(hp 103 2026-08-14T11:00:00.000+0200 "Alina Roth" \
      "7. and the export is slow as well, while we are here.")"

# One question, answered in prose that addresses nothing. There is only one thing
# it can be about.
hissue HARV-2 \
  "$(hq 2026-08-14T08:00:00.000+0200 "Is this one piece of work or two?")" \
  "$(hp 110 2026-08-14T09:00:00.000+0200 "Marie Dubois" "Treat it as one for now, support wants both in the same release.")"

# The same person twice, saying two different things. That is a correction or an
# afterthought, and calling it a disagreement would put a banner on somebody
# thinking out loud.
hissue HARV-3 \
  "$(hq 2026-08-14T08:00:00.000+0200 "Which surface is this about?")" \
  "$(hp 120 2026-08-14T09:00:00.000+0200 "Jan Kraus" "The web one.")" \
  "$(hp 121 2026-08-14T10:00:00.000+0200 "Jan Kraus" "Sorry, the mobile one.")"

# Asked and never answered.
hissue HARV-4 \
  "$(hq 2026-08-14T08:00:00.000+0200 "Who is allowed to see this?" "By when do you need it?")"

# Three questions, answered in one paragraph with no numbering and no list at
# all - the case address-matching drops on the floor and reading-for-meaning
# exists for. Two of the three questions share distinctive words with a
# sentence in the reply; the third shares nothing with any sentence and stays
# unanswered, because partial attribution is normal rather than a failure to
# parse the rest.
hissue HARV-5 \
  "$(hq 2026-08-14T08:00:00.000+0200 \
      "Which browser were you using?" \
      "Was the export button greyed out, or just slow?" \
      "Did this happen for every patient, or just one?")" \
  "$(hp 130 2026-08-14T09:00:00.000+0200 "Nora Lang" \
      "I was using Chrome. The export button was greyed out completely, not just slow to respond.")"

# A reply nobody could understand at all - no address, and nothing it shares
# with either question. Eligible to be asked again.
hissue HARV-6 \
  "$(hq 2026-08-14T08:00:00.000+0200 "Which browser were you using?" "Was the export button greyed out?")" \
  "$(hp 300 2026-08-14T09:00:00.000+0200 "Otto Vogel" "1988 was the year this all began, honestly.")"

# Already asked again once - the reask comment carries reask=1 - and the reply
# after it is still unattributed. The ask-once bound means this is reported,
# not asked a third time.
hissue HARV-7 \
  "$(hq 2026-08-14T08:00:00.000+0200 "Which browser were you using?" "Was the export button greyed out?")" \
  "$(hp 400 2026-08-14T09:00:00.000+0200 "Lena Fuchs" "Not sure honestly, it just broke.")" \
  "$(hreask 401 2026-08-14T09:30:00.000+0200 "Which browser were you using?" "Was the export button greyed out?")" \
  "$(hp 402 2026-08-14T10:00:00.000+0200 "Lena Fuchs" "Still the same weirdness as before, sorry.")"

# Matched cleanly to the only question there was - by every one of the four
# address rules - and settles nothing. Not drafted, and eligible for the same
# asking-again machinery an unattributed reply already has.
hissue HARV-8 \
  "$(hq 2026-08-14T08:00:00.000+0200 "What should the price be for a same-day change?")" \
  "$(hp 500 2026-08-14T09:00:00.000+0200 "Iris Sanne" "Whatever's easiest for engineering, honestly.")"

# The control this needs: just as short as HARV-8's reply, and a real decision.
# Resolution, not length, is what the check reads.
hissue HARV-9 \
  "$(hq 2026-08-14T08:00:00.000+0200 "What should the price be for a next-day reschedule?")" \
  "$(hp 501 2026-08-14T09:00:00.000+0200 "Iris Sanne" "19 euros.")"

# A decisive answer that names a different figure from the ticket's own
# description for what reads as the same subject. Still drafted - it is a real
# answer, not a deferral - but the row carries the disagreement rather than
# looking like an ordinary settled fact.
hissue_desc HARV-10 \
  "Currently a same-day reschedule costs 19 euros as a rush fee, and support has been quoting that to customers for months." \
  "$(hq 2026-08-14T08:00:00.000+0200 "What should the rush fee be for a same-day reschedule?")" \
  "$(hp 502 2026-08-14T09:00:00.000+0200 "Iris Sanne" "Let's raise it to 25 euros starting next release.")"

# A numbered answer is a run of paragraphs, not the line the number is on. The
# shape is the one a real reporter wrote: a preamble addressing nothing, a
# one-paragraph answer to 1, an answer to 3 whose substance is the three
# paragraphs underneath it, and a sign-off. Question 2 is never addressed.
# Everything this fixture is for is here at once: the run, the untouched
# question in the middle of it, the preamble that belongs to no ordinal, the
# sign-off that belongs to the last one, and a single-paragraph numbered
# answer that must come out exactly as it always did.
hissue HARV-12 \
  "$(hq 2026-08-14T08:00:00.000+0200 \
      "Who may see the new step?" \
      "How long should the reminder wait before it fires?" \
      "What wording should the new photo instructions use?")" \
  "$(hp 700 2026-08-14T09:00:00.000+0200 "Ute Berg" \
      "Thanks for the questions, here are the answers." \
      "1. Everyone who can already open a case." \
      "3. I will give you the wording. Here it is, in the order the assistant shows it:" \
      "Please photograph the affected area from about 30 centimetres first." \
      "Then take a close-up of the same area." \
      "Finally, hold a ruler beside it so the size is clear." \
      "That is all of it, shout if anything is unclear.")"

# Ordinals out of the order they were asked in, and one of them addressed
# twice. Order is the reply's own order, so each address opens its answer where
# it stands, and the two pieces of question two are one answer joined in the
# order they were written.
hissue HARV-13 \
  "$(hq 2026-08-14T08:00:00.000+0200 \
      "Which depot should hold the spare?" \
      "How many spares should each depot keep?")" \
  "$(hp 710 2026-08-14T09:00:00.000+0200 "Bruno Halle" \
      "2. Two spares per depot." \
      "1. The northern depot, it has the space." \
      "2. Sorry, make that three spares for the northern one.")"

# A numbered answer that opens by deciding and hands the decision back further
# down. Only the wider scope sees it, and seeing it is the point: those later
# paragraphs are on the row now, so a gate reading the opening alone would let
# them past without looking.
hissue HARV-14 \
  "$(hq 2026-08-14T08:00:00.000+0200 \
      "What should the express surcharge be?" \
      "Which depots should offer it?")" \
  "$(hp 720 2026-08-14T09:00:00.000+0200 "Iris Sanne" \
      "1. Let's say 19 euros." \
      "Actually, on reflection, whatever's easiest for engineering.")"

jq -n '{isLast:true, issues:[{key:"HARV-1"},{key:"HARV-2"},{key:"HARV-3"},{key:"HARV-4"},{key:"HARV-5"},{key:"HARV-6"},{key:"HARV-7"},{key:"HARV-8"},{key:"HARV-9"},{key:"HARV-10"},{key:"HARV-12"},{key:"HARV-13"},{key:"HARV-14"}]}' \
  > "$h/fx/search/project-issues.json"

# A concept a human signed that says one of the words refinement could not
# resolve on HARV-1. That collision is the loudest thing this pass can produce,
# and it is only interesting because the concept is verified.
cat > "$h/hokf/subsystems/queue.md" <<'MD'
---
type: Subsystem
title: The doctor queue
description: "What a doctor opens after logging in."
verified: { by: person:checkfix, at: 2026-01-01 }
---

# Overview

The case list a doctor opens is the doctor queue.
MD
jq -n '{key:"HARV-1", prompt_version:"refine-check", verdict:"needs_input",
        locality_basis:"none", terms_unresolved:["case list"]}' > "$h/state/HARV-1.verdict.json"

hrun() {
  env ORC_FIXTURE_DIR="$h/fx" ORC_STATE_DIR="$h/state" ORC_PROJECTS_FILE="$h/projects.yml" \
      ORC_CLONE_DIR="$h/clones" ORC_GAP_LEDGER="$h/no-such-ledger.jsonl" \
      "$ORC_ROOT/bin/orc-harvest.sh" --bundle "$h/hokf" "$@" 2>&1
}
hconcept="$h/hokf/domain/reporter-answers.md"
hhash() { find "$h/hokf" -type f | sort | while IFS= read -r f; do printf '%s ' "$f"; _sha1 < "$f"; done | _sha1; }

before_harvest=$(hhash)
rows=$(hrun --rows)
report=$(hrun)

hrow() { printf '%s\n' "$rows" | awk -F'\002' -v k="$1" -v n="$2" '$1 == k && $2 ~ n'; }

# The matching rules, each named on the row it produced. A pass that
# attributed by meaning rather than by address would produce the same rows here
# and different ones on a comment nobody wrote for it.
if [ "$(hrow HARV-1 '^Which case list' | awk -F'\002' '$5 == "Tomas Weber" { print $7 }')" = "by position" ]; then
  pass "a numbered list with as many items as there were questions answers them by position"
else
  fail "the positional rule did not fire"; printf '%s\n' "$rows" | cat -v | head -10; fi
if [ "$(hrow HARV-1 '^Which case list' | awk -F'\002' '$5 == "Alina Roth" { print $7 }')" = "by number" ]; then
  pass "and a reply opening \"Re 1:\" answers question one, whichever of the address forms it uses"
else
  fail "an explicit number was not read as an address"; printf '%s\n' "$rows" | cat -v | head -10; fi
if [ "$(hrow HARV-2 '^Is this one piece' | awk -F'\002' '{ print $7 }')" = "the only question" ]; then
  pass "a reply that addresses nothing answers the question when there was only one"
else
  fail "the sole-question rule did not fire"; printf '%s\n' "$rows" | cat -v | head -10; fi

# A numbered answer is the run of blocks it opened, not the line the number was
# on. Before this, everything under "3." was dropped: the row read "I will give
# you the wording. Here it is:" and the three paragraphs of wording it
# introduced were gone, while `verbatim` carried them the whole time. A round
# later the refiner said the wording had been promised and nothing had it
# written down, which was true of what it was handed and false of the world.
h12_q3=$(hrow HARV-12 '^What wording should' | awk -F'\002' '{ print $4 }')
if [ "$h12_q3" = "I will give you the wording. Here it is, in the order the assistant shows it: Please photograph the affected area from about 30 centimetres first. Then take a close-up of the same area. Finally, hold a ruler beside it so the size is clear. That is all of it, shout if anything is unclear." ]; then
  pass "a numbered answer keeps every paragraph it opened, in the order they were written"
else
  fail "a numbered answer was truncated to the paragraph carrying its number"
  printf '%s\n' "$h12_q3" | cat -v; fi

# The three boundaries, each asserted where getting it wrong would be silent.
if [ "$(hrow HARV-12 '^Who may see' | awk -F'\002' '{ print $4 }')" = "Everyone who can already open a case." ]; then
  pass "and the run ends where the reply addresses the next question, so a single-paragraph answer is exactly what it was"
else
  fail "a single-paragraph numbered answer swallowed the paragraphs of the next one"
  hrow HARV-12 '^Who may see' | cat -v; fi
if [ -z "$(hrow HARV-12 '^How long should the reminder')" ] \
   && ! hrow HARV-12 '^Who may see' | awk -F'\002' '{ print $4 }' | grep -q 'centimetres' \
   && printf '%s' "$report" | grep -q 'How long should the reminder'; then
  pass "a question the reply never numbered is attributed nothing, and no run bleeds into it"
else
  fail "a question the reply never touched was answered by a greedy boundary"
  printf '%s\n' "$rows" | grep HARV-12 | cat -v; fi
if ! hrow HARV-12 '^Who may see' | awk -F'\002' '{ print $4 }' | grep -q 'Thanks for the questions' \
   && ! hrow HARV-12 '^What wording should' | awk -F'\002' '{ print $4 }' | grep -q 'Thanks for the questions' \
   && [ -n "$(hrow HARV-12 '^Who may see' | awk -F'\002' '$8 ~ /Thanks for the questions/')" ]; then
  pass "a preamble written before the reply addressed anything belongs to no answer, and stays on the verbatim reply"
else
  fail "the preamble was attributed to an ordinal, or dropped from the reply as well"
  hrow HARV-12 '^Who may see' | cat -v; fi

# Out of order, and one ordinal twice. The reply's own order decides where each
# run opens and ends; the ordinal's value decides nothing.
if [ "$(hrow HARV-13 '^Which depot' | awk -F'\002' '{ print $4 }')" = "The northern depot, it has the space." ]; then
  pass "an ordinal addressed after a higher one opens its answer where it stands"
else
  fail "an out-of-order ordinal was mis-bounded"; hrow HARV-13 '^Which depot' | cat -v; fi
h13_q2=$(hrow HARV-13 '^How many spares' | awk -F'\002' '{ print $4 }')
if [ "$h13_q2" = "Two spares per depot. Sorry, make that three spares for the northern one." ]; then
  pass "and an ordinal addressed twice in one reply is one answer in two pieces, joined in the order written"
else
  fail "a repeated ordinal produced two rows, or lost one of its pieces"
  printf '%s\n' "$h13_q2" | cat -v; fi
if [ "$(hrow HARV-13 '^How many spares' | grep -c .)" = "1" ]; then
  pass "so one person adding to what they said is one answer, not a contested question"
else
  fail "one person addressing an ordinal twice was read as two people"
  hrow HARV-13 '^How many spares' | cat -v; fi

# The fallback: three questions, one paragraph, no numbering and no list -
# exactly the shape address-matching drops on the floor. Two of the three
# questions get an answer, and the third does not, because partial attribution
# is normal rather than a failure to parse the rest of the paragraph.
if [ "$(hrow HARV-5 '^Which browser' | awk -F'\002' '{ print $7 }')" = "by reading" ] \
   && [ "$(hrow HARV-5 '^Which browser' | awk -F'\002' '{ print $4 }')" = "I was using Chrome" ]; then
  pass "a question answered only in prose, with nothing addressing it, is matched by reading"
else
  fail "the reading fallback did not fire, or extracted the wrong fragment"
  hrow HARV-5 '^Which browser' | cat -v; fi
if [ "$(hrow HARV-5 '^Was the export button' | awk -F'\002' '{ print $7 }')" = "by reading" ] \
   && [ "$(hrow HARV-5 '^Was the export button' | awk -F'\002' '{ print $4 }')" \
        = "The export button was greyed out completely, not just slow to respond" ]; then
  pass "and a second sentence in the same paragraph is matched to the question it actually answers"
else
  fail "the second sentence was not attributed, or was attributed to the wrong question"
  hrow HARV-5 '^Was the export button' | cat -v; fi
if printf '%s' "$report" | grep -q 'Did this happen for every patient' \
   && printf '%s' "$report" | grep -q 'still unanswered' \
   && ! printf '%s\n' "$rows" | grep -q 'Did this happen for every patient'; then
  pass "the third question, which the paragraph never touches, is reported as unanswered rather than guessed at"
else
  fail "a question nothing addressed was drafted, or the fallback fabricated an answer for it"
  printf '%s\n' "$report" | head -40; fi
if [ "$(hrow HARV-5 '^Which browser' | awk -F'\002' '{ print $8 }')" \
     = "I was using Chrome. The export button was greyed out completely, not just slow to respond." ]; then
  pass "every row also carries the whole reply it was drawn from, unedited, alongside the extracted fragment"
else
  fail "the row lost the verbatim reply it was matched from"
  hrow HARV-5 '^Which browser' | cat -v; fi

# The two ways a comment is deliberately not attributed. Both are the same
# decision: a row whose question is a guess is worse than no row.
if printf '%s' "$report" | grep -q 'the export is slow as well' \
   && ! printf '%s\n' "$rows" | grep -q 'the export is slow'; then
  pass "a number nobody asked addresses nothing: the comment is reported and not drafted"
else
  fail "an out-of-range number was read as an address"; printf '%s\n' "$rows" | cat -v | head -10; fi
if ! printf '%s\n' "$rows" | grep -q 'This started this morning'; then
  pass "and a comment posted before anything was asked is not an answer to anything"
else
  fail "a comment predating the question was attributed to it"; fi

# Verbatim, minus the token that did the addressing. A definition drawn out of a
# comment is this pass deciding what somebody meant.
if [ "$(hrow HARV-1 '^Which case list' | awk -F'\002' '$5 == "Alina Roth" { print $4 }')" \
     = "the support queue, not the doctor one." ]; then
  pass "the answer is kept word for word, with only the address stripped off the front"
else
  fail "the answer was rewritten on the way in"
  hrow HARV-1 '^Which case list' | cat -v; fi

# Two people, two answers. Both kept, neither chosen.
n_first=$(hrow HARV-1 '^Which case list' | grep -c .)
if [ "$n_first" = "2" ] && [ "$(hrow HARV-1 '^Which case list' | awk -F'\002' '$10 == "yes"' | grep -c .)" = "2" ]; then
  pass "two people answering one question differently keeps both answers and marks the question contested"
else
  fail "a disagreement was resolved silently"; hrow HARV-1 '^Which case list' | cat -v; fi
if [ "$(hrow HARV-3 '^Which surface' | awk -F'\002' '$10 == "yes"' | grep -c .)" = "0" ]; then
  pass "and one person answering twice is not a disagreement, because it is one person"
else
  fail "somebody correcting themselves was reported as a contested question"
  hrow HARV-3 '^Which surface' | cat -v; fi

# A question nobody answered is reported and drafts nothing. Silence is not an
# answer, and a row saying so would be a row with no evidence on it.
if printf '%s' "$report" | grep -q 'HARV-4' \
   && printf '%s' "$report" | grep -q 'still unanswered' \
   && ! printf '%s\n' "$rows" | grep -q 'HARV-4'; then
  pass "an unanswered question is reported and drafted as nothing"
else
  fail "an unanswered question was drafted, or went unreported"; printf '%s\n' "$report" | head -40; fi

# The collision. It exists to say that a signature may be wrong, so it has to be
# loud and it has to reach the row.
if printf '%s' "$report" | grep -q 'A PERSON ANSWERED SOMETHING A VERIFIED CONCEPT ALREADY CLAIMS' \
   && printf '%s' "$report" | grep -q 'subsystems/queue.md'; then
  pass "a word a verified concept says, that refinement still had to ask about, is announced by name"
else
  fail "the collision with a verified concept was silent"; printf '%s\n' "$report" | tail -40; fi
if hrow HARV-1 '^Which case list' | awk -F'\002' '$11 ~ /queue.md/ { found = 1 } END { exit !found }'; then
  pass "and it travels on the row, so whoever reviews the answer sees both at once"
else
  fail "the collision was announced but not recorded"; hrow HARV-1 '^Which case list' | cat -v; fi

printf '\n== matched is not the same claim as resolved =='
# HARV-8: matched to the only question there was, and settles nothing. HARV-9:
# just as short a reply, and a real decision - the control that proves this is
# about resolution and not length.
if [ -z "$(hrow HARV-8 '^What should the price')" ]; then
  pass "a reply that hands the decision back is not drafted as an answer"
else
  fail "a deferral was drafted as though it had decided something"; hrow HARV-8 '^What should the price' | cat -v; fi
if printf '%s' "$report" | grep -q "answered, but nothing was decided" \
   && printf '%s' "$report" | grep -q "What should the price be for a same-day change"; then
  pass "and it is reported under its own heading, naming the question"
else
  fail "a deferring reply was not reported"; printf '%s\n' "$report" | tail -40; fi
if printf '%s' "$report" | sed -n '/still unanswered/,/^$/p' | grep -q "same-day change"; then
  fail "a question somebody actually replied to, if only vaguely, was reported as silence"
else
  pass "and it is not reported as silence, because somebody did reply"
fi
if [ "$(hrow HARV-9 '^What should the price be for a next-day' | awk -F'\002' '{ print $4 }')" = "19 euros." ]; then
  pass "a short reply that names a value is drafted normally - the check is about resolution, not length"
else
  fail "a genuine short answer was treated as a deferral"; hrow HARV-9 '^What should the price be for a next-day' | cat -v; fi
if printf '%s' "$report" | sed -n '/answered, but nothing was decided/,/^$/p' | grep -q "next-day"; then
  fail "a real answer was reported as a deferral"
else
  pass "and it is not reported among the deferrals"
fi

# The scope the check reads, now that a numbered answer is a run. HARV-14
# decides on the line carrying the number and hands the decision back in the
# paragraph underneath it. Those later paragraphs reach the row now, so a gate
# reading the opening alone would have let this past without looking at it.
if [ -z "$(hrow HARV-14 '^What should the express surcharge')" ]; then
  pass "the deferral check reads the whole run, so a decision handed back below the number is still caught"
else
  fail "the deferral check only read the block the number was on"
  hrow HARV-14 '^What should the express surcharge' | cat -v; fi
if printf '%s' "$report" | grep -q "answered, but nothing was decided" \
   && printf '%s\n' "$report" | grep -qE 'HARV-14 +What should the express surcharge be' \
   && printf '%s' "$report" | grep -q "Let's say 19 euros. Actually, on reflection, whatever's easiest for engineering."; then
  pass "and the report names it under that heading, quoting the whole run it judged rather than the line the number was on"
else
  fail "a run-scoped deferral was not reported, or was reported on a truncated answer"
  printf '%s\n' "$report" | tail -40; fi

# A deferral is matched-but-open, the same shape an unaddressed reply already
# has: eligible for --nudge once.
harv8_nudge=$(hrun --key HARV-8)
if printf '%s' "$harv8_nudge" | grep -q "a reply that did not settle anything"; then
  pass "without --nudge, a deferral is offered the same asking-again path an unattributed reply has"
else
  fail "a deferral did not surface as eligible for a nudge"; printf '%s\n' "$harv8_nudge" | tail -20; fi
harv8_nudged=$(hrun --key HARV-8 --nudge)
if printf '%s' "$harv8_nudged" | grep -q "WOULD POST" \
   && printf '%s' "$harv8_nudged" | grep -q "What should the price be for a same-day change"; then
  pass "and --nudge asks again, naming the question the deferral did not settle"
else
  fail "--nudge did not ask again on a deferral"; printf '%s\n' "$harv8_nudged" | grep -B2 -A15 'WOULD POST'; fi

# HARV-10: a decisive answer that names a different figure from the ticket's own
# description for what reads as the same subject. Still a real answer - drafted,
# not discounted - and the disagreement travels on the row.
if [ "$(hrow HARV-10 '^What should the rush fee' | awk -F'\002' '{ print $4 }')" = "Let's raise it to 25 euros starting next release." ]; then
  pass "an answer that disagrees with the description is still drafted - it is a decision, not a deferral"
else
  fail "a real, disagreeing answer was not drafted"; hrow HARV-10 '^What should the rush fee' | cat -v; fi
if hrow HARV-10 '^What should the rush fee' | awk -F'\002' '$9 ~ /ticket.s own description/ { found = 1 } END { exit !found }'; then
  pass "and the row carries what it disagrees with"
else
  fail "the contradiction was not recorded on the row"; hrow HARV-10 '^What should the rush fee' | cat -v; fi
if printf '%s' "$report" | grep -q "disagrees with what is already known" \
   && printf '%s' "$report" | grep -q "HARV-10"; then
  pass "and the report has a section for it, naming the ticket"
else
  fail "a candidate contradiction was drafted silently, with no report section"
  printf '%s\n' "$report" | tail -40; fi

# Proposes, and a person consents. The same rule config/projects.yml and a Jira
# write get.
if [ "$before_harvest" = "$(hhash)" ]; then
  pass "a run without --draft writes nothing into the bundle at all"
else
  fail "the harvest wrote to the bundle with no --draft"; fi
if printf '%s' "$report" | grep -q 'domain/reporter-answers.md .*would draft'; then
  pass "and it names the concept it would have drafted, through the drafter's own report"
else
  fail "the proposal did not say what it would draft"; printf '%s\n' "$report" | tail -30; fi
if printf '%s' "$report" | grep -qE '^ +bin/orc-harvest\.sh --draft'; then
  pass "the drift line names the command that would actually draft it"
else
  fail "the drift line sends the operator to a command that would draft nothing"
  printf '%s\n' "$report" | grep -A3 'not what the repositories'; fi

drafted=$(hrun --draft)
if [ -f "$hconcept" ]; then
  pass "--draft writes the concept"
else
  fail "--draft drafted nothing"; printf '%s\n' "$drafted" | tail -30; fi

# The whole design constraint, asserted against the file rather than against the
# intention. A reporter answering a question about their own ticket has not read
# this concept, so it may not claim they have.
if grep -qE '^generated:' "$hconcept" 2>/dev/null && ! grep -qE '^verified:' "$hconcept" 2>/dev/null; then
  pass "the drafted answers carry generated: and never verified:, which is what keeps an opinion out of the knowledge"
else
  fail "a harvested answer claimed to be verified"; sed -n '1,20p' "$hconcept" 2>/dev/null; fi
if grep -nE -- '--force|--overwrite|--verified|--promote' "$ORC_ROOT/bin/orc-harvest.sh" | code_only | grep -q .; then
  fail "bin/orc-harvest.sh has a flag that could promote an answer past a draft"
  grep -nE -- '--force|--overwrite|--verified|--promote' "$ORC_ROOT/bin/orc-harvest.sh" | code_only
else
  pass "and there is no flag on it that would say otherwise"
fi

# One drafting path. Two things that write concepts would disagree eventually,
# and then nobody could say which produced what.
if [ "$(grep -c 'process:orc-okf-draft' "$hconcept" 2>/dev/null)" = "1" ] \
   && ! grep -q 'process:orc-harvest' "$hconcept" 2>/dev/null; then
  pass "and it was written by the one thing that drafts concepts, not by a second path"
else
  fail "the answers concept names a producer that is not the drafter"
  grep -n 'process:' "$hconcept" 2>/dev/null; fi

# Both answers reach the file. A drafted row that quietly kept one of two would
# be the most expensive kind of wrong, because it would look settled.
if grep -q 'the support queue, not the doctor one' "$hconcept" \
   && grep -q 'The one a doctor opens after logging in' "$hconcept" \
   && grep -q 'Answered differently by two people' "$hconcept"; then
  pass "both sides of the disagreement are in the concept, with the disagreement named"
else
  fail "the drafted row settled a question the evidence does not settle"
  sed -n '/^| Question/,/^$/p' "$hconcept"; fi
if grep -q 'Tomas Weber, 2026-08-14' "$hconcept" && grep -q 'HARV-1' "$hconcept"; then
  pass "and every answer carries who said it, when, and which ticket it came from"
else
  fail "an answer is in the bundle with no provenance attached"
  sed -n '/^| Question/,/^$/p' "$hconcept"; fi

# A row matched by reading names how it was matched and carries the paragraph
# it was pulled from, because that is exactly the row a reviewer has the least
# reason to take on faith.
if grep -q '(by reading)' "$hconcept" \
   && grep -q 'the full reply: "I was using Chrome. The export button was greyed out completely, not just slow to respond.' "$hconcept"; then
  pass "a row matched by reading is labelled as such and carries the whole reply beside the extracted fragment"
else
  fail "a reading-matched row did not disclose how it was matched or dropped its source text"
  sed -n '/^| Question/,/^$/p' "$hconcept"; fi

# The whole numbered answer reaches the bundle, which is the half that matters:
# the refiner reads the drafted concept, never the raw reply, so a paragraph
# that stops here is a paragraph the next round does not know exists.
if grep -q 'hold a ruler beside it so the size is clear' "$hconcept"; then
  pass "the last paragraph of a multi-paragraph numbered answer is in the drafted concept"
else
  fail "the drafted concept holds the opening of a numbered answer and not its substance"
  sed -n '/^| Question/,/^$/p' "$hconcept"; fi

# HARV-10's disagreement reaches the drafted concept too, the same way a
# collision does - a candidate contradiction is a finding on the row, not
# something fixed on the way in.
if grep -q "This conflicts with the ticket's own description" "$hconcept"; then
  pass "a candidate contradiction is named in the drafted concept as well as the report"
else
  fail "a contradiction reached the state cache but not the drafted concept"
  sed -n '/^| Question/,/^$/p' "$hconcept"; fi

# The review step is where a human reads the whole record before signing, so it
# is where the note surfaces - not a Jira question the ticket never asked.
hverify() {
  env ORC_FIXTURE_DIR="$h/fx" ORC_STATE_DIR="$h/state" ORC_PROJECTS_FILE="$h/projects.yml" \
      ORC_CLONE_DIR="$h/clones" ORC_VERIFY_LEDGER="$h/no-such-verify-ledger.jsonl" \
      "$ORC_ROOT/bin/orc-verify.sh" --bundle "$h/hokf" "$@" 2>&1
}
vqueue=$(hverify queue)
if printf '%s' "$vqueue" | grep -q "This answer conflicts with"; then
  pass "and bin/orc-verify.sh's own queue shows the same conflict before anybody signs it"
else
  fail "the review queue did not surface the contradiction a reviewer needs to see"
  printf '%s\n' "$vqueue" | tail -60; fi

second=$(hrun --draft)
if printf '%s' "$second" | grep -q 'domain/reporter-answers.md *unchanged'; then
  pass "a second run is a no-op: the same comments produce the same file"
else
  fail "the answers concept was rewritten by a run that read the same comments"
  printf '%s\n' "$second" | tail -20; fi

# The marker is parsed in one place. Two readers of "is this comment ours" would
# eventually disagree, and then one pass would attribute a machine's words to a
# person.
if grep -n "$ORC_COMMENT_MARKER" "$ORC_ROOT/bin/orc-harvest.sh" "$ORC_ROOT/bin/orc-reconcile.sh" \
     | code_only | grep -q .; then
  fail "a pass spells the comment marker for itself instead of asking orc-lib.sh"
  grep -n "$ORC_COMMENT_MARKER" "$ORC_ROOT/bin/orc-harvest.sh" "$ORC_ROOT/bin/orc-reconcile.sh" | code_only
else
  pass "both passes ask orc-lib.sh whether a comment is the orchestrator's, rather than deciding for themselves"
fi

# state/ is a cache, here as everywhere. Nothing this pass keeps is a record: the
# questions and the answers are Jira comments, and Jira is not a cache - which is
# exactly why this needs no ledger and the gap loop does.
if [ -f "$h/state/HARV-1.answers.json" ] \
   && [ "$(jq -r '.answers | length' "$h/state/HARV-1.answers.json")" = "4" ]; then
  pass "what it caches under state/ is re-derivable by running it again, so there is no ledger to keep"
else
  fail "the per-ticket cache is not what the run produced"
  cat "$h/state/HARV-1.answers.json" 2>/dev/null | head -5; fi
if [ -f "$h/state/HARV-5.answers.json" ] \
   && [ "$(jq -r '.answers[0].matched_by' "$h/state/HARV-5.answers.json")" = "by reading" ] \
   && [ "$(jq -r '.answers[0].verbatim' "$h/state/HARV-5.answers.json")" \
        = "I was using Chrome. The export button was greyed out completely, not just slow to respond." ]; then
  pass "the cache carries how a reading-matched answer was matched and the reply it was read from"
else
  fail "the per-ticket cache lost how a row was matched, or the reply it came from"
  cat "$h/state/HARV-5.answers.json" 2>/dev/null; fi
# It reads the gap ledger, because that is where the words refinement could not
# resolve survive a reset. It appends to nothing: an append-only record of what
# Jira already holds in full would be a second cache pretending to be a source.
if grep -nE '(>>[^|]*(\.jsonl|LEDGER))|gap_observation' "$ORC_ROOT/bin/orc-harvest.sh" \
     | code_only | grep -q .; then
  fail "the harvest keeps a ledger of its own, which would be a second cache pretending to be a source"
  grep -nE '(>>[^|]*(\.jsonl|LEDGER))|gap_observation' "$ORC_ROOT/bin/orc-harvest.sh" | code_only
else
  pass "and it appends to no record of its own, because Jira already holds every word of it"
fi

# A hint is a thing somebody pastes, so it reproduces the run that printed it.
# A --key run whose hint dropped the key would send an operator over the whole
# project, which is a different run and, on a real board, a much longer one.
keyed=$(hrun --key HARV-1)
keyed_hints=$(printf '%s\n' "$keyed" | sed -n 's/^ *\(bin\/orc-harvest\.sh .*\)$/\1/p')
keyed_bare=$(printf '%s\n' "$keyed_hints" | grep -vc -- '--key HARV-1' | tr -d ' ')
if [ "$(printf '%s\n' "$keyed_hints" | grep -c .)" -ge 1 ] && [ "$keyed_bare" = "0" ]; then
  pass "every command the report names carries the flags the run that printed it was given"
else
  fail "a printed command describes a different run from the report above it"
  printf '%s\n' "$keyed_hints"; fi

printf '\n== asking again, and only once =='
# HARV-6: a reply nobody could understand at all. HARV-7: already asked again
# once (reask=1 in force), and the reply after that is still unattributed.
bare=$(hrun --key HARV-6)
if printf '%s' "$bare" | grep -q 'WOULD POST'; then
  fail "a run without --nudge attempted a write"
  printf '%s\n' "$bare" | grep -B2 -A2 'WOULD POST'
else
  pass "without --nudge, a reply nobody understood is reported and nothing is attempted against Jira"
fi
if printf '%s' "$bare" | grep -q 'a reply nobody could understand'; then
  pass "and the report says --nudge is what would ask again"
else
  fail "an unattributed reply with an open question was not offered a nudge"
  printf '%s\n' "$bare" | tail -20; fi

nudged=$(hrun --key HARV-6 --nudge)
n_would_post=$(printf '%s' "$nudged" | grep -c 'WOULD POST')
if [ "$n_would_post" = "1" ] \
   && printf '%s' "$nudged" | grep -q 'Which browser were you using?' \
   && printf '%s' "$nudged" | grep -q 'Was the export button greyed out?' \
   && printf '%s' "$nudged" | grep -q 'reask=1'; then
  pass "--nudge asks again with exactly one comment, naming the still-open questions and marked as a reask"
else
  fail "--nudge did not post the one comment it should have, or posted the wrong thing"
  printf '%s\n' "$nudged" | grep -B2 -A15 'WOULD POST'; fi

still=$(hrun --key HARV-7 --nudge)
if printf '%s' "$still" | grep -q 'WOULD POST'; then
  fail "a round already marked reask=1 was asked again - the ask-once bound did not hold"
  printf '%s\n' "$still" | grep -B2 -A2 'WOULD POST'
else
  pass "a round that already carries reask=1 is never asked a third time, however unclear the reply still is"
fi
if printf '%s' "$still" | grep -q 'asked again once, still not clear'; then
  pass "and it is reported under its own heading instead, because a human has to take it from here"
else
  fail "a question stuck past one reask was not reported as needing a person"
  printf '%s\n' "$still" | tail -20; fi

# HARV-5's paragraph was understood, just partially - two of three questions
# answered by reading, the third simply untouched. That is not a reply nobody
# could understand, so it must never be offered a nudge. HARV-4 is pure
# silence, which --nudge never touches either.
untouched=$(hrun --nudge --key HARV-5)
if printf '%s' "$untouched" | grep -qE 'WOULD POST|nobody could understand'; then
  fail "a reply that was understood, only partially, was treated as one nobody could understand"
  printf '%s\n' "$untouched" | tail -20
else
  pass "a reply matched by reading, even partially, is never treated as one nobody understood"
fi
silent=$(hrun --nudge --key HARV-4)
if printf '%s' "$silent" | grep -qE 'WOULD POST|nobody could understand'; then
  fail "silence - nobody replying at all - was offered a nudge"
  printf '%s\n' "$silent" | tail -20
else
  pass "and silence is never nudged: --nudge reacts to a reply nobody understood, not to nobody replying"
fi

# The text a reporter would read is held to the same bar a needs_input comment
# is: no path, no identifier, none of this system's own nouns. Reusing
# scan_for_code / scan_for_jargon / reader_sees from the needs_input check
# above rather than a second copy of the same two patterns - two spellings of
# that bar would eventually disagree about what it forbids.
reask_body=$(printf '%s\n' "$nudged" | sed -n '/WOULD POST/,/+-- raw/p')
nudge_hits=$(printf '%s\n' "$reask_body" | scan_for_both | sort -u | tr '\n' ' ')
if [ -z "$nudge_hits" ]; then
  pass "the reask comment carries no path, no code identifier and none of this system's own nouns"
else
  fail "the reask comment leaked engineering detail to the reporter: $nudge_hits"
  printf '%s\n' "$reask_body"; fi

# Exactly one write call site in the whole script, and it is a comment - never a
# label, an assignee or a duplicate link. --nudge is the only thing that can
# reach it, and both write switches still decide what happens once it does.
if grep -nE 'jira_add_label|jira_remove_label|jira_assign|jira_link_duplicate' \
     "$ORC_ROOT/bin/orc-harvest.sh" | code_only | grep -q .; then
  fail "bin/orc-harvest.sh touches a label, an assignee or a duplicate link; --nudge may only ever post a comment"
  grep -nE 'jira_add_label|jira_remove_label|jira_assign|jira_link_duplicate' "$ORC_ROOT/bin/orc-harvest.sh" | code_only
else
  pass "it never touches a label, an assignee or a duplicate link"
fi
write_sites=$(grep -nE 'jira_write|jira_comment_adf' "$ORC_ROOT/bin/orc-harvest.sh" | code_only)
if [ "$(printf '%s\n' "$write_sites" | grep -c .)" = "1" ] \
   && printf '%s\n' "$write_sites" | grep -q 'jira_comment_adf'; then
  pass "the only write call anywhere in the script is the single gated comment --nudge may post"
else
  fail "bin/orc-harvest.sh has a write call site --nudge's design does not account for"
  printf '%s\n' "$write_sites"; fi

# A decision somebody has already made is not proposed again, and it is keyed on
# the answer's own words rather than on the question. HARV-1's first question has
# two answers that disagree; refusing one of them has to drop that one and leave
# the other, because "two people answered differently" is a finding and refusing
# one of the two is not a ruling on both.
hled="$h/verifications.jsonl"
hrunv() {
  env ORC_FIXTURE_DIR="$h/fx" ORC_STATE_DIR="$h/state" ORC_PROJECTS_FILE="$h/projects.yml" \
      ORC_CLONE_DIR="$h/clones" ORC_GAP_LEDGER="$h/no-such-ledger.jsonl" \
      ORC_VERIFY_LEDGER="$hled" \
      "$ORC_ROOT/bin/orc-harvest.sh" --bundle "$h/hokf" "$@" 2>&1
}
hq1="Which case list do you mean: the one a doctor opens, or the one support works from?"
jq -nc --arg sk "$(answer_subject_key HARV-1 "$hq1")" \
       --arg pf "$(printf '%s' 'the support queue, not the doctor one.' | _terms_fold)" \
       --arg s "$hq1" '{id:"deadbeef", kind:"answer", decision:"reject",
         subject_key:$sk, proposal_fold:$pf, ticket:"HARV-1", subject:$s,
         proposal:"the support queue, not the doctor one.", text:"",
         by:"person:checkfix", at:"2026-08-22T10:00:00Z",
         reason:"the ticket is about the doctor list"}' > "$hled"
decided_rows=$(hrunv --rows)
decided_report=$(hrunv)
if ! printf '%s\n' "$decided_rows" | grep -q 'the support queue, not the doctor one' \
   && printf '%s\n' "$decided_rows" | grep -q 'The one a doctor opens after logging in'; then
  pass "a refused answer stops being proposed, and the other answer to the same question is not refused with it"
else
  fail "the refusal dropped the wrong rows"
  printf '%s\n' "$decided_rows" | cat -v | head -10; fi
if printf '%s' "$decided_report" | grep -q 'already decided, so not proposed again' \
   && printf '%s' "$decided_report" | grep -q 'reject'; then
  pass "and the report says so under its own heading rather than dropping it silently"
else
  fail "a refused row was skipped with nothing said about it"
  printf '%s\n' "$decided_report" | head -40; fi
# HARV-2's only question, refused: the question is answered and settled, so
# reporting it as unanswered would send somebody to ask a reporter for something
# already decided.
jq -nc --arg sk "$(answer_subject_key HARV-2 "Is this one piece of work or two?")" \
       --arg pf "$(printf '%s' 'Treat it as one for now, support wants both in the same release.' | _terms_fold)" \
       '{id:"deadbee2", kind:"answer", decision:"agree", subject_key:$sk, proposal_fold:$pf,
         ticket:"HARV-2", subject:"Is this one piece of work or two?",
         proposal:"Treat it as one for now, support wants both in the same release.",
         text:"Treat it as one for now.", by:"person:checkfix", at:"2026-08-22T10:00:00Z", reason:""}' \
  >> "$hled"
settled=$(hrunv)
if ! printf '%s' "$settled" | sed -n '/still unanswered/,/^== /p' | grep -q 'Is this one piece of work'; then
  pass "a question whose only answer was decided about is not then reported as one nobody replied to"
else
  fail "a signed question was reported as unanswered"
  printf '%s\n' "$settled" | sed -n '/still unanswered/,/^== /p'; fi

# A new answer that disagrees with an answer already signed on the SAME ticket -
# from an earlier round, not from this comment thread, which is the ordinary
# way a fact reaches domain/verified-answers.md. Scoped to the one ticket: a
# different card naming a different figure for what reads as the same question
# is not a contradiction, and this must not flag one.
hissue HARV-11 \
  "$(hq 2026-08-14T08:00:00.000+0200 "How much should the cancellation fee be reduced by for a loyalty member?")" \
  "$(hp 600 2026-08-14T09:00:00.000+0200 "Iris Sanne" "Let's reduce it by 15 euros for loyalty members.")"
hq11="an earlier question on the same ticket"
jq -nc --arg sk "$(answer_subject_key HARV-11 "$hq11")" \
       --arg pf "$(printf '%s' 'Reduce the cancellation fee by 10 euros for loyalty members.' | _terms_fold)" \
       '{id:"deadbee3", kind:"answer", decision:"agree", subject_key:$sk, proposal_fold:$pf,
         ticket:"HARV-11", subject:"an earlier question on the same ticket",
         proposal:"Reduce the cancellation fee by 10 euros for loyalty members.",
         text:"Reduce the cancellation fee by 10 euros for loyalty members.",
         by:"person:checkfix", at:"2026-08-20T10:00:00Z", reason:""}' \
  >> "$hled"
h11_rows=$(hrunv --rows --key HARV-11)
h11_report=$(hrunv --key HARV-11)
if printf '%s\n' "$h11_rows" | awk -F'\002' '$9 ~ /answer already signed on this ticket/ { found = 1 } END { exit !found }'; then
  pass "a new answer that disagrees with a fact already signed on this ticket is flagged"
else
  fail "a new answer contradicting an earlier signed answer on the same ticket was not flagged"
  printf '%s\n' "$h11_rows" | cat -v; fi
if printf '%s' "$h11_report" | grep -q "disagrees with what is already known" \
   && printf '%s' "$h11_report" | grep -q "HARV-11"; then
  pass "and the report names it, the same way a disagreement with the description does"
else
  fail "the report did not surface a contradiction against an earlier signed answer"
  printf '%s\n' "$h11_report" | tail -40; fi
rm -f "$hled"

rm -rf "$h"

printf '\n== drift nobody would otherwise hear about ==\n'
# --check has always detected drift correctly, and nothing in the ordinary path
# ever ran it - so a drafted concept whose evidence had moved went on being read
# by refinement as a live lead and nobody was told. These checks are about the
# telling: that it happens where it will be heard, that it says what moved, that
# it does not act, and that it does not repeat itself into being ignored.

# The machine-readable half first. A caller must not have to parse a table whose
# columns are padded to the longest value in them.
drifted=$(bok --drifted); rc=$?
if [ -z "$drifted" ] && [ "$rc" = "0" ]; then
  pass "--drifted says nothing about a bundle that matches, and exits 0"
else
  fail "--drifted reports drift on a bundle it just wrote (rc=$rc)"; printf '%s\n' "$drifted"; fi

printf '    subtitle: Kurzfall\n' >> "$b/clones/api/config/locales/de.yml"
gitq "$b/clones/api" add -A
gitq "$b/clones/api" commit --quiet -m "a string moves, so a concept does"
drifted=$(bok --drifted); rc=$?
if [ -n "$drifted" ] && [ "$rc" = "1" ]; then
  pass "--drifted names the concepts a moved string moved, and exits 1"
else
  fail "--drifted did not report a catalogue change (rc=$rc)"; fi
stray=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  [ -f "$b/okf/$line" ] || stray="$stray [$line]"
done <<< "$drifted"
if [ -z "$stray" ]; then
  pass "and prints paths into the bundle and nothing else, one per line"
else
  fail "--drifted printed something that is not a concept path:$stray"; fi

# Where the warning arrives. bin/orc-daemon.sh is the only script that runs
# unattended and repeatedly, so it is the only place a warning lands without
# somebody remembering to look. Exercised through the daemon itself rather than
# by reading it: the claim is that an operator running the ordinary command hears
# this, and only running the ordinary command can show that.
d=$(mktemp -d)
mkdir -p "$d/bin" "$d/state" "$d/fx/search"
for s in orc-lib.sh orc-daemon.sh orc-okf-draft.sh orc-jira-poll.sh; do
  ln -s "$ORC_ROOT/bin/$s" "$d/bin/$s"
done
cp -R "$b/okf" "$d/.okf"
cp "$b/projects.yml" "$d/projects.yml"
# An empty search result, so the pass is the sync and the bundle check and then
# nothing. What refinement does with a ticket is tested everywhere above.
printf '{"isLast":true,"issues":[]}\n' > "$d/fx/search/issues-changed.json"

# dpass <bundle-check ttl>
dpass() {
  env ORC_ROOT="$d" ORC_PROJECTS_FILE="$d/projects.yml" ORC_STATE_DIR="$d/state" \
      ORC_CLONE_DIR="$b/clones" ORC_FIXTURE_DIR="$d/fx" ORC_BUNDLE_CHECK_TTL="$1" \
      ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture DRY_RUN=1 \
      "$d/bin/orc-daemon.sh" --once </dev/null 2>&1
}
dhash() { find "$d/.okf" -type f | sort | while IFS= read -r f; do printf '%s ' "$f"; _sha1 < "$f"; done | _sha1; }

okf_before=$(dhash)
warned=$(dpass 0)
okf_after=$(dhash)
if printf '%s' "$warned" | grep -q 'THE BUNDLE IS NOT WHAT THE REPOSITORIES SAY'; then
  pass "an ordinary daemon pass says so when a concept has drifted"
else
  fail "the daemon ran a whole pass over a drifted bundle and said nothing"; fi
if printf '%s' "$warned" | grep -q 'domain/product-vocabulary.md'; then
  pass "and names the drifted concept, so it is a finding rather than a mood"
else
  fail "the warning does not say which concept moved"; printf '%s\n' "$warned"; fi
if printf '%s' "$warned" | grep -q 'bin/orc-okf-draft.sh$'; then
  pass "and prints the command that fixes it, unindented and whole"
else
  fail "the warning names no command"; fi

# Warn, never act. .okf/ is source: a human consented to what is in it, the same
# as config/projects.yml and the same as a Jira write. A daemon that re-drafted
# here would replace a concept a human is responsible for while that human was
# reading a log.
if [ "$okf_before" = "$okf_after" ]; then
  pass "and the pass that warned wrote nothing into the bundle"
else
  fail "the daemon re-drafted the bundle it was only supposed to warn about"; fi
# The same claim at the source level, and it has to be told from the banner text,
# which names the writing command on purpose - that is what the operator is
# supposed to run. A call goes through the variable that resolves it and a
# sentence never does, so the invocation spelling is what is searched for.
calls=$(grep -n 'ORC_ROOT/bin/orc-okf-draft\.sh' "$ORC_ROOT/bin/orc-daemon.sh" | grep -v -- '--drifted')
if [ -z "$calls" ]; then
  pass "and the only drafter call in it is the one that cannot write"
else
  fail "bin/orc-daemon.sh invokes the drafter in a mode that can write"; printf '%s\n' "$calls"; fi

# One warning per cause, not one per pass. The repo learned this at the counting
# layer - the stuck counter counts runs, not invocations - and never applied it
# where the counting is read out. A banner on every poll is one an operator
# learns to scroll past, and the one that mattered goes past with it.
again=$(dpass 0)
if printf '%s' "$again" | grep -q 'THE BUNDLE IS NOT'; then
  fail "the same drift is announced again on the next pass"
else
  pass "the same drift is not announced twice: same cause, said once"; fi

# And it is the cause that is remembered, not the fact that there was one. A
# concept that drifts after the first warning is a new thing to say.
cat > "$b/clones/api/app/models/prescription.rb" <<'RB'
class Prescription < ApplicationRecord
  # Only these may be reissued without a new consultation.
  REISSUABLE_KINDS = %w[topical oral].freeze
end
RB
gitq "$b/clones/api" add -A
gitq "$b/clones/api" commit --quiet -m "a rule is written down for the first time"
more=$(dpass 0)
if printf '%s' "$more" | grep -q 'domain/domain-rules.md'; then
  pass "a concept that drifts after that warning is a new cause, and is announced"
else
  fail "a newly drifted concept was swallowed by the earlier warning"; printf '%s\n' "$more"; fi

# The stamp, and it is the one the clone fetch already uses. --drifted re-renders
# every concept from every repository, so on a sixty-second poll it must not run
# every pass.
gitq "$b/clones/api" revert --no-edit --quiet HEAD >/dev/null
quiet_pass=$(dpass 3600)
if printf '%s' "$quiet_pass" | grep -q 'THE BUNDLE IS NOT'; then
  fail "the bundle check ran again inside its own freshness window"
else
  pass "a stamp inside its freshness window suppresses the check, as a fetch's does"; fi
if [ -f "$d/state/.bundle/checked" ]; then
  pass "and the stamp is a file in state/, which is a cache: deleting it asks again"
else
  fail "nothing recorded that the check had run"; fi

# The bundle catches up, and the warning stops. A warning that cannot go quiet is
# a warning that has stopped carrying information.
env ORC_ROOT="$d" ORC_PROJECTS_FILE="$d/projects.yml" ORC_STATE_DIR="$d/state" \
    ORC_CLONE_DIR="$b/clones" "$d/bin/orc-okf-draft.sh" --quiet >/dev/null 2>&1
clean=$(dpass 0)
if printf '%s' "$clean" | grep -q 'THE BUNDLE IS NOT'; then
  fail "the warning survives a bundle that has been re-drafted"; printf '%s\n' "$clean"
else
  pass "a re-drafted bundle is silent, so the warning is about drift and not about drafting"; fi
if printf '%s' "$clean" | grep -q 'matches the repositories again'; then
  pass "and it says once that the bundle caught up, rather than only going quiet"
else
  fail "the drift cleared without a word, so a reader cannot tell it from a skipped check"; fi
silent=$(dpass 0)
if printf '%s' "$silent" | grep -qE 'THE BUNDLE IS NOT|matches the repositories again'; then
  fail "a clean bundle is still being talked about"; printf '%s\n' "$silent"
else
  pass "and then says nothing at all about a bundle that matches"; fi

# A checkout that could not be read is not the bundle moving. Every concept for
# an unreadable repository goes unrendered, which shrinks the index listing - and
# calling that drift would send somebody to draft over concepts that are still
# correct, for a reason that is really bin/orc-repos-sync.sh's to report.
cat > "$d/broken.yml" <<YML
api:
  repo: $b/clones/api
  default_branch: staging
web:
  repo: $d/not-a-repository
  default_branch: staging
YML
mkdir -p "$d/not-a-repository"
undecided=$(env ORC_ROOT="$d" ORC_PROJECTS_FILE="$d/broken.yml" ORC_STATE_DIR="$d/state" \
                ORC_CLONE_DIR="$b/clones" "$d/bin/orc-okf-draft.sh" --drifted 2>/dev/null); rc=$?
if [ -z "$undecided" ] && [ "$rc" = "2" ]; then
  pass "an unreadable repository is not spelled as drift: nothing said, and it says it could not decide"
else
  fail "an unreadable checkout was reported as bundle drift (rc=$rc)"; printf '%s\n' "$undecided"; fi
mute=$(env ORC_ROOT="$d" ORC_PROJECTS_FILE="$d/broken.yml" ORC_STATE_DIR="$d/state2" \
           ORC_CLONE_DIR="$b/clones" ORC_FIXTURE_DIR="$d/fx" ORC_BUNDLE_CHECK_TTL=0 \
           ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture DRY_RUN=1 \
           "$d/bin/orc-daemon.sh" --once </dev/null 2>&1)
if printf '%s' "$mute" | grep -q 'THE BUNDLE IS NOT'; then
  fail "the daemon turned an unreadable checkout into a bundle-drift banner"
else
  pass "and the daemon passes that through as one line rather than a banner"; fi

# ORC_BUNDLE_CHECK=off, because the fixture demo must stay a fixture demo: it
# runs with no network and no credentials, and a bundle check is neither.
offrun=$(env ORC_ROOT="$d" ORC_PROJECTS_FILE="$d/projects.yml" ORC_STATE_DIR="$d/state3" \
             ORC_CLONE_DIR="$b/clones" ORC_FIXTURE_DIR="$d/fx" ORC_BUNDLE_CHECK=off \
             ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture DRY_RUN=1 \
             "$d/bin/orc-daemon.sh" --once </dev/null 2>&1)
if [ -d "$d/state3/.bundle" ]; then
  fail "ORC_BUNDLE_CHECK=off still ran the check"; printf '%s\n' "$offrun"
else
  pass "ORC_BUNDLE_CHECK=off does not run the check at all"; fi

rm -rf "$d"
env ORC_PROJECTS_FILE="$b/projects.yml" ORC_STATE_DIR="$b/state" ORC_CLONE_DIR="$b/clones" \
    "$ORC_ROOT/bin/orc-okf-draft.sh" --bundle "$b/okf" --quiet >/dev/null 2>&1

# Every subsystem concept says which repository it is, always - with a remote or
# without one. That claim is the only thing that lets anything tell two concepts
# about one repository apart, so a missing one is not a cosmetic gap.
noident=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "${f#"$b/okf/"}" in
    subsystems/index.md) continue ;;
    subsystems/*) : ;;
    *) continue ;;
  esac
  concept_field "$f" resource | grep -q . || noident="$noident ${f#"$b/okf/"}"
done <<< "$(find "$b/okf/subsystems" -name '*.md' -type f | sort)"
if [ -n "$noident" ]; then fail "a subsystem concept does not say which repository it is:$noident"; else
  pass "every subsystem concept names the repository it describes"; fi

# The prevention, not the detection: a repository whose concept already exists
# under some other name must have that concept updated, never a second one
# written beside it. This is the case that went wrong - nobody had set the
# config's subsystem: join, so the drafter fell back to the project key and
# wrote a duplicate next to a concept a human had verified.
mv "$b/okf/subsystems/api.md" "$b/okf/subsystems/the-backend.md"
fourth=$(bok --quiet)
if [ -f "$b/okf/subsystems/api.md" ]; then
  fail "the drafter wrote a second concept for a repository that already had one"
  printf '%s
' "$fourth"
else
  pass "a repository whose concept exists under another name gets that one, not a second"
fi
if grep -q 'app/models' "$b/okf/subsystems/the-backend.md"; then
  pass "and the renamed concept is the one that was written into"
else
  fail "the renamed concept was not updated"; fi
if [ -z "$(bundle_repo_duplicates "$b/okf")" ]; then
  pass "so a drafter run cannot leave two concepts describing one repository"
else
  fail "the drafter left a duplicate behind"; bundle_repo_duplicates "$b/okf"; fi
mv "$b/okf/subsystems/the-backend.md" "$b/okf/subsystems/api.md"
bok --quiet >/dev/null 2>&1

# A human's verified concept, with a body that deliberately disagrees with the
# repository. The draft would replace it, and that is exactly what must not
# happen: a verified concept replaced by an unverified one is a downgrade.
awk '
  $0 == "status: draft" {
    print "status: stable"
    print "verified:"
    print "  - by: human:someone"
    print "    at: 2026-01-01T00:00:00Z"
    next
  }
  $0 == "# Overview" {
    print
    print ""
    print "A human wrote this line and it must survive."
    next
  }
  { print }
' "$b/okf/subsystems/web.md" > "$b/web.human" && mv "$b/web.human" "$b/okf/subsystems/web.md"
mine=$(_sha1 < "$b/okf/subsystems/web.md")
third=$(bok --quiet)
if [ "$mine" = "$(_sha1 < "$b/okf/subsystems/web.md")" ]; then
  pass "a concept a human verified is not touched, however far the draft has moved"
else
  fail "the drafter overwrote a verified concept"; fi
if grep -q 'A human wrote this line and it must survive.' "$b/okf/subsystems/web.md"; then
  pass "and the human's own prose is still in it"
else
  fail "the human's prose was replaced"; fi
if printf '%s' "$third" | grep -q 'SKIPPED' && printf '%s' "$third" | grep -q 'subsystems/web.md'; then
  pass "the run reports the skip by name instead of passing over it in silence"
else
  fail "the run did not report skipping a verified concept"; printf '%s\n' "$third"; fi
if printf '%s' "$third" | grep -q 'would have been re-drafted'; then
  pass "and says a re-draft was withheld, which is the thing a reader needs to decide about"
else
  fail "the skip does not say what it withheld"; printf '%s\n' "$third"; fi

# Same rule as discovery: the config is source, and detecting something is not a
# licence to write it.
cfgsum=$(_sha1 < "$b/projects.yml")
bok --quiet >/dev/null 2>&1
if [ "$cfgsum" = "$(_sha1 < "$b/projects.yml")" ]; then
  pass "config/projects.yml is byte-identical after a drafter run"
else
  fail "the drafter wrote to the projects config"; fi
if printf '%s' "$first" | grep -q 'subsystem:'; then
  pass "the join it would need is proposed, and left for a human to paste"
else
  fail "the run drafted concepts the config cannot reach and never said so"; fi

if okf --version >/dev/null 2>&1; then
  if okf validate "$b/okf" >/dev/null 2>&1; then
    pass "okf validate accepts a freshly drafted bundle"
  else
    fail "okf validate rejects what the drafter drafted"; okf validate "$b/okf" || true; fi
else
  printf '  skip  the okf CLI does not run here, so the drafted bundle was not validated.\n'
  printf '        Everything above still ran: the drafts are plain markdown.\n'
  printf '        To enable: gem install okf (with rbenv, select a ruby first:\n'
  printf '        rbenv local 3.4.8).\n'
fi

printf '\n== the bundle renders the same whatever locale it is drafted in ==\n'
# Drift is decided by re-rendering a body and comparing bytes, and roughly fifteen
# sorts decide the order those bytes come out in. Collation is a locale's opinion:
# an accented `Angstrom` sorts with the A's under en_US.UTF-8 and after Z under
# C, and two catalogue rows of the same length swap places between them. Unpinned,
# the same repositories at the same commits drifted or did not depending on whose
# terminal the daemon was started from - four concepts and a full banner telling a
# human to re-draft a bundle nothing had moved under.
#
# The pin is an `export LC_ALL=C` at the top of the script rather than a wrapper
# around each sort, because a sort added later would not inherit a wrapper. That
# is worth asserting by position: an export below the first sort is not a pin.
drafter="$ORC_ROOT/bin/orc-okf-draft.sh"
pin_line=$(grep -n '^export LC_ALL=C$' "$drafter" | head -1 | cut -d: -f1)
first_sort=$(grep -nE '(^|[^_[:alnum:]])sort([[:space:]]|$)' "$drafter" | head -1 | cut -d: -f1)
if [ -n "$pin_line" ] && [ -n "$first_sort" ] && [ "$pin_line" -lt "$first_sort" ]; then
  pass "orc-okf-draft.sh pins LC_ALL=C (line $pin_line), above its first sort (line $first_sort)"
else
  fail "the locale pin is missing or below the first sort (pin=${pin_line:-none} sort=${first_sort:-none})"
fi

# And behaviourally, against a bundle this run drafted from the sandbox
# repositories rather than against whatever bundle happens to be committed. It
# used to read $ORC_ROOT/.okf, which only measured anything while this repository
# carried somebody's drafted concepts; .okf/ ships as a skeleton now, and a probe
# that silently degrades to "nothing to compare" is a check that stopped running
# without saying so.
#
# The sandbox bundle is genuine drafter output over repositories whose names the
# two locales sort differently, which is the data the pin was needed for. One line
# added to one concept is what makes the comparison non-empty: the answer has to
# be the same list in the same order under both locales, and under an unpinned
# script it is not. The concept to edit is found rather than named, so this does
# not break the next time the sandbox draft changes shape.
lb=$(mktemp -d)
mkdir -p "$lb/okf"
cp -R "$b/okf/." "$lb/okf"/ 2>/dev/null || true
lb_victim=$(find "$lb/okf" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort | head -1)
[ -n "$lb_victim" ] && printf '\nan edit no generator made\n' >> "$lb_victim"
locale_drifted() {
  env ORC_PROJECTS_FILE="$b/projects.yml" ORC_CLONE_DIR="$b/clones" \
      ORC_STATE_DIR="$lb/state-$1" LC_ALL="$1" \
      "$drafter" --bundle "$lb/okf" --drifted 2>/dev/null
}
c_out=$(locale_drifted C)
u_out=$(locale_drifted en_US.UTF-8)
if [ -z "$c_out" ] && [ -z "$u_out" ]; then
  printf '  skip  --drifted decided nothing under either locale, so there was no\n'
  printf '        rendering to compare. The clones are a cache: run\n'
  printf '        bin/orc-repos-sync.sh and this check measures something.\n'
elif [ "$c_out" = "$u_out" ]; then
  pass "--drifted names the same concepts in the same order under C and en_US.UTF-8"
else
  fail "the same bundle and the same commits drift differently depending on the locale"
  printf '  C said:            %s\n' "$(printf '%s' "$c_out" | tr '\n' ' ')"
  printf '  en_US.UTF-8 said:  %s\n' "$(printf '%s' "$u_out" | tr '\n' ' ')"
fi
rm -rf "$lb"

printf '\n== a script name spoken anywhere is a script that is there ==\n'
# A drafted concept says who produced it, and that id is this script's own name.
# What is worth asserting is the derivation rather than the string: a marker
# compared against a literal would sail through a half-done rename, and a check
# that greps for the spelling a rename left behind passes by matching nothing.
producer=$(grep '^PRODUCER=' "$drafter" | head -1 | sed -e 's/^PRODUCER=//' -e 's/^"//' -e 's/"$//')
producer_expected="process:$(basename "$drafter" .sh)"
if [ "$producer" = "$producer_expected" ]; then
  pass "a drafted concept is attributed to $producer, which is the name of the script that writes it"
else
  fail "the producer marker does not name the script that writes it"
  printf '  the script is %s, and it stamps %s\n' "$producer_expected" "${producer:-nothing}"
fi

# The region markers in an index name the file that owns the region, so they go
# stale the same way and are read by the same rename.
if grep -q "^INDEX_BEGIN='<!-- BEGIN drafted by bin/$(basename "$drafter") -->'\$" "$drafter" \
   && grep -q "^INDEX_END='<!-- END drafted by bin/$(basename "$drafter") -->'\$" "$drafter"; then
  pass "and the index region it owns is marked with that same name"
else
  fail "the index region markers name a file other than the script that replaces the region"
  grep -n '^INDEX_\(BEGIN\|END\)=' "$drafter"
fi

# And whatever the committed bundle holds carries it, because every check above
# that greps for a producer is measuring a sandbox bundle this run drafted. A
# committed concept still attributing itself to a name nothing answers to is
# exactly what a rename leaves behind, and nothing else in the suite would see it.
#
# The invariant is "no concept names a producer this repository does not answer
# to" rather than "at least one concept names the current producer". Those agree
# on a bundle with concepts in it, and they differ on a bundle with none - which
# is what ships, because .okf/ here is a skeleton and the concepts are drafted per
# installation. Asserting a positive count would mean the suite could only stay
# green while the repository carried somebody's drafted knowledge, which is the
# thing being removed.
committed_producers=$(grep -rho 'by: process:[a-z0-9_.-]*' "$ORC_ROOT/.okf" 2>/dev/null | sort -u)
stale_producers=$(printf '%s' "$committed_producers" | grep -v "^by: $producer$" | grep . || true)
n_committed=$(grep -rl "by: $producer" "$ORC_ROOT/.okf" 2>/dev/null | grep -c . | tr -d ' ')
if [ -n "$stale_producers" ]; then
  fail "a concept in .okf/ is attributed to a producer this repository does not answer to"
  printf '%s\n' "$stale_producers" | sed 's/^/      /'
elif [ "$n_committed" -gt 0 ]; then
  pass ".okf/ holds $n_committed concept(s), every one attributed to $producer"
else
  pass ".okf/ ships as a skeleton, so it carries no drafted attribution to go stale"
fi

# The drift banner prints a command for an operator to run, an index marker names
# the file that owns its region, and the README lists the scripts in a table.
# Each of those is a path inside a string, which no interpreter ever checks: a
# rename that misses one tells a human to run something that is not there.
spoken_missing="" n_spoken=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  n_spoken=$(( n_spoken + 1 ))
  [ -f "$ORC_ROOT/$p" ] || spoken_missing="$spoken_missing $p"
done <<< "$(grep -roh 'bin/orc-[a-z0-9-]*\.sh' \
              "$ORC_ROOT"/bin/*.sh "$ORC_ROOT/README.md" "$ORC_ROOT/.okf" "$ORC_ROOT/examples" \
              2>/dev/null | sort -u)"
if [ "$n_spoken" -eq 0 ]; then
  fail "no script name was found to check, so this proves nothing"
elif [ -z "$spoken_missing" ]; then
  pass "all $n_spoken script names spoken in bin/, README.md, examples/ and .okf/ resolve to a file"
else
  fail "a name is spoken that resolves to nothing:$spoken_missing"
fi

printf '\n== every link in a bundle resolves ==\n'
# A concept that cites `/domain/glossary.md` sends a reader after knowledge that
# does not exist, and a bundle is read by a refiner that cannot tell the
# difference. `okf lint` reports this, and the gem is optional, so the rule is
# checked here too: the bundle is plain markdown either way.
#
# The rule is about the bundle's own files, so the target is classified before it
# is resolved. A scheme means somebody else's server, and a relative target that
# climbs out of the bundle root names a file outside it - `../README.md` is the
# repository's README, and whether that exists is git's business. Resolving
# either one as a bundle path finds nothing there and reports it as a broken
# link, which is a correct bundle failing the assertion below: a concept citing
# a repository's own README.md on GitHub ends in `.md` like any other link.
link_is_outside_bundle() {
  case "$1" in
    '#'*|//*) return 0 ;;
    */*) case "${1%%/*}" in *:*) return 0 ;; esac ;;
    *:*) return 0 ;;
  esac
  return 1
}

# `.` and `..` resolved lexically, because the target of a broken link does not
# exist and there is nothing on disk to ask. Climbing above the root leaves a
# path the bundle prefix cannot match, which is the answer wanted there anyway.
path_lexical() {
  local part out=''
  local IFS=/
  for part in $1; do
    case "$part" in
      ''|.) ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$part" ;;
    esac
  done
  printf '%s' "$out"
}

dangling_links() {
  local bundle="$1" f target abs out=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      link_is_outside_bundle "$target" && continue
      case "$target" in
        /*) abs="$bundle/${target#/}" ;;
        *)  abs="$(dirname "$f")/$target" ;;
      esac
      abs=$(path_lexical "$abs")
      case "$abs" in "$bundle"/*) ;; *) continue ;; esac
      [ -f "$abs" ] || out="$out
  ${f#"$bundle/"} links $target"
    done <<< "$(grep -oE '\]\([^)]+\.md(#[^)]*)?\)' "$f" 2>/dev/null \
                 | sed -E 's/^\]\(//; s/\)$//; s/#.*$//')"
  done <<< "$(find "$bundle" -name '*.md' -type f 2>/dev/null | sort)"
  printf '%s' "$out"
}
if [ -n "$(dangling_links "$b/okf")" ]; then
  fail "a freshly drafted bundle links a file that does not exist:$(dangling_links "$b/okf")"
else
  pass "nothing the drafter drafts links a concept that is not there"
fi
if [ -n "$(dangling_links "$ORC_ROOT/.okf")" ]; then
  fail "the committed bundle links a file that does not exist:$(dangling_links "$ORC_ROOT/.okf")"
else
  pass "every markdown link in .okf/ resolves to a file"
fi
# The same control the scanners above get: a link that is genuinely broken has to
# be reported, or the two passes mean nothing. And the scoping is proved in the
# same breath, because a scan that reported nothing at all would pass the two
# assertions above just as quietly: the probe bundle holds one broken concept
# link beside the two spellings that are out of scope, and the report has to name
# the first and neither of the others.
mkdir -p "$b/linkprobe"
{
  printf 'see [the glossary](/domain/glossary.md)\n'
  printf 'the client [README](https://github.com/example/mobile/blob/staging/README.md)\n'
  printf 'this project [readme](../README.md)\n'
} > "$b/linkprobe/index.md"
probe=$(dangling_links "$b/linkprobe")
if [ -z "$probe" ]; then
  fail "the link check finds nothing even in a bundle whose only concept link is broken"
elif [ "$(printf '%s' "$probe" | grep -c .)" = 1 ] \
  && printf '%s' "$probe" | grep -q 'glossary'; then
  pass "a link to a missing concept is caught, and a web or out-of-bundle .md target is not the bundle's business"
else
  fail "the link check reports something other than the one broken concept link:$probe"
fi

rm -rf "$b"

printf '\n== one repository, one concept ==\n'
# The defect this exists for: the drafter drafted a second concept named after
# the repository - subsystems/<org>_api.md - next to a hand-written,
# human-verified subsystems/api.md, and both described the same repository. Refinement resolving "the API" then got two concepts that
# did not say the same thing and nothing to say which was meant. A bundle that
# contradicts itself is worse than a sparse one, because you cannot tell which
# answer you got - and neither this script nor anybody reading the diff noticed.
#
# Detected from what each concept claims to *be* - OKF's `resource:` - reduced by
# repo_ref_key so that ssh and https, .git and not, a tree URL and a blob URL all
# read as one repository. Nothing here knows the name of a project or a concept.
dups=$(bundle_repo_duplicates "$ORC_ROOT/.okf")
if [ -z "$dups" ]; then
  pass "no repository in .okf is described by two concepts"
else
  fail "two concepts describe the same repository"
  printf '%s\n' "$dups" | while IFS=$'\t' read -r key concepts; do
    printf '      %s\n        %s\n' "$key" "$concepts"
  done
fi

claims=$(bundle_repo_claims "$ORC_ROOT/.okf" | grep -c . | tr -d ' ')
if [ "$claims" -gt 0 ]; then
  pass "$claims concept(s) say which repository they describe, so the run above compared something"
else
  # Not a failure, and not a silent pass either. .okf/ ships as a skeleton, so
  # there is nothing here to collide - the scan above is vacuous and says so. What
  # proves the detector still fires is the crafted bundle immediately below, which
  # is where it was always proved: a green line from an empty bundle would
  # otherwise read as "no duplicates found" when it means "nothing was looked at".
  pass "the committed bundle holds no concept claiming a repository, so that scan was vacuous - the crafted bundle below is what proves the detector"
fi

# Both directions, because a check that cannot fail is not a check. A crafted
# bundle with the collision the real one used to have, spelled in two different
# protocols so that string equality alone would miss it.
d=$(mktemp -d)
mkdir -p "$d/subsystems"
cat > "$d/index.md" <<'YML'
---
okf_version: "0.2"
---

# Crafted
YML
cat > "$d/subsystems/api.md" <<'YML'
---
type: Subsystem
title: API
resource: https://github.com/acme/backend
---

# Overview
YML
cat > "$d/subsystems/acme-backend.md" <<'YML'
---
type: Subsystem
title: acme-backend
resource: git@github.com:acme/backend.git
---

# Overview
YML
crafted=$(bundle_repo_duplicates "$d")
if printf '%s' "$crafted" | grep -q 'github.com/acme/backend'; then
  pass "and it does catch one: two spellings of the same remote are one repository"
else
  fail "the duplicate check missed a collision it was pointed straight at"; printf '%s\n' "$crafted"; fi
if printf '%s' "$crafted" | grep -q 'subsystems/acme-backend.md' \
   && printf '%s' "$crafted" | grep -q 'subsystems/api.md'; then
  pass "and names both concepts, so the report says what to reconcile"
else
  fail "the duplicate report does not name the concepts"; printf '%s\n' "$crafted"; fi

# A concept legitimately cites other repositories in its sources - Dashboard
# cites the mobile app to make the case-list trap checkable - and a check that
# read sources as identity would call that a duplicate and be unfixable.
cat > "$d/subsystems/other.md" <<'YML'
---
type: Subsystem
title: Other
resource: https://github.com/acme/frontend
sources:
  - id: cited
    title: another repository this concept cites
    resource: https://github.com/acme/backend/blob/main/app/models/thing.rb
---

# Overview
YML
if bundle_repo_duplicates "$d" | grep -q 'subsystems/other.md'; then
  fail "citing another repository was mistaken for describing it"
else
  pass "citing a repository is not claiming to be it: sources are provenance, resource is identity"
fi
rm -rf "$d"

printf '\n== the gap a verdict leaves behind ==\n'
# The unresolved half of the vocabulary is the payload: it is what a gap-driven
# loop ranks and what a reliability report counts. What is checked here is that
# the record cannot flatter itself - that a term has to be the ticket's own word,
# and that a clean sheet cannot be earned by looking nothing up.
for f in terms_resolved terms_unresolved; do
  if grep -q "\"$f\"" "$ORC_ROOT/prompts/refine.md"; then
    pass "the output contract asks for $f"
  else
    fail "prompts/refine.md does not ask for $f"; fi
done

# The audits, pointed first at what they must catch and then at what they must
# not. An audit that flags a legitimate term is worse than no audit, because a
# noisy one gets ignored and then it protects nothing.
crafted='{"locality_basis":"bundle",
  "terms_resolved":[{"term":"follow-up case","concept":"capabilities/follow-up-cases"}],
  "terms_unresolved":["Revisit","follow_up","FollowUpDecision.vue","app/models/case.rb","the reactivation nudge"]}'
off=$(terms_off_ticket "A revisit can be started, and the follow up cases are listed" "$crafted")
for bad in follow_up FollowUpDecision.vue app/models/case.rb "the reactivation nudge"; do
  if printf '%s\n' "$off" | grep -qxF "$bad"; then
    pass "a term the ticket never said is flagged: $bad"
  else
    fail "terms_off_ticket missed '$bad'"; printf '%s\n' "$off"; fi
done
for good in Revisit "follow-up case"; do
  if printf '%s\n' "$off" | grep -qxF "$good"; then
    fail "terms_off_ticket flagged the ticket's own word: $good"
  else
    pass "the ticket's own word survives a case, hyphen or plural difference: $good"; fi
done

# End to end, because the fields being in the prompt is not the same as them
# reaching the record. Hermetic: a config with nothing to search, so this says
# nothing about whatever clones happen to be on disk.
gp=$(mktemp -d)
mkdir -p "$gp/verdicts/baseline"
cat > "$gp/projects.yml" <<'YML'
ORC:
  repo: ""
  bundle: .okf
  default_branch: main
  verify: unit-only
YML
gap_run() {
  env ORC_PROJECTS_FILE="$gp/projects.yml" ORC_STATE_DIR="$1" ORC_VERDICT_DIR="$2" \
      ORC_JIRA_MODE=fixture ORC_REFINER=replay ORC_REPO_SYNC=off \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$3"
}

gap_run "$gp/real" "$ORC_ROOT/fixtures/verdicts" ORC-103 >/dev/null 2>&1
if jq -e '(.terms_resolved | length) > 0 and (.terms_unresolved | length) > 0' \
     "$gp/real/ORC-103.verdict.json" >/dev/null 2>&1; then
  pass "a fixture run's verdict record carries both halves of the vocabulary"
else
  fail "the verdict record does not carry the resolved and unresolved terms"
  jq -c '{terms_resolved, terms_unresolved}' "$gp/real/ORC-103.verdict.json" 2>/dev/null || true
fi
unresolved_total=$(jq -s '[.[] | (.terms_unresolved // []) | length] | add' "$ORC_ROOT"/fixtures/verdicts/baseline/*.json)
if [ "${unresolved_total:-0}" -gt 0 ]; then
  pass "the shipped replay set records $unresolved_total unresolved term(s), so a fixture run demonstrates the payload rather than a clean sheet"
else
  fail "every shipped verdict resolves everything: the fixtures are too kind to show a gap"
fi

# A verdict that looked nothing up and reports no gap. Recorded as the
# contradiction it is, and not repaired: the refiner's own lists reach the record
# verbatim, because a measurement corrected on the way in measures the correction.
cat > "$gp/verdicts/baseline/ORC-102.json" <<'JSON'
{"verdict":"needs_input","confidence":"low","one_line":"The case list is broken, and which one is not said.",
 "subsystems":[],"files":[],"locality_basis":"none","terms_resolved":[],"terms_unresolved":[],
 "questions":["Which of the two case lists do you mean?"],"duplicate_of":null,"split_into":[],
 "acceptance_criteria":[],"not_verified":"nothing was searched in this run","notes":"n"}
JSON
gap_run "$gp/s1" "$gp/verdicts" ORC-102 >/dev/null 2>&1
if jq -e '.terms_contradiction | type == "string" and contains("none")' \
     "$gp/s1/ORC-102.verdict.json" >/dev/null 2>&1; then
  pass "an empty gap next to locality_basis none is recorded as a contradiction"
else
  fail "a clean sheet earned by looking nothing up was recorded as a clean sheet"
  jq -c '{locality_basis, terms_unresolved, terms_contradiction}' "$gp/s1/ORC-102.verdict.json" 2>/dev/null || true
fi
if [ "$(grep '^terms_contradiction=' "$gp/s1/ORC-102.meta" | cut -d= -f2)" = "yes" ]; then
  pass "and the meta record says so too, so a report can count it without parsing the verdict"
else
  fail "the contradiction is not in the meta record"; fi
if jq -e '(.terms_unresolved | length) == 0 and .verdict == "needs_input"' \
     "$gp/s1/ORC-102.verdict.json" >/dev/null 2>&1; then
  pass "the contradiction is reported beside the verdict, not repaired into it"
else
  fail "the recorded verdict was rewritten rather than flagged"; fi

# A consistent gap, with one term the ticket does not say. The refiner's list is
# kept whole and the audit travels next to it.
cat > "$gp/verdicts/baseline/ORC-102.json" <<'JSON'
{"verdict":"needs_input","confidence":"low","one_line":"The case list is broken, and which one is not said.",
 "subsystems":["subsystems/dashboard"],"files":["src/features/home/CaseList.vue"],"locality_basis":"bundle",
 "terms_resolved":[{"term":"case list","concept":"domain/glossary"}],
 "terms_unresolved":["doctors are complaining","authorisation_claimed_at"],
 "questions":["Which of the two case lists do you mean?"],"duplicate_of":null,"split_into":[],
 "acceptance_criteria":[],"not_verified":"nothing was searched in this run","notes":"n"}
JSON
gap_run "$gp/s2" "$gp/verdicts" ORC-102 >/dev/null 2>&1
if jq -e '.terms_off_ticket == ["authorisation_claimed_at"] and (.terms_unresolved | length) == 2
          and .terms_contradiction == null' "$gp/s2/ORC-102.verdict.json" >/dev/null 2>&1; then
  pass "the code identifier is flagged, the ticket's words are not, and the list is recorded whole"
else
  fail "the off-ticket audit did not land in the record as expected"
  jq -c '{terms_unresolved, terms_off_ticket, terms_contradiction}' "$gp/s2/ORC-102.verdict.json" 2>/dev/null || true
fi
# The gap is for the loop and the report. A reporter asked to read a list of
# words an agent could not look up stops reading these comments, and the existing
# code-shape scan would not catch a plain-English term on its own.
if sed -n "/WOULD POST   \/issue\/ORC-102\/comment/,/+-- raw/p" "$gp/s2/.would-write.log" \
     | grep -qiE 'doctors are complaining|authorisation_claimed_at|terms_unresolved'; then
  fail "the gap record reached the comment the reporter reads"
else
  pass "the gap stays in the verdict record and out of the comment"
fi
rm -rf "$gp"

printf '\n== refinement is scored against tickets the team already solved ==\n'
# The team's git history is the answer key: for a ticket whose work has merged,
# the files it touched are the diff of the commits that name it. The scoring
# command must read that and nothing else - no Jira, no fetch, no write.
score="$ORC_ROOT/bin/orc-locality-score.sh"
if grep -nE '^[^#]*jira_(write|comment_adf|add_label|assign|link_duplicate)' "$score" | grep -q .; then
  fail "the scoring command writes to Jira"
else
  pass "the scoring command posts nothing: it names no Jira write at all"; fi
if grep -nE '(^|[;&|(]|\$\()[[:space:]]*git[[:space:]]' "$score" | code_only | grep -q .; then
  fail "the scoring command runs git directly instead of through git_read"
  grep -nE '(^|[;&|(]|\$\()[[:space:]]*git[[:space:]]' "$score" | code_only
else
  pass "every repository read goes through git_read, so it cannot become a writer"; fi
if grep -q 'ORC_REPO_SYNC=off' "$score"; then
  pass "it pins the sync off: there is no version of measuring locality that wants a fetch"
else
  fail "the scoring command may fetch while it measures"; fi

# The answer key itself, against a real repository with a history built for it.
sc=$(mktemp -d)
scq() { git -C "$sc/hist" -c user.name=orc -c user.email=orc@example.invalid "${@:2}"; }
git -c init.defaultBranch=main init --quiet "$sc/hist"
for step in "a.txt:[ORC-1] the first half" "b.txt:chore: nothing to do with it" \
            "c.txt:[#ORC-1] the second half, spelled with a hash" \
            "d.txt:[ORC-10] a different ticket that starts with the same digits"; do
  printf 'x\n' > "$sc/hist/${step%%:*}"
  scq . add "${step%%:*}"
  scq . commit --quiet -m "${step#*:}"
done
scq . checkout --quiet -b wip
printf 'x\n' > "$sc/hist/e.txt"
scq . add e.txt
scq . commit --quiet -m '[ORC-1] work in progress, never merged'
scq . checkout --quiet main

keyed=$(ticket_merged_paths "$sc/hist" ORC-1 | tr '\n' ' ')
if [ "$keyed" = "a.txt c.txt " ]; then
  pass "the answer key is the merged diff: both spellings counted, unrelated commits and ORC-10 left out"
else
  fail "the answer key is wrong: got '$keyed', expected 'a.txt c.txt '"; fi
if printf '%s' "$keyed" | grep -q 'e.txt'; then
  fail "a commit on an unmerged branch was scored as an answer"
else
  pass "a commit no branch merged is somebody's work in progress, not an answer"; fi

# End to end, offline, with a verdict on disk rather than an agent call: one file
# named that the fix touched, one it did not, one touched file missed.
mkdir -p "$sc/solved/issues" "$sc/solved/search" "$sc/verdicts"
cat > "$sc/solved/issues/ORC-1.json" <<'JSON'
{"id":"1","key":"ORC-1","fields":{"summary":"the case list is broken",
 "description":"the case list is broken since yesterday","labels":[],"issuetype":{"name":"Bug"},
 "status":{"name":"Done","statusCategory":{"key":"done","name":"Done"}},
 "reporter":{"accountId":"1","displayName":"A Reporter"},
 "comment":{"comments":[],"total":0,"maxResults":100,"startAt":0}}}
JSON
printf '{"isLast":true,"issues":[]}\n' > "$sc/solved/search/open-issues.json"
cat > "$sc/verdicts/ORC-1.json" <<'JSON'
{"verdict":"ready","locality_basis":"search","files":["a.txt","never/touched.rb"],
 "terms_resolved":[{"term":"case list","concept":"domain/glossary"}],"terms_unresolved":["yesterday"]}
JSON
cat > "$sc/projects.yml" <<YML
hist:
  repo: $sc/hist
  default_branch: main
  verify: unit-only
YML
scored=$(env ORC_PROJECTS_FILE="$sc/projects.yml" ORC_CLONE_DIR="$sc/clones" \
  "$score" --fixtures "$sc/solved" --verdicts "$sc/verdicts" --json ORC-1 2>/dev/null)
if printf '%s' "$scored" | jq -e '.rows[0]
    | .touched == 2 and .named == 2 and .hit == 1 and .extra == 1 and .missed == 1
      and .locality_basis == "search"' >/dev/null 2>&1; then
  pass "it scores a real verdict against a real diff: 2 touched, 2 named, 1 hit, 1 extra, 1 missed"
else
  fail "the scoring is wrong"; printf '%s\n' "$scored" | jq -c '.rows[0]' 2>/dev/null || printf '%s\n' "$scored"; fi

# A verdict spells a path either way, and both have to count. Given three
# repositories the refiner disambiguates with a repository prefix, and a
# comparison that knew only the bare form reported every named file as a miss -
# a formatting difference presented as a locality failure.
cat > "$sc/verdicts/ORC-1.json" <<'JSON'
{"verdict":"ready","locality_basis":"search","files":["hist/a.txt","never/touched.rb"],
 "terms_resolved":[],"terms_unresolved":["yesterday"]}
JSON
scored=$(env ORC_PROJECTS_FILE="$sc/projects.yml" ORC_CLONE_DIR="$sc/clones" \
  "$score" --fixtures "$sc/solved" --verdicts "$sc/verdicts" --json ORC-1 2>/dev/null)
if printf '%s' "$scored" | jq -e '.rows[0] | .hit == 1 and .missed == 1' >/dev/null 2>&1; then
  pass "a path spelled with its repository in front counts as the same file"
else
  fail "the repository-qualified spelling of a path was scored as a miss"
  printf '%s\n' "$scored" | jq -c '.rows[0]' 2>/dev/null || printf '%s\n' "$scored"; fi
cat > "$sc/verdicts/ORC-1.json" <<'JSON'
{"verdict":"ready","locality_basis":"search","files":["a.txt","never/touched.rb"],
 "terms_resolved":[{"term":"case list","concept":"domain/glossary"}],"terms_unresolved":["yesterday"]}
JSON

# A ticket nothing merged for is reported rather than counted. Silently averaging
# it in at zero would read as a bad score where the honest answer is that there is
# no answer key.
scored=$(env ORC_PROJECTS_FILE="$sc/projects.yml" ORC_CLONE_DIR="$sc/clones" \
  "$score" --fixtures "$sc/solved" --verdicts "$sc/verdicts" --json ORC-1 ORC-999 2>/dev/null)
if printf '%s' "$scored" | jq -e '.summary.tickets == 2 and .summary.scored == 1
    and (.summary.unscorable == ["ORC-999"])' >/dev/null 2>&1; then
  pass "a ticket with no merged work is named and left out of both figures"
else
  fail "a ticket with no answer key was averaged in"; printf '%s\n' "$scored" | jq -c '.summary' 2>/dev/null || true; fi

table=$(env ORC_PROJECTS_FILE="$sc/projects.yml" ORC_CLONE_DIR="$sc/clones" \
  "$score" --fixtures "$sc/solved" --verdicts "$sc/verdicts" ORC-1 2>/dev/null)
if printf '%s' "$table" | grep -q 'proxy and not as a grade'; then
  pass "the caveat is printed where the numbers are, not in a README beside them"
else
  fail "the table reports a percentage with nothing saying how to read it"; fi
if printf '%s' "$table" | grep -qE '^  ORC-1 '; then
  pass "and the table has a row per ticket"
else
  fail "the table printed no row"; printf '%s\n' "$table"; fi
rm -rf "$sc"

printf '\n== example content is out of the active position ==\n'
# examples/ holds sample content for somebody setting this up: a sample fleet for
# config/projects.yml, and the concepts no bootstrap can draft because no
# repository records them.
#
# The whole design is the location. Anything inside .okf/ is structurally part of
# the bundle - refinement reads the directory, the drafter manages it, okf lint
# counts it - so a sample concept in there is indistinguishable from knowledge
# somebody's own team wrote until you open it and read its frontmatter. That is
# the confusion the drafted-versus-verified distinction exists to prevent,
# arriving through a different door.
#
# Separating by location rather than by a frontmatter marker is what makes the
# separation checkable at all: a marker is a promise every reader of the bundle
# has to keep, and this is a path nothing resolves to.
ex="$ORC_ROOT/examples"
ex_concepts=$(find "$ex/okf" -name '*.md' -type f 2>/dev/null | sort)
n_ex=$(printf '%s\n' "$ex_concepts" | grep -c . | tr -d ' ')
if [ "$n_ex" -gt 0 ] && [ -f "$ex/README.md" ]; then
  pass "examples/ holds $n_ex example concept(s) and a README saying what they are for"
else
  fail "examples/ is missing or empty, so everything below proves nothing"
fi

# The load-bearing one. If no script names the path, no run can reach it, and
# that holds for every command rather than for the drafter alone.
ex_readers=$(other_scripts | xargs grep -n 'examples/' 2>/dev/null | code_only || true)
if [ -z "$ex_readers" ]; then
  pass "no script in bin/, golden/ or fixtures/ names examples/ in code, so no run resolves to it"
else
  fail "a script names examples/, which puts example content back on a path something reads"
  printf '%s\n' "$ex_readers" | sed 's/^/      /'
fi

# And measured as well as argued: the suite above ran the drafter, the gap loop,
# the harvest, onboarding and a reset, every one of them in a mktemp sandbox.
examples_sum_after=$(find "$ex" -type f 2>/dev/null | sort \
  | while IFS= read -r f; do printf '%s ' "${f#"$ORC_ROOT"/}"; _sha1 < "$f"; done | _sha1)
if [ "$examples_sum_after" = "$examples_sum_before" ]; then
  pass "and examples/ is byte-identical after every run this suite made"
else
  fail "something in this suite wrote to examples/"
fi

# No example concept may collide with a path the drafter publishes. A
# hand-written concept beside a generated one of the same name is two answers to
# one question with nothing to say which was meant, which is the duplicate
# problem the one-repository-one-concept check already fails on. The published
# paths are read out of the drafter rather than listed here, so a concept added
# there is covered without this check being edited.
drafted_paths=$(grep -oE 'publish "[a-z][a-z0-9/._-]*"' "$drafter" | sed -e 's/^publish "//' -e 's/"$//' | sort -u)
ex_collide=""
for rel in $(printf '%s\n' "$ex_concepts" | sed "s#^$ex/okf/##" | grep . || true); do
  case "$rel" in subsystems/*)
    ex_collide="$ex_collide
  $rel - the drafter owns every subsystems/ concept" ;;
  esac
  printf '%s\n' "$drafted_paths" | grep -qx "$rel" \
    && ex_collide="$ex_collide
  $rel - the drafter publishes that path"
done
if [ -z "$ex_collide" ]; then
  pass "and none of them is a path the drafter publishes, so no copy lands beside a generated concept"
else
  fail "an example concept collides with a drafted one:$ex_collide"
fi

# A copy somebody made and has not finished is the one case the location does not
# cover, because then it really is in the bundle. Three properties close it, and
# all three are frontmatter or prose rather than machinery.
ex_bad=""
solved_company=$(sed -n 's/.*\*\*\([A-Za-z][A-Za-z]*\)\*\*, a tool and equipment rental company.*/\1/p' \
                   "$ORC_ROOT/fixtures/solved/README.md" | head -1)
[ -n "$solved_company" ] || fail "the example solved set no longer names its invented company, so the check below is blind"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="examples/${f#"$ex"/}"
  # A verified: date means a person read the concept and agrees with it. On an
  # unfilled example it would mean somebody signed the fiction.
  concept_is_verified "$f" && ex_bad="$ex_bad
  $rel carries a verified: date, so a refiner is told to quote the fiction in it"
  # A generated: block would put it in the drafter's hands: reported as drift,
  # re-drafted, or both.
  grep -q '^generated:' "$f" && ex_bad="$ex_bad
  $rel carries a generated: block, so the drafter reads it as a stale draft of its own"
  # The worked example is about a company that does not exist, and says so, so a
  # refiner reading an unfilled copy finds no claim about the real product. Same
  # invented company as the example solved set, because a second invented domain
  # would be a second thing to keep consistent.
  if [ -n "$solved_company" ]; then
    # Folded, because the sentence saying so wraps: a check that depended on
    # where a line broke would fail on a reflow and pass on a deletion.
    printf '%s' "$(tr '\n' ' ' < "$f")" \
      | grep -qE "${solved_company}[*]*, a[^.]*company that does not exist" \
      || ex_bad="$ex_bad
  $rel does not mark its worked example as $solved_company, a company that does not exist"
  fi
  # examples/okf/ is not a bundle root, so a markdown link to a local file
  # resolves to nothing here and to whatever the copy's directory holds once it
  # is copied. Backticked paths say the same thing and cannot be wrong.
  grep -qE '\]\((\.|/)[^)]*\.md' "$f" && ex_bad="$ex_bad
  $rel holds a markdown link to a local file, and examples/okf is not a bundle root"
done <<< "$ex_concepts"
if [ -z "$ex_bad" ]; then
  pass "every example concept is unverified, undrafted, marked as fiction and free of local links"
else
  fail "an unfilled copy of an example concept would not be safe in a bundle:$ex_bad"
fi
printf '\n== signing a fact is a command, and it shows what it signs ==\n'
# The whole point of bin/orc-verify.sh, checked behaviourally rather than by
# grep: the sign-off the entire knowledge model rests on used to mean
# hand-editing OKF frontmatter, and a review step nobody can operate is a
# bottleneck on the loop rather than a detail of it.
vf=$(mktemp -d)
mkdir -p "$vf/state" "$vf/okf/domain" "$vf/okf/subsystems"
vled="$vf/verifications.jsonl"
vrun() {
  env ORC_STATE_DIR="$vf/state" ORC_GAP_LEDGER="$vf/gaps.jsonl" \
      ORC_VERIFY_LEDGER="$vled" ORC_PROJECTS_FILE="$vf/projects.yml" \
      ORC_CLONE_DIR="$vf/clones" \
      "$ORC_ROOT/bin/orc-verify.sh" --bundle "$vf/okf" "$@" 2>&1
}
: > "$vf/projects.yml"
# The report wraps its prose at 76 columns, so a sentence in it is not a line in
# it. Every assertion below that looks for a sentence flattens first - otherwise
# a check would pass or fail on where a word happened to land.
flat() { tr '\n' ' ' | tr -s ' '; }
vq1="Which case list do you mean: the one a doctor opens, or the one support works from?"
cat > "$vf/state/VER-1.answers.json" <<JSON
{"key":"VER-1","answers":[
 {"question":"$vq1","asked_at":"2026-08-14T08:00:00.000+0200",
  "answer":"The one a doctor opens after logging in.","author":"Tomas Weber",
  "answered_at":"2026-08-15T09:00:00.000+0200","matched_by":"by position",
  "verbatim":"The one a doctor opens after logging in.","contested":true,"collides_with":"case list"},
 {"question":"$vq1","asked_at":"2026-08-14T08:00:00.000+0200",
  "answer":"the support queue, not the doctor one.","author":"Alina Roth",
  "answered_at":"2026-08-16T10:00:00.000+0200","matched_by":"by number",
  "verbatim":"Re 1: the support queue, not the doctor one.","contested":true,"collides_with":"case list"}
]}
JSON
# A human's prose above the region this script owns, so the check below is about
# a machine leaving somebody's writing alone rather than about an empty file.
cat > "$vf/okf/index.md" <<'MD'
---
okf_version: "0.2"
title: Knowledge bundle
---

# What this is

A human wrote this paragraph and nothing here may discard it.
MD
cat > "$vf/okf/domain/index.md" <<'MD'
# Domain

A human's prose, in a human's file.
MD
# The accumulating table, in the shape bin/orc-okf-draft.sh renders it, because
# that table is what a reviewer is being asked to sign.
cat > "$vf/okf/domain/open-vocabulary.md" <<'MD'
---
type: Glossary
title: Open vocabulary
generated:
  by: process:orc-okf-draft
  at: 2026-08-20T10:00:00Z
---

# The words

| Word | Tickets | What the evidence says |
|---|---|---|
| Nudge | 2 | 2 repositories say the word (api, web), under `notifications.reminder`. None of those keys names anything the code declares. |
| Rebooking | 2 | No configured repository says it at all. |
MD
cat > "$vf/okf/domain/reporter-answers.md" <<MD
---
type: Reference
title: Answers people gave
generated:
  by: process:orc-okf-draft
  at: 2026-08-20T10:00:00Z
---

# What is on the table

| Question | Answered | Ticket | Asked |
|---|---|---|---|
| $vq1 | The one a doctor opens after logging in. - Tomas Weber, 2026-08-15 *(by position)* | VER-1 | 2026-08-14 |
MD
cat > "$vf/okf/subsystems/api.md" <<'MD'
---
type: Subsystem
title: The API
generated:
  by: process:orc-okf-draft
  at: 2026-08-18T10:00:00Z
---

# Overview

Drafted, not verified.
MD
cat > "$vf/gaps.jsonl" <<'JSON'
{"key":"VER-4","prompt_version":"refine-check","verdict":"needs_input","locality_basis":"none","recorded_at":"2026-08-19T10:00:00Z","terms_unresolved":["Nudge","Rebooking"]}
{"key":"VER-7","prompt_version":"refine-check","verdict":"needs_input","locality_basis":"none","recorded_at":"2026-08-21T10:00:00Z","terms_unresolved":["Nudge","Rebooking"]}
JSON

vhash() { find "$vf/okf" -type f | sort | while IFS= read -r f; do printf '%s ' "$f"; _sha1 < "$f"; done | _sha1; }

queue=$(vrun queue)
# The two kinds of item, from the two places they come from, and the numbers
# down the screen with no gap in them: a queue whose visible numbering skips is
# a queue somebody types the wrong number out of.
if printf '%s' "$queue" | grep -q 'awaiting a decision: 4 facts, 1 drafted concept'; then
  pass "the queue holds every answer row, every drafted word and every unsigned concept"
else
  fail "the queue counted the wrong things"; printf '%s\n' "$queue" | head -20; fi
nums=$(printf '%s\n' "$queue" | awk 'match($0, /^  [0-9]+ +\[[0-9a-f]{8}\]/) { print $1 }' | tr '\n' ' ')
if [ "$nums" = "1 2 3 4 5 " ]; then
  pass "and they are numbered 1 to 5 in the order they are printed in, with no gap"
else
  fail "the queue numbering does not match the order it prints in: '$nums'"
  printf '%s\n' "$queue"; fi
# The two accumulating files are the ones whose rows are in the queue, so they
# are deliberately not offered as whole files to sign.
if ! printf '%s' "$queue" | grep -q 'concept  domain/reporter-answers.md' \
   && ! printf '%s' "$queue" | grep -q 'concept  domain/open-vocabulary.md'; then
  pass "neither accumulating file is offered as a whole file to sign"
else
  fail "an accumulating concept was offered for whole-file verification"
  printf '%s\n' "$queue"; fi
# Provenance on the row itself, and how it was matched, because a row matched by
# reading prose is weaker evidence than one the reporter numbered and a reviewer
# has to see which they are looking at before they sign.
if printf '%s' "$queue" | grep -q 'Tomas Weber  (matched by position)' \
   && printf '%s' "$queue" | grep -q 'Alina Roth  (matched by number)'; then
  pass "every answer row names who said it, when, and which of the four rules matched it"
else
  fail "the queue row does not carry its provenance"; printf '%s\n' "$queue" | head -30; fi
if printf '%s' "$queue" | flat | grep -q 'answered this same question differently'; then
  pass "and a contested question says so on both of its rows rather than in a footnote"
else
  fail "a contested question was not flagged where the decision is made"; fi

# The id of the row that mentions a phrase. It is on the row's first line and the
# phrase is on one of the lines under it, so the id has to be remembered as the
# block is walked rather than matched on the same line.
vid() {
  printf '%s\n' "$queue" | awk -v w="$1" '
    match($0, /\[[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\]/) {
      id = substr($0, RSTART + 1, 8)
    }
    index($0, w) && id != "" { print id; exit }'
}
id_tomas=$(vid 'The one a doctor opens')
id_alina=$(vid 'the support queue, not the doctor one')
id_word=$(vid Nudge)
id_concept0=$(printf '%s\n' "$queue" | awk '/concept/ && match($0, /\[[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\]/) { print substr($0, RSTART + 1, 8); exit }')
if [ -n "$id_tomas" ] && [ -n "$id_alina" ] && [ -n "$id_word" ] \
   && [ "$id_tomas" != "$id_alina" ]; then
  pass "every row carries its own eight-character id, so a script never has to name a position"
else
  fail "the queue did not give each row an id of its own: '$id_tomas' '$id_alina' '$id_word'"
  printf '%s\n' "$queue"; fi

# Nothing is signed that was not displayed. --yes answers the confirmation; it
# does not remove the record above it, and there is no flag that does.
signed=$(vrun verify "$id_tomas" --agree --yes)
signed_flat=$(printf '%s' "$signed" | flat)
if printf '%s' "$signed_flat" | grep -q "$vq1" \
   && printf '%s' "$signed_flat" | grep -q 'The one a doctor opens after logging in' \
   && printf '%s' "$signed_flat" | grep -q 'Tomas Weber'; then
  pass "verifying prints the question, the answer and who wrote it before it signs anything"
else
  fail "a fact was signed without being displayed in the same step"
  printf '%s\n' "$signed" | head -30; fi

# Promotion rather than an edit in place. This is the whole design: the drafted
# file has to keep growing, so the signed fact leaves it instead of freezing it.
if [ -f "$vf/okf/domain/verified-answers.md" ] \
   && grep -q 'The one a doctor opens after logging in' "$vf/okf/domain/verified-answers.md"; then
  pass "agreeing promotes the fact into a file this system never drafts"
else
  fail "the signed fact did not reach domain/verified-answers.md"
  ls -la "$vf/okf/domain"; fi
if ! grep -q '^verified:' "$vf/okf/domain/reporter-answers.md"; then
  pass "and the accumulating file it came from is never given a verified: date, so the drafter can still write it"
else
  fail "a verified: date was put on the accumulating file, which freezes it"; fi
if concept_is_verified "$vf/okf/domain/verified-answers.md" \
   && [ -n "$(concept_verified_by "$vf/okf/domain/verified-answers.md")" ]; then
  pass "the promoted file carries a verified: block the shared reader understands, so it names the people rather than a count"
else
  fail "the promoted file's verified: block is not readable by orc-lib.sh"
  sed -n '1,14p' "$vf/okf/domain/verified-answers.md"; fi

# The index region, replaced where it already is, with a human's prose left
# where they put it.
if grep -q 'A human wrote this paragraph' "$vf/okf/index.md" \
   && grep -q 'BEGIN verified by bin/orc-verify.sh' "$vf/okf/index.md" \
   && grep -q 'domain/verified-answers.md' "$vf/okf/index.md"; then
  pass "the signed file is listed in the bundle's front door, and the prose above it survives"
else
  fail "the index region discarded a human's writing, or listed nothing"
  cat "$vf/okf/index.md"; fi
before_render=$(vhash)
vrun render >/dev/null
if [ "$before_render" = "$(vhash)" ]; then
  pass "rendering again writes nothing: the signed files are a view of the ledger and the ledger has not moved"
else
  fail "a second render changed the bundle, so the index or a signed file is not stable"; fi

# The loudest thing the review can print, and the only place it is visible: a
# second person about to decide the same question sees what the first one signed,
# side by side with what is in front of them.
side=$(vrun show "$id_alina")
if printf '%s' "$side" | flat | grep -q 'already decided about this same subject' \
   && printf '%s' "$side" | flat | grep -q 'The one a doctor opens after logging in'; then
  pass "showing a fact names every decision already made about the same subject, and quotes it"
else
  fail "a contradicting signature was not shown to the person about to sign against it"
  printf '%s\n' "$side" | tail -20; fi

# A refusal is a decision, and it is the half with nowhere else to live.
if vrun reject "$id_alina" --yes >/dev/null 2>&1; then
  fail "a refusal was recorded with no reason on it"
else
  pass "a refusal with no reason is refused: the ledger line is the only record it leaves"
fi
refused=$(vrun reject "$id_alina" --reason "The ticket is about the doctor list, not the support one." --yes)
if printf '%s' "$refused" | flat | grep -q 'the support queue, not the doctor one' \
   && grep -q '"decision":"reject"' "$vled"; then
  pass "refusing displays what is being refused and records it in the ledger"
else
  fail "the refusal was not displayed or not recorded"; printf '%s\n' "$refused" | tail -20; fi
q2=$(vrun queue)
q2_flat=$(printf '%s' "$q2" | flat)
if ! printf '%s' "$q2_flat" | grep -q 'The one a doctor opens after logging in' \
   && ! printf '%s' "$q2_flat" | grep -q 'the support queue, not the doctor one'; then
  pass "a decided row leaves the queue, whichever way it was decided"
else
  fail "a decided row is still being offered"; printf '%s\n' "$q2" | head -30; fi

# A word may not be signed as it stands: the drafted row says what the
# repositories say ABOUT the word, which is not what the word means.
# A printed command carries only the outcomes the item actually has. Pasting an
# --agree line under a word and being refused reads as a bug in the tool rather
# than as the rule it is - the misleading-diagnostic rule in a new place.
wordshow=$(vrun show "$id_word")
if ! printf '%s' "$wordshow" | grep -q 'verify .* --agree' \
   && printf '%s' "$wordshow" | grep -q 'verify .* --as' \
   && printf '%s' "$wordshow" | grep -q 'reject'; then
  pass "the commands printed under a word offer --as and --edit and never the --agree it would refuse"
else
  fail "the printed commands include one this item would refuse"
  printf '%s\n' "$wordshow" | tail -5; fi
conceptshow=$(vrun show "$id_concept0")
if printf '%s' "$conceptshow" | grep -q 'verify .* --agree' \
   && ! printf '%s' "$conceptshow" | grep -q 'reject'; then
  pass "and the ones under a drafted concept offer only the signature, because a refusal there would be undone"
else
  fail "a drafted concept was offered a refusal it cannot record"
  printf '%s\n' "$conceptshow" | tail -5; fi

bare=$(vrun verify "$id_word" --agree --yes)
if printf '%s' "$bare" | flat | grep -q 'cannot be agreed to as it stands' \
   && [ ! -f "$vf/okf/domain/verified-vocabulary.md" ]; then
  pass "a word cannot be agreed to bare: signing the evidence line would file it as the definition"
else
  fail "a word was signed with the evidence sentence as its definition, or refused for another reason"
  printf '%s\n' "$bare" | tail -5; fi
worded=$(vrun verify "$id_word" --as "A push notification reminding a patient about an appointment nobody has confirmed." --yes)
if grep -q 'A push notification reminding a patient' "$vf/okf/domain/verified-vocabulary.md" 2>/dev/null \
   && ! grep -q '2 repositories say the word' "$vf/okf/domain/verified-vocabulary.md"; then
  pass "and --as writes the reviewer's sentence rather than the evidence it was shown beside"
else
  fail "the signed vocabulary row carries the wrong text"
  printf '%s\n' "$worded" | tail -10; sed -n '/^| Word/,$p' "$vf/okf/domain/verified-vocabulary.md" 2>/dev/null; fi

# An accumulating file, asked for by the only name anybody would use for it. The
# refusal is the explanation, so it says where the rows are signed instead.
whole=$(vrun verify domain/reporter-answers.md --agree --yes 2>&1)
if printf '%s' "$whole" | flat | grep -q 'keep growing' \
   && ! grep -q '^verified:' "$vf/okf/domain/reporter-answers.md"; then
  pass "signing an accumulating file whole is refused, and the refusal says where its rows are signed"
else
  fail "an accumulating file was signed whole, or the refusal explains nothing"
  printf '%s\n' "$whole" | tail -5; fi
# A drafted concept is re-rendered from the repositories on the next run, so a
# refusal of one would be undone rather than recorded.
id_concept=$(printf '%s\n' "$queue" | awk 'match($0, /\[[0-9a-f]{8}\]/) && /concept/ { print substr($0, RSTART + 1, 8); exit }')
if vrun reject "$id_concept" --reason "no" --yes >/dev/null 2>&1; then
  fail "a drafted concept was refused, which the next draft would undo"
else
  pass "a drafted concept cannot be refused: the next draft would undo it, so it is not offered as a decision"
fi
# Signed whole, which is what a concept file's signature has always meant.
vrun verify domain/../subsystems/api.md --agree --yes >/dev/null 2>&1
vrun verify subsystems/api.md --agree --yes >/dev/null
if concept_is_verified "$vf/okf/subsystems/api.md"; then
  pass "a concept file is still signed whole, by writing verified: into its own frontmatter"
else
  fail "signing a concept did not write a verified: block"
  sed -n '1,14p' "$vf/okf/subsystems/api.md"; fi

# Deciding again is the whole of the way back from a refusal, and it is the reason
# a decided id still resolves: the row has left the queue, `queue --decided`
# prints it, and that id names it again.
if vrun queue --decided | grep -q "$id_alina"; then
  pass "a decided row is still addressable by its id, which is what makes a decision reversible"
else
  fail "a decided row cannot be named again, so a refusal is final in practice"
  vrun queue --decided | head -20; fi
lines_before=$(grep -c '"subject_key"' "$vled")
redecided=$(vrun verify "$id_alina" --as "The support queue, which is a different list." --yes)
if grep -q 'The support queue, which is a different list' "$vf/okf/domain/verified-answers.md" \
   && [ "$(grep -c '"subject_key"' "$vled")" = "$(( lines_before + 1 ))" ]; then
  pass "and deciding again overrules the earlier decision by appending one line, never by rewriting the ledger"
else
  fail "a re-decision did not take effect, or rewrote the ledger"
  printf '%s\n' "$redecided" | tail -10; cat "$vled"; fi
if printf '%s' "$redecided" | flat | grep -q 'decided already'; then
  pass "and it says out loud that it is overruling a decision rather than making a first one"
else
  fail "re-deciding did not say that a decision already stood"
  printf '%s\n' "$redecided" | head -25; fi

# bin/orc-okf-draft.sh must not know these files exist. Behaviourally, because a
# grep for a path cannot tell a comment from a publish call.
sf=$(_sha1 < "$vf/okf/domain/verified-answers.md")
env ORC_PROJECTS_FILE="$vf/projects.yml" ORC_STATE_DIR="$vf/state" ORC_CLONE_DIR="$vf/clones" \
  "$ORC_ROOT/bin/orc-okf-draft.sh" --bundle "$vf/okf" --quiet >/dev/null 2>&1
if [ "$sf" = "$(_sha1 < "$vf/okf/domain/verified-answers.md")" ]; then
  pass "a drafter run leaves the signed files exactly as it found them"
else
  fail "bin/orc-okf-draft.sh wrote a file only bin/orc-verify.sh may write"; fi
# shellcheck disable=SC2016  # a grep pattern matching the literal $ORC_VERIFIED
if ! grep -nE 'publish "(\$ORC_VERIFIED|domain/verified-)' "$ORC_ROOT/bin/orc-okf-draft.sh" | code_only | grep -q .; then
  pass "and it has no publish call naming either of them, so the promotion needs no rail to protect it"
else
  fail "the drafter publishes one of the signed files"
  # shellcheck disable=SC2016  # the same literal pattern
  grep -nE 'publish "(\$ORC_VERIFIED|domain/verified-)' "$ORC_ROOT/bin/orc-okf-draft.sh"; fi

# Three diagnostics that would each name the wrong cause. The queue is read
# through a command substitution, so a refusal inside it would kill only the
# subshell and the run would carry on to report a missing item where the real
# finding is a typo - the repository's own rule about orc_die inside $( ), in a
# third place.
typo=$(vrun show zzz 2>&1)
if printf '%s' "$typo" | flat | grep -q 'none of the three things this takes'; then
  pass "something that is not an address at all is named as that, rather than as an item nothing holds"
else
  fail "a typo was diagnosed as a missing queue item"; printf '%s\n' "$typo" | tail -3; fi
empty=$(env ORC_STATE_DIR="$vf/nostate" ORC_GAP_LEDGER="$vf/nogaps.jsonl" \
  ORC_VERIFY_LEDGER="$vf/noledger.jsonl" ORC_PROJECTS_FILE="$vf/projects.yml" \
  ORC_CLONE_DIR="$vf/clones" "$ORC_ROOT/bin/orc-verify.sh" --bundle "$vf/nobundle" queue 2>&1)
if printf '%s' "$empty" | flat | grep -q 'nothing to review rather than nothing left'; then
  pass "and a bundle that was never drafted is not reported as one somebody has been through"
else
  fail "an undrafted bundle read as a finished review"; printf '%s\n' "$empty" | tail -3; fi
norender=$(env ORC_STATE_DIR="$vf/nostate" ORC_GAP_LEDGER="$vf/nogaps.jsonl" \
  ORC_VERIFY_LEDGER="$vf/noledger.jsonl" ORC_PROJECTS_FILE="$vf/projects.yml" \
  ORC_CLONE_DIR="$vf/clones" "$ORC_ROOT/bin/orc-verify.sh" --bundle "$vf/nobundle" render 2>&1)
if printf '%s' "$norender" | flat | grep -q 'nothing has been signed yet'; then
  pass "and an absent ledger is not reported as one the signed files already match"
else
  fail "rendering with no ledger claimed the files were up to date"; printf '%s\n' "$norender" | tail -3; fi

# `okf validate` is optional here - the gem does not run on every machine - so the
# frontmatter values it would reject are checked without it. `status: current`
# read perfectly well and is not one of the three the format defines, which is
# exactly the kind of thing a bundle carries silently until somebody validates it.
badstatus=""
for _f in "$vf/okf/domain/verified-answers.md" "$vf/okf/domain/verified-vocabulary.md"; do
  [ -f "$_f" ] || continue
  case "$(concept_field "$_f" status)" in
    draft|stable|deprecated) : ;;
    *) badstatus="$badstatus ${_f#"$vf/okf/"}=$(concept_field "$_f" status)" ;;
  esac
  [ -n "$(concept_field "$_f" description)" ] || badstatus="$badstatus ${_f#"$vf/okf/"}=no-description"
done
unset _f
if [ -z "$badstatus" ]; then
  pass "each signed file declares a status the format defines, and a description"
else
  fail "a signed file carries frontmatter OKF does not define:$badstatus"; fi

# The markers are derived from the script's own filename rather than compared
# with a literal, which a half-done rename would pass.
vname="bin/$(basename "$ORC_ROOT/bin/orc-verify.sh")"
if grep -qF "<!-- BEGIN verified by $vname -->" "$ORC_ROOT/bin/orc-verify.sh" \
   && grep -qF "<!-- END verified by $vname -->" "$ORC_ROOT/bin/orc-verify.sh"; then
  pass "the index markers name the script that owns them, spelled from its own filename"
else
  fail "the index region markers do not match bin/orc-verify.sh's own name; a stale marker orphans a region rather than failing"
fi

# The gap loop stops proposing a word somebody decided about, and says which of
# the two it was rather than dropping it silently.
gapout=$(env ORC_STATE_DIR="$vf/state" ORC_GAP_LEDGER="$vf/gaps.jsonl" \
  ORC_VERIFY_LEDGER="$vled" ORC_PROJECTS_FILE="$vf/projects.yml" ORC_CLONE_DIR="$vf/clones" \
  "$ORC_ROOT/bin/orc-gap-loop.sh" --bundle "$vf/okf" --basis any --no-record 2>&1)
if printf '%s' "$gapout" | grep -qE 'Nudge +[0-9]+ +[0-9]+ +agreed on review'; then
  pass "the gap loop stops proposing a word somebody signed, and names the human decision as the reason"
else
  fail "a signed word was proposed again, or the reason was not named"
  printf '%s\n' "$gapout" | head -20; fi

# --- verified concepts nobody has re-read in a long time --------------------
#
# Advisory only. A `verified:` concept is frozen - bin/orc-okf-draft.sh will
# not re-draft it and prompts/refine.md quotes it as knowledge with no
# checking against code - so a signature that has quietly gone false is the
# most confidently-wrong answer this system produces, and this list is the one
# place a person is reminded one is out there. It must inform a human and
# nothing else: the item counts and the exit code are about a *first*
# decision, and an aged concept has already been decided.
ag="$vf/aged"
mkdir -p "$ag/okf/subsystems" "$ag/state"
agrun() {
  env ORC_STATE_DIR="$ag/state" ORC_VERIFY_LEDGER="$ag/led.jsonl" \
      ORC_PROJECTS_FILE="$vf/projects.yml" ORC_CLONE_DIR="$vf/clones" \
      "$ORC_ROOT/bin/orc-verify.sh" --bundle "$ag/okf" "$@" 2>&1
}
agrc=0
cat > "$ag/okf/index.md" <<'MD'
---
okf_version: "0.2"
title: Knowledge bundle
---

# What this is

A human wrote this paragraph.
MD
agrecent=$(date -u +%F)
# A signature inside the threshold: must never reach the advisory list.
cat > "$ag/okf/subsystems/api.md" <<MD
---
type: Subsystem
title: The API
verified:
  - by: person:alina@example.com
    at: $agrecent
---

# Overview

Signed the other day.
MD
# An unsigned concept: belongs in the ordinary drafted-concept queue, never here.
cat > "$ag/okf/subsystems/worker.md" <<'MD'
---
type: Subsystem
title: The worker
generated:
  by: process:orc-okf-draft
  at: 2026-08-20T10:00:00Z
---

# Overview

Drafted, unsigned.
MD
agweb() {  # agweb <iso-date> - rewrite the aged concept with a chosen signature date
  cat > "$ag/okf/subsystems/web.md" <<MD
---
type: Subsystem
title: The web app
verified:
  - by: person:rafa@example.com
    at: $1
---

# Overview

Signed once, years ago, and never revisited.
MD
}

agweb 2019-03-01
agq=$(agrun queue); agrc=$?
agq_flat=$(printf '%s' "$agq" | flat)
if [ "$agrc" = "1" ] \
   && printf '%s' "$agq" | grep -q 'awaiting a decision: 0 facts, 1 drafted concept'; then
  pass "an aged verified concept moves neither the item counts nor the exit code: those still answer for what awaits a first decision"
else
  fail "the aged-signature section leaked into the queue's own accounting (rc=$agrc)"
  printf '%s\n' "$agq" | head -20; fi
if printf '%s' "$agq_flat" | grep -q 'not re-read in over 180 days' \
   && printf '%s' "$agq_flat" | grep -qE 'subsystems/web\.md +last signed by person:rafa@example\.com, [0-9]+ year\(s\) ago'; then
  pass "a signature past the threshold is listed, naming the file, the signer and how long ago"
else
  fail "the aged signature was not surfaced with its signer and age"
  printf '%s\n' "$agq" | tail -20; fi
if ! printf '%s' "$agq_flat" | grep -q 'subsystems/api\.md'; then
  pass "a signature inside the threshold is left off: age is not staleness, and a list a reviewer keeps reading is a short one"
else
  fail "a recent signature was reported as aged"; fi
if printf '%s' "$agq" | grep -qE 'concept +subsystems/worker\.md' \
   && printf '%s' "$agq_flat" | grep -q '1 verified concept not re-read'; then
  pass "an unsigned concept stays in the ordinary drafted-concept queue; only the signed-and-aged one reaches the advisory list"
else
  fail "an unsigned concept was misfiled, or a second concept was pulled into the aged list"
  printf '%s\n' "$agq"; fi

# Renewing the signature: re-reading the concept and signing it again moves the
# date forward, and the concept then leaves this list on its own. No new
# machinery - concept_verified_at simply reads the newer date.
agweb "$agrecent"
agq2=$(agrun queue); agrc2=$?
agq2_flat=$(printf '%s' "$agq2" | flat)
if [ "$agrc2" = "1" ] \
   && ! printf '%s' "$agq2_flat" | grep -q 'not re-read' \
   && printf '%s' "$agq2" | grep -q 'awaiting a decision: 0 facts, 1 drafted concept'; then
  pass "a concept re-signed with a current date drops out of the advisory list by itself, and the counts and exit code never moved"
else
  fail "a renewed signature did not leave the aged list (rc=$agrc2)"
  printf '%s\n' "$agq2" | tail -15; fi
# With every signature fresh, the queue prints exactly what it prints with no
# such feature: the advisory list is purely additive, appended after everything
# else and perturbing nothing above it.
if [ "$agq" != "$agq2" ] && [ "${agq#"$agq2"}" != "$agq" ]; then
  pass "with every signature fresh the queue output is byte for byte what it was before this section existed"
else
  fail "the aged section changed the output above it rather than being appended after it"
  diff <(printf '%s\n' "$agq2") <(printf '%s\n' "$agq") | head -20; fi

# A finished bundle still exits 0 and still says so; the advisory list rides
# alongside that rather than through it.
agrun verify subsystems/worker.md --agree --yes >/dev/null 2>&1
agweb 2019-03-01
agq3=$(agrun queue); agrc3=$?
if [ "$agrc3" = "0" ] \
   && printf '%s' "$agq3" | grep -q 'nothing awaits a decision' \
   && printf '%s' "$agq3" | flat | grep -q 'not re-read in over 180 days'; then
  pass "a finished bundle still exits 0 and still reports nothing awaiting a decision, with the advisory list beneath it"
else
  fail "the advisory list broke the finished-bundle message or its exit code (rc=$agrc3)"
  printf '%s\n' "$agq3"; fi

rm -rf "$vf"

printf '\n== Figma design context ==\n'
# A ticket's description already carries whatever Figma frames the reporter
# meant - a file key and a node-id in a URL Jira may wrap as a link mark's
# href, an inline card's url, or plain visible text. figma_links_in_issue
# reads the raw ADF for all three shapes rather than the plain-text rendering,
# because that rendering keeps a text node's own text and drops every mark's
# attrs - a link whose display text is not the URL, or a smart-embedded frame
# with no visible text at all, would otherwise be invisible to it.
fg=$(mktemp -d)

cat > "$fg/desc.json" <<'JSON'
{"type":"doc","version":1,"content":[
  {"type":"paragraph","content":[{"type":"text","text":"See the design","marks":[{"type":"link","attrs":{"href":"https://www.figma.com/design/ABC123XYZ/My-File?node-id=12-345"}}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"https://www.figma.com/file/ZZZ999/Old?node-id=1%3A23"}]},
  {"type":"inlineCard","attrs":{"url":"https://www.figma.com/design/DEF456/Frame?node-id=7-8"}},
  {"type":"paragraph","content":[{"type":"text","text":"https://www.figma.com/design/GHI789/WholeFile"}]}
]}
JSON
fg_issue=$(jq -c --slurpfile d "$fg/desc.json" -n '{fields:{description:$d[0]}}')
links=$(figma_links_in_issue "$fg_issue")
expected=$(printf 'ABC123XYZ\t12:345\nDEF456\t7:8\nZZZ999\t1:23')
if [ "$links" = "$expected" ]; then
  pass "a link mark's href, an inline card's url and plain visible text are all read, and a bare file link with no frame is skipped"
else
  fail "figma_links_in_issue did not extract the expected file/node pairs"; printf 'got:\n%s\n' "$links"
fi

legacy_issue=$(jq -nc --arg d 'Design at https://www.figma.com/design/LEGACY01/Old?node-id=3-4 please review' '{fields:{description:$d}}')
if [ "$(figma_links_in_issue "$legacy_issue")" = "$(printf 'LEGACY01\t3:4')" ]; then
  pass "a legacy plain-string description is read the same way an ADF one is"
else
  fail "a legacy plain-string description was not parsed for a figma link"
fi

none_issue=$(jq -nc '{fields:{description:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:"nothing here"}]}]}}}')
if [ -z "$(figma_links_in_issue "$none_issue")" ]; then
  pass "a ticket with no figma link names none"
else
  fail "a figma link was invented out of a description that names none"
fi

# The judgment call: fetch an image only when layout plausibly matters. A
# frame or a node with more than one child is a composition an image can show
# that a layer list cannot; a lone text layer's characters already are its
# whole content.
frame_json=$(jq -nc '{nodes:{"1:1":{document:{id:"1:1",type:"FRAME",name:"Screen",children:[{id:"1:2",type:"TEXT",name:"Label",characters:"Hi"}]}}}}')
text_json=$(jq -nc '{nodes:{"1:1":{document:{id:"1:1",type:"TEXT",name:"Label",characters:"Hi"}}}}')
multi_json=$(jq -nc '{nodes:{"1:1":{document:{id:"1:1",type:"GENERIC",name:"X",children:[{id:"a"},{id:"b"}]}}}}')
if figma_wants_image "$frame_json" "1:1"; then pass "a frame is worth an image"; else fail "a frame with children was not judged worth an image"; fi
if figma_wants_image "$text_json" "1:1"; then fail "a lone text layer should not cost an image fetch"; else pass "a lone text layer's characters are its whole content, so no image is fetched for it"; fi
if figma_wants_image "$multi_json" "1:1"; then pass "more than one child is enough on its own, even with no container type"; else fail "a node with several children was not judged worth an image"; fi

summary=$(figma_node_summary "$frame_json" "1:1")
if printf '%s' "$summary" | grep -q 'FRAME "Screen"' && printf '%s' "$summary" | grep -q 'TEXT "Label": "Hi"'; then
  pass "the node summary names every layer's type and name, and a text layer's own characters"
else
  fail "the node summary is missing a layer or its text"; printf '%s\n' "$summary"
fi

# Fixture mode, the same contract jira_read has: a canned file if one exists,
# a clean failure if it does not, and no token needed either way.
fgfix="$fg/fixtures"
mkdir -p "$fgfix/figma/nodes" "$fgfix/figma/images"
printf '%s' "$frame_json" > "$fgfix/figma/nodes/FILEKEY1_1-1.json"
printf 'PNGDATA' > "$fgfix/figma/images/FILEKEY1_1-1.png"

fixture_call() {
  # fixture_call <fixture-dir> <function> <args...>
  local dir="$1" fn="$2"; shift 2
  # shellcheck disable=SC2016  # expands in the child bash -c, not here
  env ORC_FIXTURE_DIR="$dir" ORC_JIRA_MODE=fixture \
    bash -c '. "$0" >/dev/null 2>&1 && "$1" "${@:2}"' "$lib" "$fn" "$@"
}

got_node=$(fixture_call "$fgfix" figma_fetch_node FILEKEY1 1:1)
if printf '%s' "$got_node" | jq -e '.nodes["1:1"].document.type == "FRAME"' >/dev/null 2>&1; then
  pass "figma_fetch_node reads a canned fixture in fixture mode, needing no token at all"
else
  fail "figma_fetch_node did not read its fixture"; printf '%s\n' "$got_node"
fi

missing_node=$(fixture_call "$fgfix" figma_fetch_node NOPE 9:9); rc=$?
if [ -z "$missing_node" ] && [ "$rc" != "0" ]; then
  pass "a missing figma fixture fails the read cleanly rather than returning something invented"
else
  fail "a missing figma fixture did not fail cleanly (rc=$rc)"; fi

imgout="$fg/out.png"
fixture_call "$fgfix" figma_fetch_image FILEKEY1 1:1 "$imgout" >/dev/null
if [ -f "$imgout" ] && [ "$(cat "$imgout")" = "PNGDATA" ]; then
  pass "figma_fetch_image reads a canned fixture image the same way"
else
  fail "figma_fetch_image did not read its fixture image"; fi

# No FIGMA_TOKEN configured, anywhere but fixture mode: a read fails without
# ever touching the network. This is what makes "no token" today's behaviour
# rather than a degraded one - nothing is attempted at all.
mkdir -p "$fg/fakebin-notoken"
cat > "$fg/fakebin-notoken/curl" <<'SH'
#!/usr/bin/env bash
echo "curl was called: $*" >&2
exit 99
SH
chmod +x "$fg/fakebin-notoken/curl"
# shellcheck disable=SC2016  # expands in the child bash -c, not here
notoken_out=$(env -u FIGMA_TOKEN ORC_JIRA_MODE=dry-run PATH="$fg/fakebin-notoken:$PATH" \
  bash -c '. "$0" >/dev/null 2>&1 && figma_fetch_node "$1" "$2"' "$lib" ANY 1:1 2>&1)
notoken_rc=$?
if [ "$notoken_rc" != "0" ] && ! printf '%s' "$notoken_out" | grep -q 'curl was called'; then
  pass "with no FIGMA_TOKEN configured, a figma read fails without ever calling curl"
else
  fail "a figma read reached curl (or did not fail) with no token configured"; printf '%s\n' "$notoken_out"
fi

# A token that IS configured: the live path, against a stubbed socket, the
# same reason the Jira live write path is checked this way rather than
# trusted from fixture mode alone - a break here is invisible to fixture mode
# because a fixture read never builds a URL or a request.
mkdir -p "$fg/fakebin"
cat > "$fg/fakebin/curl" <<'SH'
#!/usr/bin/env bash
log="$FIGMA_STUB_LOG"
printf 'ARGV: %s\n' "$*" >> "$log"
out=""; hdr=""; cfg=""; prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;; -D) hdr="$a" ;; --config) cfg="$a" ;;
  esac
  prev="$a"
done
url="${!#}"
if [ -n "$cfg" ]; then
  printf 'CFGPERM: %s\n' "$(stat -f %Lp "$cfg" 2>/dev/null || stat -c %a "$cfg" 2>/dev/null)" >> "$log"
  printf 'CFGDUMP: ' >> "$log"; cat "$cfg" >> "$log"; printf '\n' >> "$log"
fi
case "$url" in
  *files/BADKEY*)     printf 'HTTP/1.1 404 Not Found\r\n\r\n' > "$hdr"; : > "$out"; printf '404' ;;
  *files/*/nodes*)    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"; cat "$FIGMA_STUB_NODE" > "$out"; printf '200' ;;
  *images/*)          printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"; cat "$FIGMA_STUB_IMAGES" > "$out"; printf '200' ;;
  *render-host*)      printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"; printf 'RENDEREDPNG' > "$out"; printf '200' ;;
  *)                  printf 'HTTP/1.1 500 Internal\r\n\r\n' > "$hdr"; : > "$out"; printf '500' ;;
esac
SH
chmod +x "$fg/fakebin/curl"

printf '{"nodes":{"10:20":{"document":{"id":"10:20","type":"FRAME","name":"Login screen","children":[{"id":"10:21","type":"TEXT","name":"Title","characters":"Sign in"}]}}}}' > "$fg/node.json"
printf '{"images":{"10:20":"http://render-host.test/xyz.png"}}' > "$fg/images.json"

live_call() {
  local fn="$1"; shift
  # shellcheck disable=SC2016  # expands in the child bash -c, not here
  env FIGMA_STUB_LOG="$fg/calls.log" FIGMA_STUB_NODE="$fg/node.json" FIGMA_STUB_IMAGES="$fg/images.json" \
      PATH="$fg/fakebin:$PATH" ORC_JIRA_MODE=dry-run FIGMA_TOKEN=figma-token-not-real \
      bash -c '. "$0" >/dev/null 2>&1 && "$1" "${@:2}"' "$lib" "$fn" "$@"
}

: > "$fg/calls.log"
node_resp=$(live_call figma_fetch_node GOODKEY 10:20)
if printf '%s' "$node_resp" | jq -e '.nodes["10:20"].document.type == "FRAME"' >/dev/null 2>&1; then
  pass "figma_fetch_node calls the real endpoint shape and parses the response"
else
  fail "figma_fetch_node against a stubbed socket did not return the expected node"; printf '%s\n' "$node_resp"
fi
if grep 'ARGV' "$fg/calls.log" | grep -q 'figma-token-not-real'; then
  fail "the Figma token appears in curl's arguments, where the process table can see it"
else
  pass "the Figma token never appears in curl's arguments"
fi
if grep -q 'CFGPERM: 600' "$fg/calls.log"; then
  pass "the token's config file is 0600"
else
  fail "the token's config file is not locked down to 0600"
fi
if grep -q 'X-Figma-Token: figma-token-not-real' "$fg/calls.log"; then
  pass "the token reaches Figma through the header line in that config file instead"
else
  fail "the X-Figma-Token header never reached the request"
fi

: > "$fg/calls.log"
img_out="$fg/live-out.png"
if live_call figma_fetch_image GOODKEY 10:20 "$img_out" >/dev/null && [ "$(cat "$img_out")" = "RENDEREDPNG" ]; then
  pass "figma_fetch_image follows the images endpoint's pre-signed URL to the actual bytes"
else
  fail "figma_fetch_image did not retrieve the rendered PNG through the stub"
fi

: > "$fg/calls.log"
bad_out=$(live_call figma_fetch_node BADKEY 1:1 2>"$fg/bad.err"); bad_rc=$?
if [ -z "$bad_out" ] && [ "$bad_rc" != "0" ]; then
  pass "a 404 on a stale link fails the read rather than dying or returning garbage"
else
  fail "a 404 from Figma was not handled as a clean failure"; fi

rm -rf "$fg"
printf '\n== Figma design context, wired into refinement ==\n'
fg2=$(mktemp -d)
mkdir -p "$fg2/fixtures/issues" "$fg2/fixtures/search" "$fg2/fixtures/figma/nodes" "$fg2/fixtures/figma/images"
printf '{"issues":[]}' > "$fg2/fixtures/search/open-issues.json"

cat > "$fg2/fixtures/issues/FIG-1.json" <<'JSON'
{
  "key": "FIG-1",
  "fields": {
    "summary": "Add the new login screen",
    "description": {
      "type": "doc", "version": 1,
      "content": [
        {"type":"paragraph","content":[{"type":"text","text":"Build this: https://www.figma.com/design/GOODKEY/Login?node-id=10-20"}]}
      ]
    },
    "labels": [], "issuetype": {"name": "Story"},
    "reporter": {"accountId": "acct-1"}, "status": {"name": "To Do"},
    "updated": "2026-01-01T00:00:00.000+0000",
    "comment": {"comments": []}
  }
}
JSON
printf '{"nodes":{"10:20":{"document":{"id":"10:20","type":"FRAME","name":"Login screen","children":[{"id":"10:21","type":"TEXT","name":"Title","characters":"Sign in"}]}}}}' \
  > "$fg2/fixtures/figma/nodes/GOODKEY_10-20.json"
printf 'PNGBYTES' > "$fg2/fixtures/figma/images/GOODKEY_10-20.png"

cat > "$fg2/fixtures/issues/FIG-4.json" <<'JSON'
{
  "key": "FIG-4",
  "fields": {
    "summary": "Some ticket",
    "description": "See https://www.figma.com/design/STALEKEY/Old?node-id=9-9",
    "labels": [], "issuetype": {"name": "Story"},
    "reporter": {"accountId": "acct-1"}, "status": {"name": "To Do"},
    "updated": "2026-01-01T00:00:00.000+0000",
    "comment": {"comments": []}
  }
}
JSON

mkdir -p "$fg2/fakebin"
cat > "$fg2/fakebin/claude" <<'SH'
#!/bin/sh
cat > "$ORC_CHECK_AGENT_INPUT"
jq -nc --arg r '{"verdict":"needs_input","confidence":"low","one_line":"x","subsystems":[],"files":[],"locality_basis":"none","terms_resolved":[],"terms_unresolved":[],"questions":["Which state does the button show while sending?"],"duplicate_of":null,"split_into":[],"acceptance_criteria":[],"not_verified":"nothing","notes":"nothing"}' '{result:$r}'
SH
chmod +x "$fg2/fakebin/claude"

empty_yml="$fg2/empty.yml"
: > "$empty_yml"

fig_refine() {
  local token="$1" tag="$2"
  env ORC_PROJECTS_FILE="$empty_yml" ORC_STATE_DIR="$fg2/state-$tag" ORC_CLONE_DIR="$fg2/clones" \
      ORC_FIXTURE_DIR="$fg2/fixtures" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      FIGMA_TOKEN="$token" ORC_CHECK_AGENT_INPUT="$fg2/agent-input-$tag.txt" PATH="$fg2/fakebin:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force "$3" >"$fg2/refine-$tag.log" 2>&1
  cat "$fg2/agent-input-$tag.txt" 2>/dev/null
}

ctx_with_token=$(fig_refine "figma-token-not-real" "wt" FIG-1)
if printf '%s' "$ctx_with_token" | grep -q '# Design' \
   && printf '%s' "$ctx_with_token" | grep -q 'Opened:' \
   && printf '%s' "$ctx_with_token" | grep -q 'GOODKEY, node 10:20'; then
  pass "a ticket's figma link reaches the refiner as opened design files, named the same way a repository path is"
else
  fail "the design section never reached the agent"; printf '%s\n' "$ctx_with_token" | sed -n '/# Design/,/# Ticket/p'
  echo "--- refine log ---"; cat "$fg2/refine-wt.log"
fi

design_dir="$fg2/state-wt/design/FIG-1"
if [ -f "$design_dir"/GOODKEY_10-20.md ] && grep -q 'FRAME "Login screen"' "$design_dir"/GOODKEY_10-20.md; then
  pass "the node's layer/text structure is written to a file the agent can open with Read"
else
  fail "the node summary file is missing or empty"; ls -la "$design_dir" 2>&1
fi
if [ -f "$design_dir"/GOODKEY_10-20.png ] && [ "$(cat "$design_dir"/GOODKEY_10-20.png)" = "PNGBYTES" ]; then
  pass "and the rendered image is fetched alongside it, because this frame is a composition"
else
  fail "the rendered image was not written, even though the frame has children"
fi

mkdir -p "$fg2/fakebin-notoken"
cat > "$fg2/fakebin-notoken/curl" <<'SH'
#!/usr/bin/env bash
echo "curl was called: $*" >&2
exit 99
SH
chmod +x "$fg2/fakebin-notoken/curl"
fig1_issue=$(cat "$fg2/fixtures/issues/FIG-1.json")
# shellcheck disable=SC2016  # expands in the child bash -c, not here
no_ctx=$(env -u FIGMA_TOKEN ORC_JIRA_MODE=dry-run PATH="$fg2/fakebin-notoken:$PATH" \
  bash -c '. "$0" >/dev/null 2>&1 && figma_design_context "$1" "$2"' "$lib" FIG-1 "$fig1_issue" 2>"$fg2/no-token.err")
if [ -z "$no_ctx" ] && ! grep -q 'curl was called' "$fg2/no-token.err"; then
  pass "with no FIGMA_TOKEN configured, a linked ticket gets no design section at all - today's behaviour, unchanged"
else
  fail "a ticket with a figma link but no token produced a design section, or touched the network"; printf '%s\n' "$no_ctx"; cat "$fg2/no-token.err"
fi

# shellcheck disable=SC2016  # expands in the child bash -c, not here
missing_ctx=$(env ORC_FIXTURE_DIR="$fg2/fixtures" ORC_JIRA_MODE=fixture ORC_STATE_DIR="$fg2/state-missing" FIGMA_TOKEN=irrelevant \
  bash -c '. "$0" >/dev/null 2>&1 && figma_design_context "$1" "$2"' "$lib" FIG-9 \
  "$(jq -nc --arg d 'https://www.figma.com/design/NOFIX/Nope?node-id=1-1' '{fields:{description:$d}}')")
if printf '%s' "$missing_ctx" | grep -q 'Could not open' && ! printf '%s' "$missing_ctx" | grep -q 'Opened:'; then
  pass "a stale or unfetchable link is reported by name in the context rather than silently dropped"
else
  fail "a stale figma link was not reported"; printf '%s\n' "$missing_ctx"
fi

# shellcheck disable=SC2016  # expands in the child bash -c, not here
nolink_ctx=$(env ORC_FIXTURE_DIR="$fg2/fixtures" ORC_JIRA_MODE=fixture ORC_STATE_DIR="$fg2/state-nolink" FIGMA_TOKEN=whatever \
  bash -c '. "$0" >/dev/null 2>&1 && figma_design_context "$1" "$2"' "$lib" FIG-10 \
  "$(jq -nc '{fields:{description:"just plain text, no figma link"}}')")
if [ -z "$nolink_ctx" ]; then
  pass "a ticket naming no figma link gets no design section, token configured or not"
else
  fail "a design section appeared with no link to justify it"
fi

degraded=$(env ORC_PROJECTS_FILE="$empty_yml" ORC_STATE_DIR="$fg2/state-degraded" ORC_CLONE_DIR="$fg2/clones" \
    ORC_FIXTURE_DIR="$fg2/fixtures" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
    FIGMA_TOKEN=irrelevant ORC_CHECK_AGENT_INPUT="$fg2/agent-input-degraded.txt" PATH="$fg2/fakebin:$PATH" \
    "$ORC_ROOT/bin/orc-refine.sh" --judge-only --force FIG-4 2>"$fg2/degraded.err")
if printf '%s' "$degraded" | jq -e '.verdict == "needs_input"' >/dev/null 2>&1; then
  pass "a stale figma link degrades the design context but never the refinement itself"
else
  fail "refinement failed instead of degrading when a figma link could not be opened"
  printf '%s\n' "$degraded"; cat "$fg2/degraded.err"
fi

rm -rf "$fg2"

printf '\n== a ticket that contradicts what the code already does ==\n'
# Every question source so far filters what the refiner already thought of;
# none of it ever added a question from what it read in the repositories. A
# database check constraint is the mechanical evidence a ticket can disagree
# with, and the comparison is the same reuse as everywhere else in this
# system: answer_contradicts_text was built for two different numbers about
# what reads as the same subject, and here the code's own rule stands in for
# one side of it.
cc=$(mktemp -d)
mkdir -p "$cc/repos/api/db" "$cc/fixtures/issues" "$cc/fixtures/search"
cat > "$cc/repos/api/db/schema.rb" <<'RB'
ActiveRecord::Schema[7.1].define(version: 1) do
  create_table "clinics" do |t|
    t.integer "monthly_second_opinion_count", null: false, default: 0
    t.check_constraint "monthly_second_opinion_count <= 3", name: "second_opinion_cap"
  end
end
RB
git -C "$cc/repos/api" init --quiet --initial-branch=main >/dev/null 2>&1
cat > "$cc/projects.yml" <<YML
api:
  repo: $cc/repos/api
  verify: unit-only
YML
printf '{"issues":[]}' > "$cc/fixtures/search/open-issues.json"

# --- the schema reader and the derived finding, at the unit they are written at
cc_rules=$(schema_numeric_rules "$cc/repos/api")
if [ "$cc_rules" = "$(printf 'clinics\tmonthly_second_opinion_count\t<=\t3')" ]; then
  pass "a numeric check constraint is read as table, column, operator and number"
else
  fail "the schema reader did not find the fixture constraint"; printf '%s\n' "$cc_rules"; fi

cc_repos=$(printf 'api\t%s/repos/api\n' "$cc")
cc_txt_contra="A clinic should be able to request up to 5 second opinions in a single month, not the current cap of 3."
cc_txt_same="A clinic can currently request up to 3 second opinions a month; this only adds a warning banner at the limit."
cc_txt_unrelated="Add a CSV export button to the case list screen."

cc_json=$(code_contradictions_json "$(code_contradictions "$cc_txt_contra" "$cc_repos")")
if printf '%s' "$cc_json" | jq -e '
    length == 1 and .[0].table == "clinics" and .[0].column == "monthly_second_opinion_count"
    and .[0].op == "<=" and .[0].code_value == "3"
    and (.[0].ticket_text | contains("5 second opinions"))' >/dev/null 2>&1; then
  pass "a ticket naming a different number for the same rule is a finding, with the rule's own evidence behind it"
else
  fail "the contradiction was not found, or not recorded correctly"; printf '%s\n' "$cc_json"; fi
if [ -z "$(code_contradictions "$cc_txt_same" "$cc_repos")" ]; then
  pass "a ticket naming the code's own number is not a contradiction"
else
  fail "a ticket restating the existing rule was flagged as contradicting it"; fi
if [ -z "$(code_contradictions "$cc_txt_unrelated" "$cc_repos")" ]; then
  pass "a ticket that never mentions the rule produces no finding"
else
  fail "a finding was produced with nothing in the ticket pointing at it"; fi

cat > "$cc/fixtures/issues/CONTRA-1.json" <<JSON
{
  "key": "CONTRA-1",
  "fields": {
    "summary": "Raise the second opinion limit",
    "description": "$cc_txt_contra",
    "labels": [], "issuetype": {"name": "Story"},
    "reporter": {"accountId": "acct-1"}, "status": {"name": "To Do"},
    "updated": "2026-01-01T00:00:00.000+0000",
    "comment": {"comments": []}
  }
}
JSON
cat > "$cc/fixtures/issues/CONTRA-2.json" <<JSON
{
  "key": "CONTRA-2",
  "fields": {
    "summary": "Export button",
    "description": "$cc_txt_unrelated",
    "labels": [], "issuetype": {"name": "Story"},
    "reporter": {"accountId": "acct-1"}, "status": {"name": "To Do"},
    "updated": "2026-01-01T00:00:00.000+0000",
    "comment": {"comments": []}
  }
}
JSON

# Stand-in agents again, for the reason every other promoted-question section in
# this file uses one: no canned fixture verdict is authored against this, and
# one that was would be a fixture measuring whoever wrote it.
cc_run() {
  local name="$1" verdict="$2" key="$3"
  mkdir -p "$cc/fakebin-$name"
  printf '%s' "$verdict" > "$cc/fakebin-$name/verdict.json"
  cat > "$cc/fakebin-$name/claude" <<SH
#!/bin/sh
cat > /dev/null
jq -Rsc '{result: .}' < "$cc/fakebin-$name/verdict.json"
SH
  chmod +x "$cc/fakebin-$name/claude"
  env ORC_PROJECTS_FILE="$cc/projects.yml" ORC_STATE_DIR="$cc/state-$name" ORC_CLONE_DIR="$cc/clones" \
      ORC_FIXTURE_DIR="$cc/fixtures" ORC_REPO_SYNC=off ORC_JIRA_MODE=fixture ORC_REFINER=claude \
      PATH="$cc/fakebin-$name:$PATH" \
      "$ORC_ROOT/bin/orc-refine.sh" --force "$key" >/dev/null 2>&1
}

# The refiner's own question is about something else entirely: the finding
# still has to reach the ticket.
cc_v1='{"verdict":"needs_input","confidence":"medium","one_line":"Second opinions are capped per clinic per month.","subsystems":[],"files":[],"locality_basis":"search","terms_resolved":[],"terms_unresolved":[],"questions":["What should the confirmation screen say once the request is sent?"],"duplicate_of":null,"split_into":[],"acceptance_criteria":["A clinic can request more second opinions than today."],"not_verified":"nothing","notes":""}'
cc_run cc1 "$cc_v1" CONTRA-1
cc1_body=$(comment_of "$cc/state-cc1" CONTRA-1)
if printf '%s' "$cc1_body" | grep -qF 'at most 5' && printf '%s' "$cc1_body" | grep -qF 'at most 3'; then
  pass "the ticket is asked about the number the code already enforces, against the number it names itself"
else
  fail "the contradiction never reached the ticket"; printf '%s\n' "$cc1_body"; fi
if printf '%s' "$cc1_body" | grep -qF 'What should the confirmation screen say'; then
  pass "and the refiner's own question is still asked beside it"
else
  fail "promoting the contradiction displaced the refiner's own question"; fi
if printf '%s' "$cc1_body" | grep -q 'monthly_second_opinion_count\|clinics\.rb\|check_constraint'; then
  fail "a code identifier reached the comment a reporter reads"
  printf '%s\n' "$cc1_body" | grep 'monthly_second_opinion_count\|clinics\.rb\|check_constraint'
else
  pass "no code identifier: the rule is named the way a reporter would name it"; fi
if printf '%s' "$cc1_body" | scan_for_both | grep -q .; then
  fail "the promoted contradiction question does not meet the bar the rest of the comment is held to"
  printf '%s' "$cc1_body" | scan_for_both | sort -u
else
  pass "the promoted contradiction question passes the same code and jargon scan as every other comment"; fi
if jq -e '(.contradiction_gaps | length) == 1
          and (.contradiction_gaps[0].table == "clinics")
          and (.contradiction_gaps[0].code_value == "3")
          and (.contradiction_asked == ["3"])' \
     "$cc/state-cc1/CONTRA-1.verdict.json" >/dev/null 2>&1; then
  pass "the record carries the finding with the rule's evidence, and what was asked beside it"
else
  fail "the verdict record does not carry the contradiction finding"
  jq -c '{contradiction_gaps, contradiction_asked}' "$cc/state-cc1/CONTRA-1.verdict.json" 2>/dev/null || true; fi
if [ "$(meta_field "$cc/state-cc1" CONTRA-1 contradiction_gap_count)" = "1" ] \
   && [ "$(meta_field "$cc/state-cc1" CONTRA-1 contradiction_asked_count)" = "1" ] \
   && [ "$(meta_field "$cc/state-cc1" CONTRA-1 question_count)" = "2" ]; then
  pass "and state/ counts what the ticket was actually asked, with the promoted part separable"
else
  fail "the counts in state/ do not say what the ticket was asked"
  grep -E '^(question_count|contradiction_)' "$cc/state-cc1/CONTRA-1.meta" 2>/dev/null || true; fi

# The refiner asking about the same rule itself, in words close enough to share
# two content words with the subject and to name the code's own number: asking
# again underneath would be the same question twice on one comment.
cc_v2=$(printf '%s' "$cc_v1" | jq -c '.questions = ["Should the clinic be limited to 3 second opinions a month, or is 5 the new limit?"]')
cc_run cc2 "$cc_v2" CONTRA-1
cc2_body=$(comment_of "$cc/state-cc2" CONTRA-1)
if printf '%s' "$cc2_body" | grep -qF 'existing logic already enforces'; then
  fail "a contradiction the refiner already asked about was asked again underneath its own question"
  printf '%s\n' "$cc2_body"
else
  pass "a contradiction the refiner asked about itself is not asked a second time"; fi
if jq -e '(.contradiction_gaps | length) == 1 and (.contradiction_asked == [])' \
     "$cc/state-cc2/CONTRA-1.verdict.json" >/dev/null 2>&1; then
  pass "and it is still recorded, because a finding found and not asked is not a finding never found"
else
  fail "the record lost the finding when the refiner asked about it itself"; fi

# The two verdicts that carry no question list at all. A ready comment is not
# overruled by adding one, and a duplicate is being closed against another
# ticket - the same rule the two prior promoted questions already follow.
cc_v3=$(printf '%s' "$cc_v1" | jq -c '.verdict = "ready" | .questions = []')
cc_run cc3 "$cc_v3" CONTRA-1
if comment_of "$cc/state-cc3" CONTRA-1 | grep -qF 'existing logic already enforces'; then
  fail "a ready comment grew a question, which means a verdict was overruled here rather than reported"
else
  pass "a ready verdict is reported, not overruled: no contradiction question is added to its comment"; fi
if jq -e '(.contradiction_gaps | length) == 1 and (.contradiction_asked == [])' \
     "$cc/state-cc3/CONTRA-1.verdict.json" >/dev/null 2>&1; then
  pass "and the finding is still recorded on a ready verdict"
else
  fail "a ready verdict lost the contradiction finding"; fi

cc_v4=$(printf '%s' "$cc_v1" | jq -c '.verdict = "duplicate" | .duplicate_of = "CONTRA-9" | .questions = []')
cc_run cc4 "$cc_v4" CONTRA-1
if comment_of "$cc/state-cc4" CONTRA-1 | grep -qF 'existing logic already enforces'; then
  fail "a duplicate comment asks about a rule on a ticket that is being closed"
else
  pass "a duplicate is not asked about either: the surviving ticket is where that question belongs"; fi

# The interaction that made the off-ticket and integration promotions worth
# getting right, in a third place: a card announced as having nothing left to
# ask, whose split is drawn around a rule nobody has confirmed still holds, is
# a split drawn around the wrong scope.
cc_v5=$(printf '%s' "$cc_v1" | jq -c '.questions = [] | .split_into = [{"title":"Raise the cap","description":"Change the monthly limit."},{"title":"Notify clinics","description":"Tell clinics about the new limit."}]')
cc_run cc5 "$cc_v5" CONTRA-1
cc5_body=$(comment_of "$cc/state-cc5" CONTRA-1)
if printf '%s' "$cc5_body" | grep -qF 'existing logic already enforces'; then
  pass "a card with no questions of its own still asks about the rule nobody confirmed"
else
  fail "the promoted contradiction was dropped on a card whose own question list was empty"
  printf '%s\n' "$cc5_body"; fi
if printf '%s' "$cc5_body" | grep -q "nothing left to ask, only the split remains"; then
  fail "a card was announced as having nothing left to ask while a contradiction was being asked about"
else
  pass "an open contradiction question is not the terminal state, whatever the refiner's own list says"; fi
if printf '%s' "$cc5_body" | grep -qF 'Raise the cap'; then
  fail "a split proposal drawn around an unconfirmed rule was shown to the reporter"
else
  pass "and the split proposal is withheld, the same as on any other round with a question open"; fi
if [ "$(meta_field "$cc/state-cc5" CONTRA-1 split_ready)" = "no" ] \
   && jq -e '.split_ready == false' "$cc/state-cc5/CONTRA-1.verdict.json" >/dev/null 2>&1; then
  pass "and split_ready says no in both places, so a report reads the same thing the comment says"
else
  fail "split_ready still says yes on a card with a promoted contradiction question open"; fi

# Regression safety: a ticket the code's own rules do not contradict behaves
# exactly as it did before this capability existed.
cc_v6=$(printf '%s' "$cc_v1" | jq -c '.one_line = "Add an export button." | .questions = ["What should the exported filename be?"]')
cc_run cc6 "$cc_v6" CONTRA-2
cc6_body=$(comment_of "$cc/state-cc6" CONTRA-2)
if printf '%s' "$cc6_body" | grep -qF 'existing logic already enforces'; then
  fail "a contradiction question was asked on a ticket the code's rules do not disagree with"
else
  pass "a ticket with no contradiction produces no new question"; fi
if jq -e '.contradiction_gaps == [] and .contradiction_asked == []' \
     "$cc/state-cc6/CONTRA-2.verdict.json" >/dev/null 2>&1; then
  pass "and the record carries no finding, because there is none to record"
else
  fail "an empty contradiction was recorded as though it were a finding"; fi
if [ "$(meta_field "$cc/state-cc6" CONTRA-2 contradiction_gap_count)" = "0" ] \
   && [ "$(meta_field "$cc/state-cc6" CONTRA-2 contradiction_asked_count)" = "0" ]; then
  pass "and state/ counts zero, the same as any other ticket this capability does not touch"
else
  fail "state/ counted a contradiction where the ticket and the code agree"; fi

rm -rf "$cc"

printf '\n== knowledge bundle ==\n'
if okf --version >/dev/null 2>&1; then
  if okf validate "$ORC_ROOT/.okf" >/dev/null 2>&1; then pass "the .okf bundle is OKF v0.2 conformant"; else
    fail "okf validate rejects the bundle"; okf validate "$ORC_ROOT/.okf" || true; fi
else
  printf '  skip  the okf CLI does not run here, so the graph checks are not run.\n'
  printf '        The bundle is plain markdown and refinement reads it either way.\n'
  printf '        To enable: gem install okf (with rbenv, select a ruby first:\n'
  printf '        rbenv local 3.4.8).\n'
fi

printf '\n'
if [ "$failures" = "0" ]; then
  printf 'all checks passed\n\n'; exit 0
fi
printf '%s check(s) failed\n\n' "$failures"; exit 1
