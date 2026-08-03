import { timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { appendFile, readFile, rename, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';

const port = Number(process.env.PORT || 8787);
const token = process.env.UPDATE_AGENT_TOKEN || '';
const composeFile = process.env.UPDATE_COMPOSE_FILE || '/install/docker-compose.yml';
const envFile = process.env.UPDATE_ENV_FILE || '/install/.env';
const projectName = process.env.UPDATE_PROJECT_NAME || 'veriqorn';
const backendImage = process.env.UPDATE_BACKEND_IMAGE || 'ghcr.io/veriqorn/veriqorn-backend';
const frontendImage = process.env.UPDATE_FRONTEND_IMAGE || 'ghcr.io/veriqorn/veriqorn-frontend';
const releasesUrl = process.env.UPDATE_RELEASES_URL || 'https://api.github.com/repos/veriqorn/veriqorn-platform/releases/latest';
const cosignImage = process.env.UPDATE_COSIGN_IMAGE || 'ghcr.io/sigstore/cosign/cosign:v2.4.3';
const cosignIdentity = process.env.UPDATE_COSIGN_IDENTITY || 'https://github.com/veriqorn/veriqorn-platform/.github/workflows/publish-platform-images.yml@refs/tags/v*';
const stateFile = '/state/update-jobs.jsonl';
let activeJob = null;

if (token.length < 32) throw new Error('UPDATE_AGENT_TOKEN must be at least 32 characters.');

const isReleaseTag = (value) => /^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(value);
const equalToken = (candidate) => {
  const left = Buffer.from(candidate || '');
  const right = Buffer.from(token);
  return left.length === right.length && timingSafeEqual(left, right);
};
const json = (response, status, value) => {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
};
const authorize = (request) => {
  const header = request.headers.authorization || '';
  return header.startsWith('Bearer ') && equalToken(header.slice(7));
};
const readBody = async (request) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 16 * 1024) throw new Error('Request body is too large.');
    chunks.push(chunk);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
};
const run = (args, environment = {}) => new Promise((resolve, reject) => {
  const child = spawn('docker', args, { env: { ...process.env, ...environment }, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', (data) => { output = (output + data).slice(-8000); });
  child.stderr.on('data', (data) => { output = (output + data).slice(-8000); });
  child.once('error', reject);
  child.once('close', (code) => code === 0 ? resolve(output.trim()) : reject(new Error(output.trim() || `docker exited ${code}`)));
});
const composeArgs = (...args) => ['compose', '--project-name', projectName, '--env-file', envFile, '-f', composeFile, ...args];
const release = async () => {
  const response = await fetch(releasesUrl, { headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'veriqorn-update-agent' }, signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`Release lookup failed (${response.status}).`);
  const data = await response.json();
  if (!data || data.draft || data.prerelease || !isReleaseTag(data.tag_name)) throw new Error('The release source did not return a stable semver tag.');
  return { version: data.tag_name, releaseNotesUrl: typeof data.html_url === 'string' ? data.html_url : null };
};
const installedVersion = async () => {
  const env = await readFile(envFile, 'utf8');
  return env.match(/^PLATFORM_VERSION=(.+)$/m)?.[1]?.trim() || process.env.UPDATE_CURRENT_VERSION || 'unknown';
};
const updateEnvVersion = async (version) => {
  const current = await readFile(envFile, 'utf8');
  const next = /^PLATFORM_VERSION=/m.test(current)
    ? current.replace(/^PLATFORM_VERSION=.*$/m, `PLATFORM_VERSION=${version}`)
    : `${current.replace(/\s*$/, '\n')}PLATFORM_VERSION=${version}\n`;
  await writeFile(`${envFile}.next`, next, { mode: 0o600 });
  await rename(`${envFile}.next`, envFile);
};
const record = async (job) => appendFile(stateFile, `${JSON.stringify({ ...job, recordedAt: new Date().toISOString() })}\n`, { mode: 0o600 });
const safeMessage = (error) => String(error instanceof Error ? error.message : error).replace(/Bearer\s+\S+/gi, 'Bearer [redacted]').slice(0, 1000);
const waitForBackend = async () => {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch('http://backend:3001/healthz', { signal: AbortSignal.timeout(2_000) });
      if (response.ok) return;
    } catch { /* service is still starting */ }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error('Backend health check timed out after 60 seconds. No automatic rollback was attempted.');
};
const getStatus = async () => {
  const currentVersion = await installedVersion();
  try {
    const latest = await release();
    return { currentVersion, latestVersion: latest.version, updateAvailable: latest.version !== currentVersion, releaseNotesUrl: latest.releaseNotesUrl, job: activeJob };
  } catch (error) {
    return { currentVersion, latestVersion: null, updateAvailable: false, releaseNotesUrl: null, job: activeJob, warning: safeMessage(error) };
  }
};
const imageDigest = async (image) => {
  const result = await run(['image', 'inspect', image, '--format', '{{index .RepoDigests 0}}']);
  if (!result.includes('@sha256:')) throw new Error(`No immutable digest found for ${image}.`);
  return result;
};
const verifyImageSignature = async (image) => run([
  'run', '--rm', cosignImage, 'verify',
  '--certificate-identity-regexp', `^${cosignIdentity.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace('v\\*', 'v.*')}$`,
  '--certificate-oidc-issuer', 'https://token.actions.githubusercontent.com',
  image,
]);
const execute = async (job) => {
  try {
    const latest = await release();
    const current = await installedVersion();
    if (latest.version === current) throw new Error('This installation is already on the latest release.');
    const environment = { PLATFORM_VERSION: latest.version };
    await run(composeArgs('pull', 'backend', 'frontend'), environment);
    const backendDigest = await imageDigest(`${backendImage}:${latest.version}`);
    const frontendDigest = await imageDigest(`${frontendImage}:${latest.version}`);
    await verifyImageSignature(backendDigest);
    await verifyImageSignature(frontendDigest);
    await updateEnvVersion(latest.version);
    await run(composeArgs('up', '-d', '--no-deps', 'backend', 'frontend'));
    await waitForBackend();
    job.status = 'succeeded';
    job.message = `Installed ${latest.version}. Backend ${backendDigest}; frontend ${frontendDigest}.`;
  } catch (error) {
    job.status = 'failed';
    job.message = safeMessage(error);
  }
  job.finishedAt = new Date().toISOString();
  await record(job);
};

createServer(async (request, response) => {
  if (!authorize(request)) return json(response, 401, { message: 'Unauthorized' });
  if (request.method === 'GET' && request.url === '/v1/updates/status') {
    try { return json(response, 200, await getStatus()); } catch (error) { return json(response, 500, { message: safeMessage(error) }); }
  }
  if (request.method === 'POST' && request.url === '/v1/updates/jobs') {
    if (activeJob && ['queued', 'running'].includes(activeJob.status)) return json(response, 409, { message: 'An update is already in progress.' });
    try {
      const body = await readBody(request);
      const requestedBy = body?.requestedBy?.email;
      if (typeof requestedBy !== 'string' || requestedBy.length > 320) return json(response, 400, { message: 'Missing request identity.' });
      activeJob = { id: `upd_${Date.now()}`, status: 'queued', requestedAt: new Date().toISOString(), requestedBy };
      await record(activeJob);
      activeJob.status = 'running';
      void execute(activeJob);
      return json(response, 202, { id: activeJob.id, status: activeJob.status });
    } catch (error) { return json(response, 400, { message: safeMessage(error) }); }
  }
  return json(response, 404, { message: 'Not found' });
}).listen(port, '0.0.0.0', () => console.log(`update-agent listening on ${port}`));
