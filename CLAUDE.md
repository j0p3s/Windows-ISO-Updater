# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Windows ISO Updater: one self-elevating `.cmd` file (batch launcher + embedded PowerShell/WPF GUI) that unpacks a Windows 10/11 ISO, downloads and slipstreams updates and drivers, re-signs modded drivers, and rebuilds a bootable ISO. The released `Windows-ISO-updater-GUI_vX.Y.Z.cmd` in the repo root is **generated** — never edit it; edit `src/` and rebuild.

## Commands

```bash
python3 src/build.py                          # assemble the .cmd from src/ (removes the older versioned .cmd)
pwsh -NoProfile -File tests/run-tests.ps1     # all suites (PowerShell 7 on Linux; ~18 suites)
python3 src/lang/keys.py --missing            # GUI texts still missing per language
python3 src/isohashes.py                      # refresh src/iso-hashes.json from microsoft.com (run before a release)
```

CI (`.github/workflows/tests.yml`) rebuilds and fails if `git status` is not clean, so always commit the rebuilt `.cmd` (and the deletion of the old-version one) together with `src/` changes.

**Running a single suite:** suites load functions from `tests/v2body.ps1` (the PowerShell part of the built `.cmd`), which `run-tests.ps1` creates and deletes. To run one suite by hand, build, then:

```bash
pwsh -NoProfile -Command '$c=[IO.File]::ReadAllText((Get-Item ./Windows-ISO-updater-GUI_v*.cmd).FullName); $i=$c.IndexOf("`r`n#PS-BEGIN"); [IO.File]::WriteAllText("tests/v2body.ps1",$c.Substring($i+2).Replace("`r`n","`n"))'
pwsh -NoProfile -File tests/isocheck.tests.ps1      # engine-catalog.tests.ps1 instead takes -Engine tests/v2body.ps1
```

A suite fails if any line starts with `FAIL `. New suites must be added to the `$suites` list in `tests/run-tests.ps1`. Tests dot-source function definitions from the AST (main is never run) and use stand-ins in `tests/fake/` (`dism`, `signtool`, `inf2cat`, `makecat`, `expand`, `wsl`, `wslpath`); DISM, WPF, real driver installs and live downloads need a manual Windows run.

## Architecture

- **Build (`src/build.py`)** concatenates: `00_header.cmd` (batch: elevation, then `Invoke-Expression` of everything after `#PS-BEGIN` in the same file) → engine → GUI parts (`40_gui_xaml`, `45_gui_dialogs`, `48_gui_lang`, `50_gui`, `55_gui_main`). Output must be pure ASCII with CRLF (build enforces ASCII; `.gitattributes` keeps `*.cmd -text`).
- **Legacy engine `src/engine_v1.ps1`** is not included whole: `build.py` pulls **hard-coded 1-based line ranges** (`rng(a, b)`) out of it and patches them with exact-match `edit(old, new)` calls that abort the build if the match count differs. Editing `engine_v1.ps1` shifts those ranges — prefer putting new/replacement logic in a numbered `src/NN_engine_*.ps1` file (many v1 regions have already moved there; comments in `build.py` say which).
- **Generated functions:** `src/iso-hashes.json` becomes `Get-KnownIsoHashes`, and `src/lang/<code>.json` (English text → translation) becomes `Get-LangData` with non-ASCII as `&#x..;` entities.
- **Version** lives only in `$Script:AppVersion` in `src/10_engine_head.ps1`; the build injects it into the file name, header (`@@VERSION@@`/`@@FILENAME@@`) and window title.
- **Runtime model:** the engine is loaded both into the GUI runspace and a background worker runspace. Long jobs run in the worker; `Write-Host` there goes to the Activity panel and `Write-Host -NoNewline` to the status line. Job entry point and "run everything" are in `32_engine_jobs.ps1`. Servicing follows Microsoft's Dynamic Update order (WinRE → install.wim → boot.wim → media), in `35_engine_service.ps1`.
- The README "Building from source" section has a per-file table of what each `src/` part does.

## Gotchas

- Engine runs under **Windows PowerShell 5.1**, tests under PowerShell 7: variables are case-insensitive (`$u` == `$U`), `ConvertFrom-Json` doesn't unroll top-level arrays, and console-tool stderr becomes a terminating error under `$ErrorActionPreference = 'Stop'` — use `Invoke-Native` / `Invoke-Exe`. Wrapping a `New-Object List[object]` in `@()` previously broke startup on Windows ("Argument types do not match") without failing tests.
- **Every new GUI text** (XAML `Text`/`Content`/`ToolTip`/`Header`, `T '...'` calls, `New-Table` columns) must be translated in all 5 `src/lang/*.json` (pt, es, fr, de, it) with identical `{0}` placeholders, or `lang.tests.ps1` fails. Product/tool names that stay untranslated go in `KEEP` in `src/lang/keys.py`. Messages/questions must go through `T`, not be set on controls directly.

## Releasing

1. Bump `$Script:AppVersion`; add a `## vX.Y.Z — date` entry to `CHANGELOG.md` (becomes the release notes); update the README badge/start line/version table and `.github/ISSUE_TEMPLATE/bug_report.yml`.
2. Rebuild, test, merge to `main`.
3. Run **Actions → release** on `main` (`version`, optional `title`, `prerelease`). It checks version + changelog, rebuilds, tests, tags and attaches the `.cmd` + `.sha256`.
4. To promote an existing pre-release to stable, use **Actions → promote-release** (never re-run `release` for an existing tag); `scripts/package_release.py` requires the changelog entry to start with `**Stable release.**` and the app bytes to be unchanged since the tag.

## Repo conventions

- GitHub repo is `j0p3s/Windows-ISO-Updater` (the GitHub tooling may still use the old name `Win10-ISO-Updater`). Force-push is blocked on branches.
- Never commit or publish: `signing/`, `*.pfx`/`*.p12`, settings JSON, ISOs/WIMs, real answer files, or private data from user logs (user/PC/account names, paths, product keys, Wi-Fi names). Scrub logs before quoting them in issues/PRs.
- The repo owner prefers replies in Portuguese. Session handoff notes go in `HANDOFF.md` (gitignored at the root; `docs/HANDOFF.md` is the committed copy).
