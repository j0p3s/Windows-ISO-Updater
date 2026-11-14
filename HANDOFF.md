# HANDOFF — Windows ISO Updater

## 1. Goal
- Maintain and release the Windows ISO Updater: one self-elevating `.cmd` (batch + PowerShell/WPF GUI) that updates a Windows 10/11 ISO (updates, drivers, re-signing, rebuild). Latest work: Buy Me a Coffee text button + start maximized, released as **4.7.4** (stable).

## 2. Current status
- App version **4.7.4** (stable, 2026-11-14): the title-bar coffee control (`CoffeeBtn`) is now a yellow (`#FFDD00`, dark text) text button "Buy me a coffee" using the `Btn` style, opening `$Script:CoffeeUrl` = `https://buymeacoffee.com/j0p3s` (`src/10_engine_head.ps1`; click handler in `src/55_gui_main.ps1`). Yellow is `#FFDD00`, not `#FFC857`, so the light-theme colour remap in `src/50_gui.ps1` does not touch it. New text "Buy me a coffee" translated in all 5 `src/lang/*.json`.
- The window starts maximized: `$W.Add_Loaded({ Set-WorkAreaMax $true })` in `src/55_gui_main.ps1` (manual work-area maximize; a real WPF Maximized would cover the taskbar).
- **v4.7.4 published** stable + latest on 2026-11-14: PR #29 squash-merged as `1408030`, then Actions -> release on `main` (`prerelease=false`). Assets: `.cmd` + `.sha256`; `.cmd` digest `sha256:b68ea469f52d58c0545d993f0a00683d0ebe74a740db0c7843c7840a3350b591`. Only v4.7.3 and v4.7.4 exist as releases.
- Earlier: 4.7.3 added the heart icon button; on 2026-11-13 the owner deleted all older GitHub releases. README/CHANGELOG link to no deleted release.
- License: **GPL-3.0-or-later** since PR #25; versions up to 4.7.1 stay available under MIT.
- `src/isohashes.py` run for 4.7.4: no new hashes (152 in `iso-hashes.json`).
- **Commit history is kept on purpose** (owner, 2026-11-13): needed to trace bugs later. Never rewrite or squash `main`'s existing history.

## 3. Key decisions
- Replies to the owner in **Portuguese**.
- `CLAUDE.md` holds the durable facts (commands, architecture, gotchas, release); this file holds session state only. Don't duplicate.
- Branch reuse after a merged PR: restart from `origin/main`, then `git merge -s ours origin/ccr-0ebf53e0-gw0121`, then normal push — because **force-push is blocked**.
- PRs: draft first, squash-merge once CI is green (squash keeps one commit per change on `main`). The owner merges or explicitly asks Claude to.
- The coffee button is a real text button (owner asked to replace the icon-only version in 4.7.4).
- New logic goes into numbered `src/NN_engine_*.ps1`, not `src/engine_v1.ps1` (editing it shifts `build.py` line ranges).

## 4. Tried and failed
- `merge_pull_request` with a short SHA → "sha must be exactly 40 characters". Use `git rev-parse HEAD`.
- Force-push to the branch → rejected by repo rules (use the `-s ours` merge above).
- `curl` to api.github.com from the container → "GitHub access to this repository is not enabled"; use the `mcp__github__*` tools (check runs, `actions_list`, `actions_run_trigger`, `get_release_by_tag`).
- The `release` workflow attaches only the `.cmd` + `.sha256`; the ZIP bundles come only from `promote-release`. Don't link a release ZIP in the README for a direct stable release.
- Local test runs: `run-tests.ps1` prints failures as indented `  FAIL ...` lines, so `grep "^FAIL "` misses them. Use `grep -E "^\s*FAIL|^FAILED"` (4.7.4's first CI run failed on `theme.tests.ps1` while a wrong local grep showed 0).
- New colours in XAML or `New-Brush` need an entry in `$Script:LightColors` (`src/50_gui.ps1`), or `theme.tests.ps1` fails; the coffee button maps `FFDD00`/`1A1A1A` to themselves.
- Older: `@()` around a `New-Object List[object]` broke startup on Windows (4.2.0/4.3.0) while tests passed — tests on PS7 don't catch PS5.1 issues.
- Older (4.7.0): forcing HTTP language-pack URLs to HTTPS → `SEC_E_WRONG_PRINCIPAL`; keep the URL from UUP metadata as-is.

## 5. Files that matter
- `CLAUDE.md` — commands, single-suite recipe, architecture, gotchas, release steps. Read first.
- `src/build.py` — assembles the `.cmd`; hard-coded `rng()` ranges + exact `edit()` patches.
- `src/10_engine_head.ps1` — `$Script:AppVersion` (only version source), `$Script:CoffeeUrl`, `$Script:GeneratorUrl`.
- `src/40_gui_xaml.ps1` — window XAML (title-bar buttons incl. `CoffeeBtn`); `src/55_gui_main.ps1` — event handlers.
- `src/32_engine_jobs.ps1` / `src/35_engine_service.ps1` — job entry/"run everything" / servicing order.
- `src/lang/*.json`, `src/lang/keys.py` — translations (pt, es, fr, de, it); `--missing` lists gaps.
- `src/iso-hashes.json`, `src/isohashes.py` — known ISO hashes; refresh before releases.
- `tests/run-tests.ps1` — runs all suites; `tests/fake/` — stand-in tools.
- `CHANGELOG.md` — release notes source; `.github/workflows/{tests,release,promote-release}.yml`.
- `Windows-ISO-updater-GUI_v4.7.4.cmd` — generated; never edit.

## 6. Next steps
1. Wait for the owner's next request.
2. If old tags still exist after the release cleanup, ask the owner before deleting them (they keep the history findable; release-note compare links use them).
3. For any change, first: `git fetch origin main && git checkout -B ccr-0ebf53e0-gw0121 origin/main`, then `git merge -s ours origin/ccr-0ebf53e0-gw0121`.
4. Before any release, run `python3 src/isohashes.py`. Stable release: bump version, CHANGELOG `## vX.Y.Z — date` starting `**Stable release.**`, README badge/start line/table, `bug_report.yml`; merge; run `release.yml` on `main` with `prerelease=false`.
5. Optional: refresh `docs/screenshots/01-source.png` (ISO check, coffee button, maximized window). `docs/HANDOFF.md` was removed in 4.7.4 (stale).

## 7. Open questions / gotchas
- The coffee text button (look in both themes, title-bar fit) and the maximized start are not verified on Windows; check on the next manual run.
- A full **Run everything** (slipstream + ISO build) on Windows hasn't been verified by logs in recent versions; only manual Windows runs cover DISM/WPF.
- Never publish private data from user logs (user/PC/account names, paths, product keys, Wi-Fi names), `signing/`, or `*.pfx` files.
- Every new GUI string needs all 5 translations or `lang.tests.ps1` fails; CI fails if the rebuilt `.cmd` isn't committed.
