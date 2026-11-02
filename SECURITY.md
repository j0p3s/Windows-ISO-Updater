# Security

## Your signing key

The tool creates a self-signed code-signing certificate to re-sign modded drivers. Its private key is saved as `signing\DriverSigning.pfx` next to the `.cmd`.

- **Keep it private and backed up.** Anyone who has it can sign drivers that every PC installed from your ISO will trust.
- Only the public `DriverSigning.cer` goes into the ISO.
- If you think it leaked: delete the `signing` folder, remove the certificate from `certmgr.msc` (Personal, and on installed PCs Trusted Root + Trusted Publishers, subject `CN=Custom Driver Signing`), and sign your packages again — a new certificate is created.

## Your ISO

The ISO contains your `autounattend.xml`, which usually holds an account password and a Wi‑Fi key in plain text, and your `$OEM$` folder. Treat the ISO and the USB stick like those passwords.

## What the tool downloads

Updates and Microsoft deployment / signing tools come from Microsoft's Update Catalog, download / symbol servers and NuGet packages. Language packs can be imported, downloaded from direct Microsoft CAB URLs, or discovered automatically through UUP dump. Automatic package metadata is fetched over HTTPS. Payloads are restricted to allowed Microsoft hosts, using the exact URL supplied by the metadata. Microsoft can supply HTTP-only CDN links; these are permitted only with a valid expected byte count and SHA-1, both checked before caching or conversion. HTTP transport does not provide confidentiality; integrity relies on the HTTPS metadata hash and Windows package-signature checks during DISM integration. The app does not change signed URLs, switch their hosts or follow redirects. Direct CAB links remain HTTPS-only. Genuine HTTPS payloads retain normal certificate validation and may retry curl certificate / CA-file errors through the Windows HTTPS downloader; they are never downgraded to HTTP. HTTP / server refusals do not trigger another client. Missing or mismatched integrity metadata stops the download; partial files are removed. ESD conversion uses DISM and support tools downloaded from an immutable upstream revision with pinned SHA-256 checks.

If you choose in-app Windows downloads, the app requests metadata and a download-and-convert package from `api.uupdump.net` / `uupdump.net`. UUP dump is a community project. Its package downloads Windows payloads from Microsoft and runs its upstream downloader / converter tools locally. Package ZIP paths are checked before extraction; the app validates the resulting ISO's boot files and selected Windows image metadata before publishing it, and writes a SHA-256 and provenance file. It does not bundle these third-party tools or bypass service blocks.

The optional generate-cat-file signing engine downloads pinned source from GitHub. The app has no telemetry and does not upload your signing key, drivers, answer files or ISO contents. Download services see the requests you make (including selected UUP build, language and edition).

## While it runs

- It needs administrator rights (DISM, mounting images, certificates).
- During signing, the certificate is trusted on this PC only for the check and removed again (stores that already trusted it are left alone).
- With *Let Windows Defender skip the work folder*, an exclusion for the work folder is added only for the job and removed afterwards (also at the next start if the program was closed during a job).
- While a job runs, it asks Windows not to go to sleep (a power request, listed by `powercfg /requests`). The request ends with the job, or when the program closes.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **Report a vulnerability** (Security tab → Advisories) on this repository, with steps to reproduce.
