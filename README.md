# manga-zh-localizer

> **面向日漫、韩漫、彩漫与带字插画的跨 Agent 零依赖无损中文汉化插件（Windows）**
>
> Zero-dependency, pixel-lossless Chinese manga & illustration localization plugin for **DeepSeek Harness (DSH), Antigravity, Claude Code, Cursor, Codex, Gemini CLI, and OpenCode** on Windows.

---

## 核心特性 (Features)

- **Windows 原生零额外依赖**：仅需系统自带 PowerShell 5.1+、`.NET System.Drawing`（内联 C# `LockBits` 内存缓冲）与 Microsoft Edge / Chrome / Brave 无头渲染，**无需 Python、CUDA 或 Photoshop**。
- **100% 原分辨率无损保真**：
  - 常规气泡（纯白/纯黑/灰底回忆/彩色气泡）、半透明气泡、速度线压字、HD 网点纸（相位对齐 `patch_copy`）、渐变/横竖结构线与微小边框修补全部由 C# `LockBits` 毫秒级确定性处理，非文字区域像素差异 = `0`。
  - 极端复杂彩绘/发丝压字支持外部 AI 修图后，通过 `roi_composite.ps1` 仅对文字笔画差异掩膜（`glyph_diff`）羽化贴回原图。
- **专业汉化组级矢量排版引擎**：
  - 基于无头 Chromium `writing-mode: vertical-rl` + **2× HiDPI 超采样** + **24 向 0 模糊无尖刺圆形描边**，渲染真实系统字重（禁止伪粗体）。
  - 自动处理竖排标点（`「」『』……—～`）、纵中横（`⁉`、`‼`、`！？`）与 2+ 字母拉丁专有名词侧转（`.latin`）。
  - 内置 **2-pass Chamfer 3-4 距离变换气泡腔体光学居中**（彻底免疫对话框尖尾干扰）+ 碰边/越界/重叠自动审计（`[CleanAudit]` / `[Audit]`）。
- **多 Agent 一次配置、处处通用**：
  - 遵循开放标准 **Agent Skills (`SKILL.md`)** 与 **Agent Plugins (`plugin.json`)**，同一仓库原生包含 Antigravity、Claude Code、Cursor、Codex、Gemini CLI、OpenCode 清单、斜杠命令与规则。
  - 所有个人目录（收件箱、输出库、临时目录、个人作品术语表）集中在用户目录 `~/.manga-zh-localizer/` 下，**跨所有 Agent 共享，且永不污染 Git 仓库**。

---

## 多 Agent 兼容矩阵 (Supported Agents)

| Agent / CLI | 原生支持文件 | 安装方式 | 斜杠命令 / 触发 |
| :--- | :--- | :--- | :--- |
| **DeepSeek Harness (DSH)** | `package.json` + `cordis.patch.yml` + `dsh/index.js` + `skills/` | **原生插件**：`dsh plugin --profile desktop add github:tomotinlove/manga-zh-localizer`（自动注册技能 + `manga_*` 工具）<br>**纯 Skill**：`.\scripts\install.ps1 -Targets dsh` | 原生工具 `manga_doctor` / `manga_scan` / `manga_build` / `manga_package` + 自动激活 `SKILL.md` |
| **Antigravity** | `plugin.json` + `rules/AGENTS.md` + `skills/` | `.\scripts\install.ps1 -Targets antigravity` | 自然语言 / 快捷提示词 |
| **Claude Code** | `.claude-plugin/plugin.json` + `marketplace.json` + `commands/` + `skills/` | `/plugin marketplace add tomotinlove/manga-zh-localizer` 后 `/plugin install manga-zh-localizer` 或 `.\scripts\install.ps1 -Targets claude` | `/manga-localize` `/manga-scan` `/manga-build` `/manga-package` `/manga-doctor` |
| **Cursor** | `.cursor-plugin/plugin.json` + `.cursor/rules/*.mdc` + `commands/` + `skills/` | Cursor 插件安装或 `.\scripts\install.ps1 -Targets cursor` | `/manga-localize` 等 + 自动规则 |
| **Gemini CLI** | `gemini-extension.json` + `GEMINI.md` + `commands/manga/*.toml` + `skills/` | `gemini extensions install https://github.com/tomotinlove/manga-zh-localizer` 或 `.\scripts\install.ps1 -Targets gemini-cli` | `/manga:localize` `/manga:scan` `/manga:build` `/manga:package` `/manga:doctor` |
| **Codex / OpenCode** | `AGENTS.md` + `skills/manga-zh-localizer/SKILL.md` | `.\scripts\install.ps1 -Targets codex,opencode` | 自动按 `SKILL.md` 激活 |
| **通用 Agent Skills (`npx skills`)** | `skills/manga-zh-localizer/SKILL.md` | `npx skills add tomotinlove/manga-zh-localizer` 或 `.\scripts\install.ps1 -Targets agents` | 自动按 `SKILL.md` 激活 |

---

## 快速开始 (Quick Start)

### 1. 克隆仓库并运行一键安装

```powershell
git clone https://github.com/tomotinlove/manga-zh-localizer.git
cd manga-zh-localizer

# 自动检测本机已安装的 Agent 并安装，同时初始化共享配置（推荐指定自定义路径）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install.ps1" `
  -Targets auto `
  -InboxDir "D:\Manga\inbox" `
  -OutDir "D:\Manga\out" `
  -TmpDir "D:\Manga_tmp"
```

> **开发/联动模式**：加 `-Mode link` 会使用 NTFS 目录联接（Junction），在仓库 `git pull` 更新后所有 Agent 立即生效。先预览不写入可加 `-DryRun`。

### 2. 运行环境自检 (`doctor`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\doctor.ps1"
```

检查项包括 PowerShell、`.NET System.Drawing`、无头 Edge/Chrome/Brave、常用中文排版字体、目录配置及已加载术语表。

### 3. 在任意 Agent 中开干

- **方式 A（收件箱模式）**：把漫画原图丢进你配置的 `inbox_dir`，在对话中直接说「帮我汉化最新漫画」或输入 `/manga-localize`（Gemini CLI 为 `/manga:localize`）。
- **方式 B（直接传路径，免建收件箱）**：直接告诉 Agent 图片路径，例如「帮我无损汉化 `D:\comics\p0.png` 和 `D:\comics\p1.png`」。
- **方式 C（命令行快捷入口）**：安装器会自动在 `~/.manga-zh-localizer/bin/manga-zh.cmd` 生成快捷命令：
  ```cmd
  manga-zh doctor
  manga-zh scan -Latest
  manga-zh build -Job my_comic
  manga-zh package -Job my_comic
  ```

---

## 路径与配置优先级 (Configuration)

所有脚本通过 `skills/manga-zh-localizer/scripts/_common.ps1` 按以下优先级解析路径（高优先级覆盖低优先级）：

1. **命令行参数**：`-InboxDir`、`-OutDir`、`-TmpDir`、`-BrowserPath`、`-ConfigPath`
2. **环境变量**：`MANGA_INBOX_DIR`、`MANGA_OUT_DIR`、`MANGA_TMP_DIR`、`MANGA_BROWSER_BIN`、`MANGA_GLOSSARY_DIR`、`MANGA_CONFIG_PATH`
3. **仓库本地覆盖**：`config/config.local.json`（已被 `.gitignore` 忽略）
4. **跨 Agent 共享用户配置**：`~/.manga-zh-localizer/config.json`
5. **便携默认值**：`./inbox`、`./out`、`%TEMP%\manga-zh-localizer`、自动搜索 Edge / Chrome / Brave

示例 `~/.manga-zh-localizer/config.json`（见 [config/config.example.json](./config/config.example.json)）：

```json
{
  "inbox_dir": "D:\\Manga\\inbox",
  "out_dir": "D:\\Manga\\out",
  "tmp_dir": "D:\\Manga_tmp",
  "browser_bin": "",
  "max_parallel": 4,
  "super_sample": 2,
  "col_width": 950,
  "glossary_dirs": []
}
```

---

## 术语表管理 (Glossaries)

仓库本身仅包含空白模板 [skills/manga-zh-localizer/glossaries/_template.json](./skills/manga-zh-localizer/glossaries/_template.json)，不包含任何个人作品数据。

将你自己的作品术语表 `.json` 放入 `~/.manga-zh-localizer/glossaries/`（例如 `my-series.json`），所有已安装的 Agent 在 `scan` 阶段都会自动发现并保持角色译名、称呼与口癖跨页统一。

---

## 项目结构 (Repository Layout)

```text
manga-zh-localizer/
├── package.json / cordis.patch.yml    # DeepSeek Harness (DSH) 原生 Cordis 插件清单
├── dsh/index.js                       # DSH 零依赖入口（注册 Skill Provider + manga_* 工具）
├── plugin.json                        # Antigravity & Agent Plugins 1.0 根清单
├── gemini-extension.json              # Gemini CLI 原生扩展清单
├── GEMINI.md / AGENTS.md / CLAUDE.md  # 各平台上下文入口
├── .claude-plugin/
│   ├── plugin.json                    # Claude Code 原生插件清单
│   └── marketplace.json               # Claude Code 市场目录清单
├── .cursor-plugin/
│   └── plugin.json                    # Cursor 原生插件清单
├── .cursor/rules/
│   └── manga-zh-localizer.mdc         # Cursor 自动按需规则
├── rules/AGENTS.md                    # Antigravity 常驻规则
├── commands/
│   ├── manga-*.md                     # Claude Code & Cursor 斜杠命令
│   └── manga/*.toml                   # Gemini CLI 斜杠命令 (/manga:*)
├── config/
│   ├── config.example.json            # 路径配置模板
│   └── gallery-dl.example.json        # 可选 Pixiv 下载配置模板
├── scripts/
│   ├── install.ps1                    # 多 Agent 一键安装/卸载与配置脚本
│   ├── doctor.ps1                     # 环境与字体自检入口
│   └── smoke_test.ps1                 # 全链路无损端到端回归测试
└── skills/manga-zh-localizer/         # 开放标准 Agent Skill（可独立分发）
    ├── SKILL.md
    ├── glossaries/_template.json
    ├── references/
    │   ├── schemas.md                 # clean_plan / layout / rois JSON 规范
    │   └── lessons.md                 # 实战排坑与汉化组排版工艺手册
    └── scripts/
        ├── _common.ps1                # 分层配置与浏览器解析器
        ├── batch_job.ps1              # 并行调度总入口 (scan/build/package/doctor)
        ├── doctor.ps1                 # 环境自检实现
        ├── grid_inspect.ps1           # LockBits 网格与自动气泡检测
        ├── clean_bubbles.ps1          # 15+ 种无损去字与 Chamfer DT 审计
        ├── render_typeset.ps1         # 2× 超采样竖横排引擎与光学居中审计
        ├── roi_composite.ps1          # 可选 AI 修图 ROI 笔画掩膜无损贴回
        ├── make_sheet.ps1             # 高缓存接触表拼接
        ├── make_longstrip.ps1         # 有序多页导出与竖向长图拼接
        └── fetch_pixiv.ps1            # 可选 gallery-dl 下载辅助脚本
```

---

## 端到端自动化验证 (Smoke Test)

修改任何脚本后，运行自带的合成漫画端到端测试（自动验证 `doctor` → `scan` → `build` → **非文字区 0 像素差异** + **灰气泡保色** + **0 审计告警** → `package` 有序输出与长图拼接）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\smoke_test.ps1"
```

---

## License

[MIT](./LICENSE)
