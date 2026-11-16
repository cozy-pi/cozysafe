/**
 * Puts store/text/<lang>.json on the App Store page of the version being prepared
 * (never a version that is live or in review), through the App Store Connect API:
 *
 *   KEY_ID=… ISSUER=… KEY_B64=… node tools/store-text-asc.mjs [--write]
 *
 * Without --write it only says what it would change. It writes text only: name,
 * subtitle and privacy policy URL (app information), description, keywords,
 * promotional text and the two URLs (the version). Nothing is sent for review.
 * A language without its own screenshots shows the English ones.
 * Nothing but Node: no packages.
 */
import { readFileSync, readdirSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';

const BUNDLE_ID = 'com.cozypi.cozysafe';
const URLS = {
  privacyPolicyUrl: 'https://safe.cozypi.com/privacy',
  supportUrl: 'https://safe.cozypi.com/feedback',
  marketingUrl: 'https://safe.cozypi.com',
};
// store/text file name → App Store locale.
const LOCALE = {
  en: 'en-US', vi: 'vi', de: 'de-DE', es: 'es-ES', fr: 'fr-FR', id: 'id', it: 'it', ja: 'ja', ko: 'ko',
  pt: 'pt-BR', ru: 'ru', th: 'th', tr: 'tr', zh: 'zh-Hans', 'zh-Hant': 'zh-Hant',
};
const EDITABLE = ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'];

const write = process.argv.includes('--write');
const { KEY_ID, ISSUER, KEY_B64 } = process.env;
if (!KEY_ID || !ISSUER || !KEY_B64) {
  console.error('Usage: KEY_ID=… ISSUER=… KEY_B64=… node tools/store-text-asc.mjs [--write]');
  process.exit(2);
}

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' });
  const body = b64({ iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' });
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

const texts = {};
for (const f of readdirSync('store/text').filter((f) => f.endsWith('.json')).sort()) {
  const lang = f.slice(0, -5);
  if (!LOCALE[lang]) throw new Error(`store/text/${f}: no App Store locale for "${lang}"`);
  texts[LOCALE[lang]] = JSON.parse(readFileSync(`store/text/${f}`, 'utf8'));
}

const app = (await api('GET', `/apps?filter[bundleId]=${BUNDLE_ID}`)).data.find((a) => a.attributes.bundleId === BUNDLE_ID);
if (!app) throw new Error(`No app ${BUNDLE_ID}`);

// The app information and the version that can still be edited.
const state = (x) => x.attributes.appStoreState ?? x.attributes.state ?? x.attributes.appVersionState;
const info = (await api('GET', `/apps/${app.id}/appInfos`)).data.find((i) => EDITABLE.includes(state(i)));
const version = (await api('GET', `/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=20`)).data
  .find((v) => EDITABLE.includes(state(v)));
if (!info || !version) throw new Error('No app information or version being prepared: nothing to edit');
console.log(`${app.attributes.name} · version ${version.attributes.versionString} (${state(version)})${write ? '' : ' · dry run'}`);

/** Makes or updates one localization per language; says what changed. */
async function sync(kind, listPath, parent, parentType, fieldsOf) {
  const have = Object.fromEntries((await api('GET', `${listPath}?limit=200`)).data.map((l) => [l.attributes.locale, l]));
  for (const [locale, t] of Object.entries(texts)) {
    const want = fieldsOf(t);
    const cur = have[locale];
    const changed = Object.keys(want).filter((k) => (cur?.attributes?.[k] ?? '') !== want[k]);
    if (cur && !changed.length) { console.log(`  ${kind} ${locale}: same`); continue; }
    console.log(`  ${kind} ${locale}: ${cur ? `update ${changed.join(', ')}` : 'new'}`);
    if (!write) continue;
    if (cur) {
      await api('PATCH', `/${kind}/${cur.id}`, { data: { type: kind, id: cur.id, attributes: Object.fromEntries(changed.map((k) => [k, want[k]])) } });
    } else {
      await api('POST', `/${kind}`, {
        data: { type: kind, attributes: { locale, ...want }, relationships: { [parent]: { data: { type: parentType, id: parent === 'appInfo' ? info.id : version.id } } } },
      });
    }
  }
}

await sync('appInfoLocalizations', `/appInfos/${info.id}/appInfoLocalizations`, 'appInfo', 'appInfos',
  (t) => ({ name: t.name, subtitle: t.subtitle, privacyPolicyUrl: URLS.privacyPolicyUrl }));
await sync('appStoreVersionLocalizations', `/appStoreVersions/${version.id}/appStoreVersionLocalizations`, 'appStoreVersion', 'appStoreVersions',
  (t) => ({ description: t.description, keywords: t.keywords, promotionalText: t.promo, supportUrl: URLS.supportUrl, marketingUrl: URLS.marketingUrl }));
console.log(write ? 'Written. Nothing was sent for review.' : 'Dry run: nothing written (add --write).');
