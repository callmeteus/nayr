#!/usr/bin/env node

const path = require("path");
const fs = require("fs");

const target = path.join(path.dirname(process.execPath), "nayr");

fs.rmSync(target, { force: true });

console.log(`nayr unlinked → ${target}`);
