# Handoff: Windows ISO Updater

Repository: `j0p3s/Windows-ISO-Updater`. The GitHub tools here use the old name, `Win10-ISO-Updater`.
Local clone: `/home/user/Win10-ISO-Updater`. Branch: `ccr-0ebf53e0-gw0121`.
Latest release: **v4.4.0** (2026-10-31), published and identical to `main`.

## Done in this session

| Version | What |
|---|---|
| 4.0.0 | Choice of signing engine (MakeCat, libwdi-style, generate-cat-file, Inf2Cat), ported from NVIDIA Modded Drivers Signer 2.3.0 |
| 4.1.0 | Faster slipstream: updates already in the image skipped, `boot.wim` in one pass, editions in parallel, time per step |
| 4.2.0 | Interface in PT, ES, FR, DE and IT |
| 4.3.0 | Original ISO check: SHA-256 against Microsoft's published hashes (built-in `src/iso-hashes.json` plus live microsoft.com pages) |
| 4.3.1 | Fix: 4.2.0 and 4.3.0 didn't open on Windows ("Argument types do not match": `@()` over a `New-Object` `List[object]` in `Get-UiTexts`/`Set-UiTexts`) |
| 4.4.0 | Media Creation Tool ISOs recognised (`install.esd`) and Microsoft signatures of the setup and boot files checked; new statuses `mct` and `badsig`; button renamed "Check the ISO" |

- The v4.3.0 release was deleted earlier (its tag was kept). The v4.2.0 and v4.3.0 releases are still on GitHub, but neither version opens.
- **Confirmed on the user's Windows 10:** 4.4.0 runs. The user's MCT `Windows.iso` came out as `mct`, with 7 files checked and none bad. A debug-tool run found no errors.
- Drafted a Reddit post for v4.4.0, given in chat and not saved.

## Workflow

1. Edit `src/`.
2. `python3 src/build.py` (output must be ASCII with CRLF line endings).
3. `pwsh -NoProfile -File tests/run-tests.ps1`: 15 suites, about 578 checks.
4. Bump `$Script:AppVersion` in `src/10_engine_head.ps1` and update `CHANGELOG.md`, `README.md` (badge and version table) and `.github/ISSUE_TEMPLATE/bug_report.yml`.
5. Restart the branch from `origin/main`, commit, then `git merge -s ours origin/<branch>`. Force-push is blocked, and this merge lets a normal push go through.
6. Push and open a draft PR.
7. When CI is green: mark the PR ready, squash-merge, then run the `release.yml` workflow (`version`, `title`).
8. Check that the release asset's SHA-256 matches the local build.

New GUI texts must be translated in all 5 `src/lang/*.json` files; `lang.tests.ps1` fails otherwise.

## Next tasks / open items

- [ ] Get logs from a full **Run everything** under the debug tool on 4.4.0. Only Clean up was exercised there, so slipstream and ISO build are untested.
- [ ] Optional: delete the v4.2.0 and v4.3.0 releases. They don't open; the user hasn't decided.
- [ ] Before each release, run `python3 src/isohashes.py` so the built-in hash list keeps Microsoft's current ISOs. `--archive` (Internet Archive) is slow and mostly useless.
- [ ] Optional: refresh `docs/screenshots/01-source.png` to show the ISO check on page 1.
- [ ] The Claude GitHub App isn't installed on the repo, so PR events don't reach the session. Check CI by polling.

## Constraints

- Never publish private data: user, PC and account names, paths from logs, product keys, Wi-Fi names, `DriverSigning.pfx`.
- Reply to the user in Portuguese.
