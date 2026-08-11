[CmdletBinding()]
param(
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [switch]$Production
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
  throw "Environment file not found: $EnvFile"
}

$values = @{}
Get-Content -LiteralPath $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([^#=\s]+)\s*=\s*(.*)$') {
    $values[$matches[1]] = $matches[2].Trim()
  }
}

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Get-Setting([string]$Name) {
  return [string]($values[$Name])
}

function Require-Secret([string]$Name, [int]$MinimumLength) {
  $value = Get-Setting $Name
  $unsafeValues = @('', 'change-me', 'replace-with-a-long-random-secret', 'replace-with-a-unique-12-plus-character-password')
  if ($unsafeValues -contains $value -or $value -match '(?i)^(admin123|password|secret|changeme)$') {
    $errors.Add("$Name must be replaced with a unique secret.")
    return
  }
  if ($value.Length -lt $MinimumLength) {
    $errors.Add("$Name must contain at least $MinimumLength characters.")
  }
}

Require-Secret 'JWT_SECRET' 32
Require-Secret 'TRACE_TOKEN_SECRET' 32
Require-Secret 'PLATFORM_UPDATE_AGENT_TOKEN' 32
Require-Secret 'POSTGRES_PASSWORD' 16
Require-Secret 'MINIO_ROOT_PASSWORD' 16
Require-Secret 'MINIO_SERVICE_SECRET_KEY' 16
Require-Secret 'BACKEND_BOOTSTRAP_ADMIN_PASSWORD' 12

if ((Get-Setting 'MINIO_SERVICE_ACCESS_KEY').Length -lt 3) {
  $errors.Add('MINIO_SERVICE_ACCESS_KEY must contain at least 3 characters.')
}

$email = Get-Setting 'BACKEND_BOOTSTRAP_ADMIN_EMAIL'
if ($email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
  $errors.Add('BACKEND_BOOTSTRAP_ADMIN_EMAIL must be a valid administrator email address.')
}

$version = Get-Setting 'PLATFORM_VERSION'
if ($version -eq 'latest') {
  $warnings.Add('PLATFORM_VERSION=latest is acceptable only for a new install; pin a release tag before production handoff.')
}

$publicHost = Get-Setting 'VERIQORN_PUBLIC_HOST'
if ($Production -or $publicHost) {
  if ([string]::IsNullOrWhiteSpace($publicHost)) {
    $errors.Add('VERIQORN_PUBLIC_HOST is required for a production TLS deployment.')
  }
  foreach ($name in @('FRONTEND_URL', 'CORS_ORIGINS', 'NEXT_PUBLIC_API_URL')) {
    $value = Get-Setting $name
    if ($value -notmatch '^https://') {
      $errors.Add("$name must use https:// for a production TLS deployment.")
      continue
    }
    try {
      if (([Uri]$value).Host -ne $publicHost) {
        $errors.Add("$name must use the same host as VERIQORN_PUBLIC_HOST.")
      }
    } catch {
      $errors.Add("$name must be a valid HTTPS URL.")
    }
  }
  if ((Get-Setting 'BACKEND_SECURE_COOKIES').ToLowerInvariant() -ne 'true') {
    $errors.Add('BACKEND_SECURE_COOKIES=true is required for a production TLS deployment.')
  }
}

$allowedHosts = Get-Setting 'OUTBOUND_ALLOWED_HOSTS'
if ([string]::IsNullOrWhiteSpace($allowedHosts)) {
  $errors.Add('OUTBOUND_ALLOWED_HOSTS must list the permitted LLM and connector destinations.')
}

if ($warnings.Count -gt 0) {
  Write-Host 'Preflight warnings:' -ForegroundColor Yellow
  $warnings | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow }
}

if ($errors.Count -gt 0) {
  Write-Host 'Preflight failed:' -ForegroundColor Red
  $errors | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
  exit 1
}

& docker compose --env-file $EnvFile -f (Join-Path $PSScriptRoot 'docker-compose.yml') config --quiet
if ($LASTEXITCODE -ne 0) {
  throw 'Docker Compose validation failed.'
}

Write-Host 'Preflight passed. Secrets were validated without being printed.' -ForegroundColor Green
