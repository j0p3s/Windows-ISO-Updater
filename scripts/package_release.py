"""Package an existing release with current documentation; preserve its tested app bytes."""
import argparse
import hashlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(root, output, version, source_revision, app_revision):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Version must be X.Y.Z")
    for revision in (source_revision, app_revision):
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Use full commit SHAs for source and application revisions")
    app = f"Windows-ISO-updater-GUI_v{version}.cmd"
    original = subprocess.check_output(["git", "show", f"{app_revision}:{app}"], cwd=root)
    if (root / app).read_bytes() != original:
        raise ValueError("The current app differs from the tagged release; use a new version")
    marker = f"## v{version} "
    lines = (root / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(marker))
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## v")), len(lines))
    notes = "\n".join(lines[start + 1:end]).strip()
    if not notes.startswith("**Stable release.**"):
        raise ValueError("The changelog must identify this version as a stable release")
    base = "https://github.com/j0p3s/Windows-ISO-Updater"
    notes += (
        f"\n\n**Downloads:** use the single `.cmd` or `Windows-ISO-Updater-v{version}.zip` "
        "(app, checksum and current documentation). "
        f"`Windows-ISO-Updater-v{version}-source.zip` contains the source and updated stable "
        "documentation. Verify downloads with `SHA256SUMS`."
        "\n\n**Source snapshots:** the original tag and GitHub-generated source archives retain "
        "the tested app commit. The attached source ZIP includes the stable documentation "
        f"from [{source_revision[:7]}]({base}/commit/{source_revision}). "
        "The app and its published SHA-256 are unchanged.\n"
    )
    previous = subprocess.check_output(
        ["git", "tag", "--list", "v*", "--sort=-v:refname"], cwd=root, text=True
    ).splitlines()
    version_parts = tuple(map(int, version.split(".")))
    previous = next((tag for tag in previous if re.fullmatch(r"v\d+\.\d+\.\d+", tag) and tuple(map(int, tag[1:].split("."))) < version_parts), None)
    if previous:
        notes += f"\n**Full Changelog:** {base}/compare/{previous}...v{version}\n"
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / app, output / app)
    shutil.copy2(root / "CHANGELOG.md", output / "CHANGELOG.md")
    (output / (app + ".sha256")).write_text(sha256(output / app) + "  " + app + "\n", encoding="ascii")
    (output / "RELEASE-NOTES.md").write_text(notes, encoding="utf-8")
    provenance = (
        f"Windows ISO Updater v{version} stable release\nApplication tag: v{version}\n"
        f"Application commit: {app_revision}\nStable documentation/source snapshot: {source_revision}\n"
        f"Application SHA-256: {sha256(output / app)}\n"
    )
    (output / "SOURCE-REVISION.txt").write_text(provenance, encoding="ascii")
    prefix = f"Windows-ISO-Updater-v{version}/"
    bundle = f"Windows-ISO-Updater-v{version}.zip"
    source = f"Windows-ISO-Updater-v{version}-source.zip"
    with zipfile.ZipFile(output / bundle, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in (app, app + ".sha256", "README.md", "CHANGELOG.md", "SECURITY.md", "CONTRIBUTING.md", "LICENSE", "RELEASE-NOTES.md", "SOURCE-REVISION.txt"):
            path = root / name if name in ("README.md", "SECURITY.md", "CONTRIBUTING.md", "LICENSE") else output / name
            archive.write(path, prefix + name)
    subprocess.run(["git", "archive", "--format=zip", "--prefix=" + prefix, "--output=" + str(output / source), source_revision], cwd=root, check=True)
    with zipfile.ZipFile(output / source, "a", zipfile.ZIP_DEFLATED) as archive:
        for name in ("RELEASE-NOTES.md", "SOURCE-REVISION.txt"):
            archive.write(output / name, prefix + name)
    names = (app, app + ".sha256", bundle, source, "CHANGELOG.md", "RELEASE-NOTES.md")
    (output / "SHA256SUMS").write_text("".join(sha256(output / name) + "  " + name + "\n" for name in names), encoding="ascii")
    for name in (bundle, source):
        with zipfile.ZipFile(output / name) as archive:
            if archive.testzip() or archive.read(prefix + app) != original:
                raise ValueError("Release archive validation failed")
            for document in ("README.md", "CHANGELOG.md", "SECURITY.md", "CONTRIBUTING.md"):
                if archive.read(prefix + document) != (root / document).read_bytes():
                    raise ValueError("Documentation does not match the source revision")
    print(f"Packaged v{version}: {sha256(output / app)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    package(Path(__file__).resolve().parents[1], args.output.resolve(), args.version, args.source_revision, args.app_revision)
