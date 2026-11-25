# Field-Tested Pitfalls & Solutions (`manga-zh-localizer`)

Distilled from multi-page production localization runs:

## 1. Cleaning Pitfalls (`clean_bubbles.ps1`)
- **Double-bordered / intercom bubbles (e.g., concentric octagon frames)**:
  - `bubbles_auto.json` may pick a seed near the outer edge (`y0 + 6..14`), landing in the narrow white gap *between* outer and inner borders so flood-fill never enters the text interior.
  - **Fix**: Place `seed` well inside the inner border (offset away from center glyphs) and verify `boxes.json` `bubble_bbox` matches the full bubble size.
- **Flat light-grey panel backgrounds behind thick SFX**:
  - `translucent_dark` can leave soft dark halos around very thick SFX brush strokes on flat grey fills.
  - **Fix**: Sample the exact panel grey RGB and fill tightly with `solid_rect` (avoiding adjacent panel/bubble borders).
- **`interp_v` / `interp_h` bleeding black lines or character art**:
  - Never let an `interp_v` box's top/bottom edge (`y0`/`y1`) touch a black panel/bubble border, hair, clothing, or prop outline — it drags dark pillars or smears figures vertically. `clean_bubbles.ps1` emits `WARN_INTERP_DARK_EDGE` if >= 6% of boundary pixels are dark. Prefer flat sampled `solid_rect` strictly inside flat bars, `copy_col`/`copy_row` for 1D structures, or `copy_along_dir` for slanted/horizontal lines.
- **SFX over speedlines, hatching, or patterned backgrounds (NEVER stamp `solid_rect`!)**:
  - Stamping `solid_rect [255,255,255]` over speedlines or patterned upholstery punches glaring white blocks and erases lineart.
  - **Fix**: Use `copy_along_dir` with the exact measured speedline vector `dir: [dx, dy]` and clean anchor `"side": "pos" | "neg" | "both"` to restore uninterrupted speedlines; for SFX crossing a single bubble outline, erase strictly the glyph polygon and seal the 10–20px gap with `draw_lines` (`smooth: true`).
- **Grey flashback bubbles (`RGB ~230`) bleached white by `white_bubble`**:
  - `white_bubble` with `thresh: 215` matches `RGB(230,230,230)` and bleaches shaded flashback bubbles to pure white. `clean_bubbles.ps1` emits `WARN_GREY_BUBBLE_SEED` when seed luminance <= 242 — always use `color_flood` to preserve original bubble tint.
- **Two-tone backgrounds (e.g., grey panel bg meeting pure-white motion glow)**:
  - Never paint a single flat grey rectangle across a grey-to-white glow boundary; split into two tight polygons following the glow curve (`[230,230,230]` on grey side, `[255,255,255]` on white side).
- **Speech tails skewing bubble centering**:
  - Row-span medians get dragged toward protruding horizontal speech tails, shifting text 15–60px off-center. Both `clean_bubbles.ps1` and `render_typeset.ps1` use a **2-pass Chamfer 3-4 Distance Transform** (`dist >= 0.72 * maxD` weighted centroid), which ignores tails/spikes and auto-snaps enclosed single-cavity bubbles dead-center (collision-safe) while marking cavity centers as magenta diamonds on `audit.jpg`.
- **Open / edge-cropped bubbles**:
  - Always set `"open_side": "left" | "right" | "top" | "bottom"` when a bubble is clipped by a panel/page edge, and verify clean sheets before typesetting.
- **Stepped / merged multi-part ("snowman") bubbles**:
  - Clean in one pass (`white_bubble`), but **always split into separate `layout.json` blocks** centered on each sub-chamber with `"snap_to_bubble": false` so text never drifts across the pinched waist.
- **Bubble-cavity auto-snap over-snapping exceptions (`snap_to_bubble: false`)**:
  - Auto-snapping enclosed cavities works on 90%+ of regular speech bubbles, EXCEPT three geometries: (1) unclosed radial/spiky bubbles where BFS escapes and encloses against an outer panel wall, (2) narrow vertical scream bubbles with an asymmetric bulge at one end, and (3) multi-lobe ("snowman") bubbles cleaned in one pass. Check magenta cavity diamonds on `audit.jpg` and set `"snap_to_bubble": false` on those blocks.
- **1:1 `orig/clean` & `-DiffOut` verification for non-bubble SFX & tight polygons**:
  - Downscaled `ColWidth 950` contact sheets easily hide 3–8px leftover kana specks along hair/borders and subtle `RGB(230) -> RGB(255)` grey-bubble bleaching. Whenever a page uses `poly_fill`, `copy_along_dir`, `interp_*`, `draw_lines`, or grey `color_flood`, pass `-DiffOut <diff.jpg>` (magenta = major edit, cyan = subtle tonal shift) and inspect 1:1 `orig | clean` crops before delivering.
- **`translucent_anchored` / `translucent_halo` creating giant blurry grey smears on high-contrast B&W lineart**:
  - Laplace harmonic diffusion averages boundary colors across the mask; when a text+white-halo block crosses a sharp boundary between pure black `#000000` background and grey clothing/hair/white lineart, it creates a soft rectangular grey smudge. `clean_bubbles.ps1` emits `WARN_HARMONIC_SMEAR` whenever a harmonic mask spans a high-contrast boundary (`lumSpan >= 150`) over a large region.
  - **Fix**: Never use `translucent_anchored`/`translucent_halo` on stroked text crossing black-bg + character lineart. Crop the panel, clean via AI inpainting (sequentially if multiple panels to avoid rate-limit bursts), trim any aspect-ratio white letterbox margins, and composite strictly on removed dark+white glyphs using `roi_composite.ps1 -AutoTrimAiMargins` (`mode: "glyph_diff"`, `polarity: "both"`).
- **Adjacent `layout.json` blocks in stepped boxes overlapping extraction padding**:
  - `render_typeset.ps1` extracts each block from the rendered text layer using `rect` padded by ~16px; if two adjacent blocks' `rect`s overlap horizontally and vertically (e.g., a stepped L-shaped narration box), the second block's extraction box can slice an edge character from the first block and stamp a shifted ghost fragment. Always keep adjacent `rect`s separated by at least 12–15px.
- **Outside-bubble `solid_rect` notching adjacent bubbles or chopping highlight ovals**:
  - Stamping a rectangular `solid_rect` on small handwritten text hugging a colored speech bubble clips a glaring square notch into the bubble rim; stamping a tight `solid_rect` over a hand-drawn highlight oval punches a white hole and leaves broken slivers on both edges.
  - **Fix**: Use a contour-hugging `poly_fill` staying strictly outside the bubble curve, and erase the *entire* hand-drawn highlight oval cleanly before re-rendering a complete `halo` behind the Chinese text.
- **Closed flat-color props & reaction bubbles**:
  - Using `copy_along_dir` (`side: "both"`) across a closed dark-outlined prop can hit an adjacent panel divider and drag dark streaks back across the prop.
  - **Fix**: Use `color_flood` from a clean interior seed inside the dark outline to erase the source strokes cleanly in one pass with zero divider bleed.
- **`copy_col` / `copy_along_dir` anchor verification & full-res QA**:
  - Before running `copy_col` or `copy_along_dir`, verify the sampled `src_x`/`src_y` or `side` (`pos` vs `neg`) contains zero hair strands, panel dividers, or text tips along the entire `[y0..y1]`/`[x0..x1]` span; never rely solely on downscaled contact sheets to clear potential color blocks or bubble notches — always inspect 1:1 crops or full-res `_zh.png` before packaging.
- **White-stroked text inside tinted bubbles (`color_flood` seed & `tol` trap)**:
  - On pink/blue bubbles (`RGB ~251,197,208`) with white-outlined text, placing `seed` near the text hits the white stroke (leaving white ghost text), and default `tol: 32–48` cannot cross tint-to-white (`Delta=58`).
  - **Fix**: Place `seed` in an open tinted margin well away from text and raise `tol` to `70–85` (`> max(255 - bgRGB)`, still far below dark outlines) so both black ink and white outline erase cleanly in one pass.
- **`poly_fill` `"sample"` silent-white trap & sequential-op `"sample"` overwrite**:
  - `poly_fill` only accepts explicit `"rgb": [r,g,b]` — passing `"sample"` silently defaults to pure white `[255,255,255]`. Likewise, a `solid_rect` `"sample"` point placed inside a region already painted by an earlier op in the same `clean_plan.json` samples the *new* color instead of the original artwork.
  - **Fix**: Always specify explicit `"rgb"` on `poly_fill`, and either run `"sample"` ops before overwriting ops or use `copy_col`/`copy_row` from untouched adjacent columns/rows.
- **Gradient `copy_col` band-splitting, off-white backgrounds & flat-bg tilted gridlines**:
  - A single `copy_col` column over a 1D gradient can graze hair/borders at one end and drag a horizontal seam across the panel; stamping `[255,255,255]` on pale-lavender/off-white backgrounds (`RGB 244–250`) leaves a glaring white box; `copy_along_dir` with an approximate angle smears thin straight gridlines on flat-color surfaces.
  - **Fix**: Numerically check `src_x` RGB across `[y0..y1]` and split into 2 clean `copy_col` bands if needed; use `copy_col`/`copy_row` on off-white/tinted backgrounds; use `solid_rect` + exact-endpoint `draw_lines` for thin straight gridlines on flat backgrounds.
- **Curved hair silhouettes & `patch_copy` across vertical panel dividers**:
  - Never expand a rectangular `solid_rect` over curved hair/character silhouettes (use contour-hugging `poly_fill`). When `patch_copy` covers text overlapping a vertical panel divider, keep `dx = 0` (`offset: [0, dy]`) so the divider stays pixel-aligned, and always verify the final build at full-res / 2× zoom.

## 2. Ultra-Large Spreads, Thick Outlines & Deterministic Fallback
- **Pages > 4000px wide or stroke radius > 25px**:
  - Headless Chromium `2xSS` can approach GPU/texture limits, and CSS `text-shadow` rings can show gaps on massive (`>40px`) outlines.
  - **Fix**: Render giant outline titles directly via C# GDI+ `GraphicsPath` (`Pen` with `LineJoin.Round`, `StartCap`/`EndCap = Round` + `FillPath`) at native resolution — zero gaps, ultra-crisp, <1.5s.
- **When AI image inpainting is unavailable or rate-limited on B&W manga**:
  - Pure-white tabletops, straight structural edges, and vertical/sloped monochrome screentones can be reconstructed natively in C# `LockBits`: clear pure-white zones, extend suit/screentone textures along each segment's slope using a tight tiling period (`12..16px`) so horizontal accents do not repeat into stair-step artifacts, and redraw crisp anti-aliased straight structural lines.

## 3. Vertical Punctuation, Parallel Speed & PowerShell Execution
- **Vertical em-dash `—` (`U+2014`) & wave dash `～`/`〜` (`U+FF5E`/`U+301C`)**:
  - Handled automatically in `render_typeset.ps1`: `U+2014` maps to upright `U+FE31` (`.vdash`), and `～`/`〜`/`~` map to `.vwave` with `"Microsoft YaHei", "SimSun", sans-serif` fallback so `YouYuan` / `STKaiti` never drop vertical `～` glyphs.
- **Zero-guess collision avoidance & directional `WARN_BORDER_HITS`**:
  - `MangaTypesetAuditorV5` scales auto-clearance search radius up to `1.15 * font_size` to dodge adjacent starburst rays/borders automatically, and reports exact collision sides (`WARN_BORDER_HITS=N[T:..,B:..,L:..,R:..]`) if any hits remain.
- **Parallel lock-free headless rendering & `batch_job.ps1`**:
  - `render_typeset.ps1` isolates `--user-data-dir` and `HtmlOut` per invocation so `batch_job.ps1` (`-Mode scan` / `-Mode build` / `-Mode package`) safely runs up to 4 pages concurrently, skipping unchanged `clean_final.png` during partial `-Pages` re-renders.
- **PowerShell 5.1 quoting & `-File` array parameter pitfall**:
  - Never pass multi-line scripts or `$var` loops inside double-quoted `-Command "..."` (variables expand prematurely). Write pure ASCII `.ps1` helpers under `<job_dir>` and run with `-File`.
  - Passing an array variable or comma-separated paths to `-Images` via `powershell -File` (`make_sheet.ps1` / `make_longstrip.ps1`) binds trailing items to positional integer parameters and fails. Always pass a single pipe-delimited string (`-Images "<p0>|<p1>|..."`) via `-File`.
- **Batch Contact Sheets**:
  - `make_sheet.ps1` tiles horizontally in one row; for 5+ pages, `batch_job.ps1` automatically splits into 4 pages per sheet so small kana/kanji stay sharp while keeping vision turns minimal.
- **Cultural memes, English/Latin names & footnotes**:
  - Retain recognized English/Latin stage names and band names in original Latin script; `render_typeset.ps1` auto-wraps 2+ letter Latin runs in `.latin` (`text-orientation: sideways`) inside `vertical-rl`.
  - Verify obscure Japanese comedy/game references via web search before translating, keep dialogue natural in Chinese, and place concise `※注：...` footnotes in open margin space when non-Japanese readers would otherwise miss the joke.
- **Ordered multi-page export & vertical long stitched strip (`make_longstrip.ps1`)**:
  - Dumping flat `_p0_zh.png` files into an output folder and re-rendering a subset of pages scrambles `LastWriteTime` (breaking gallery/cloud-drive order).
  - Always package multi-page jobs via `batch_job.ps1 -Mode package` (which invokes `make_longstrip.ps1 -OrderedOutDir "<out>/<job>" -ShowPageNumbers`) to emit 1-based zero-padded files (`01_...`, `02_...`) with strictly monotonic timestamps plus a vertical long stitched strip (`00_<job>_long_zh.png`, auto-split if height > `MaxHeight`).
  - **Post-tweak sync rule**: ALWAYS re-run `batch_job.ps1 -Mode package` as the final step after ANY partial edit so timestamps and the long strip stay synchronized.

## 4. Veteran Scanlation Craft Rules (Line-Breaking, Screentones, SFX & Proofreading)
- **Vertical bubble punctuation & line-break craft (`可读性 > 理想留白 > 照抄原文`)**:
  - **Omit internal commas `，` and terminal periods `。`** inside regular vertical speech bubbles — replace pauses with semantic line breaks or a space. Always use standard `……` (never `......`).
  - **Never put `的` (or trailing particles `了`/`呢`/`吗`) at the top of a vertical column**, never split multi-character words, and shape lines organically to the bubble's oval curve rather than rigid equal-length boxes or jarring staircase notches.
  - Default `line_height` `1.20–1.33`, `letter_spacing` `0`, lock ONE font family per bubble role across the whole chapter, and never hide sloppy cleaning underneath overly thick white strokes.
- **HD screentone & complex background cleaning**:
  - Never blur or smudge HD uniform screentones (creates instant moiré/mush). Use `patch_copy` (`auto_align: true`) to phase-lock an adjacent clean screentone patch onto the exact dot grid; for linear gradient tones, shift strictly *perpendicular* to the gradient direction.
  - Preserve structural continuity (rails, dividers, hair/collar contours); treat AI inpainting cautiously on high-detail color/textured art where hallucinations or softness breaks can appear.
- **SFX triage & styling order**:
  - For pure atmospheric SFX over complex hair/screentones/color art, **preserve original brushwork + add a small margin annotation** (`*咔哒`); fully erase & redraw plot/pun/dialogue-critical or clean-bg SFX.
  - For warped/perspective SFX, transform/warp BEFORE applying stroke (stroking first causes jagged spikes); for color-page glow text, use a blurred copy underneath rather than flat opaque halos.
- **Anti-translationese, name verification & raw-free proofreading**:
  - Break Japanese SOV word order into concise natural spoken Chinese, keep character register consistent without injecting unrelated regional dialect, cross-verify unfamiliar foreign names via **heritage + in-story etymology + source phonetics**, and always perform a **raw-free Chinese read-through** before typesetting to catch omissions (`漏译`), typos, and stiff pacing.
