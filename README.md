# Veriqorn Community Install

Public self-hosted installation assets for Veriqorn Community.

This repository contains deployment files only:
- `docker-compose.yml`
- `.env.example`
- setup notes for running Veriqorn with prebuilt Docker images from GHCR

Application source code is not included in this repository.

## Quick Start

1. Clone this repository or download `docker-compose.yml` and `.env.example`.
2. Copy `.env.example` to `.env`.
3. Set a strong `JWT_SECRET`, `POSTGRES_PASSWORD`, and `MINIO_ROOT_PASSWORD`.
4. Start the stack:

```bash
docker compose -f docker-compose.yml up -d
```

5. Open the services:
- Frontend: `http://localhost:3000`
- Backend: `http://localhost:3001`
- MinIO Console: `http://localhost:9001`

## Default Credentials

- Admin: `admin@example.com` / `admin123`
- User: `user@example.com` / `user123`

Change the default passwords after the first login in production deployments.

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

## Images

- `ghcr.io/veriqorn/veriqorn-backend`
- `ghcr.io/veriqorn/veriqorn-frontend`

Available package versions are listed at `https://github.com/orgs/veriqorn/packages`.

## License

The files in this repository are licensed under Apache-2.0.
