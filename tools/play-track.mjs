/**
 * Put an Android build that is already on Google Play into another testing track.
 *
 *   node tools/play-track.mjs <service-account.json>                      list the tracks and their builds
 *   node tools/play-track.mjs <service-account.json> <versionCode> <track> make that build the track's release
 *
 * release.yml uploads each build to `internal` (no review: testers get it within
 * minutes), then calls this to put the same build into `alpha` (closed testing, which
 * Google reviews). A build can be uploaded only once, so the second track reuses it.
 */
import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';

const PKG = 'com.cozypi.cozysafe';
const [keyPath, versionCode, track] = process.argv.slice(2);
if (!keyPath) {
  console.error('Usage: node tools/play-track.mjs <service-account.json> [versionCode track]');
  process.exit(2);
}
const sa = JSON.parse(readFileSync(keyPath, 'utf8'));

async function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'RS256', typ: 'JWT' });
  const body = b64({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  });
  const sig = createSign('RSA-SHA256').update(`${head}.${body}`).sign(sa.private_key).toString('base64url');
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${body}.${sig}` }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error(`No access token: ${JSON.stringify(j)}`);
  return j.access_token;
}

const tk = await token();
const BASE = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PKG}`;
async function api(method, path, body) {
  const r = await fetch(BASE + path, {
    method,
    headers: { Authorization: `Bearer ${tk}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}: ${text}`);
  return text ? JSON.parse(text) : {};
}

const edit = await api('POST', '/edits');
const E = `/edits/${edit.id}`;
const { tracks = [] } = await api('GET', `${E}/tracks`);
console.log('Tracks:');
for (const t of tracks) {
  const rel = (t.releases ?? []).map((r) => `${r.name ?? '?'} [${(r.versionCodes ?? []).join(',')}] ${r.status}`).join(' · ');
  console.log(`  ${t.track.padEnd(28)} ${rel || '(empty)'}`);
}

if (!versionCode) {
  await api('DELETE', E);
  process.exit(0);
}
if (!tracks.some((t) => t.track === track)) {
  await api('DELETE', E);
  console.error(`✗ No track "${track}"; pick one from the list above.`);
  process.exit(1);
}
const source = tracks.flatMap((t) => t.releases ?? []).find((r) => (r.versionCodes ?? []).includes(String(versionCode)));
if (!source) {
  await api('DELETE', E);
  console.error(`✗ Build ${versionCode} is on no track yet; upload it first.`);
  process.exit(1);
}
await api('PUT', `${E}/tracks/${track}`, {
  track,
  releases: [{
    name: source.name,
    versionCodes: [String(versionCode)],
    status: 'completed',
    ...(source.releaseNotes ? { releaseNotes: source.releaseNotes } : {}),
  }],
});
const done = await api('POST', `${E}:commit`);
console.log(`✓ Build ${versionCode} (${source.name ?? ''}) → ${track} · edit ${done.id}`);
