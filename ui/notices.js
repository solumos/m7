import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';

// Include the full upstream notices for all production dependencies, even those
// removed by tree shaking. Fail the build if a new dependency needs manual review.
const lock = JSON.parse(readFileSync(new URL('./package-lock.json', import.meta.url)));
let notices = 'M7 original software: Unlicense. Third-party code retains its own licenses.\n';
notices += '\nChakra Petch font, sourced from Google Fonts; SIL Open Font License 1.1.\n' + readFileSync(new URL('./public/fonts/OFL.txt', import.meta.url), 'utf8');
const logos = JSON.parse(readFileSync(new URL('./public/companies/sources.json', import.meta.url)));
notices += '\nCompany logos supplied through Coinbase Tokenized Stocks metadata. These brand assets and trademarks remain the property of their respective owners and are not covered by the M7 Unlicense. Their display identifies the underlying companies; it does not indicate affiliation or endorsement.\n';
for (const logo of logos.assets) notices += `\n${logo.name} (${logo.symbol}): ${logo.source_url}\n`;
for (const [path, pkg] of Object.entries(lock.packages)) {
  if (!path || pkg.dev) continue;
  if (pkg.license !== 'MIT') throw new Error(`Review the license for ${path} before distribution.`);
  const license = readFileSync(new URL(`./${path}/LICENSE`, import.meta.url), 'utf8');
  notices += `\n${'='.repeat(72)}\n${path.replace('node_modules/', '')} ${pkg.version} — ${pkg.license}\n\n${license}\n`;
}
writeFileSync(new URL('./public/THIRD_PARTY_NOTICES.txt', import.meta.url), notices);
copyFileSync(new URL('../LICENSE', import.meta.url), new URL('./public/LICENSE.txt', import.meta.url));
