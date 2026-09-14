#!/usr/bin/env node
// gpu-check.mjs — does headless Chromium in this container render WebGL on the GPU? (#305)
//
//   node scripts/gpu-check.mjs            -> one line per candidate flag set, then the first that uses the GPU
//
// Launches the Playwright MCP's own Chromium with each candidate set of launch args, reads the WebGL
// UNMASKED_RENDERER string, and calls a renderer "hardware" unless it names a software rasteriser.
// Exit 0 when at least one candidate is hardware, 1 otherwise. The winning args belong in
// .devcontainer/playwright-mcp.json (launchOptions.args).
import { createRequire } from 'node:module';

const PLAYWRIGHT_MODULE = '/usr/lib/node_modules/@playwright/mcp/node_modules/playwright';
const SOFTWARE_RENDERER = /swiftshader|llvmpipe|softpipe|software/i;
const CANDIDATES = [
  { name: 'default (no flags)', headless: true, args: [] },
  {
    name: 'angle-vulkan',
    headless: true,
    args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist'],
  },
  { name: 'angle-gl-egl', headless: true, args: ['--use-gl=angle', '--use-angle=gl-egl', '--ignore-gpu-blocklist'] },
  { name: 'egl', headless: true, args: ['--use-gl=egl', '--ignore-gpu-blocklist'] },
  {
    name: 'new-headless angle-vulkan',
    headless: false,
    args: ['--headless=new', '--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist'],
  },
  {
    name: 'new-headless angle-gl-egl',
    headless: false,
    args: ['--headless=new', '--use-gl=angle', '--use-angle=gl-egl', '--ignore-gpu-blocklist'],
  },
];

const { chromium } = createRequire(import.meta.url)(PLAYWRIGHT_MODULE);

async function rendererFor(candidate) {
  const browser = await chromium.launch({ headless: candidate.headless, args: candidate.args });
  try {
    const page = await browser.newPage();
    return await page.evaluate(() => {
      const gl =
        document.createElement('canvas').getContext('webgl2') ?? document.createElement('canvas').getContext('webgl');
      if (!gl) return 'no WebGL context';
      const info = gl.getExtension('WEBGL_debug_renderer_info');
      return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    });
  } finally {
    await browser.close();
  }
}

let winner;
for (const candidate of CANDIDATES) {
  let renderer;
  try {
    renderer = await rendererFor(candidate);
  } catch (error) {
    renderer = `launch failed: ${String(error.message).split('\n')[0]}`;
  }
  const isHardware = !SOFTWARE_RENDERER.test(renderer) && !/^(no WebGL|launch failed)/.test(renderer);
  console.log(`${isHardware ? 'GPU ' : 'soft'}  ${candidate.name.padEnd(28)} ${renderer}`);
  if (isHardware && !winner) winner = candidate;
}
if (winner) {
  console.log(`\nfirst hardware candidate: ${winner.name}`);
  console.log(JSON.stringify({ headless: winner.headless, args: winner.args }));
  process.exit(0);
}
console.log('\nno candidate rendered on the GPU');
process.exit(1);
