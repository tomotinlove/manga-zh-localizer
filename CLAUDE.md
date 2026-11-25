# CLAUDE.md

See [AGENTS.md](./AGENTS.md), [rules/AGENTS.md](./rules/AGENTS.md), and [skills/manga-zh-localizer/SKILL.md](./skills/manga-zh-localizer/SKILL.md) for the complete `manga-zh-localizer` localization workflow, zero-defect cleaning/typesetting constraints, and PowerShell CLI reference.

- Available slash commands: `/manga-localize`, `/manga-scan`, `/manga-build`, `/manga-package`, `/manga-doctor`.
- Verify changes with `powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\smoke_test.ps1"`.
