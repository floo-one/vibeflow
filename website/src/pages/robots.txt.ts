import type { APIRoute } from 'astro';
import { url } from '../data/site';

// Generated, not in public/, so the Sitemap line follows SITE_URL and BASE_PATH.
export const GET: APIRoute = ({ site }) => {
  const sitemap = new URL(url('sitemap-index.xml'), site).href;
  return new Response(`User-agent: *\nAllow: /\n\nSitemap: ${sitemap}\n`, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
