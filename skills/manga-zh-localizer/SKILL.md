---
name: manga-zh-localizer
description: >-
  Fast, lossless Chinese localization workflow for Japanese/Korean/color manga pages and text-bearing illustrations on Windows.
  Use whenever the user asks to translate, clean, typeset, or localize manga comics, doujinshi, or anime illustrations into Chinese,
  or wants to refine dialogue or typography on a previously localized page.
---

# Manga & Illustration Fast Lossless Chinese Localizer (v4.4)

Fast, zero-dependency (Windows PowerShell 5.1 + inline C# `LockBits` + 2× HiDPI headless Edge/Chrome) workflow that preserves **100% original resolution and pixel fidelity** on all artwork outside text strokes, renders **print-sharp supersampled vector Chinese typography with pixel-level optical centering & border-collision audit**, and runs cleanly across **DeepSeek Harness (DSH), Antigravity, Claude Code, Cursor, Codex, Gemini CLI, and OpenCode**.

## Path & Runtime Configuration

Never hardcode personal user paths. All scripts resolve paths automatically via `scripts/_common.ps1` in this precedence order:

1. Explicit CLI flags: `-InboxDir`, `-OutDir`, `-TmpDir`, `-BrowserPath`, `-ConfigPath`
2. Environment variables: `MANGA_INBOX_DIR`, `MANGA_OUT_DIR`, `MANGA_TMP_DIR`, `MANGA_BROWSER_BIN`, `MANGA_GLOSSARY_DIR`, `MANGA_CONFIG_PATH`
3. Repo-local override: `<plugin_root>/config/config.local.json` (gitignored)
4. User-global shared config: `~/.manga-zh-localizer/config.json` (shared across all agents on the machine)
5. Portable defaults: `./inbox`, `./out`, `$env:TEMP\manga-zh-localizer`, auto-detected Edge/Chrome/Brave

Let `<SCRIPTS>` denote the `scripts` directory next to this `SKILL.md` file (`./scripts`). Always invoke scripts via:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" ...
```

Keep any temporary `.ps1` helpers pure ASCII, read/write JSON/HTML with explicit UTF-8, and ALWAYS pass multi-image lists to `-File` as a single pipe-delimited string `"<p0>|<p1>|..."` (never comma-separated or unjoined arrays).

---

## Core Principles (Read First!)

1. **Match Input Resolution**:
   - Process every input image at its exact native `W × H` resolution. Do not ask the user to re-download 4K originals when standard HD or `_master1200` files are provided. Only warn if an image was downscaled by a chat upload preview (`<= 1024px`).
2. **Concise Translation, Uniform Typography & Zero-Misalignment Rule (汉化组排版铁律)**:
   - **Keep Chinese concise**: Target **70%–85%** of the original Japanese kana/kanji character count. Never write wordy literal translations that force shrinking fonts.
   - **Natural Oral Chinese & Raw-Free Proofread**: Break Japanese SOV word order (avoid stiff "如果是你的话…" translationese), match character register without injecting unrelated dialect, verify unfamiliar foreign names via nationality + etymology + phonetics, and always perform a **raw-free Chinese read-through** to catch skipped half-lines (`漏译`), typos, and stiff phrasing before typesetting.
   - **Vertical Bubble Punctuation & Line-Break Craft (`可读性 > 理想留白 > 照抄原文`)**:
     - In regular vertical speech bubbles, **omit internal commas `，` and terminal periods `。`** — use semantic line breaks (or a space) instead. Always use standard `……` (never `......`), upright `—` (`U+FE31`), and `⁉`/`⁈`/`‼` or `.tcy`.
     - Break lines at semantic clause boundaries — **never split multi-character words** and **NEVER place `的` (or trailing particles `了`/`呢`/`吗`) at the top of a vertical column**.
     - Shape multi-column bubbles organically (olive/diamond silhouette matching the ellipse; avoid rigid equal-length blocks or jarring staircase notches), default `line_height` `1.20–1.33`, `letter_spacing` `0`, and maintain clean breathing room from bubble borders (never mask dirty cleans with overly thick white outlines).
   - **Uniform Base Font Size**: Pick ONE base font size for the page (`~2.35%–2.5%` of page width, e.g., `19px–20px` on an `800px`-wide page, `46px–50px` on `2000px`). Keep ALL regular speech bubbles within **`90%–115%` of base size**.
   - **Never crush text into tiny ant-fonts** to force-fit a bubble. If a line overflows at `>= 90%` base size, **tighten the Chinese wording or add a column break** instead of shrinking `font_size`.
   - **True Font Weights, Scene Consistency & Spike-Free Outlines**: Lock ONE font family per bubble role across the chapter — `dialogue` (`Microsoft YaHei` `700`, or `round` for soft/cute bubbles; never use `serif`/`handwritten` for standard casual dialogue), `serif` (`STZhongsong` `400` for narration/formal monologue), `handwritten` (`STKaiti` `400`), `round` (`YouYuan` `400` for gentle OS/chibi), `brush` (`STXingkai` `400` for calligraphy/dramatic lines), `scream` (`SimHei` `700`). NEVER pass faux-bold `700` to `400`-only fonts (`STZhongsong`/`STKaiti`/`YouYuan`/`STXingkai`). `render_typeset.ps1` defaults to **`2×` HiDPI supersampling** + **24-angle 0-blur circular outline**, and auto-formats upright `…` (`U+FE19`), `—` (`U+FE31`), `～` (`.vwave`), and sideways 2+ letter Latin runs (`.latin`).
   - **Strict Translation Coverage & SFX Triage**: ALWAYS fully clean & translate **props/objects** (signs, notes, labels), **photo/UI captions & stickers**, **reaction/emotion bubbles**, and **SFX on clean, flat-color, or 1D-gradient backgrounds**. Restrict *"留原字+旁注"* STRICTLY to pure atmospheric SFX (e.g., rain streaks, ambient rustle) overlapping intricate hair, screentones, or complex multi-color artwork where deterministic cleaning is impossible and AI inpainting is unavailable.
   - **Keep Recognized English/Latin Proper Nouns & Annotate Obscure Memes**: Retain well-known English/Latin stage names, band names, or loan-terms in original Latin letters rather than long clunky transliterations. When a punchline relies on an obscure foreign pun or cultural meme, verify it with your web-search tool (if available; cap to at most 1 parallel batch), keep in-bubble dialogue natural, and add a crisp, unobtrusive `※注：...` footnote in open margin space.
   - **Zero Text Misalignment (v4 Bubble-Cavity Optical Snapping)**: Always run `clean_bubbles.ps1 -BoxesOut boxes.json` (2-pass Chamfer Distance-Transform `optical_center`, completely immune to speech tails & spikes), set `"optical_center": true` on regular blocks so `render_typeset.ps1` detects the enclosed bubble cavity in `clean.png`, snaps ink center onto the exact cavity optical center (`cav=(x,y)`, collision-safe), and audits `WARN_BORDER_HITS` + `WARN_OFFCENTER` (drawn as magenta cavity diamonds on `audit.jpg`). Use `"snap_to_bubble": false` only on open unbordered bubbles, asymmetric narrow-scream bubbles, or manually centered multi-lobe snowman chambers.
   - **Zero Solid Color Blocks / Background Smears**:
     - NEVER stamp `solid_rect [255,255,255]` over speedlines, screentones, gradients, tilted gridlines, patterned textures, off-white/lavender backgrounds (`RGB 244–250`), curved hair/character silhouettes, or touching any speech-bubble outline.
     - For outside-bubble text next to a curved bubble or hair contour, use contour-hugging `poly_fill` with explicit `"rgb"` (never `"sample"`, which silently defaults to pure white). Never point a later op's `"sample"` at pixels already overwritten earlier in the same `clean_plan.json`.
     - For text over hand-drawn highlight ovals, erase the *entire* highlight cleanly and re-render a complete `halo`.
     - For `copy_col`/`copy_row`/`copy_along_dir`, verify the reference column/row/side contains zero hair, borders, or text tips along the full target span (split 1D-gradient `copy_col` into 2 clean bands if needed); prefer `solid_rect` + exact-endpoint `draw_lines` over `copy_along_dir` for thin straight gridlines on flat backgrounds; keep `dx = 0` (`offset: [0, dy]`) when `patch_copy` spans a vertical panel divider.
     - **NEVER use `translucent_anchored`/`translucent_halo` across sharp high-contrast B&W lineart + black-bg/garment/hair boundaries** (Laplace diffusion creates giant blurry grey smears -> triggers `[CleanAudit] WARN_HARMONIC_SMEAR`). For stroked text over intricate lineart + black background: if your agent has an AI image-editing tool/MCP, crop the raw panel without gridlines, invoke AI inpainting **sequentially** to remove ONLY text & outlines in crisp flat monochrome lineart, and composite strictly on removed text strokes via `roi_composite.ps1 -AutoTrimAiMargins` (`mode: "glyph_diff"`, `polarity: "both"`); if no AI image tool is available, use crisp `poly_fill` + `patch_copy` + `draw_lines` or ask the user to supply an inpainted panel crop.
     - NEVER bleach light-grey/tinted bubbles (`RGB <= 242`) with `white_bubble` — use `color_flood` (also ideal for closed flat-color props & reaction bubbles; when tinted bubbles contain **white-stroked text**, place `seed` in an open tinted margin with `tol: 70–85` above tint-to-white channel delta). Use `copy_along_dir` for speedlines/hatching, phase-aligned `patch_copy` for HD screentones, and `draw_lines` for micro border repairs.
   - **Ordered Multi-Page Delivery + Long Strip**: For any multi-page work (`>= 2` pages), always finish with `batch_job.ps1 -Mode package` (which calls `make_longstrip.ps1 -OrderedOutDir "<out>/<job>" -ShowPageNumbers`) so pages are grouped into a dedicated folder with 1-based zero-padded prefixes (`01_...`, `02_...`), strictly monotonic timestamps, and a vertical long stitched strip (`00_<job>_long_zh.png`).

For exact JSON formats, see [references/schemas.md](./references/schemas.md). For battle-tested edge cases, see [references/lessons.md](./references/lessons.md).

---

## Fast High-Cache 3-Turn Procedure (v4.4)

### Turn 1: One-Shot Parallel Scan + Auto-Bubble Summary + Single Preview Sheet
1. Run **one single command** (no throwaway `.ps1` helpers needed):
   ```powershell
   # Option A: Scan latest work in configured inbox_dir
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode scan -Latest

   # Option B: Scan explicit local image file(s) directly (works without configuring inbox_dir)
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode scan -Images "D:\manga\p0.png|D:\manga\p1.png" -Job my_manga
   ```
   (Use `-Pattern "<prefix>*"` to target specific inbox files, or pass `-InboxDir` / `-OutDir` / `-TmpDir` to override paths.) This scans all pages **in parallel** (`-FastPreview -PrintSummary`), prints every detected text bubble's exact `box`, Chamfer interior `seed`, `optical_center`, `ink` bbox, `bg_type`, and active glossary paths, saves `job_manifest.json`, and stitches `preview_sheet.jpg` (auto-split 4 pages/sheet for 5+ pages).
2. Inspect **`preview_sheet.jpg`** using your agent's image/vision reading tool (plus any relevant user glossary from `~/.manga-zh-localizer/glossaries/` or `./glossaries/`; cap web searches to at most **1 parallel batch** for genuinely unknown terms/memes), draft concise Chinese translations for ALL pages together, and perform a **raw-free Chinese read-through**.

### Turn 2: Parallel Clean + Cavity-Snapped Auto-Clearance Typeset + QA Sheets
1. Write `clean_plan.json` and `layout.json` for ALL pages in parallel into `<job_dir>\p0`, `p1`, ..., using the exact `box`/`seed`/`optical_center` printed in Turn 1:
   - Set `"optical_center": true` on regular blocks; set `"snap_to_bubble": false` only on open unbordered/radial bubbles, asymmetric narrow-scream bubbles, or stepped/multi-lobe chambers.
   - **Keep adjacent `layout.json` block `rect`s separated by `>= 12px`** so extraction padding never clips a neighboring block's edge characters into a shifted ghost.
   - If a panel has white-outlined text crossing sharp B&W lineart + black background, leave it out of `clean_plan.json`, clean its raw panel crop via sequential AI image-editing (if available), and composite onto `clean_final.png` using `roi_composite.ps1 -AutoTrimAiMargins` (`mode: "glyph_diff"`, `polarity: "both"`).
2. Run **one single parallel build command**:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode build -Job <job>
   ```
   This cleans + typesets ALL pages in parallel (with scaled auto-clearance & directional `WARN_BORDER_HITS=N[T/B/L/R]` + `WARN_RECT_OVERLAP` diagnostics), filters browser stderr noise, and emits `diff_sheet.jpg`, `qa_sheet.jpg`, and `audit_sheet.jpg`. For partial post-QA tweaks, re-run with `-Pages "p1"` (automatically skips unchanged `clean_final.png`).

### Turn 3: Contact-Sheet + Mandatory 1:1 Clean-Diff QA & Ordered Delivery
1. Inspect **`qa_sheet.jpg`** and **`diff_sheet.jpg`** (plus `audit_sheet.jpg` if any `[Audit]` warning appeared) using your agent's image-reading tool. **Mandatory gate**: whenever ANY page uses non-bubble, gradient, bubble-adjacent, or textured cleaning (`poly_fill`, `copy_col`/`copy_row`, `copy_along_dir`, `patch_copy`, `translucent_*`, or AI + `roi_composite`), inspect the **full-res `_zh.png`** (plus a **2× `orig | clean | zh` crop strip** for subtle seams/specks) after the final build — never sign off solely on exit code `0` or downscaled contact sheets.
2. Verify:
   - `0` `[CleanAudit]` warnings (`WARN_HARMONIC_SMEAR` / `WARN_GREY_BUBBLE_SEED` / `WARN_INTERP_DARK_EDGE`) and `0` `[Audit]` warnings (`WARN_BORDER_HITS` / `WARN_OFFCENTER` / `WARN_TIGHT_MARGIN` / `WARN_RECT_OVERLAP`)
   - Crisp, sharp fonts, spike-free circular outlines, uniform font sizes, upright vertical `…`/`—`/`～`, sideways `.latin` proper nouns, zero stray `，` / terminal `。` or column-top `的`
   - Zero leftover source strokes, zero solid color blocks, zero bloated white strokes hiding dirty cleans, zero background smears or artwork distortion
3. **Package & Deliver** in **one single command**:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode package -Job <job>
   ```
   (Automatically copies single-page outputs to `<out_dir>\<base>_zh.png`, or packages multi-page works via `make_longstrip.ps1` into `<out_dir>\<job>\01_..NN_` + `00_<job>_long_zh.png` with monotonic timestamps. **After ANY single-page post-QA tweak, ALWAYS re-run `-Mode package`** to keep timestamps and the long strip in sync.)
   - Deliver the output file paths and a concise translation table.
