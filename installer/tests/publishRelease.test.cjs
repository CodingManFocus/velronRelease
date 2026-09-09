const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { publishRelease, installerFiles } = require('../scripts/publishRelease.cjs');

function fixture(t, { failUpload = false, corruptDigest = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'velron-publish-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const file of installerFiles) fs.writeFileSync(path.join(directory, file), `fixture:${file}`);
  const releases = new Map([['installer-latest', { id: 1, draft: false, body: 'previous release' }]]);
  const assets = new Map([[1, [{ id: 11, name: 'legacy.exe', state: 'uploaded', digest: 'legacy', size: 1 }]]]);
  const operations = [];
  const repos = {
    async getReleaseByTag({ tag }) {
      // Faithfully model the documented published-only tag lookup contract.
      if (!releases.has(tag) || releases.get(tag).draft) throw Object.assign(new Error('not found'), { status: 404 });
      return { data: releases.get(tag) };
    },
    async createRelease(args) {
      operations.push(['create', args.tag_name, args.draft]);
      const release = { id: releases.size + 1, ...args };
      releases.set(args.tag_name, release); assets.set(release.id, []);
      return { data: release };
    },
    async listReleaseAssets() {},
    async listReleases() {},
    async compareCommitsWithBasehead({ basehead }) { const [base, head] = basehead.split('...'); return { data: { status: base < head ? 'ahead' : 'behind' } }; },
    async uploadReleaseAsset({ release_id, name, data }) {
      operations.push(['upload', name]);
      if (failUpload && name === installerFiles[2]) throw new Error('upload unavailable');
      const list = assets.get(release_id);
      list.push({ id: list.length + 20, name, size: data.length, state: 'uploaded', digest: corruptDigest ? 'sha256:bad' : `sha256:${crypto.createHash('sha256').update(data).digest('hex')}` });
    },
    async updateRelease(args) {
      operations.push(['update', args.release_id, args.draft]);
      const release = [...releases.values()].find(r => r.id === args.release_id);
      Object.assign(release, args); return { data: release };
    },
    async deleteReleaseAsset({ asset_id }) {
      operations.push(['delete', asset_id]);
      for (const [id, list] of assets) assets.set(id, list.filter(asset => asset.id !== asset_id));
    },
  };
  return {
    input: { github: { rest: { repos }, paginate: async (method, { release_id }) => method === repos.listReleases ? [...releases.values()] : assets.get(release_id) }, context: { repo: { owner: 'owner', repo: 'repo' }, sha: 'a'.repeat(40) }, directory },
    releases, assets, operations,
  };
}

test('upload failure preserves the old public page and all legacy assets', async t => {
  const f = fixture(t, { failUpload: true });
  await assert.rejects(publishRelease(f.input), /upload unavailable/);
  assert.equal(f.releases.get('installer-latest').body, 'previous release');
  assert.equal(f.releases.get(`installer-${'a'.repeat(40)}`).draft, true);
  assert.equal(f.assets.get(1)[0].digest, 'legacy');
  assert.equal(f.operations.some(([name]) => name === 'update' || name === 'delete'), false);
});

test('digest mismatch prevents publication and alias advancement', async t => {
  const f = fixture(t, { corruptDigest: true });
  await assert.rejects(publishRelease(f.input), /SHA-256 verification/);
  assert.equal(f.releases.get('installer-latest').body, 'previous release');
  assert.equal(f.releases.get(`installer-${'a'.repeat(40)}`).draft, true);
});

test('publishes a verified version before switching the alias, with an idempotent rerun', async t => {
  const f = fixture(t);
  await publishRelease(f.input);
  const firstCount = f.operations.filter(([name]) => name === 'upload').length;
  assert.equal(firstCount, 5);
  assert.deepEqual(f.operations.slice(-2), [['update', 2, false], ['update', 1, false]]);
  assert.match(f.releases.get('installer-latest').body, /installer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/);
  await publishRelease(f.input);
  assert.equal(f.operations.filter(([name]) => name === 'upload').length, firstCount);
  assert.equal(f.operations.some(([name]) => name === 'delete'), false);
  assert.equal(f.assets.get(1)[0].digest, 'legacy');
});

test('rerunning a different build cannot replace published bytes', async t => {
  const f = fixture(t);
  await publishRelease(f.input);
  fs.writeFileSync(path.join(f.input.directory, installerFiles[0]), 'different build');
  const count = f.operations.length;
  await assert.rejects(publishRelease(f.input), /Published installer differs/);
  assert.equal(f.operations.length, count);
});

test('a rerun finds and repairs an unpublished draft left by an interrupted upload', async t => {
  const f = fixture(t);
  const repos = f.input.github.rest.repos;
  const upload = repos.uploadReleaseAsset;
  repos.uploadReleaseAsset = async args => {
    if (args.name === installerFiles[2]) throw new Error('interrupted upload');
    return upload(args);
  };
  await assert.rejects(publishRelease(f.input), /interrupted upload/);
  const tag = `installer-${'a'.repeat(40)}`;
  const draft = f.releases.get(tag);
  assert.equal(draft.draft, true);
  assert.equal(f.releases.get('installer-latest').body, 'previous release');
  repos.uploadReleaseAsset = upload;
  await publishRelease(f.input);
  assert.equal(f.releases.get(tag).id, draft.id);
  assert.equal(f.releases.get(tag).draft, false);
  assert.equal(f.operations.filter(([name]) => name === 'create').length, 1);
  assert.equal(f.operations.filter(([name]) => name === 'upload').length, 5);
  assert.equal(f.assets.get(1)[0].digest, 'legacy');
});

test('rerunning an older source after a newer release cannot roll back the stable page', async t => {
  const f = fixture(t);
  await publishRelease(f.input);
  const oldSource = f.input.context.sha;
  f.input.context.sha = 'b'.repeat(40);
  await publishRelease(f.input);
  const currentBody = f.releases.get('installer-latest').body;
  const count = f.operations.length;
  f.input.context.sha = oldSource;
  const url = await publishRelease(f.input);
  assert.equal(f.releases.get('installer-latest').body, currentBody);
  assert.equal(f.operations.length, count);
  assert.match(url, /installer-b{40}$/);
});
