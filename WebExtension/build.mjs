// Bundles the extension into Extensions/Advanced/Resources, which Xcode copies into the appex.
// Run `npm run build` after changing anything in src/ or static/.
import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';

const out = new URL('../Extensions/Advanced/Resources/', import.meta.url).pathname;
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(new URL('./static/', import.meta.url).pathname, out, { recursive: true });

await build({
  entryPoints: { background: 'src/background.js', content: 'src/content.js' },
  outdir: out,
  bundle: true,
  format: 'iife',
  target: ['safari16'],
  minify: true,
  legalComments: 'linked',
  logLevel: 'info',
});
