// Renders an SVG to PNG at a given point size and scale (headless Chromium via Playwright).
// Usage: node scripts/render-png.js <in.svg> <out.png> <width-pt> <height-pt> <scale>
const { chromium } = require('playwright'); const fs = require('fs');
const [svgPath, outPath, w, h, scale] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch({executablePath: process.env.CHROMIUM_PATH || '/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell'});
  const p = await b.newPage({viewport: {width: +w, height: +h}, deviceScaleFactor: +scale});
  const svg = fs.readFileSync(svgPath, 'utf8').replace('<svg ', '<svg style="display:block" ');
  await p.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
  await p.screenshot({path: outPath, omitBackground: true, clip: {x: 0, y: 0, width: +w, height: +h}});
  await b.close();
})();
