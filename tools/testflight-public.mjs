/**
 * Public TestFlight beta: an external group "Public Testers" with a public invite link
 * (https://testflight.apple.com/join/…). Fills what Apple requires for external testing
 * (beta description, feedback email, privacy policy, Beta App Review contact and notes,
 * "What to Test"), adds a build to the group and submits it to Beta App Review.
 * Safe to run again: what exists is updated, a build already submitted is left alone.
 *
 *   node tools/testflight-public.mjs <AuthKey_XXXXXXXXXX.p8> <Issuer ID> [build number]
 *
 * Without a build number: the newest processed build of the newest release (highest
 * vX.Y.Z tag), so a branch test build is never sent to the public.
 *
 * Apple turns the public link on only after the group's first build is approved: the
 * first run submits, run it again after approval to get the link.
 *
 * The contact name and phone for Beta App Review stay out of this public repository:
 * they come from ASC_REVIEW_FIRST_NAME, ASC_REVIEW_LAST_NAME, ASC_REVIEW_PHONE when set,
 * otherwise what is already in App Store Connect is kept.
 */
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createPrivateKey, sign } from 'node:crypto';

const BUNDLE_ID = 'com.cozypi.cozysafe';
const GROUP = 'Public Testers';
const EMAIL = 'support@cozypi.com';
const DESCRIPTION =
  'Cozy Safe is an encrypted vault for photos, documents, files and notes. Everything is ' +
  'encrypted on your device before it is saved. Optional sync with a device on the same ' +
  'Wi-Fi or through your own Google Drive. No account, no server, no ads. Open source.';
const WHAT_TO_TEST =
  'Create a vault, add photos, files and notes, lock and unlock it, back up to a file and ' +
  'restore. This is a beta: do not keep your only copy of something important in it yet. ' +
  'Feedback: ' + EMAIL;
const REVIEW_NOTES =
  'No account or sign-in. On first launch, create a vault: choose a password, then the app ' +
  'shows a 24-word Recovery Key (any words can be noted; it is only needed to restore). ' +
  'Everything stays on the device. Sync is optional: with a second device on the same ' +
  'Wi-Fi, or with a Google Drive account.';

const [p8Path, issuer, buildArg] = process.argv.slice(2);
if (!p8Path || !issuer) {
  console.error('Usage: node tools/testflight-public.mjs <AuthKey_XXXX.p8> <Issuer ID> [build number]');
  process.exit(2);
}
const keyId = basename(p8Path).match(/^AuthKey_([A-Z0-9]+)\.p8$/)?.[1];
if (!keyId) {
  console.error('The key file must be named AuthKey_<KeyID>.p8');
  process.exit(2);
}
const key = createPrivateKey(readFileSync(p8Path));

function jwt() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid: keyId, typ: 'JWT' });
  const body = b64({ iss: issuer, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' });
  const sig = sign('sha256', Buffer.from(`${head}.${body}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${sig.toString('base64url')}`;
}

async function api(method, path, body) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}\n${text}`);
  return text ? JSON.parse(text) : null;
}

const app = (await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data?.[0];
if (!app) throw new Error(`no app with bundle ID ${BUNDLE_ID}`);
const appRel = { app: { data: { type: 'apps', id: app.id } } };

// 1. Beta app information (required for external testers).
const locs = (await api('GET', `/v1/apps/${app.id}/betaAppLocalizations`)).data;
const locEn = locs.find((l) => l.attributes.locale === 'en-US');
const locAttrs = {
  feedbackEmail: EMAIL,
  description: DESCRIPTION,
  marketingUrl: 'https://safe.cozypi.com/',
  privacyPolicyUrl: 'https://safe.cozypi.com/privacy',
};
if (locEn) {
  await api('PATCH', `/v1/betaAppLocalizations/${locEn.id}`, {
    data: { type: 'betaAppLocalizations', id: locEn.id, attributes: locAttrs },
  });
} else {
  await api('POST', '/v1/betaAppLocalizations', {
    data: { type: 'betaAppLocalizations', attributes: { locale: 'en-US', ...locAttrs }, relationships: appRel },
  });
}
console.log('✓ beta description, feedback email, privacy policy');

// 2. Beta App Review contact and notes.
const rd = (await api('GET', `/v1/apps/${app.id}/betaAppReviewDetail`)).data;
const rdAttrs = { contactEmail: EMAIL, demoAccountRequired: false, notes: REVIEW_NOTES };
if (process.env.ASC_REVIEW_FIRST_NAME) rdAttrs.contactFirstName = process.env.ASC_REVIEW_FIRST_NAME;
if (process.env.ASC_REVIEW_LAST_NAME) rdAttrs.contactLastName = process.env.ASC_REVIEW_LAST_NAME;
if (process.env.ASC_REVIEW_PHONE) rdAttrs.contactPhone = process.env.ASC_REVIEW_PHONE;
const rdNow = (
  await api('PATCH', `/v1/betaAppReviewDetails/${rd.id}`, {
    data: { type: 'betaAppReviewDetails', id: rd.id, attributes: rdAttrs },
  })
).data.attributes;
const missing = ['contactFirstName', 'contactLastName', 'contactPhone'].filter((k) => !rdNow[k]);
console.log(`✓ Beta App Review contact${missing.length ? ` (MISSING: ${missing.join(', ')})` : ''}`);

// 3. The build.
let version = null;
if (!buildArg) {
  const tags = execFileSync('git', ['tag', '--list', 'v[0-9]*.[0-9]*.[0-9]*'], { encoding: 'utf8' })
    .split('\n')
    .filter(Boolean)
    .map((t) => t.slice(1));
  const num = (v) => v.split('.').map(Number);
  tags.sort((a, b) => {
    const [x, y] = [num(a), num(b)];
    return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
  });
  version = tags.at(-1);
  if (!version) throw new Error('no release tag vX.Y.Z (fetch tags, or pass a build number)');
}
const query = buildArg
  ? `filter[version]=${encodeURIComponent(buildArg)}`
  : `filter[preReleaseVersion.version]=${encodeURIComponent(version)}&filter[processingState]=VALID`;
const builds = await api(
  'GET',
  `/v1/builds?filter[app]=${app.id}&${query}&filter[expired]=false&sort=-uploadedDate&limit=1&include=preReleaseVersion`,
);
const b = builds.data?.[0];
if (!b) throw new Error(`no processed build ${buildArg ? `number ${buildArg}` : `of version ${version}`} yet`);
const name = builds.included?.find((x) => x.type === 'preReleaseVersions')?.attributes.version;
console.log(`✓ build ${name} (${b.attributes.version}), processing: ${b.attributes.processingState}`);

const bl = (await api('GET', `/v1/builds/${b.id}/betaBuildLocalizations`)).data.find(
  (l) => l.attributes.locale === 'en-US',
);
if (bl) {
  await api('PATCH', `/v1/betaBuildLocalizations/${bl.id}`, {
    data: { type: 'betaBuildLocalizations', id: bl.id, attributes: { whatsNew: WHAT_TO_TEST } },
  });
} else {
  await api('POST', '/v1/betaBuildLocalizations', {
    data: {
      type: 'betaBuildLocalizations',
      attributes: { locale: 'en-US', whatsNew: WHAT_TO_TEST },
      relationships: { build: { data: { type: 'builds', id: b.id } } },
    },
  });
}
console.log('✓ What to Test');

// 4. External group, with the build.
let group = (
  await api('GET', `/v1/betaGroups?filter[app]=${app.id}&filter[name]=${encodeURIComponent(GROUP)}`)
).data?.[0];
if (!group) {
  group = (
    await api('POST', '/v1/betaGroups', {
      data: { type: 'betaGroups', attributes: { name: GROUP, feedbackEnabled: true }, relationships: appRel },
    })
  ).data;
  console.log(`✓ created group "${GROUP}"`);
}
await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, { data: [{ type: 'builds', id: b.id }] });
console.log('✓ build added to the group');

// 5. Beta App Review (skipped when this build was already submitted).
const sub = await api('GET', `/v1/builds/${b.id}/betaAppReviewSubmission`).catch(() => null);
if (sub?.data) {
  console.log(`• Beta App Review: ${sub.data.attributes.betaReviewState}`);
} else {
  const r = await api('POST', '/v1/betaAppReviewSubmissions', {
    data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: b.id } } } },
  });
  console.log(`✓ submitted to Beta App Review: ${r.data.attributes.betaReviewState}`);
}

// 6. Public link (Apple allows it only after the group's first build is approved).
try {
  const r = await api('PATCH', `/v1/betaGroups/${group.id}`, {
    data: { type: 'betaGroups', id: group.id, attributes: { publicLinkEnabled: true, publicLinkLimitEnabled: false } },
  });
  console.log(`\nPUBLIC LINK: ${r.data.attributes.publicLink ?? '(none yet: run again after approval)'}`);
} catch (e) {
  console.log(`\n• Public link not on yet (usually: no approved build). Run again after approval.\n${String(e.message).slice(0, 300)}`);
}
