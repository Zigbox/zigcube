#!/usr/bin/env bash
# Fails unless this repository's environment ENV (default `release`) exists and protects a
# release: at least one required reviewer, admins may not bypass it, and only the branch `main`
# may deploy to it. GitHub creates a missing environment, unprotected, the moment a job names it,
# and runs that job at once; a repository that cannot hold protection rules (a private repository
# on a free plan) has none. Either way the owner's approval would be skipped, so the release
# stops here, before anything is written, instead (docs/releases/automation.md, step 1).
#
# Needs GH_TOKEN (actions: read) and GITHUB_REPOSITORY, and runs the gh that GH names
# (.github/actions/setup-gh), else the one on PATH. Prints one line saying what it found.
#
# Usage: release-env.sh [ENV]. Used by release.yml's `plan` and `publish` jobs.
set -euo pipefail

env=${1:-release}
gh=${GH:-gh}
fail() {
  echo "release-env: $1; the release stops (docs/releases/automation.md, step 1)" >&2
  exit 1
}
err=$(mktemp)
trap 'rm -f "$err"' EXIT

base="repos/$GITHUB_REPOSITORY/environments/$env"
if ! summary=$("$gh" api "$base" --jq '[
    ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length),
    .can_admins_bypass,
    .deployment_branch_policy.protected_branches,
    .deployment_branch_policy.custom_branch_policies
  ] | map(tostring) | join(" ")' 2> "$err"); then
  if grep -q 'HTTP 404' "$err"; then fail "the environment '$env' does not exist"; fi
  fail "could not read the environment '$env': $(head -c 200 "$err")"
fi
read -r reviewers bypass protected custom <<< "$summary"
[[ "$reviewers" =~ ^[0-9]+$ ]] || fail "the environment '$env' reads as '$summary'"
[ "$reviewers" -gt 0 ] || fail "the environment '$env' has no required reviewer"
[ "$bypass" = false ] || fail "admins may bypass the environment '$env' (can_admins_bypass)"
if [ "$protected" != false ] || [ "$custom" != true ]; then
  fail "the environment '$env' does not limit deployments to chosen branches"
fi
if ! branches=$("$gh" api "$base/deployment-branch-policies" \
  --jq '[.branch_policies[] | (.type // "branch") + ":" + .name] | sort | join(" ")' \
  2> "$err"); then
  fail "could not read the branch policies of '$env': $(head -c 200 "$err")"
fi
[ "$branches" = "branch:main" ] ||
  fail "the environment '$env' admits '$branches', not the branch main alone"
echo "release-env: '$env' has $reviewers required reviewer(s), no admin bypass, branch main only"
