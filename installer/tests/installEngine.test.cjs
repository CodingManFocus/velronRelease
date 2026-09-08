const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { getDefaults, toEnvironment } = require('../app/installOptions.cjs');
const exec = promisify(execFile);
const engine = path.resolve(__dirname, '../../install.sh');

async function fixture(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'velron-engine-test-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const home = path.join(dir, "home with 'quotes and \\slashes");
  const bin = path.join(dir, 'tools'); const downloads = path.join(dir, 'downloads');
  await Promise.all([home, bin, downloads].map(value => fs.mkdir(value, { recursive: true })));
  const assets = [];
  for (const component of ['velron', 'velron-client']) {
    for (const platform of ['linux', 'macos']) for (const arch of ['x64', 'arm64']) {
      const name = `${component}-${platform}-${arch}`;
      const content = '#!/bin/sh\nprintf "fake binary\\n"\n';
      await fs.writeFile(path.join(downloads, name), content);
      assets.push(crypto.createHash('sha256').update(content).digest('hex') + '  ' + name);
    }
  }
  await fs.writeFile(path.join(downloads, 'SHA256SUMS.txt'), assets.join('\n') + '\n');
  await fs.writeFile(path.join(bin, 'curl'), '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n case "$1" in https://*) url=$1;; -o) shift; output=$1;; esac\n shift\ndone\ncp "$FAKE_DOWNLOADS/${url##*/}" "$output"\n', { mode: 0o755 });
  await fs.writeFile(path.join(bin, 'systemctl'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  await fs.writeFile(path.join(bin, 'launchctl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  for (const host of ['codex', 'claude']) await fs.writeFile(path.join(bin, host), '#!/bin/sh\n[ "$1 $2 $3" = "mcp get --help" ] && exit 0\n[ "$1 $2 $3" = "mcp get velron" ] && exit "${FAKE_EXISTING_ENTRY:-1}"\nprintf "%s\\n" "$*" >> "$FAKE_HOST_CALLS"\nexit 0\n', { mode: 0o755 });
  const options = { ...getDefaults(process.platform, home), autostart: false, startNow: false, integration: 'both' };
  const env = { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, XDG_DATA_HOME: path.join(dir, 'data'),
    XDG_CONFIG_HOME: path.join(dir, 'config'), FAKE_DOWNLOADS: downloads, FAKE_HOST_CALLS: path.join(dir, 'host-calls'), NO_COLOR: '1' };
  return { dir, home, bin, downloads, options, env, run: (patch = {}, extra = {}) => exec('/bin/sh', [engine, '--non-interactive'], {
    env: { ...env, ...toEnvironment({ ...options, ...patch }), ...extra }, timeout: 20000, maxBuffer: 1024 * 1024,
  }) };
}

test('headless engine installs both components, configures remote MCP and preserves exact quoted paths', { skip: process.platform === 'win32' }, async t => {
  const f = await fixture(t); const token = 'a'.repeat(43);
  const { stdout } = await f.run({ connection: 'remote', vcpUrl: 'wss://example.com:4141/vcp/v1', vcpToken: token });
  assert.match(stdout, /VELRON_INSTALL_STAGE:complete/);
  assert.ok(!stdout.includes(token));
  const config = JSON.parse(await fs.readFile(path.join(f.options.velronHome, 'config.json'), 'utf8'));
  assert.equal(config.port, 4141);
  const mcp = JSON.parse(await fs.readFile(path.join(f.options.velronHome, 'stdio-mcp.json'), 'utf8'));
  assert.equal(mcp.mcpServers.velron.command, path.join(f.options.commandDir, 'velron-client'));
  const privateEnv = path.join(f.options.velronHome, 'client.env');
  assert.equal((await fs.stat(privateEnv)).mode & 0o777, 0o600);
  const { stdout: configured } = await exec('/bin/sh', ['-c', '. "$1"; printf "%s" "$VELRON_HOME"', 'test', privateEnv]);
  assert.equal(configured, f.options.velronHome);
  assert.equal((await fs.readFile(f.env.FAKE_HOST_CALLS, 'utf8')).split('\n').filter(Boolean).length, 2);
});

test('component-only installs, existing config, MCP entries and local reconnection are preserved correctly', { skip: process.platform === 'win32' }, async t => {
  const f = await fixture(t);
  await f.run({ components: 'server', keepConfig: false, httpPort: 5151, vcpPort: 5153 });
  await assert.rejects(fs.stat(path.join(f.options.velronHome, 'stdio-mcp.json')));
  const before = await fs.readFile(path.join(f.options.velronHome, 'config.json'), 'utf8');
  const { stdout } = await f.run({}, { FAKE_EXISTING_ENTRY: '0' });
  assert.equal(await fs.readFile(path.join(f.options.velronHome, 'config.json'), 'utf8'), before);
  assert.match(stdout, /Preserved the existing codex/);
  await assert.rejects(fs.stat(f.env.FAKE_HOST_CALLS));
  await f.run({ components: 'client', connection: 'remote', vcpUrl: 'wss://example.com/vcp/v1', vcpToken: 'b'.repeat(43) });
  await f.run({ components: 'client', connection: 'local' });
  const clientEnv = await fs.readFile(path.join(f.options.velronHome, 'client.env'), 'utf8');
  assert.ok(!clientEnv.includes('VELRON_VCP_TOKEN'));
  assert.equal(await fs.readFile(path.join(f.options.velronHome, 'config.json'), 'utf8'), before);
  assert.equal((await fs.readFile(path.join(f.home, '.profile'), 'utf8')).match(/# >>> velron >>>/g).length, 1);
});

test('checksum failures and invalid selections fail before installing unverified binaries', { skip: process.platform === 'win32' }, async t => {
  const f = await fixture(t);
  await fs.writeFile(path.join(f.downloads, 'SHA256SUMS.txt'), '0'.repeat(64) + '  velron-' + (process.platform === 'darwin' ? 'macos' : 'linux') + '-' + (process.arch === 'arm64' ? 'arm64' : 'x64') + '\n');
  await assert.rejects(f.run(), error => error.code !== 0 && /SHA-256 verification failed/.test(error.stderr));
  await assert.rejects(fs.stat(path.join(f.options.commandDir, 'velron')));
  await assert.rejects(f.run({ components: 'typo' }), error => error.code !== 0);
});
