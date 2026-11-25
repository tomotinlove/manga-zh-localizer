---
description: Turn 2 — Parallel lossless cleaning, 2x supersampled Chinese typesetting, optical cavity centering, and QA sheet build.
argument-hint: "<job_name> [optional: -Pages p1 -CleanOnly -ForceClean]"
---

Run Turn 2 (`build`) of `manga-zh-localizer` for an existing scanned job.

User arguments: `$ARGUMENTS`

1. Resolve `<SCRIPTS>` as `${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts` (fallback `./skills/manga-zh-localizer/scripts`).
2. Ensure `clean_plan.json` and `layout.json` exist in `<job_dir>\p0`, `p1`, ... and adhere to `skills/manga-zh-localizer/SKILL.md`.
3. Invoke:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode build -Job <job> [optional flags]
   ```
4. Inspect `qa_sheet.jpg`, `diff_sheet.jpg`, and any `[CleanAudit]` / `[Audit]` warnings; inspect full-res `_zh.png` for any non-bubble/textured cleans before packaging.
