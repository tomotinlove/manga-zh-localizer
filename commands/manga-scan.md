---
description: Turn 1 — Parallel scan of manga pages, auto-bubble coordinate detection, and preview contact sheet generation.
argument-hint: "[--latest | pattern | path1|path2]"
---

Run Turn 1 (`scan`) of `manga-zh-localizer`.

User arguments: `$ARGUMENTS`

1. Resolve `<SCRIPTS>` as `${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts` (fallback `./skills/manga-zh-localizer/scripts`).
2. Invoke:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode scan <flags from $ARGUMENTS or -Latest>
   ```
   (Pass multiple paths as a single pipe-delimited string `-Images "<p0>|<p1>"`.)
3. Read the generated `preview_sheet.jpg` using your image-reading tool, check any active glossaries printed in stdout, and present the bubble inventory + concise draft Chinese translations for confirmation or immediate build.
