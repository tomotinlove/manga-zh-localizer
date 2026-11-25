/**
 * DeepSeek Harness (DSH) native Cordis plugin for manga-zh-localizer.
 *
 * Zero external runtime dependencies:
 * 1. Registers the bundled `manga-zh-localizer` Agent Skill into `ctx.skills`
 *    (with `resourceBase` pointing directly at `skills/manga-zh-localizer/`).
 * 2. Registers structured `manga_doctor`, `manga_scan`, `manga_build`, and
 *    `manga_package` tools into `ctx.tools` wrapping `batch_job.ps1`.
 */

import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(PLUGIN_DIR);
const SKILL_DIR = join(REPO_ROOT, 'skills', 'manga-zh-localizer');
const SKILL_MD_URL = new URL('../skills/manga-zh-localizer/SKILL.md', import.meta.url);
const BATCH_SCRIPT = join(SKILL_DIR, 'scripts', 'batch_job.ps1');

const PROVIDER_NAME = 'manga-zh-localizer';
const SKILL_DESCRIPTION =
  'Fast, lossless Chinese localization workflow for Japanese/Korean/color manga pages and text-bearing illustrations on Windows. Use whenever the user asks to translate, clean, typeset, or localize manga comics, doujinshi, or anime illustrations into Chinese, or refine dialogue/typography.';

export const name = 'manga-zh-localizer';

function runBatchJob(mode, extraArgs, pluginConfig = {}) {
  if (process.platform !== 'win32') {
    return Promise.resolve({
      ok: false,
      exitCode: 1,
      output:
        'manga-zh-localizer requires Windows (PowerShell 5.1+, .NET System.Drawing, and headless Edge/Chrome).',
    });
  }

  const args = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    BATCH_SCRIPT,
    '-Mode',
    mode,
    ...extraArgs,
  ];

  const env = { ...process.env };
  if (pluginConfig.inboxDir && !env.MANGA_INBOX_DIR) env.MANGA_INBOX_DIR = String(pluginConfig.inboxDir);
  if (pluginConfig.outDir && !env.MANGA_OUT_DIR) env.MANGA_OUT_DIR = String(pluginConfig.outDir);
  if (pluginConfig.tmpDir && !env.MANGA_TMP_DIR) env.MANGA_TMP_DIR = String(pluginConfig.tmpDir);
  if (pluginConfig.browserBin && !env.MANGA_BROWSER_BIN) env.MANGA_BROWSER_BIN = String(pluginConfig.browserBin);

  return new Promise((resolve) => {
    execFile(
      'powershell.exe',
      args,
      {
        cwd: REPO_ROOT,
        env,
        windowsHide: true,
        maxBuffer: 16 * 1024 * 1024,
        timeout: 300_000,
      },
      (error, stdout, stderr) => {
        const combined = [stdout, stderr].filter(Boolean).join('\n').trim();
        const exitCode = error ? (typeof error.code === 'number' ? error.code : 1) : 0;
        resolve({
          ok: exitCode === 0,
          exitCode,
          output: combined || (error ? error.message : 'OK'),
        });
      },
    );
  });
}

function makeOutputSpec() {
  return {
    schema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        ok: { type: 'boolean' },
        exitCode: { type: 'integer' },
        output: { type: 'string' },
      },
      required: ['ok', 'exitCode', 'output'],
    },
    render: (_args, value) => [
      {
        type: 'text',
        text: value.ok
          ? value.output
          : `[exitCode=${value.exitCode}]\n${value.output}`,
      },
    ],
  };
}

function registerSkill(ctx) {
  if (!ctx?.skills || typeof ctx.skills.registerProvider !== 'function') return;

  const resourceBase = { kind: 'directory', path: SKILL_DIR };
  const candidate = {
    name: 'manga-zh-localizer',
    description: SKILL_DESCRIPTION,
    provider: PROVIDER_NAME,
    source: 'plugin',
    resourceBase,
    locator: SKILL_MD_URL,
    rank: 450,
  };

  const provider = {
    name: PROVIDER_NAME,
    list: () => Promise.resolve([candidate]),
    async get() {
      return {
        name: candidate.name,
        description: candidate.description,
        provider: candidate.provider,
        source: candidate.source,
        resourceBase,
        content: await readFile(SKILL_MD_URL, 'utf8'),
      };
    },
  };

  const dispose = ctx.skills.registerProvider(() => provider);
  if (typeof dispose === 'function' && typeof ctx.effect === 'function') {
    ctx.effect(() => dispose, 'manga-zh-localizer: skill provider');
  }
}

function registerTools(ctx, config) {
  if (!ctx?.tools || typeof ctx.tools.register !== 'function') return;

  const output = makeOutputSpec();

  ctx.tools.register({
    name: 'manga_doctor',
    description:
      'Check manga-zh-localizer environment readiness on Windows (PowerShell, .NET GDI+, headless Edge/Chrome, CJK fonts, configured directories, and active glossaries).',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        inboxDir: { type: 'string', description: 'Optional override for inbox directory.' },
        outDir: { type: 'string', description: 'Optional override for output directory.' },
        tmpDir: { type: 'string', description: 'Optional override for temporary workspace directory.' },
        browserBin: { type: 'string', description: 'Optional override for headless Edge/Chrome executable.' },
      },
    },
    output,
    async execute(args = {}) {
      const cli = [];
      if (args.inboxDir) cli.push('-InboxDir', args.inboxDir);
      if (args.outDir) cli.push('-OutDir', args.outDir);
      if (args.tmpDir) cli.push('-TmpDir', args.tmpDir);
      if (args.browserBin) cli.push('-BrowserPath', args.browserBin);
      return runBatchJob('doctor', cli, config);
    },
  });

  ctx.tools.register({
    name: 'manga_scan',
    description:
      'Turn 1 of manga-zh-localizer: scan manga pages in parallel, detect bubble boxes/seeds/optical centers, save job_manifest.json, and stitch preview_sheet.jpg.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        images: {
          type: 'array',
          items: { type: 'string' },
          description: 'Explicit local image file paths in reading order (optional; uses inbox if omitted).',
        },
        latest: { type: 'boolean', description: 'Scan the latest work in inboxDir (default true when images/pattern omitted).' },
        pattern: { type: 'string', description: 'Optional glob pattern inside inboxDir (e.g. "12345*").' },
        job: { type: 'string', description: 'Optional job name.' },
        inboxDir: { type: 'string', description: 'Optional override for inbox directory.' },
        outDir: { type: 'string', description: 'Optional override for output directory.' },
        tmpDir: { type: 'string', description: 'Optional override for temporary workspace directory.' },
        maxParallel: { type: 'integer', description: 'Max parallel page workers (default 4).' },
      },
    },
    output,
    async execute(args = {}) {
      const cli = [];
      if (Array.isArray(args.images) && args.images.length > 0) {
        cli.push('-Images', args.images.join('|'));
      } else if (args.pattern) {
        cli.push('-Pattern', args.pattern);
      } else if (args.latest !== false) {
        cli.push('-Latest');
      }
      if (args.job) cli.push('-Job', args.job);
      if (args.inboxDir) cli.push('-InboxDir', args.inboxDir);
      if (args.outDir) cli.push('-OutDir', args.outDir);
      if (args.tmpDir) cli.push('-TmpDir', args.tmpDir);
      const mp = args.maxParallel || config.maxParallel;
      if (mp > 0) cli.push('-MaxParallel', String(mp));
      return runBatchJob('scan', cli, config);
    },
  });

  ctx.tools.register({
    name: 'manga_build',
    description:
      'Turn 2 of manga-zh-localizer: run parallel lossless bubble cleaning and 2x supersampled Chinese typesetting with optical centering, border-hit audit, and diff/qa/audit contact sheets.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        job: { type: 'string', description: 'Job name created by manga_scan.' },
        jobDir: { type: 'string', description: 'Optional explicit job directory containing job_manifest.json.' },
        pages: {
          type: 'array',
          items: { type: 'string' },
          description: 'Optional subset of page keys to re-render (e.g. ["p1"]).',
        },
        cleanOnly: { type: 'boolean', description: 'Run only clean_bubbles phase without typesetting.' },
        forceClean: { type: 'boolean', description: 'Force re-running clean_bubbles even when clean_final.png is up to date.' },
        superSample: { type: 'integer', description: 'Supersampling factor 1-3 (default 2).' },
        tmpDir: { type: 'string', description: 'Optional override for temporary workspace directory.' },
        outDir: { type: 'string', description: 'Optional override for output directory.' },
      },
    },
    output,
    async execute(args = {}) {
      const cli = [];
      if (args.job) cli.push('-Job', args.job);
      if (args.jobDir) cli.push('-JobDir', args.jobDir);
      if (Array.isArray(args.pages) && args.pages.length > 0) cli.push('-Pages', args.pages.join('|'));
      if (args.cleanOnly) cli.push('-CleanOnly');
      if (args.forceClean) cli.push('-ForceClean');
      const ss = args.superSample || config.superSample;
      if (ss > 0) cli.push('-SuperSample', String(ss));
      if (args.tmpDir) cli.push('-TmpDir', args.tmpDir);
      if (args.outDir) cli.push('-OutDir', args.outDir);
      return runBatchJob('build', cli, config);
    },
  });

  ctx.tools.register({
    name: 'manga_package',
    description:
      'Turn 3 of manga-zh-localizer: export final lossless PNGs into outDir (single page or ordered multi-page folder 01_..NN_ + vertical long stitched strip 00_<job>_long_zh.png with monotonic timestamps).',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        job: { type: 'string', description: 'Job name created by manga_scan.' },
        jobDir: { type: 'string', description: 'Optional explicit job directory containing job_manifest.json.' },
        outDir: { type: 'string', description: 'Optional override for output directory.' },
        tmpDir: { type: 'string', description: 'Optional override for temporary workspace directory.' },
      },
    },
    output,
    async execute(args = {}) {
      const cli = [];
      if (args.job) cli.push('-Job', args.job);
      if (args.jobDir) cli.push('-JobDir', args.jobDir);
      if (args.outDir) cli.push('-OutDir', args.outDir);
      if (args.tmpDir) cli.push('-TmpDir', args.tmpDir);
      return runBatchJob('package', cli, config);
    },
  });
}

export function apply(ctx, config = {}) {
  if (typeof ctx.inject === 'function') {
    ctx.inject(['skills'], (skillCtx) => registerSkill(skillCtx));
    ctx.inject(['tools'], (toolCtx) => registerTools(toolCtx, config));
  } else {
    registerSkill(ctx);
    registerTools(ctx, config);
  }
}

export default { name, apply };
