---
description: End-to-end 3-turn lossless Chinese localization for manga pages or illustrations (scan -> clean & typeset -> QA & package).
argument-hint: "[image path(s), glob pattern, or empty for latest in inbox]"
---

Run the full **manga-zh-localizer** 3-turn lossless localization workflow.

User arguments: `$ARGUMENTS`

1. Follow the instructions in `skills/manga-zh-localizer/SKILL.md` (inside `${CLAUDE_PLUGIN_ROOT}` if installed as a Claude Code plugin, or the plugin/workspace root).
2. Resolve the script directory `<SCRIPTS>` as `${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts` (falling back to `./skills/manga-zh-localizer/scripts`).
3. **Turn 1 (Scan & Translate)**:
   - If `$ARGUMENTS` specifies image path(s), run `batch_job.ps1 -Mode scan -Images "<p0>|<p1>|..."`.
   - If `$ARGUMENTS` is a filename pattern, run `batch_job.ps1 -Mode scan -Pattern "$ARGUMENTS"`.
   - If `$ARGUMENTS` is empty, run `batch_job.ps1 -Mode scan -Latest`.
   - Inspect `preview_sheet.jpg` with your vision tool, load any matching glossary from `~/.manga-zh-localizer/glossaries/`, draft concise natural oral Chinese (70%–85% of JP char count, no internal `，` or terminal `。` in regular vertical bubbles, no leading `的`), and run a raw-free read-through.
4. **Turn 2 (Clean & Typeset)**:
   - Write `clean_plan.json` and `layout.json` for every page into `<job_dir>\p0`, `p1`, ... using the exact auto-detected coordinates (`optical_center: true` on regular bubbles, adjacent block `rect`s separated by `>= 12px`).
   - Run `batch_job.ps1 -Mode build -Job <job>`.
5. **Turn 3 (QA & Package)**:
   - Inspect `qa_sheet.jpg`, `diff_sheet.jpg`, and (if any warning appeared) `audit_sheet.jpg`. For any non-bubble, gradient, bubble-adjacent, or textured clean, inspect the full-res `_zh.png` (and 2× `orig | clean | zh` crop if needed) to guarantee zero color blocks, smears, or border collisions.
   - Run `batch_job.ps1 -Mode package -Job <job>` (and always re-run `-Mode package` after any partial page tweak).
   - Deliver the output paths and a concise translation table.
