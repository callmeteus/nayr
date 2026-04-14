#!/usr/bin/env node

const { execSync } = require("child_process");
const path = require("path");

const binDir = path.dirname(process.execPath);
const target = path.join(binDir, "nayr");
const source = path.resolve(__dirname, "nayr.js");

execSync(`chmod +x ${source}`);
execSync(`ln -sf ${source} ${target}`);

console.log(`nayr linked → ${target}`);
