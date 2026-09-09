const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const installerFiles = Object.freeze([
  'Velron-Installer-windows-x64.exe',
  'Velron-Installer-windows-arm64.exe',
  'Velron-Installer-macos-universal.zip',
  'Velron-Installer-linux.tar.gz',
]);
const digest = data => `sha256:${crypto.createHash('sha256').update(data).digest('hex')}`;

/** Publish a complete immutable version before changing the stable download page. */
async function publishRelease({ github, context, directory = 'dist' }) {
  const { owner, repo } = context.repo;
  if (!/^[a-f0-9]{40}$/.test(context.sha)) throw new Error('Expected an immutable source SHA');
  const tag = `installer-${context.sha}`;
  const payloads = new Map(installerFiles.map(name => {
    const data = fs.readFileSync(path.join(directory, name));
    if (!data.length) throw new Error(`Empty artifact: ${name}`);
    return [name, data];
  }));
  const sums = Array.from(payloads, ([name, data]) => `${digest(data).slice(7)}  ${name}`).join('\n') + '\n';
  payloads.set('SHA256SUMS-installers.txt', Buffer.from(sums));
  const versionUrl = `https://github.com/${owner}/${repo}/releases/tag/${tag}`;
  const body = [
    'Download the installer for your computer from the links below.',
    '',
    ...Array.from(payloads.keys(), name => `- [${name}](https://github.com/${owner}/${repo}/releases/download/${tag}/${name})`),
    '',
    'Windows: open the x64 or ARM64 executable. macOS: extract the ZIP and open Velron Installer.app. Linux: extract the archive and open Velron-Installer.desktop.',
    'Windows and macOS launchers do not have a trusted publisher signature. Your OS may request approval.',
    '',
    `Source: ${context.sha}`,
    `<!-- installer-release: ${tag} -->`,
  ].join('\n');
  const repos = github.rest.repos;
  async function byTag(releaseTag) {
    try { return (await repos.getReleaseByTag({ owner, repo, tag: releaseTag })).data; }
    catch (error) { if (error.status !== 404) throw error; }
    // The tag endpoint is documented for published releases. A failed upload
    // leaves a draft which must be found through the authenticated release list.
    const drafts = (await github.paginate(repos.listReleases, { owner, repo, per_page: 100 }))
      .filter(candidate => candidate.draft && candidate.tag_name === releaseTag);
    if (drafts.length > 1) throw new Error(`Multiple drafts exist for ${releaseTag}; review them before publishing`);
    return drafts[0] ?? null;
  }
  const alias = await byTag('installer-latest');
  const currentTag = /<!-- installer-release: (installer-([a-f0-9]{40})) -->/.exec(alias?.body ?? '');
  if (currentTag && currentTag[2] !== context.sha) {
    // Workflow/job reruns may execute after a newer release. Serial execution
    // alone does not prevent an old run from rolling the stable page backward.
    const comparison = (await repos.compareCommitsWithBasehead({ owner, repo, basehead: `${currentTag[2]}...${context.sha}`, per_page: 1 })).data;
    if (comparison.status === 'behind') return `https://github.com/${owner}/${repo}/releases/tag/${currentTag[1]}`;
    if (comparison.status !== 'ahead') throw new Error('Installer source does not descend from the current published version');
  }
  let release = await byTag(tag);
  if (!release) release = (await repos.createRelease({
    owner, repo, tag_name: tag, target_commitish: context.sha,
    name: `Velron Installer ${context.sha.slice(0, 7)}`, body,
    draft: true, prerelease: false, make_latest: 'false',
  })).data;
  let assets = await github.paginate(repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
  for (const [name, data] of payloads) {
    const existing = assets.find(asset => asset.name === name);
    if (existing?.size === data.length && existing?.digest === digest(data) && existing?.state === 'uploaded') continue;
    // A rerun can repair only an unpublished draft. Public bytes are immutable.
    if (!release.draft) throw new Error(`Published installer differs from this build: ${name}`);
    if (existing) await repos.deleteReleaseAsset({ owner, repo, asset_id: existing.id });
    await repos.uploadReleaseAsset({ owner, repo, release_id: release.id, name, data,
      headers: { 'content-type': 'application/octet-stream', 'content-length': data.length } });
  }
  assets = await github.paginate(repos.listReleaseAssets, { owner, repo, release_id: release.id, per_page: 100 });
  for (const [name, data] of payloads) {
    const matches = assets.filter(asset => asset.name === name);
    if (matches.length !== 1 || matches[0].state !== 'uploaded' || matches[0].size !== data.length || matches[0].digest !== digest(data)) {
      throw new Error(`Uploaded installer failed size/SHA-256 verification: ${name}`);
    }
  }
  if (release.draft) await repos.updateRelease({
    owner, repo, release_id: release.id, body, draft: false, prerelease: false, make_latest: 'false',
  });
  // One metadata update switches the visible table. Legacy assets on the alias
  // remain untouched so existing download URLs never disappear mid-upgrade.
  const aliasBody = `${body}\n\n[Versioned release](${versionUrl})\n\nUse the links above for this version. Any older files under Assets are retained for existing links.\n`;
  if (alias) {
    await repos.updateRelease({ owner, repo, release_id: alias.id, name: 'Velron Installer', body: aliasBody, draft: false, prerelease: false, make_latest: 'false' });
  } else {
    await repos.createRelease({ owner, repo, tag_name: 'installer-latest', target_commitish: context.sha, name: 'Velron Installer', body: aliasBody, draft: false, prerelease: false, make_latest: 'false' });
  }
  return versionUrl;
}
module.exports = { publishRelease, installerFiles };
