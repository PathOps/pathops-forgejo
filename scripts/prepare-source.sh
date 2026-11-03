#!/usr/bin/env bash
# Prepare a patched upstream Forgejo source tree.
#
# usage: scripts/prepare-source.sh          fetch the pinned upstream tag and apply patches/*.patch
#        scripts/prepare-source.sh --clean  remove the prepared tree
#
# The tree is created at $PATHOPS_FORGEJO_WORKDIR/forgejo (default:
# <repo>/.work/forgejo) and is recreated from scratch on every run. The script
# fails if the upstream tag does not resolve to UPSTREAM_COMMIT or if any patch
# does not apply cleanly.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${PATHOPS_FORGEJO_WORKDIR:-$ROOT/.work}
SRC="$WORK/forgejo"
UPSTREAM_REPO=${UPSTREAM_REPO:-https://codeberg.org/forgejo/forgejo.git}
VERSION=$(tr -d '[:space:]' <"$ROOT/UPSTREAM_VERSION")
COMMIT=$(tr -d '[:space:]' <"$ROOT/UPSTREAM_COMMIT")

die() {
  echo "prepare-source: $*" >&2
  exit 1
}

case "$WORK" in
  "" | /) die "refusing to use workdir '$WORK'" ;;
esac

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$SRC"
  echo "prepare-source: removed $SRC"
  exit 0
fi

rm -rf "$SRC"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" remote add origin "$UPSTREAM_REPO"
git -C "$SRC" fetch -q --depth 1 --no-tags origin "+refs/tags/$VERSION:refs/tags/$VERSION"

actual=$(git -C "$SRC" rev-parse "refs/tags/$VERSION^{commit}")
[ "$actual" = "$COMMIT" ] || die "upstream tag $VERSION resolves to $actual, expected $COMMIT"
git -C "$SRC" -c advice.detachedHead=false checkout -q "$COMMIT"

shopt -s nullglob
patches=("$ROOT"/patches/*.patch)
[ "${#patches[@]}" -gt 0 ] || die "no patches found in $ROOT/patches"
for p in "${patches[@]}"; do
  git -C "$SRC" apply --check "$p" || die "patch does not apply cleanly: $(basename "$p")"
  git -C "$SRC" apply "$p"
  echo "prepare-source: applied $(basename "$p")"
done

# The version Forgejo reports (Makefile STORED_VERSION_FILE): the upstream
# release, so API clients see the version whose behavior they get.
compat=$(sed -n 's/^GITEA_COMPATIBILITY ?= //p' "$SRC/Makefile")
echo "${VERSION#v}+${compat}" >"$SRC/VERSION"

echo "prepare-source: Forgejo $VERSION ($COMMIT) + ${#patches[@]} patch(es) ready in $SRC"
