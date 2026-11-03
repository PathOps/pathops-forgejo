#!/usr/bin/env bash
# Release metadata shared by build.sh and the GitHub workflows.
#
# usage: scripts/metadata.sh check-tag <tag>       validate <upstream-version>-pathops.<n>
#        scripts/metadata.sh labels <image-version> print OCI labels, one KEY=VALUE per line
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(tr -d '[:space:]' <"$ROOT/UPSTREAM_VERSION")
COMMIT=$(tr -d '[:space:]' <"$ROOT/UPSTREAM_COMMIT")
SOURCE_URL=https://github.com/PathOps/pathops-forgejo

case "${1:-}" in
  check-tag)
    tag=${2:?tag required}
    re="^${VERSION//./\\.}-pathops\\.[1-9][0-9]*$"
    if [[ ! "$tag" =~ $re ]]; then
      echo "metadata: tag '$tag' does not match ${VERSION}-pathops.<n> (UPSTREAM_VERSION=$VERSION)" >&2
      exit 1
    fi
    echo "metadata: tag $tag matches UPSTREAM_VERSION $VERSION"
    ;;
  labels)
    image_version=${2:?image version required}
    revision=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    cat <<LABELS
org.opencontainers.image.title=pathops-forgejo
org.opencontainers.image.description=PathOps patched Forgejo: operator-created Authorized Integrations and PathOps delegated authorization_details enforcement
org.opencontainers.image.source=$SOURCE_URL
org.opencontainers.image.url=$SOURCE_URL
org.opencontainers.image.version=$image_version
org.opencontainers.image.revision=$revision
org.opencontainers.image.licenses=GPL-3.0-or-later
org.opencontainers.image.vendor=PathOps
io.pathops.forgejo.upstream.version=$VERSION
io.pathops.forgejo.upstream.commit=$COMMIT
LABELS
    ;;
  *)
    echo "usage: $0 check-tag <tag> | labels <image-version>" >&2
    exit 2
    ;;
esac
