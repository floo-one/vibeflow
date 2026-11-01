import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: process.env.SITE_URL ?? 'https://floo-one.github.io',
  base: process.env.BASE_PATH ?? '/vibeflow',
  trailingSlash: 'always',
  integrations: [sitemap({ filter: (page) => !page.includes('/og/') })],
});
