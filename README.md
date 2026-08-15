# Veriqorn Community Install

Public self-hosted installation assets for Veriqorn Community.

Full Quick Start: <https://veriqorn.vercel.app/docs/quick-start-installation>

For Enterprise deployment and activation, see
<https://veriqorn.vercel.app/docs/ai-pro-license>.

This repository contains deployment-facing files only:
- `docker-compose.yml`
- `.env.example`
- installation and update notes for running Veriqorn from prebuilt Docker images in GHCR

Application source code is not included in this repository.

## Quick Start

1. Clone this repository or download `docker-compose.yml` and `.env.example`.
2. Copy `.env.example` to `.env`.
3. Set distinct strong values for `JWT_SECRET`, `TRACE_TOKEN_SECRET`, `POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD`,
   `MINIO_SERVICE_SECRET_KEY`, and the one-time
   `BACKEND_BOOTSTRAP_ADMIN_EMAIL` / `BACKEND_BOOTSTRAP_ADMIN_PASSWORD` pair.
4. Run the preflight check before the first start. It validates required secrets and Compose configuration without printing their values:

```bash
chmod +x ./preflight.sh
./preflight.sh
```

On Windows PowerShell, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\preflight.ps1
```

For an Internet-facing production deployment, configure the TLS values in `.env` and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -Production
```

On Linux, use `./preflight.sh .env --production`.

5. Optional but recommended before customer handoff: verify image access:

```bash
docker pull ghcr.io/veriqorn/veriqorn-backend:latest
docker pull ghcr.io/veriqorn/veriqorn-frontend:latest
```

If either command returns `unauthorized`, make the GHCR package public or run
`docker login ghcr.io` with a token that can read the package before starting.

6. Start the platform:

```bash
docker compose -f docker-compose.yml up -d
```

For an Internet-facing deployment, use the TLS profile instead. It serves the
application through Caddy on ports 80/443; keep the app, database, and MinIO
ports bound to loopback as provided by the Compose file:

```bash
docker compose --profile tls -f docker-compose.yml up -d
```

After `.env` is prepared, the platform starts with that single command.

## Enterprise Overlay

Community is the default and never needs a product license. For Enterprise,
follow the [Enterprise deployment and activation guide](https://veriqorn.vercel.app/docs/ai-pro-license),
then obtain access to the Enterprise image registry and a signed license file
from Veriqorn. Keep that license outside Git, then create
`.env.enterprise` from `.env.enterprise.example` and set its local path.
The example pins the tested Enterprise AI v0.1.0 images (paired with
Community Core v0.2.6) by digest. Do not replace them with an unverified tag.

Authenticate to GHCR with a token that has read access to the private
Enterprise packages before starting:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USER --password-stdin
```

For in-product updates of private Enterprise images, set
`UPDATE_REGISTRY_USERNAME` and `UPDATE_REGISTRY_TOKEN` in local `.env`. The
agent creates a temporary Docker CLI configuration for the pull and removes it
when the job finishes; never commit the token.

The Enterprise image already contains Veriqorn's production **public**
verification key for `veriqorn-prod-2026-01`, so the customer does not need to
configure it. Never put the issuer private key, a customer license, or a
registry credential in `.env.enterprise`. The license operator signs the
customer license with the matching private key and the customer mounts that
issued JSON via `VERIQORN_LICENSE_FILE`. Key rotation is delivered in a new
Enterprise image before licenses signed with a new `keyId` are issued.

This does not replace activation. On first start, the Enterprise backend
creates an installation-specific key pair and an administrator exports its
activation-request JSON. Send that JSON to Veriqorn; it contains only the
installation's public identity and fingerprint. Veriqorn signs a license bound
to that installation and returns the license JSON to mount. Do not send the
installation private key or expect to receive Veriqorn's issuer private key.

Generate and retain a separate `VERIQORN_INSTALLATION_KEY_ENCRYPTION_KEY` for
the Enterprise installation. It must be a 32-byte base64url value and encrypts
the installation's locally stored private identity key. Losing it prevents the
existing installation identity from being read; rotating it is a planned
maintenance operation, not a value to regenerate during an upgrade.

Start the same platform with the overlay:

```bash
docker compose --env-file .env --env-file .env.enterprise \
  -f docker-compose.yml -f compose.enterprise.yml up -d
```

The overlay replaces only `backend` and `frontend` images and mounts the
license file read-only at `/run/veriqorn/license/license.json`. PostgreSQL,
MinIO, named volumes, and all Community environment contracts are unchanged.
Do not put the license document itself in `.env` or commit it to an
installation repository.

## Air-gapped Community bundle

On an Internet-connected staging machine, pull a pinned, signed Community
release, verify its Cosign signature, then create a transport bundle from the
local images:

```powershell
powershell -ExecutionPolicy Bypass -File .\bundle-airgap.ps1 `
  -BackendImage ghcr.io/veriqorn/veriqorn-backend@sha256:<digest> `
  -FrontendImage ghcr.io/veriqorn/veriqorn-frontend@sha256:<digest> `
  -Version v0.1.0 `
  -OutputDirectory .\veriqorn-community-v0.1.0-airgap
```

The script copies Compose/preflight assets, exports the two Docker images, and
writes `bundle-manifest.json` and `SHA256SUMS`. It refuses to overwrite a
bundle and never includes a customer license or registry credentials. On the
offline host, verify `SHA256SUMS`, load the image archives with `docker load`,
set the pinned image references in `.env`, and run the normal preflight and
Compose commands. Enterprise air-gapped delivery additionally requires the
customer-specific Enterprise images and license; it is supplied separately.

## Data Persistence

Application updates recreate containers, but they do not recreate your data volumes.

- PostgreSQL data lives in the Docker named volume `${VERIQORN_POSTGRES_VOLUME}`.
- MinIO object storage lives in the Docker named volume `${VERIQORN_MINIO_VOLUME}`.
- A normal upgrade with `docker compose pull` and `docker compose up -d` keeps both volumes intact.

This means updating to a new backend or frontend image does not wipe projects, runs, licenses, or uploaded artifacts.

Only `docker compose down -v` removes persisted application data.

## What Starts

| Service | Purpose | Lifecycle |
|---------|---------|-----------|
| `frontend` | Web UI on port `3000` | Long-running |
| `backend` | API, auth, uploads, and application logic on port `3001` | Long-running |
| `postgres` | PostgreSQL database stored in the `postgres_data` named volume | Long-running |
| `minio` | S3-compatible object storage stored in the `minio_data` named volume | Long-running |
| `minio-init` | One-shot bucket bootstrap for `artifacts`, `traces`, and `screenshots` | Exits after successful initialization |

A fresh installation starts 5 containers total. In steady state, 4 stay running and `minio-init` remains completed.

## Passwords And Secrets

Infrastructure passwords are configured in `.env` before the first start:
- `JWT_SECRET` - application signing secret
- `TRACE_TOKEN_SECRET` - distinct application secret for trace access tokens
- `POSTGRES_PASSWORD` - PostgreSQL password
- `MINIO_ROOT_PASSWORD` - MinIO admin password
- `MINIO_SERVICE_ACCESS_KEY` and `MINIO_SERVICE_SECRET_KEY` - least-privilege
  credentials used by the backend for artifacts, traces, and screenshots

Optional defaults you can override in `.env`:
- `POSTGRES_USER` (default `postgres`)
- `POSTGRES_DB` (default `test_ops`)
- `MINIO_ROOT_USER` (default `minioadmin`)
- `PLATFORM_VERSION` (default `latest`)
- `POSTGRES_HOST_PORT` (default `5432`)
- `MINIO_API_PORT` (default `9000`)
- `MINIO_CONSOLE_PORT` (default `9001`)
- `FRONTEND_PORT` (default `3000`)
- `BACKEND_PORT` (default `3001`)
- `VERIQORN_POSTGRES_VOLUME` (default `veriqorn-postgres-data`)
- `VERIQORN_MINIO_VOLUME` (default `veriqorn-minio-data`)
- `NEXT_PUBLIC_KB_URL` (default `http://localhost:5174`, if the standalone KB site is deployed)

## First Administrator

On an empty database, the backend creates only the administrator specified by
`BACKEND_BOOTSTRAP_ADMIN_EMAIL` and `BACKEND_BOOTSTRAP_ADMIN_PASSWORD`. No
default application users or passwords exist. Remove the bootstrap password
from the environment after the first successful login.

## Open The Services

- Frontend: `http://localhost:3000`
- Backend: `http://localhost:3001`
- MinIO Console: `http://localhost:9001`

## Reset To A Clean Installation

```bash
docker compose -f docker-compose.yml down -v
```

This removes the PostgreSQL and MinIO named volumes created by Docker Compose.

## Upgrading

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
```

To pin a specific release, set `PLATFORM_VERSION` in `.env`.

If you stay on the same PostgreSQL major version, the existing database volume continues to work across application updates. A PostgreSQL major upgrade is different: treat that as a database migration and take a backup first.

The bundled update agent pulls immutable image digests and verifies their
keyless Cosign signatures before switching versions. Keep
`UPDATE_COSIGN_IDENTITY` set to the official publish workflow unless your
organization deliberately publishes its own signed images.

## DevOps Handoff

For customer-facing install preflight, validation, and data-safety commands, see
`DEVOPS-HANDOFF.md`.

## Images

- `ghcr.io/veriqorn/veriqorn-backend`
- `ghcr.io/veriqorn/veriqorn-frontend`

Available package versions are listed at `https://github.com/orgs/veriqorn/packages`.

## Related Repositories

- Community source code: `https://github.com/Veriqorn/veriqorn`
- Public docs and marketing site: `https://github.com/veriqorn/veriqorn-site`

## License

The files in this repository are licensed under Apache-2.0.
