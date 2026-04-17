#!/usr/bin/env node
// Fetch Springer papers for T5-P0 via headed Playwright browser (TIB VPN required).
// Usage: node scripts/fetch_t5_springer.mjs
//
// 1. Ensure TIB VPN is active.
// 2. Script opens headed Chromium (persistent profile) and navigates to Springer.
// 3. Click any Cloudflare challenge in the browser window if it appears.
// 4. Script auto-detects when you pass it and fetches both PDFs.
//
// Papers:
//   Bennett-4g0d: Mogensen 2018 NGC 36:203 — reversible GC / hash-cons
//   Bennett-3x2v: Axelsen & Glück 2013 LNCS 7948 — reversible heap / EXCH

// Import playwright from FQHE project (already installed there)
import { createRequire } from 'module';
const require = createRequire('/home/tobias/Projects/FQHE/package.json');
const { chromium } = require('playwright');

import { writeFileSync, existsSync, mkdirSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const OUTPUT_DIR = resolve(__dirname, '..', 'docs', 'literature', 'memory');
mkdirSync(OUTPUT_DIR, { recursive: true });

// Use the FQHE persistent browser profile (reuse cookies / session state)
const USER_DATA_DIR = resolve(__dirname, '..', 'scripts', '.browser-profile');
mkdirSync(USER_DATA_DIR, { recursive: true });

const PAPERS = [
  {
    id:   'Bennett-4g0d',
    name: 'Mogensen 2018 NGC 36:203',
    // Springer article page (will ask for institutional access)
    pageUrl: 'https://link.springer.com/article/10.1007/s00354-018-0037-3',
    // Direct PDF download URL (Springer pattern)
    pdfUrl:  'https://link.springer.com/content/pdf/10.1007/s00354-018-0037-3.pdf',
    file:    'Mogensen2018_reversible_gc.pdf',
  },
  {
    id:   'Bennett-3x2v',
    name: 'Axelsen & Glück 2013 LNCS 7948',
    pageUrl: 'https://link.springer.com/chapter/10.1007/978-3-642-38986-3_9',
    pdfUrl:  'https://link.springer.com/content/pdf/10.1007/978-3-642-38986-3_9.pdf',
    file:    'AxelsenGluck2013_reversible_heap.pdf',
  },
];

// Wait until the Springer article page has loaded past any Cloudflare/access challenge.
// We check for the presence of Springer article metadata or the download button.
async function waitForSpringerPage(page, timeoutMs = 180000) {
  console.log('\nWaiting for Springer page to load past any challenge...');
  console.log('>>> If you see a Cloudflare or access challenge, click through it <<<');
  console.log(`>>> You have ${timeoutMs / 1000}s — take your time <<<\n`);

  try {
    await page.waitForFunction(() => {
      // Real Springer article pages have:
      //   <meta name="citation_title"> or <meta name="dc.title">
      //   or the article title heading
      //   or a "Download PDF" link
      return (
        document.querySelector('meta[name="citation_title"]') ||
        document.querySelector('meta[name="dc.title"]') ||
        document.querySelector('h1.c-article-title') ||
        document.querySelector('a[data-track-action="download pdf"]') ||
        document.querySelector('.c-pdf-download') ||
        document.querySelector('#main-content')
      );
    }, { timeout: timeoutMs });

    const title = await page.title();
    console.log(`Page loaded: "${title}"`);
    console.log('Access challenge passed!\n');
    // Small pause to let any redirects settle
    await new Promise(r => setTimeout(r, 2000));
    return true;
  } catch (_) {
    console.error('Timed out waiting for Springer page to load.');
    return false;
  }
}

async function fetchPdf(page, paper) {
  const outPath = resolve(OUTPUT_DIR, paper.file);

  if (existsSync(outPath)) {
    console.log(`SKIP ${paper.id}: ${paper.file} (already exists)`);
    return 'skipped';
  }

  console.log(`\n--- Fetching ${paper.id}: ${paper.name} ---`);
  console.log(`  Page: ${paper.pageUrl}`);
  console.log(`  PDF:  ${paper.pdfUrl}`);

  // Navigate to article page first (to set cookies/referer)
  try {
    await page.goto(paper.pageUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
    const passed = await waitForSpringerPage(page);
    if (!passed) {
      console.log(`FAIL ${paper.id}: could not get past access challenge`);
      return 'failed';
    }
  } catch (e) {
    console.log(`FAIL ${paper.id}: navigation error: ${e.message}`);
    return 'failed';
  }

  // Now fetch the PDF directly using the page's authenticated request context
  try {
    process.stdout.write(`  Downloading PDF ... `);
    const response = await page.request.get(paper.pdfUrl, {
      timeout: 60000,
      headers: {
        'Referer': paper.pageUrl,
        'Accept': 'application/pdf,*/*',
      },
    });

    if (response.status() !== 200) {
      console.log(`FAIL (HTTP ${response.status()})`);
      // Try DOI redirect as fallback
      console.log(`  Trying DOI redirect...`);
      const doiUrl = `https://doi.org/10.1007/s00354-018-0037-3`;
      const r2 = await page.request.get(paper.pdfUrl, { timeout: 60000 });
      if (r2.status() !== 200) {
        console.log(`FAIL (HTTP ${r2.status()} via DOI)`);
        return 'failed';
      }
    }

    const body = await response.body();
    const header = body.slice(0, 5).toString('ascii');
    if (header !== '%PDF-') {
      console.log(`FAIL (not a PDF — got: "${header}" — likely a login page)`);
      // Save what we got for debugging
      const debugPath = outPath + '.debug.html';
      writeFileSync(debugPath, body);
      console.log(`  Debug content saved to: ${debugPath}`);
      return 'failed';
    }

    writeFileSync(outPath, body);
    console.log(`OK (${(body.length / 1024).toFixed(0)} KB) -> ${outPath}`);
    return 'ok';

  } catch (e) {
    console.log(`ERROR: ${e.message}`);
    return 'failed';
  }
}

async function main() {
  console.log('=== T5-P0 Springer Paper Fetcher ===');
  console.log('Launching headed Chromium (persistent profile)...');
  console.log('Make sure TIB VPN is active!\n');

  const context = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-sandbox',
    ],
    viewport: { width: 1280, height: 900 },
  });

  const page = context.pages()[0] || await context.newPage();

  const results = {};

  for (const paper of PAPERS) {
    const result = await fetchPdf(page, paper);
    results[paper.id] = result;
    // Small pause between papers
    if (result !== 'skipped') {
      await new Promise(r => setTimeout(r, 2000));
    }
  }

  console.log('\n=== Summary ===');
  for (const [id, result] of Object.entries(results)) {
    console.log(`  ${id}: ${result}`);
  }

  await context.close();

  const anyFailed = Object.values(results).some(r => r === 'failed');
  if (anyFailed) {
    console.log('\nSome downloads failed. Check the debug .html files for details.');
    process.exit(1);
  }
  console.log('\nAll done!');
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
