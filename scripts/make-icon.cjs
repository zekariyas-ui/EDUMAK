'use strict';

const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const pngToIco = require('png-to-ico');

async function main() {
  const root = path.resolve(__dirname, '..');
  const source = path.join(root, 'EDUMAK_Cloud_App', 'icons', 'edumak-icon.svg');
  const outputDir = path.join(root, 'build');
  const output = path.join(outputDir, 'edumak.ico');
  fs.mkdirSync(outputDir, { recursive: true });

  const png = await sharp(source).resize(256, 256).png().toBuffer();
  const ico = await pngToIco(png);
  fs.writeFileSync(output, ico);
  console.log('Created Windows application icon:', output);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
