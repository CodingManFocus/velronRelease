const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const installerFiles = Object.freeze([
  'Velron-Installer-windows-x64.exe',
  'Velron-Installer-windows-arm64.exe',
  'Velron-Installer-macos-universal.zip',
  'Velron-Installer-linux.tar.gz',
]);

/** Prepare local files for a human to upload; this helper cannot publish releases. */
async function prepareReleaseFiles(directory = 'dist') {
  const inputs = installerFiles.map(name => {
    const filename = path.join(directory, name);
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.size === 0) {
      throw new Error(`Expected a non-empty regular file: ${name}`);
    }
    return { name, filename, size: stat.size };
  });

  const lines = [];
  for (const input of inputs) {
    const hash = crypto.createHash('sha256');
    let bytesRead = 0;
    for await (const chunk of fs.createReadStream(input.filename)) {
      hash.update(chunk);
      bytesRead += chunk.length;
    }
    if (bytesRead !== input.size) throw new Error(`Artifact changed while hashing: ${input.name}`);
    lines.push(`${hash.digest('hex')}  ${input.name}`);
  }

  const checksumPath = path.join(directory, 'SHA256SUMS-installers.txt');
  fs.writeFileSync(checksumPath, `${lines.join('\n')}\n`);
  return checksumPath;
}

if (require.main === module) {
  prepareReleaseFiles(process.argv[2] ?? 'dist').then(
    checksumPath => console.log(`Prepared ${installerFiles.length} installer files and ${checksumPath} for manual upload.`),
    error => { console.error(error.message); process.exitCode = 1; },
  );
}

module.exports = { installerFiles, prepareReleaseFiles };
