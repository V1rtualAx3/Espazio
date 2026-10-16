// Renders Resources/AppIcon.iconset from Resources/Brand/AppIcon.svg (headless Chromium via Playwright).
// Usage: node scripts/render-iconset.js Resources/Brand/AppIcon.svg Resources/AppIcon.iconset
const { chromium } = require('playwright'); const fs = require('fs');
const [svgPath, outDir, previewSvg, previewOut] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch({executablePath:'/opt/pw-browsers/chromium-1194/chrome-linux/chrome'});
  const svg = fs.readFileSync(svgPath, 'utf8');
  fs.mkdirSync(outDir, {recursive: true});
  for (const base of [16, 32, 128, 256, 512]) for (const scale of [1, 2]) {
    const px = base * scale;
    const p = await b.newPage({viewport: {width: px, height: px}});
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('<svg ', `<svg style="display:block" `).replace(/width="1024" height="1024"/, `width="${px}" height="${px}"`)}</body></html>`);
    const name = `icon_${base}x${base}${scale === 2 ? '@2x' : ''}.png`;
    await p.screenshot({path: `${outDir}/${name}`, omitBackground: true}); await p.close();
  }
  await b.close();
})();
