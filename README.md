# PathOps Forgejo

This repository does not maintain an independent Forgejo distribution.

It reproducibly builds selected upstream [Forgejo](https://codeberg.org/forgejo/forgejo)
releases with a minimal PathOps patch set required by the PathOps Cell security
model (PathOps Decision 0050, operation-scoped rich delegated authorization).

Current patch set:

- `0001`: the operator command `forgejo admin user create-authorized-integration`
  honors `[authorized_integration]` (`ALLOWED_DOMAINS`/`BLOCKED_DOMAINS`), so Cell
  onboarding can create a user's Authorized Integration for the Cell's private
  Dex without the web UI; `--reuse-existing` makes it idempotent.
- `0002`: enforcement of PathOps delegated `authorization_details` (RFC 9396) on
  the API, for tokens of the configured PathOps delegation issuer.
- `0003`: the BUILD_AND_PUSH vocabulary (PathOps Decision 0056): a
  repository-scoped read token for the Tekton resolver, a read-only deploy key
  for the build's checkout, and a read-only repository action. Access token
  creation and deletion (basic-auth-only routes) accept a delegated token for
  exactly what its details authorize.
- `0004`: Dex-first sign-in (PathOps Decision 0059): `/user/login` redirects to
  the configured OAuth2 source (the Cell's Dex) and offers no local form;
  Forgejo-local username/password sign-in is served only at the unlinked
  recovery route `/user/login/break-glass`, which does not depend on Dex.

Without the PathOps settings, behavior is identical to upstream.

## Why

The PathOps Tenant Control Plane (TCP) creates a user's application
repositories in Forgejo **as the user**, with short-lived JWTs that the Cell's
Dex derives from one operation the user approved (for example
`create app app-a`). The token reaches Forgejo through the user's Authorized
Integration: Forgejo checks the issuer, the audience Forgejo generated for the
integration, and the integration's claim rules (`sub` = the user, `azp` = the
TCP).

Creating a personal repository requires the broad scopes
`write:user` + `write:repository`. With those alone, a token for `app-a` could
also create `app-b`, add SSH keys or delete repositories. The token's
`authorization_details` carry the exact approved actions and resources; this
patch set makes Forgejo enforce them, so the scope is not the boundary.

## Configuration

```ini
[authorized_integration]
ALLOWED_DOMAINS = dex-<cell>.example.org         ; upstream setting
; PathOps (0002): tokens of this issuer carry PathOps authorization_details
PATHOPS_DELEGATION_ISSUER = https://dex-<cell>.example.org
PATHOPS_DELEGATION_AUTHORIZED_PARTY = pathops-tenant-control-plane
```

```ini
[service]
; PathOps (0004): the OAuth2 authentication source (its unique name) that is
; the normal interactive sign-in
PATHOPS_LOGIN_SOURCE = dex
```

A token whose `iss` is `PATHOPS_DELEGATION_ISSUER` is accepted only when:

- its Authorized Integration pins `sub` and `azp` with equality claim rules;
- its `azp` is `PATHOPS_DELEGATION_AUTHORIZED_PARTY`;
- the request is an API v1 request (never web, git, LFS or packages);
- its `authorization_details` parse as the vocabulary below (at least one
  `forgejo` detail; details of other tools are ignored here).

Each API request is then authorized against the details **before any handler
runs**; anything not listed is `403`:

| Request | Needs |
|---|---|
| `GET /user` | any PathOps token |
| `POST /user/repos` `{name}` | `pathops_repository` `create` of `name` (owner = the token's user) |
| `GET /repos/{o}/{r}`, `.../branches/{b}`, `.../git/trees/{sha}` | `pathops_repository` `create`, `seed` or `read` of `o/r` |
| `POST /repos/{o}/{r}/contents` | `pathops_repository` `seed` of `o/r` |
| `GET /repos/{o}/{r}/hooks` | `pathops_webhook` `configure` of `o/r` |
| `POST /repos/{o}/{r}/hooks`, `PATCH .../hooks/{id}` | `pathops_webhook` `configure` of `o/r`, with exactly its `url` and events among its `events` |
| `GET /users/{o}/tokens` | any `pathops_repository_token` |
| `POST /users/{o}/tokens` `{name, scopes, repositories}` | `pathops_repository_token` `create`: exactly its `name`, its `scopes` (`["read:repository"]`) and the one repository `o/r` |
| `DELETE /users/{o}/tokens/{name}` | `pathops_repository_token` `revoke` of that exact name (never an id) |
| `GET /repos/{o}/{r}/keys` | `pathops_deploy_key` `configure` of `o/r` |
| `POST /repos/{o}/{r}/keys` `{title, key, read_only}` | `pathops_deploy_key` `configure` of `o/r`: its `title`, `read_only` present and `true` |

Detail vocabulary v1:

```json
{"type": "pathops_repository", "version": 1, "tool": "forgejo",
 "owner": "gaston", "repository": "app-a", "actions": ["create", "seed"]}
{"type": "pathops_webhook", "version": 1, "tool": "forgejo",
 "owner": "gaston", "repository": "app-a", "url": "http://.../webhooks/forgejo/<app id>",
 "events": ["push"], "actions": ["configure"]}
{"type": "pathops_repository_token", "version": 1, "tool": "forgejo",
 "owner": "gaston", "repository": "app-a", "name": "pathops-resolution-<app id>",
 "scopes": ["read:repository"], "actions": ["create", "revoke"]}
{"type": "pathops_deploy_key", "version": 1, "tool": "forgejo",
 "owner": "gaston", "repository": "app-a", "title": "pathops-checkout-<app id>",
 "read_only": true, "actions": ["configure"]}
```

`pathops_repository` actions are `create`, `seed` and `read`. A repository
token is created as the user's access token, readable only for that one
repository; `revoke` deletes an orphan of the same name (when the answer of
its creation was lost). A deploy key is never deleted through a delegated
token.

Bodies that are checked are rejected when two keys of an object are equal
ignoring case, and escaped paths are refused, so the value checked is the value
the handler uses.

## Sign-in (0004)

With `PATHOPS_LOGIN_SOURCE` set:

| Request | Answer |
|---|---|
| `GET /user/login` | `303` to `/user/oauth2/<source>` (`redirect_to` kept in its cookie; a signed-in user is redirected as upstream); `503` without a local form when the name is not an active OAuth2 source (never a fallback to local sign-in) |
| `POST /user/login` | `403`: local credentials are not accepted here |
| `GET /user/login/break-glass` | the upstream local sign-in form, without the OAuth2 sources, posting to itself |
| `POST /user/login/break-glass` | the upstream local sign-in (2FA, captcha, remember-me unchanged) |

The break-glass route is not linked from any page, needs nothing from the
OAuth2 provider (it works while Dex is down) and exists only while
`ENABLE_INTERNAL_SIGNIN` is true. It is for a Forgejo-local recovery account,
never for automation. The OAuth2 sign-in and callback, auto-registration and
account linking are upstream's. Without the setting, `/user/login` is upstream's
and `/user/login/break-glass` is `404`.

## Onboarding

Cell onboarding, with operator (bootstrap) authority, never the TCP's:

```bash
forgejo admin user create-authorized-integration --username gaston --name pathops-tcp \
  --issuer https://dex-<cell>.example.org --scope write:user --scope write:repository --repo all \
  --claim-eq sub=<the user's Dex subject> --claim-eq azp=pathops-tenant-control-plane --reuse-existing
```

It prints the integration as JSON, including the Forgejo-generated
`audience` the TCP must request from Dex.

## Image

```text
ghcr.io/pathops/pathops-forgejo:v16.0.5-pathops.<n>
```

- Releases are published only by the `release` workflow, from tags. There is
  no `latest` tag. Pin the image by digest (shown in the workflow summary).
- Built with the upstream `Dockerfile.rootless`, so the runtime layout, user
  and entrypoint match the official rootless image. Forgejo reports the
  upstream version; OCI labels name the PathOps release and the upstream commit.

## Build locally

Requirements: `git`, Go (the version in upstream `go.mod`), Docker with BuildKit.

```bash
./scripts/test.sh      # fetch pinned upstream, apply patches, gofmt, vet, tests of the patched packages
./scripts/build.sh     # same source, docker build -> pathops-forgejo:local (never pushes)
./scripts/prepare-source.sh --clean
```

`test.sh` runs the tests of the packages the patches touch (`cmd`,
`modules/setting`, `services/auth/...`, `routers/api/shared`,
`routers/api/v1/permissions`, `routers/web/auth`) and the integration tests
(SQLite) of the sign-in routes plus upstream's sign-in, OAuth2 and 2FA
integration tests, with `TZ=UTC` because upstream claim tests compare times in
the local zone. `TEST_SSH_PORT` moves the integration server's SSH port when
upstream's 2203 is taken on the machine.

## Versioning and upstream policy

`<upstream-version>-pathops.<patch-revision>`, e.g. `v16.0.5-pathops.1`. The
release workflow rejects tags whose upstream part differs from
`UPSTREAM_VERSION`. `UPSTREAM_VERSION`/`UPSTREAM_COMMIT` change deliberately,
re-verifying that the patches apply and the tests pass; Dependabot updates only
the pinned GitHub Actions. To find the commit of a tag:
`git ls-remote https://codeberg.org/forgejo/forgejo.git 'refs/tags/<tag>'`.

## CI and releases

- **`ci`** (pull requests, pushes to `main`): prepares the source and runs the
  tests. No registry credentials.
- **`release`** (tags `v*-pathops.*`): validates the tag and re-runs the tests;
  builds and pushes the image once (BuildKit SBOM and provenance) in the only
  job that can write packages; records the digest and creates a GitHub
  artifact attestation; a job without write permission checks the binary and
  runs an informational Trivy scan of the published digest.

Verify a release with:

```bash
gh attestation verify oci://ghcr.io/pathops/pathops-forgejo@<digest> --repo PathOps/pathops-forgejo
```

## License

GNU General Public License, version 3 or later, the same license as Forgejo.
See `LICENSE` and `NOTICE`.
