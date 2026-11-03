#!/bin/sh
# Builds and pushes ghcr.io/zigbox/python-app:v1 and :v2 for demo-c2 (linux/amd64),
# then prints both digests and checks that they share every layer but the last.
# Needs docker with buildx, and `docker login ghcr.io` with a token that has write:packages.
set -eu
repo=ghcr.io/zigbox/python-app
cd "$(dirname "$0")"
base=$(docker buildx imagetools inspect python:3.12-slim --format '{{json .Manifest}}' \
  | python3 -c 'import json,sys; m=json.load(sys.stdin); print([d["digest"] for d in m["manifests"] if d["platform"]["architecture"]=="amd64" and d["platform"]["os"]=="linux"][0].split(":")[1])')
work=$(mktemp -d)
for v in v1 v2; do
  sed "s/BASE_DIGEST/$base/" Dockerfile > "$work/Dockerfile"
  sed "s/^VERSION = \"v1\"/VERSION = \"$v\"/" app.py > "$work/app.py"
  docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
    --push -t "$repo:$v" "$work"
done
rm -rf "$work"
for v in v1 v2; do
  printf '%s %s\n' "$v" "$(docker buildx imagetools inspect "$repo:$v" --format '{{json .Manifest}}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
done
for v in v1 v2; do
  docker buildx imagetools inspect --raw "$repo:$v" \
    | python3 -c 'import json,sys; print(" ".join(l["digest"][7:19] for l in json.load(sys.stdin)["layers"]))'
done
