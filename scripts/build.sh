#!/usr/bin/env bash
# Build the PathOps Forgejo image locally with the upstream rootless
# Dockerfile of the patched source tree. Never pushes.
#
# usage: scripts/build.sh
#   IMAGE          local image reference      (default: pathops-forgejo:local)
#   IMAGE_VERSION  release version (labels)   (default: <upstream>-pathops.dev)
#   SKIP_PREPARE=1 reuse an already prepared tree
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PATHOPS_FORGEJO_WORKDIR:-$ROOT/.work}/forgejo"
VERSION=$(tr -d '[:space:]' <"$ROOT/UPSTREAM_VERSION")
IMAGE=${IMAGE:-pathops-forgejo:local}
IMAGE_VERSION=${IMAGE_VERSION:-${VERSION}-pathops.dev}

[ "${SKIP_PREPARE:-0}" = "1" ] || "$ROOT/scripts/prepare-source.sh"

labels=()
while IFS= read -r label; do
  labels+=(--label "$label")
done < <("$ROOT/scripts/metadata.sh" labels "$IMAGE_VERSION")

docker build -f "$SRC/Dockerfile.rootless" --build-arg RELEASE_VERSION="$IMAGE_VERSION" "${labels[@]}" -t "$IMAGE" "$SRC"
echo "build: $IMAGE (release $IMAGE_VERSION)"
