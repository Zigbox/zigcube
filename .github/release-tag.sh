#!/usr/bin/env bash
# Prints the commit that the tag TAG of this repository names (an annotated tag is followed to its
# commit), or `absent` when there is no such tag. Any other answer from GitHub exits 1, so a
# failed lookup never reads as "absent". Needs GH_TOKEN and GITHUB_REPOSITORY, and runs the gh
# that GH names (.github/actions/setup-gh), else the one on PATH.
#
# Usage: release-tag.sh TAG. Used by release.yml's `plan` and `publish` jobs.
set -euo pipefail

tag=${1:-}
[ -n "$tag" ] || { echo "usage: release-tag.sh TAG" >&2; exit 1; }
gh=${GH:-gh}
err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ref=$("$gh" api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" \
  --jq '.object.type + " " + .object.sha' 2> "$err"); then
  read -r type object <<< "$ref"
  if [ "$type" = tag ]; then
    object=$("$gh" api "repos/$GITHUB_REPOSITORY/git/tags/$object" --jq .object.sha)
  fi
  [[ "$object" =~ ^[0-9a-f]{40}$ ]] || { echo "release-tag: $tag names '$object'" >&2; exit 1; }
  echo "$object"
elif grep -q 'HTTP 404' "$err"; then
  echo absent
else
  echo "release-tag: could not look up $tag: $(head -c 200 "$err")" >&2
  exit 1
fi
