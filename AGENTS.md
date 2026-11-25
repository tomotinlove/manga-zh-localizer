# manga-zh-localizer — Agent Instructions

This repository packages **manga-zh-localizer (v4.4)**, a zero-dependency lossless Chinese manga & illustration localization plugin for Windows (PowerShell 5.1 + C# `LockBits` + 2× HiDPI headless Edge/Chrome) compatible with DeepSeek Harness (DSH), Antigravity, Claude Code, Cursor, Codex, Gemini CLI, and OpenCode.

## Using This Plugin

- **Core Skill**: Follow [skills/manga-zh-localizer/SKILL.md](./skills/manga-zh-localizer/SKILL.md) for the complete 3-turn high-cache workflow (`scan` -> `build` -> `package`).
- **Always-On Craft Constraints**: Follow [rules/AGENTS.md](./rules/AGENTS.md) for cleaning guards, typography, vertical punctuation, and mandatory QA gates.
- **Configuration**: Never hardcode personal paths. All scripts load settings via `skills/manga-zh-localizer/scripts/_common.ps1` (`CLI flags` > `MANGA_*` env vars > `config/config.local.json` > `~/.manga-zh-localizer/config.json` > portable defaults).
- **Environment Check**: Run `powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\doctor.ps1"`.
- **Automated Smoke Test**: Run `powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\smoke_test.ps1"` after modifying any script.

## Repository Conventions

- Keep all `.ps1` files **pure ASCII** (PowerShell 5.1 compatibility) and use explicit UTF-8 (`[System.Text.Encoding]::UTF8`) when reading/writing JSON or HTML.
- Keep all personal paths, credentials, and personal series glossaries outside Git (`~/.manga-zh-localizer/` or `config/*.local.json`).
