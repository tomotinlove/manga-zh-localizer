# GEMINI.md — `manga-zh-localizer` Extension Context

When the user asks to translate, clean, typeset, or localize manga pages or text-bearing illustrations into Chinese:

1. Activate and follow the bundled skill `skills/manga-zh-localizer/SKILL.md` and the concise constraints in `rules/AGENTS.md`.
2. Use the bundled slash commands (`/manga:localize`, `/manga:scan`, `/manga:build`, `/manga:package`, `/manga:doctor`) or invoke `skills/manga-zh-localizer/scripts/batch_job.ps1` directly via `powershell -NoProfile -ExecutionPolicy Bypass -File ...`.
3. Never hardcode personal paths; rely on `_common.ps1` (`CLI flags` > `MANGA_*` env vars > `~/.manga-zh-localizer/config.json` > portable defaults).
4. Enforce all zero-defect QA gates (`0` `[CleanAudit]` / `[Audit]` warnings, full-res inspection for non-bubble/textured cleans, and re-running `-Mode package` after any partial edit).
