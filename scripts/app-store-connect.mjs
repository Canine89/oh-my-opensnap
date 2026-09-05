import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createPrivateKey, sign } from 'node:crypto';

// API 키는 로컬 파일에서만 읽으며 토큰/개인키를 출력하거나 파일로 저장하지 않는다.
const root = join(homedir(), '.appstoreconnect');
const configPath = join(root, 'oh-my-opensnap.json');
const saved = existsSync(configPath) ? JSON.parse(readFileSync(configPath, 'utf8')) : {};
const keyDirectory = join(root, 'private_keys');
const keys = existsSync(keyDirectory) ? readdirSync(keyDirectory).filter(name => /^AuthKey_[A-Z0-9]+\.p8$/.test(name)) : [];
const keyID = process.env.OMOS_ASC_API_KEY || saved.keyId || (keys.length === 1 ? keys[0].slice(8, -3) : undefined);
const issuer = process.env.OMOS_ASC_API_ISSUER || saved.issuerId;
if (!/^[A-Z0-9]+$/.test(keyID || '') || !/^[0-9a-f-]{36}$/i.test(issuer || '')) {
  throw new Error('App Store Connect의 API 키 ID와 발급자 ID가 필요합니다. 환경변수 또는 ~/.appstoreconnect/oh-my-opensnap.json에 설정하세요.');
}
const key = createPrivateKey(readFileSync(join(keyDirectory, `AuthKey_${keyID}.p8`)));
const bundleID = 'com.goldenrabbit.omopensnap.mas';

function token() {
  const now = Math.floor(Date.now() / 1000);
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const input = `${encode({ alg: 'ES256', kid: keyID, typ: 'JWT' })}.${encode({ iss: issuer, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })}`;
  return `${input}.${sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}

async function get(path, query = {}) {
  const url = new URL(path, 'https://api.appstoreconnect.apple.com');
  Object.entries(query).forEach(([key, value]) => url.searchParams.set(key, value));
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token()}` }, signal: AbortSignal.timeout(30000) });
  const body = await response.json();
  if (!response.ok) throw new Error(`App Store Connect ${response.status}: ${JSON.stringify(body.errors || body)}`);
  return body;
}

const command = process.argv[2] || 'inspect';
if (!['inspect', 'wait-build'].includes(command)) throw new Error('사용법: node scripts/app-store-connect.mjs inspect | wait-build <마케팅 버전> <빌드 번호>');
const apps = await get('/v1/apps', { 'filter[bundleId]': bundleID });
const app = apps.data.find(item => item.attributes.bundleId === bundleID);
if (!app) throw new Error(`해당 번들 ID의 앱 레코드를 찾지 못했습니다: ${bundleID}`);

if (command === 'inspect') {
  const [versions, builds, groups] = await Promise.all([
    get(`/v1/apps/${app.id}/appStoreVersions`, { 'filter[platform]': 'MAC_OS', limit: '10' }),
    get('/v1/builds', { 'filter[app]': app.id, sort: '-uploadedDate', limit: '10', include: 'preReleaseVersion' }),
    get(`/v1/apps/${app.id}/betaGroups`, { limit: '20' })
  ]);
  console.log(JSON.stringify({ app: { id: app.id, ...app.attributes },
    versions: versions.data.map(item => ({ id: item.id, ...item.attributes })),
    builds: builds.data.map(item => ({ id: item.id, ...item.attributes })),
    betaGroups: groups.data.map(item => ({ id: item.id, name: item.attributes.name, isInternalGroup: item.attributes.isInternalGroup })) }, null, 2));
} else {
  const [version, buildNumber] = process.argv.slice(3);
  if (!version || !buildNumber) throw new Error('마케팅 버전과 빌드 번호를 모두 지정하세요.');
  const deadline = Date.now() + 15 * 60 * 1000;
  let completed = false;
  while (Date.now() < deadline) {
    const result = await get('/v1/builds', { 'filter[app]': app.id, 'filter[version]': buildNumber, include: 'preReleaseVersion' });
    const build = result.data.find(item => result.included?.some(release =>
      release.type === 'preReleaseVersions' && release.id === item.relationships.preReleaseVersion.data.id
      && release.attributes.version === version && release.attributes.platform === 'MAC_OS'));
    if (build?.attributes.processingState === 'VALID') {
      console.log(JSON.stringify({ appID: app.id, version, buildNumber, buildID: build.id, processingState: 'VALID' }));
      completed = true;
      break;
    }
    if (['FAILED', 'INVALID'].includes(build?.attributes.processingState)) throw new Error(`빌드 처리 실패: ${build.attributes.processingState}`);
    console.log(`빌드 ${version} (${buildNumber}): ${build?.attributes.processingState || '업로드 반영 대기'}`);
    await new Promise(resolve => setTimeout(resolve, 15000));
  }
  if (!completed) throw new Error('15분 안에 빌드 처리 완료를 확인하지 못했습니다. 이후 wait-build로 다시 확인하세요.');
}
