/**
 * The App Store provisioning profile of Cozy Safe Beta (com.cozypi.cozysafe.beta), made
 * through the App Store Connect API when it is not there yet:
 *
 *   KEY_ID=… ISSUER=… KEY_B64=… node tools/asc-beta-profile.mjs <out.mobileprovision>
 *
 * Registers the bundle id with Associated Domains (the only capability the app uses,
 * app/ios/Runner/Runner.entitlements), then finds or makes an App Store profile for it
 * with the team's distribution certificates, and writes the profile to the given file.
 * testflight.yml runs it in a job of its own, so the key never sits next to the build.
 * Nothing but Node: no packages.
 */
import { writeFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';

const BUNDLE_ID = 'com.cozypi.cozysafe.beta';
const APP_NAME = 'Cozy Safe Beta';
const PROFILE_NAME = 'Cozy Safe Beta App Store (CI)';

const out = process.argv[2];
const { KEY_ID, ISSUER, KEY_B64 } = process.env;
if (!out || !KEY_ID || !ISSUER || !KEY_B64) {
  console.error('Usage: KEY_ID=… ISSUER=… KEY_B64=… node tools/asc-beta-profile.mjs <out.mobileprovision>');
  process.exit(2);
}

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' });
  const body = b64({ iss: ISSUER, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
  const key = createPrivateKey(Buffer.from(KEY_B64, 'base64').toString('utf8'));
  const sig = sign('sha256', Buffer.from(`${head}.${body}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${head}.${body}.${sig}`;
}

const tk = token();
async function api(method, path, body) {
  const r = await fetch(`https://api.appstoreconnect.apple.com/v1${path}`, {
    method,
    headers: { Authorization: `Bearer ${tk}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}: ${text}`);
  return text ? JSON.parse(text) : {};
}

// The bundle id (the filter matches by prefix, so pick the exact one).
let bundle = (await api('GET', `/bundleIds?filter[identifier]=${BUNDLE_ID}&limit=200`)).data
  .find((b) => b.attributes.identifier === BUNDLE_ID);
if (!bundle) {
  bundle = (await api('POST', '/bundleIds', {
    data: { type: 'bundleIds', attributes: { identifier: BUNDLE_ID, name: APP_NAME, platform: 'IOS' } },
  })).data;
  console.log(`Registered ${BUNDLE_ID}`);
} else {
  console.log(`${BUNDLE_ID} is registered`);
}

const caps = (await api('GET', `/bundleIds/${bundle.id}/bundleIdCapabilities`)).data;
let capabilityAdded = false;
if (!caps.some((c) => c.attributes.capabilityType === 'ASSOCIATED_DOMAINS')) {
  await api('POST', '/bundleIdCapabilities', {
    data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType: 'ASSOCIATED_DOMAINS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } },
    },
  });
  capabilityAdded = true;
  console.log('Associated Domains turned on');
}

// The profile: reuse an active one, unless a capability was just added (a profile made
// before it does not carry the entitlement).
const named = (await api('GET', `/profiles?filter[name]=${encodeURIComponent(PROFILE_NAME)}&limit=200`)).data
  .filter((p) => p.attributes.name === PROFILE_NAME);
let profile = capabilityAdded ? undefined : named.find((p) => p.attributes.profileState === 'ACTIVE');
if (!profile) {
  for (const p of named) await api('DELETE', `/profiles/${p.id}`);
  const certs = (await api('GET', '/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200')).data;
  if (!certs.length) throw new Error('No distribution certificate in this team');
  profile = (await api('POST', '/profiles', {
    data: {
      type: 'profiles',
      attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: certs.map((c) => ({ type: 'certificates', id: c.id })) },
      },
    },
  })).data;
  console.log(`Made the profile "${PROFILE_NAME}" (${certs.length} certificate(s))`);
} else {
  console.log(`Profile "${PROFILE_NAME}" is active`);
}

writeFileSync(out, Buffer.from(profile.attributes.profileContent, 'base64'));
console.log(`Written to ${out}, expires ${profile.attributes.expirationDate}`);
