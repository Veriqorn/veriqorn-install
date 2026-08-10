[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$BackendImage,
  [Parameter(Mandatory)]
  [string]$FrontendImage,
  [Parameter(Mandatory)]
  [string]$OutputDirectory,
  [string]$Version = 'unversioned'
)

$ErrorActionPreference = 'Stop'

function Assert-LocalImage {
  param([Parameter(Mandatory)][string]$Image)
  & docker image inspect $Image *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Docker image is not present locally: $Image. Pull and verify the pinned image before creating an air-gapped bundle."
  }
}

function Get-ImmutableDigest {
  param([Parameter(Mandatory)][string]$Image)
  $metadata = & docker image inspect $Image | ConvertFrom-Json
  $digest = @($metadata.RepoDigests)[0]
  if ([string]::IsNullOrWhiteSpace($digest) -or $digest -notmatch '@sha256:[a-f0-9]{64}$') {
    throw "Image does not have a registry digest: $Image. Pull it by digest and verify its signature before bundling."
  }
  return $digest
}

$root = Split-Path -Parent $PSCommandPath
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $destination) {
  throw "Output directory already exists: $destination. Use a new empty directory so a bundle is never overwritten."
}

Assert-LocalImage $BackendImage
Assert-LocalImage $FrontendImage
$backendDigest = Get-ImmutableDigest $BackendImage
$frontendDigest = Get-ImmutableDigest $FrontendImage

New-Item -ItemType Directory -Force -Path $destination | Out-Null
$imagesDirectory = Join-Path $destination 'images'
New-Item -ItemType Directory -Force -Path $imagesDirectory | Out-Null

foreach ($file in @('docker-compose.yml', 'compose.enterprise.yml', '.env.example', '.env.enterprise.example', 'README.md', 'preflight.ps1', 'preflight.sh')) {
  $source = Join-Path $root $file
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $destination $file)
  }
}

$backendTar = Join-Path $imagesDirectory 'veriqorn-community-backend.tar'
$frontendTar = Join-Path $imagesDirectory 'veriqorn-community-frontend.tar'
& docker save --output $backendTar $BackendImage
if ($LASTEXITCODE -ne 0) { throw "Failed to export $BackendImage" }
& docker save --output $frontendTar $FrontendImage
if ($LASTEXITCODE -ne 0) { throw "Failed to export $FrontendImage" }

$images = @(
  [ordered]@{
    role = 'community-backend'
    reference = $BackendImage
    immutableDigest = $backendDigest
    archive = 'images/veriqorn-community-backend.tar'
  },
  [ordered]@{
    role = 'community-frontend'
    reference = $FrontendImage
    immutableDigest = $frontendDigest
    archive = 'images/veriqorn-community-frontend.tar'
  }
)

$manifest = [ordered]@{
  schemaVersion = 1
  product = 'veriqorn'
  edition = 'community'
  version = $Version
  createdAt = (Get-Date).ToUniversalTime().ToString('o')
  images = $images
  licenseIncluded = $false
  notes = @(
    'This generic bundle contains no customer license or registry credentials.',
    'Verify image signatures against the release workflow identity before use.',
    'Load images with docker load --input <archive>, then set pinned image values in .env.'
  )
}
$manifestPath = Join-Path $destination 'bundle-manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$checksumFiles = Get-ChildItem -LiteralPath $destination -Recurse -File |
  Where-Object { $_.Name -ne 'SHA256SUMS' } |
  Sort-Object FullName
$checksums = foreach ($file in $checksumFiles) {
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/').Replace('\', '/')
  "$hash  $relative"
}
Set-Content -LiteralPath (Join-Path $destination 'SHA256SUMS') -Value $checksums -Encoding ascii

Write-Output "Created air-gapped Community bundle: $destination"
Write-Output 'No license file was included.'
