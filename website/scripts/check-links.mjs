// Fails when an internal href or src in dist/ points at a file the build did not produce.
// External links are not fetched. Run after `astro build`: node scripts/check-links.mjs
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

const dist = path.resolve('dist');
const base = (process.env.BASE_PATH ?? '/vibeflow').replace(/\/?$/, '/');

function htmlFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return htmlFiles(full);
    return name.endsWith('.html') ? [full] : [];
  });
}

function target(link) {
  let rel = decodeURIComponent(link.slice(base.length).split('#')[0].split('?')[0]);
  if (rel === '' || rel.endsWith('/')) rel += 'index.html';
  return path.join(dist, rel);
}

const broken = [];
let checked = 0;
for (const file of htmlFiles(dist)) {
  const html = readFileSync(file, 'utf8');
  for (const [, link] of html.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    if (!link.startsWith(base) && link !== base.slice(0, -1)) continue;
    checked++;
    if (!existsSync(target(link))) broken.push(`${path.relative(dist, file)}: ${link}`);
  }
}

if (broken.length) {
  console.error(`Broken internal links (${broken.length}):\n  ${broken.join('\n  ')}`);
  process.exit(1);
}
console.log(`Link check: ${checked} internal links in dist/ resolve.`);
