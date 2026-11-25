---
description: Check PowerShell, .NET GDI+, headless Edge/Chrome, CJK fonts, configured directories, and active glossaries.
---

Run the `manga-zh-localizer` environment self-check (`doctor`).

1. Resolve `<SCRIPTS>` as `${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts` (fallback `./skills/manga-zh-localizer/scripts`).
2. Invoke:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode doctor
   ```
3. Summarize readiness and suggest fixes if any browser, font, or directory check reports a warning or failure.
