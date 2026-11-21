'use strict';
const path = require('node:path');
const root = path.join(__dirname, '..');
function detect(platform = process.platform, arch = process.arch) {
  const target = {
    'darwin/arm64': 'darwin-aarch64',
    'linux/x64': 'linux-x86_64',
    'linux/arm64': 'linux-arm64',
  }[`${platform}/${arch}`];
  if (!target)
    throw Error(
      `dbsandbox: unsupported platform ${platform}/${arch}. Supported: macOS Apple Silicon, Linux x86_64 and Linux ARM64.`,
    );
  return { target, asset: `dbsandbox-${target}.tar.gz` };
}
const binaryPath = () => path.join(root, 'binaries', 'dbsandbox');
module.exports = { root, detect, binaryPath };
