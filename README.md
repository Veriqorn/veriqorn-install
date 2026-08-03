# Veriqorn Community Install

Public self-hosted installation assets for Veriqorn Community.

This repository contains deployment-facing files only:
- `docker-compose.yml`
- `.env.example`
- installation and update notes for running Veriqorn from prebuilt Docker images in GHCR

Application source code is not included in this repository.

## Quick Start

1. Clone this repository or download `docker-compose.yml` and `.env.example`.
2. Copy `.env.example` to `.env`.
3. Set strong values for `JWT_SECRET`, `POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD`,
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

- Product source code: `https://github.com/veriqorn/veriqorn-platform`
- Public docs and marketing site: `https://github.com/veriqorn/veriqorn-site`

## License

The files in this repository are licensed under Apache-2.0.
