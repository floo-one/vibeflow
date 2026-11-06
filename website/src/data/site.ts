import { readFileSync } from 'node:fs';
import path from 'node:path';

export const REPO_URL = 'https://github.com/floo-one/vibeflow';
export const CHANGELOG_URL = REPO_URL + '/blob/main/CHANGELOG.md';
export const DMG_URL = REPO_URL + '/releases/latest/download/Maagical.dmg';
export const PUBLISHER = 'floo.one LLC';

// Astro runs from website/, so the app's project.yml is one level up. import.meta.url would
// point into the bundle after a build.
function readVersion(): string {
  const file = path.resolve(process.cwd(), '../project.yml');
  let text: string;
  try {
    text = readFileSync(file, 'utf8');
  } catch {
    throw new Error(`site.ts: cannot read ${file} for MARKETING_VERSION`);
  }
  const match = text.match(/MARKETING_VERSION:\s*"([^"]+)"/);
  if (!match?.[1]) throw new Error(`site.ts: no MARKETING_VERSION in ${file}`);
  return match[1];
}

export const VERSION = readVersion();

/** An internal link with the base path in front: url('meetings/') → /vibeflow/meetings/. */
export function url(path = ''): string {
  const base = import.meta.env.BASE_URL.endsWith('/')
    ? import.meta.env.BASE_URL
    : import.meta.env.BASE_URL + '/';
  return base + path.replace(/^\//, '');
}
