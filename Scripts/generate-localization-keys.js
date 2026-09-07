#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const RESERVED = new Set([
  'Type', 'Protocol', 'Self', 'self', 'class', 'struct', 'enum',
  'func', 'var', 'let', 'import', 'return', 'switch', 'case',
  'default', 'break', 'continue', 'where', 'in', 'for', 'while',
  'repeat', 'if', 'else', 'guard', 'do', 'try', 'catch', 'throw',
  'as', 'is', 'nil', 'true', 'false', 'super', 'init', 'deinit',
]);

function esc(name) {
  if (RESERVED.has(name)) return '`' + name + '`';
  if (/^[0-9]/.test(name)) return '_' + name;
  return name;
}

function cap(s) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function generate(obj, keyPath = [], indent = 1) {
  const pad = '    '.repeat(indent);
  const keys = Object.keys(obj).sort();
  let leaves = '';
  let nested = '';

  for (const key of keys) {
    const val = obj[key];
    if (typeof val === 'string') {
      const fullKey = [...keyPath, key].join('.');
      leaves += `${pad}static let ${esc(cap(key))} = "${fullKey}"\n`;
    } else if (typeof val === 'object' && val !== null) {
      if (nested || leaves) nested += '\n';
      nested += `${pad}enum ${esc(cap(key))} {\n`;
      nested += generate(val, [...keyPath, key], indent + 1);
      nested += `${pad}}\n`;
    }
  }

  return leaves + nested;
}

// --- Main ---

const backendRoot = path.resolve(__dirname, '..');
const inputFile = path.resolve(backendRoot, '..', 'FynnCloud-UI', 'i18n', 'locales', 'en.json');
const outputFile = path.join(backendRoot, 'Sources', 'FynnCloudServer', 'DTOs', 'LocalizationKeys.swift');

if (!fs.existsSync(inputFile)) {
  console.error(`❌ Input file not found: ${inputFile}`);
  console.error('   Make sure FynnCloud-UI is located next to FynnCloud-Backend');
  process.exit(1);
}

const json = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
const body = generate(json);

const swift = `// ⚠️ AUTO-GENERATED FILE - DO NOT EDIT MANUALLY
// Generated from: FynnCloud-UI/i18n/locales/en.json
// Run: node Scripts/generate-localization-keys.js

// swiftlint:disable type_body_length file_length
enum LocalizationKeys {
${body}}
// swiftlint:enable type_body_length file_length
`;

fs.writeFileSync(outputFile, swift);
console.log(`✅ Generated ${outputFile}`);
