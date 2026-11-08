#!/usr/bin/env bash
# Test the patched Forgejo source: gofmt and go vet on the packages the patches
# touch, and their unit tests, including every PathOps test. The full upstream
# suite (and its integration tests) is upstream's; these packages are the ones
# the patch set changes.
#
# usage: scripts/test.sh   (set SKIP_PREPARE=1 to reuse an already prepared tree)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PATHOPS_FORGEJO_WORKDIR:-$ROOT/.work}/forgejo"
TAGS="sqlite sqlite_unlock_notify"
# Upstream's claim tests compare times in the local zone against UTC values.
export TZ=UTC

[ "${SKIP_PREPARE:-0}" = "1" ] || "$ROOT/scripts/prepare-source.sh"
cd "$SRC"

echo "test: gofmt on Go files touched by the patches"
mapfile -t changed < <({ git diff --name-only; git ls-files --others --exclude-standard; } | grep '\.go$' | sort -u)
if [ "${#changed[@]}" -gt 0 ]; then
  unformatted=$(gofmt -l "${changed[@]}")
  [ -z "$unformatted" ] || {
    echo "test: gofmt needed for: $unformatted" >&2
    exit 1
  }
fi

packages=(./cmd/ ./modules/setting/ ./services/auth/... ./routers/api/shared/ ./routers/api/v1/permissions/)
echo "test: go vet ${packages[*]}"
go vet -tags "$TAGS" "${packages[@]}"

echo "test: go test ${packages[*]}"
go test -tags "$TAGS" "${packages[@]}"

echo "test: PathOps tests"
out=$(go test -tags "$TAGS" -count=1 -v ./services/auth/pathops/ ./services/auth/method/ ./routers/api/v1/permissions/ \
  -run 'PathOps|TestSourceRepositoryToken|TestWebhookToken|TestParse|TestRepositoryTokenDetail|TestDeployKeyDetail|TestRepositoryRead')
echo "$out" | grep -E -- '^--- (PASS|FAIL)'
for t in TestSourceRepositoryToken TestWebhookToken TestParse TestAuthorizedIntegrationPathOps \
  TestRepositoryTokenDetail TestDeployKeyDetail TestRepositoryRead TestParseRepositoryTokenAndDeployKey \
  TestReqBasicOrRevProxyAuthPathOps; do
  grep -q -- "--- PASS: $t " <<<"$out" || {
    echo "test: $t did not run and pass" >&2
    exit 1
  }
done

echo "test: OK"
