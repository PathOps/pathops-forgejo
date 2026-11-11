#!/usr/bin/env bash
# Test the patched Forgejo source: gofmt and go vet on the packages the patches
# touch, and their unit tests, including every PathOps test. The full upstream
# suite (and its integration tests) is upstream's; these packages are the ones
# the patch set changes, plus the integration tests of the sign-in routes
# (patch 0004) and upstream's sign-in, OAuth2 and 2FA integration tests.
#
# usage: scripts/test.sh   (set SKIP_PREPARE=1 to reuse an already prepared tree)
#   TEST_SSH_PORT  the integration server's SSH port (default upstream's 2203),
#                  for a machine where that port is taken
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

packages=(./cmd/ ./modules/setting/ ./services/auth/... ./routers/api/shared/ ./routers/api/v1/permissions/ ./routers/web/auth/)
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

echo "test: integration (sqlite): PathOps sign-in and upstream sign-in, OAuth2, 2FA"
make generate-ini-sqlite >/dev/null
[ -z "${TEST_SSH_PORT:-}" ] || sed -i "s/^SSH_PORT *= .*/SSH_PORT         = $TEST_SSH_PORT/" tests/sqlite.ini
go test -c -tags "$TAGS" forgejo.org/tests/integration -o integrations.sqlite.test
out=$(GITEA_ROOT="$SRC" GITEA_CONF=tests/sqlite.ini ./integrations.sqlite.test -test.v \
  -test.run '^(TestPathOps|TestSignin|TestSignIn|TestOAuth|TestLinkAccount|TestSignOut|TestSignup|TestTwoFactor|TestWebAuthn)')
echo "$out" | grep -E -- '^--- (PASS|FAIL)'
! grep -q -- '^--- FAIL' <<<"$out" || exit 1
for t in TestPathOpsLoginRedirectsToDex TestPathOpsLoginOffersNoLocalForm TestPathOpsBreakGlass TestPathOpsBreakGlassWithoutDex \
  TestPathOpsDexCallback TestPathOpsLoginUnset; do
  grep -q -- "--- PASS: $t " <<<"$out" || {
    echo "test: $t did not run and pass" >&2
    exit 1
  }
done

echo "test: OK"
