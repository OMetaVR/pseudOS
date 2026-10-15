#!/usr/bin/env bash
# Merge upstream LiveContainer into this fork, build the result, and only then
# move main. Run by .github/workflows/sync-upstream.yml (see FORK.md).
#
#   1. Candidate = sync/upstream (an earlier or hand/AI-fixed merge) + main + upstream,
#      falling back to a fresh main + upstream merge.
#   2. Merge conflict  -> open an "upstream-sync" issue for the fixer, stop.
#   3. Push the candidate to sync/upstream, build it with build.yml, wait.
#   4. Build passed    -> fast-forward main, start the release build, close issues.
#      Build failed    -> open an issue for the fixer.
#
# Needs: GH_TOKEN, GITHUB_REPOSITORY, git, gh.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/LiveContainer/LiveContainer.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
SYNC_BRANCH="sync/upstream"
BUILD_WORKFLOW="build.yml"
LABEL="upstream-sync"
FIX_LABEL="needs-ai-fix"
REPO="$GITHUB_REPOSITORY"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"
MERGE_OPTS=(--no-edit -s ort -X diff-algorithm=histogram -X find-renames)

log() { echo "::notice::$*"; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config rerere.enabled true

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch --no-tags upstream "$UPSTREAM_BRANCH"
git fetch --no-tags origin main
HAS_SYNC=0
git fetch --no-tags origin "$SYNC_BRANCH" 2>/dev/null && HAS_SYNC=1

UP=$(git rev-parse "upstream/$UPSTREAM_BRANCH")
MAIN=$(git rev-parse origin/main)
SHORT=${UP:0:7}

if git merge-base --is-ancestor "$UP" "$MAIN"; then
  log "main already contains upstream $SHORT"
  exit 0
fi

ensure_labels() {
  gh label create "$LABEL" -R "$REPO" --color 1D76DB --description "Automatic upstream sync" --force >/dev/null
  gh label create "$FIX_LABEL" -R "$REPO" --color D93F0B --description "Picked up by the local Claude fixer" --force >/dev/null
  gh label create ai-fixing -R "$REPO" --color FBCA04 --description "The local Claude fixer is working on it" --force >/dev/null
  gh label create needs-human -R "$REPO" --color B60205 --description "Automatic fixing gave up" --force >/dev/null
}

# open_issue KIND TITLE BODY: one open issue per kind+upstream commit; repeats become comments.
open_issue() {
  local kind=$1 title=$2 body=$3 existing
  ensure_labels
  existing=$(gh issue list -R "$REPO" --state open --label "$LABEL" --json number,title \
    -q ".[] | select(.title == \"$title\") | .number" | head -n1)
  body="$body

<!-- fork-sync kind=$kind upstream=$UP main=$MAIN run=$RUN_URL -->"
  if [ -n "$existing" ]; then
    gh issue comment "$existing" -R "$REPO" --body "Still failing in $RUN_URL"
  else
    gh issue create -R "$REPO" --title "$title" --label "$LABEL" --label "$FIX_LABEL" --body "$body"
  fi
}

# try_merge BASE REF...: merge each REF into BASE on the local "candidate" branch.
CONFLICTS=""
try_merge() {
  local base=$1; shift
  git checkout -q -B candidate "$base"
  for ref in "$@"; do
    if ! git merge "${MERGE_OPTS[@]}" -m "Merge $ref ($(git rev-parse --short "$ref")) into fork" "$ref"; then
      CONFLICTS=$(git diff --name-only --diff-filter=U)
      git merge --abort
      return 1
    fi
  done
}

OK=0
if [ "$HAS_SYNC" = 1 ] && try_merge "origin/$SYNC_BRANCH" origin/main "upstream/$UPSTREAM_BRANCH"; then
  OK=1
  log "Built candidate on top of existing $SYNC_BRANCH"
elif try_merge origin/main "upstream/$UPSTREAM_BRANCH"; then
  OK=1
  log "Built fresh candidate from main"
fi

if [ "$OK" = 0 ]; then
  open_issue conflict "Upstream sync: merge conflict ($SHORT)" "$(cat <<EOF
Merging upstream [\`$SHORT\`](https://github.com/LiveContainer/LiveContainer/commit/$UP) into \`main\` hit conflicts in:

\`\`\`
$CONFLICTS
\`\`\`

The local fixer resolves this on \`$SYNC_BRANCH\` and re-runs the sync. To fix it by hand instead:

\`\`\`sh
git fetch origin && git fetch upstream
git checkout -B $SYNC_BRANCH origin/main
git merge upstream/$UPSTREAM_BRANCH     # resolve, keeping the fork's changes (see FORK.md)
git push -f origin $SYNC_BRANCH
gh workflow run sync-upstream.yml
\`\`\`

Sync run: $RUN_URL
EOF
)"
  exit 1
fi

CANDIDATE=$(git rev-parse candidate)
git push -f origin "candidate:refs/heads/$SYNC_BRANCH"

# Build the candidate. Pushes made with GITHUB_TOKEN don't trigger workflows, but dispatches do.
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run "$BUILD_WORKFLOW" -R "$REPO" --ref "$SYNC_BRANCH" -f release__nightly=false
RUN_ID=""
for _ in $(seq 1 30); do
  sleep 10
  RUN_ID=$(gh run list -R "$REPO" -w "$BUILD_WORKFLOW" -b "$SYNC_BRANCH" -e workflow_dispatch -L 5 \
    --json databaseId,createdAt,headSha \
    -q "[.[] | select(.createdAt >= \"$STARTED\" and .headSha == \"$CANDIDATE\")][0].databaseId // empty")
  [ -n "$RUN_ID" ] && break
done
[ -n "$RUN_ID" ] || { echo "::error::Couldn't find the build run for $CANDIDATE"; exit 1; }
BUILD_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/$RUN_ID"
log "Building $CANDIDATE: $BUILD_URL"

if ! gh run watch "$RUN_ID" -R "$REPO" --interval 30 --exit-status >/dev/null; then
  FAILED_LOG=$(gh run view "$RUN_ID" -R "$REPO" --log-failed 2>/dev/null | sed -E 's/^[^\t]*\t[^\t]*\t[^ ]+ //' \
    | grep -E 'error:|error |\*\* BUILD FAILED|failed with exit code|##\[error\]' | head -n 40 || true)
  open_issue build "Upstream sync: build failed ($SHORT)" "$(cat <<EOF
Upstream [\`$SHORT\`](https://github.com/LiveContainer/LiveContainer/commit/$UP) merged cleanly into \`$SYNC_BRANCH\` (\`${CANDIDATE:0:7}\`), but the build failed: $BUILD_URL

\`\`\`
$FAILED_LOG
\`\`\`

\`main\` was not changed. The local fixer fixes this on \`$SYNC_BRANCH\` and re-runs the sync.

Sync run: $RUN_URL
EOF
)"
  exit 1
fi

# Promote. Plain push: if main moved during the build this fails and the next run retries.
git push origin "candidate:main"
gh workflow run "$BUILD_WORKFLOW" -R "$REPO" --ref main -f release__nightly=true
git push origin --delete "$SYNC_BRANCH" || true

for n in $(gh issue list -R "$REPO" --state open --label "$LABEL" --json number -q '.[].number'); do
  gh issue close "$n" -R "$REPO" --comment "Synced upstream \`$SHORT\` into \`main\` (build passed: $BUILD_URL). A new release build is running."
done
log "main is now ${CANDIDATE:0:7} with upstream $SHORT"
