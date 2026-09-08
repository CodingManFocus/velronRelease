const { test } = require('node:test');
const assert = require('node:assert/strict');
const { getDefaults, validateOptions, toEnvironment } = require('../app/installOptions.cjs');

test('Unix and Windows choices use native absolute paths and encode every installer setting', () => {
  for (const [platform, home] of [['linux', '/home/focus'], ['darwin', '/Users/focus'], ['win32', 'C:\\Users\\Focus']]) {
    const options = validateOptions(getDefaults(platform, home, {}), platform);
    assert.equal(options.components, 'both');
    assert.equal(Object.keys(toEnvironment(options)).length, 14);
    assert.equal(toEnvironment(options).VELRON_INSTALL_KEEP_CONFIG, 'true');
  }
});

test('remote mode validates credentials, path, scheme, token and clears unused secrets', () => {
  const options = { ...getDefaults('linux', '/home/focus'), connection: 'remote', vcpUrl: 'wss://example.com:4141/vcp/v1', vcpToken: 'a'.repeat(43) };
  assert.equal(validateOptions(options, 'linux').vcpToken.length, 43);
  for (const url of ['http://example.com/vcp/v1', 'wss://a:b@example.com/vcp/v1', 'wss://example.com/vcp/v2', 'wss://example.com/vcp/v1?', 'wss://example.com/vcp/v1#']) {
    assert.throws(() => validateOptions({ ...options, vcpUrl: url }, 'linux'));
  }
  assert.throws(() => validateOptions({ ...options, vcpToken: 'short' }, 'linux'));
  assert.equal(validateOptions({ ...options, connection: 'local' }, 'linux').vcpToken, '');
  assert.equal(validateOptions({ ...options, components: 'server' }, 'linux').vcpToken, '');
  assert.equal(validateOptions({ ...options, components: 'server' }, 'linux').connection, 'local');
  assert.equal(validateOptions({ ...options, components: 'client', httpPort: 0 }, 'linux').httpPort, 4141);
});

test('rejects malformed inputs at the privileged boundary', () => {
  const base = getDefaults('linux', '/home/focus');
  for (const patch of [{ commandDir: 'relative' }, { velronHome: '/a\n/b' }, { httpPort: 0 }, { vcpPort: 4141 }, { keepConfig: 'true' }, { components: 'nothing' }, { integration: 'shell' }, { serverHost: 'x;curl evil' }, { allowedHosts: 'x,$(id)' }, { arbitraryCommand: 'whoami' }]) {
    assert.throws(() => validateOptions({ ...base, ...patch }, 'linux'));
  }
  const windows = getDefaults('win32', 'C:\\Users\\Focus', {});
  for (const commandDir of ['C:relative', '\\rooted-without-drive', 'C:\\%TEMP%\\bin', 'C:\\bad|path']) assert.throws(() => validateOptions({ ...windows, commandDir }, 'win32'));
});
