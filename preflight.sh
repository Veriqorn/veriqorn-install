#!/usr/bin/env sh
set -eu

env_file="${1:-.env}"
production="${VERIQORN_PREFLIGHT_PRODUCTION:-false}"

if [ "${2:-}" = "--production" ]; then
  production=true
fi

if [ ! -f "$env_file" ]; then
  echo "Environment file not found: $env_file" >&2
  exit 1
fi

setting() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$env_file" | tail -n 1 | sed 's/[[:space:]]*$//'
}

errors=0
warnings=0

fail() { printf '%s\n' "ERROR: $1" >&2; errors=$((errors + 1)); }
warn() { printf '%s\n' "WARNING: $1" >&2; warnings=$((warnings + 1)); }

require_secret() {
  name="$1"
  minimum="$2"
  value="$(setting "$name")"
  case "$value" in
    ''|change-me|replace-with-a-long-random-secret|replace-with-a-unique-12-plus-character-password|admin123|password|secret|changeme)
      fail "$name must be replaced with a unique secret." ;;
    *)
      if [ "${#value}" -lt "$minimum" ]; then
        fail "$name must contain at least $minimum characters."
      fi ;;
  esac
}

require_secret JWT_SECRET 32
require_secret TRACE_TOKEN_SECRET 32
require_secret PLATFORM_UPDATE_AGENT_TOKEN 32
require_secret POSTGRES_PASSWORD 16
require_secret MINIO_ROOT_PASSWORD 16
require_secret MINIO_SERVICE_SECRET_KEY 16
require_secret BACKEND_BOOTSTRAP_ADMIN_PASSWORD 12

email="$(setting BACKEND_BOOTSTRAP_ADMIN_EMAIL)"
case "$email" in *'@'*.*) ;; *) fail 'BACKEND_BOOTSTRAP_ADMIN_EMAIL must be a valid administrator email address.' ;; esac

access_key="$(setting MINIO_SERVICE_ACCESS_KEY)"
if [ "${#access_key}" -lt 3 ]; then
  fail 'MINIO_SERVICE_ACCESS_KEY must contain at least 3 characters.'
fi

if [ "$(setting PLATFORM_VERSION)" = latest ]; then
  warn 'PLATFORM_VERSION=latest is acceptable only for a new install; pin a release tag before production handoff.'
fi

public_host="$(setting VERIQORN_PUBLIC_HOST)"
if [ "$production" = true ] || [ -n "$public_host" ]; then
  if [ -z "$public_host" ]; then
    fail 'VERIQORN_PUBLIC_HOST is required for a production TLS deployment.'
  fi
  for name in FRONTEND_URL CORS_ORIGINS NEXT_PUBLIC_API_URL; do
    value="$(setting "$name")"
    case "$value" in
      "https://$public_host"|"https://$public_host/"*) ;;
      https://*) fail "$name must use the same host as VERIQORN_PUBLIC_HOST." ;;
      *) fail "$name must use https:// for a production TLS deployment." ;;
    esac
  done
  if [ "$(setting BACKEND_SECURE_COOKIES)" != true ]; then
    fail 'BACKEND_SECURE_COOKIES=true is required for a production TLS deployment.'
  fi
fi

if [ -z "$(setting OUTBOUND_ALLOWED_HOSTS)" ]; then
  fail 'OUTBOUND_ALLOWED_HOSTS must list the permitted LLM and connector destinations.'
fi

if [ "$errors" -ne 0 ]; then
  printf 'Preflight failed with %s error(s).\n' "$errors" >&2
  exit 1
fi

docker compose --env-file "$env_file" -f "$(dirname "$0")/docker-compose.yml" config --quiet
printf 'Preflight passed. Secrets were validated without being printed.\n'
