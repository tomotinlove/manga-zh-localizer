---
description: Turn 3 — Export final lossless PNGs into ordered folder + vertical long stitched strip with monotonic timestamps.
argument-hint: "<job_name> [optional: -OutDir <path>]"
---

Run Turn 3 (`package`) of `manga-zh-localizer` to publish verified pages to the configured output directory.

User arguments: `$ARGUMENTS`

1. Resolve `<SCRIPTS>` as `${CLAUDE_PLUGIN_ROOT}\skills\manga-zh-localizer\scripts` (fallback `./skills/manga-zh-localizer/scripts`).
2. Invoke:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SCRIPTS>\batch_job.ps1" -Mode package -Job <job> [optional -OutDir]
   ```
3. Report the packaged single-page PNG or multi-page ordered folder (`01_...`..`NN_` + `00_<job>_long_zh.png`).
