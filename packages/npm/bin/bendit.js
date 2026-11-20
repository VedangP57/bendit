#!/usr/bin/env node
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');

const installPath = path.join(__dirname, '..', 'install.sh');
const result = spawnSync('bash', [installPath, ...process.argv.slice(2)], { stdio: 'inherit' });

if (result.error) {
  if (result.error.code === 'ENOENT') {
    console.error('bendit needs bash, and it was not found on PATH.');
  } else {
    console.error('bendit could not run its installer: ' + result.error.message);
  }
  process.exit(2);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status === null ? 1 : result.status);
