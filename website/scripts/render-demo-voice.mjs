#!/usr/bin/env node
// Renders every line the website demo speaks with ElevenLabs, once, so the demo sounds like
// the app. Run by hand; the results are committed (no key in CI).
//
//   node scripts/render-demo-voice.mjs            render missing or changed clips
//   node scripts/render-demo-voice.mjs --force    render all clips again
//
// In:  src/data/demo-lines.json   { model, voices: {name: id}, lines: [{id, voice, speed, text}] }
// Out: public/demo/voice/<id>.mp3 and public/demo/voice/voice.json
//      { clips: { <id>: { text, d, t: [start ms per character], h } } }
//      plus voice.js (the same data as window.DEMO_VOICE, for the file:// prototype).
//
// Key: ELEVENLABS_API_KEY, else the app's Keychain item (service one.floo.vibeflow,
// account elevenlabs-api-key). The key is never printed.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const linesFile = path.join(root, 'src/data/demo-lines.json');
const outDir = path.join(root, 'public/demo/voice');
const force = process.argv.includes('--force');

function apiKey() {
  if (process.env.ELEVENLABS_API_KEY) return process.env.ELEVENLABS_API_KEY.trim();
  try {
    return execFileSync('security', ['find-generic-password', '-s', 'one.floo.vibeflow', '-a', 'elevenlabs-api-key', '-w'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 60_000 }).trim();
  } catch {
    console.error('No ElevenLabs key: set ELEVENLABS_API_KEY or allow access to the VibeFlow Keychain item.');
    process.exit(1);
  }
}

const spec = JSON.parse(readFileSync(linesFile, 'utf8'));
mkdirSync(outDir, { recursive: true });
const manifestFile = path.join(outDir, 'voice.json');
const old = existsSync(manifestFile) ? JSON.parse(readFileSync(manifestFile, 'utf8')).clips : {};
const clips = {};
let key = null, rendered = 0, chars = 0;

for (const line of spec.lines) {
  const voiceId = spec.voices[line.voice] ?? line.voice;
  const speed = line.speed ?? 1;
  const h = createHash('sha1').update(JSON.stringify([line.text, voiceId, speed, spec.model])).digest('hex').slice(0, 12);
  const mp3 = path.join(outDir, `${line.id}.mp3`);
  if (!force && old[line.id]?.h === h && existsSync(mp3)) { clips[line.id] = old[line.id]; continue; }

  key ??= apiKey();
  const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}/with-timestamps?output_format=mp3_44100_64`, {
    method: 'POST',
    headers: { 'xi-api-key': key, 'content-type': 'application/json' },
    body: JSON.stringify({
      text: line.text, model_id: spec.model, language_code: 'en',
      voice_settings: { speed, stability: 0.5, similarity_boost: 0.75 },
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(`${line.id}: HTTP ${res.status} (${body.length} bytes)`);
    if (res.status === 401 || res.status === 403) console.error(body.slice(0, 300));
    process.exit(1);
  }
  const json = await res.json();
  const a = json.alignment;
  if (!a || a.characters.join('') !== line.text) {
    console.error(`${line.id}: the alignment does not match the text; check for characters ElevenLabs rewrites.`);
    process.exit(1);
  }
  writeFileSync(mp3, Buffer.from(json.audio_base64, 'base64'));
  const t = a.character_start_times_seconds.map(s => Math.round(s * 1000));
  const d = Math.round(a.character_end_times_seconds.at(-1) * 1000);
  clips[line.id] = { text: line.text, d, t, h };
  rendered++; chars += line.text.length;
  console.log(`${line.id}  ${(d / 1000).toFixed(1)} s`);
}

writeFileSync(manifestFile, JSON.stringify({ clips }) + '\n');
writeFileSync(path.join(outDir, 'voice.js'), `window.DEMO_VOICE = ${JSON.stringify({ clips })};\n`);
console.log(`${rendered} rendered (${chars} characters), ${spec.lines.length - rendered} unchanged.`);
