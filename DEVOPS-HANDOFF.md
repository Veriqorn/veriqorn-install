# Veriqorn Self-Hosted DevOps Handoff

Status as of `2026-05-13`: GHCR image access is public, and the documented
compose install path from `latest` passed the fresh-volume smoke.

## Release Blocker

Verify image access from the target environment:

```bash
docker pull ghcr.io/veriqorn/veriqorn-backend:latest
docker pull ghcr.io/veriqorn/veriqorn-frontend:latest
```

Both commands must succeed before customer handoff. If either returns
`unauthorized`, make the GHCR package public or provide a read-capable GHCR
token and run:

```bash
docker login ghcr.io
```

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/veriqorn/veriqorn-install/master/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/veriqorn/veriqorn-install/master/.env.example
cp .env.example .env
```

Before first start, set production values in `.env`:

- `JWT_SECRET`
- `POSTGRES_PASSWORD`
- `MINIO_ROOT_PASSWORD`
- `MINIO_SERVICE_SECRET_KEY`
- `FRONTEND_URL`
- `CORS_ORIGINS`
- `NEXT_PUBLIC_API_URL`
- `NEXT_PUBLIC_KB_URL`, if the standalone Knowledge Base site is deployed

Run the preflight check before starting. It fails on placeholder or weak
secrets, a missing outbound-host allowlist, invalid Compose interpolation, and,
with `-Production`, missing HTTPS and secure-cookie settings:

```bash
chmod +x ./preflight.sh
./preflight.sh .env --production
```

For a Windows-hosted installation, use `powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -Production` instead.

For production, prefer a pinned release tag:

```env
PLATFORM_VERSION=v0.1.0
```

Start:

```bash
docker compose --env-file .env --profile tls -f docker-compose.yml up -d
docker compose --env-file .env -f docker-compose.yml ps
```

Do not publish backend, PostgreSQL, or MinIO directly through an Internet
firewall. The supplied Compose file binds them to loopback; expose only Caddy
ports 80/443 after the preflight check passes.

## Validate

```bash
curl -fsS http://localhost:3001/healthz
curl -fsS http://localhost:3000/runtime-config.js
```

Authenticate:

```bash
curl -sS -c veriqorn.cookies -X POST http://localhost:3001/api/v1/auth/session \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"admin123"}'
```

Upload a real Allure result or ZIP:

```bash
curl -sS -b veriqorn.cookies -X POST http://localhost:3001/api/v1/projects/default/imports/allure-jobs \
  -F "file=@allure-results.zip" \
  -F "runName=Release Smoke" \
  -F "sourceKind=ci_archive" \
  -F "environment=production-smoke"
```

Then confirm the run appears in the UI at `http://localhost:3000`.

## Data Safety

Normal updates preserve data:

```bash
docker compose --env-file .env -f docker-compose.yml pull
docker compose --env-file .env -f docker-compose.yml up -d
```

Do not run `docker compose down -v` unless you intentionally want to remove
PostgreSQL and MinIO data volumes.

## In-app updates

The default Compose file includes a local `update-agent`. A platform admin can
then see the installed release and request an update in **Settings → Platform
Updates**; no server shell access is needed for the normal update path.

Before starting, set a unique high-entropy value in `.env`:

```env
PLATFORM_UPDATE_AGENT_TOKEN=<at-least-32-random-characters>
```

The agent is intentionally not published on a host port. The backend talks to
it only over the private Compose network. It is the only service with Docker
socket access, and it accepts only a token-authenticated request from the
backend. It does not accept a Docker image, tag, command, or Compose path from
the UI: it selects the latest stable GitHub release, pulls only the allow-listed
Veriqorn backend/frontend images, records immutable image digests, updates
`PLATFORM_VERSION`, recreates those two services, and waits for backend health.

Docker socket access is root-equivalent. Keep the Compose file and `.env`
owned by a trusted operator, do not expose `update-agent` through a reverse
proxy or host port, and rotate `PLATFORM_UPDATE_AGENT_TOKEN` if it is exposed.
The agent deliberately does not perform automatic rollback after a failed
health check because a release may already have applied an irreversible database
migration. Restore from the normal database backup procedure if required.
