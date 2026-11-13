# HANDOFF — Windows ISO Updater

## 1. Goal
- Maintain and release the Windows ISO Updater: one self-elevating `.cmd` (batch + PowerShell/WPF GUI) that updates a Windows 10/11 ISO (updates, drivers, re-signing, rebuild). Latest work: relicensed MIT -> GPL-3.0-or-later and released 4.7.2.

## 2. Current status
- `main` = `1d661e4` (PR #26 squash-merged). CI green. Nothing in progress: no open PRs from this session, no scheduled check-ins, no PR subscriptions.
- License: **GPL-3.0-or-later** since PR #25 (`LICENSE` = official GPL v3 text; notice in `src/00_header.cmd` header; README badge / License / No warranty sections). Versions up to 4.7.1 stay available under MIT.
- App version **4.7.2**, published **stable + latest** on 2026-11-10 via Actions -> release (license-only; app behaves like 4.7.1). Assets: `.cmd` + `.sha256`; `.cmd` SHA-256 `698beadec3c8e8c4242248867a26ec9e67a3a8aa319a9e2901b262ab665e8451`.
- `src/isohashes.py` was run for 4.7.2: no new hashes.

## 3. Key decisions
- Replies to the owner in **Portuguese**.
- `CLAUDE.md` holds the durable facts (commands, architecture, gotchas, release); this file holds session state only. Don't duplicate.
- Branch reuse after a merged PR: restart from `origin/main`, then `git merge -s ours origin/ccr-0ebf53e0-gw0121`, then normal push — because **force-push is blocked**.
- PRs: draft first, squash-merge once CI is green. The owner merges or explicitly asks Claude to.
- License notice says "v3 or later" (GNU-recommended); owner was told "v3 only" is a two-word change and didn't ask for it.
- New logic goes into numbered `src/NN_engine_*.ps1`, not `src/engine_v1.ps1` (editing it shifts `build.py` line ranges).

## 4. Tried and failed
- `merge_pull_request` with a short SHA → "sha must be exactly 40 characters". Use `git rev-parse HEAD`.
- Force-push to the branch → rejected by repo rules (use the `-s ours` merge above).
- `curl` to api.github.com from the container → "GitHub access to this repository is not enabled"; use the `mcp__github__*` tools (check runs, `actions_list`, `actions_run_trigger`, `get_release_by_tag`).
- The `release` workflow attaches only the `.cmd` + `.sha256`; the ZIP bundles come only from `promote-release`. Don't link a release ZIP in the README for a direct stable release.
- Older: `@()` around a `New-Object List[object]` broke startup on Windows (4.2.0/4.3.0) while tests passed — tests on PS7 don't catch PS5.1 issues.
- Older (4.7.0): forcing HTTP language-pack URLs to HTTPS → `SEC_E_WRONG_PRINCIPAL`; keep the URL from UUP metadata as-is (`CHANGELOG.md:3-8`).

## 5. Files that matter
- `CLAUDE.md` — commands, single-suite recipe, architecture, gotchas, release steps. Read first.
- `src/build.py` — assembles the `.cmd`; hard-coded `rng()` ranges + exact `edit()` patches.
- `src/10_engine_head.ps1` — `$Script:AppVersion` (only version source).
- `src/32_engine_jobs.ps1` / `src/35_engine_service.ps1` — job entry/"run everything" / servicing order.
- `src/lang/*.json`, `src/lang/keys.py` — translations (pt, es, fr, de, it); `--missing` lists gaps.
- `src/iso-hashes.json`, `src/isohashes.py` — known ISO hashes; refresh before releases.
- `tests/run-tests.ps1` — runs all suites; `tests/fake/` — stand-in tools.
- `CHANGELOG.md` — release notes source; `.github/workflows/{tests,release,promote-release}.yml`.
- `Windows-ISO-updater-GUI_v4.7.2.cmd` — generated; never edit.
- `docs/HANDOFF.md` — older committed copy, **stale** (stops at 4.4.0); this root file supersedes it.

## 6. Next steps
1. Wait for the owner's next request; for any change, first: `git fetch origin main && git checkout -B ccr-0ebf53e0-gw0121 origin/main`, then `git merge -s ours origin/ccr-0ebf53e0-gw0121`.
2. Before any release, run `python3 src/isohashes.py` and commit the refreshed hashes. For a stable release: bump version, CHANGELOG `## vX.Y.Z — date` starting `**Stable release.**`, README badge/start line/table, `bug_report.yml`; merge; run `release.yml` on `main` with `prerelease=false`.
3. Optional: refresh `docs/HANDOFF.md` (stale since 4.4.0) or delete it if `CLAUDE.md` + this file suffice — ask the owner.
4. Optional: refresh `docs/screenshots/01-source.png` to show the ISO check.

## 7. Open questions / gotchas
- Owner never decided whether to delete the broken v4.2.0/v4.3.0 GitHub releases.
- A full **Run everything** (slipstream + ISO build) on Windows hasn't been verified by logs in recent versions; only manual Windows runs cover DISM/WPF.
- Never publish private data from user logs (user/PC/account names, paths, product keys, Wi-Fi names), `signing/`, or `*.pfx` files.
- Every new GUI string needs all 5 translations or `lang.tests.ps1` fails; CI fails if the rebuilt `.cmd` isn't committed.
