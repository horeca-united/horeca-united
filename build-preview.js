#!/usr/bin/env node
// HUOS private staging build: publish ONLY the generated HTML, never repository internals.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
execFileSync(process.execPath, [path.join(__dirname, 'build.js')], { stdio: 'inherit' });
const out = path.join(__dirname, 'dist');
fs.mkdirSync(out, { recursive: true });
fs.copyFileSync(path.join(__dirname, 'index.html'), path.join(out, 'index.html'));
console.log('Private preview output built: dist/index.html');
