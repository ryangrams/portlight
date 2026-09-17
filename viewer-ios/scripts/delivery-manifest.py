#!/usr/bin/env python3
"""DELIVERY-01: write DELIVERY-MANIFEST.json, a reproducible inventory of the Portlight iPhone delivery.

  python3 scripts/delivery-manifest.py        # from viewer-ios/, after the final evidence run

Records the source identity (the Portlight checkout's commit, and the git state of the new work), a SHA-256 for every
source file, the evidence files, the acceptance status, the toolchains, and whether each required deliverable exists.
Read-only apart from the manifest itself: it never commits, pushes, uploads or signs anything. Exits 1 when a
required deliverable is missing."""
import datetime, glob, hashlib, json, os, subprocess, sys

IOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.dirname(IOS)
OUTPUT = os.path.join(IOS, "DELIVERY-MANIFEST.json")
# Generated or machine-local; the same list scripts/studio leaves out of the Studio mirror.
SKIP_DIRS = {".build", ".swiftpm", "DerivedData", "build", "evidence", "xcuserdata", "__pycache__", "Portlight.iconset"}
SKIP_FILES = {".DS_Store", os.path.basename(OUTPUT)}

# What the handoff's final delivery lists: source, reproducible build, test evidence, simulator screenshots of the
# connection and session states, a physical-iPhone test script, known limitations, and install/signing steps.
REQUIRED = {
    "source: Xcode project": ["Portlight.xcodeproj/project.pbxproj"],
    "source: PortlightKit package": ["PortlightKit/Package.swift"],
    "build: simulator": ["scripts/build-simulator"],
    "build: physical iPhone": ["scripts/test-device"],
    "install and signing steps": ["docs/INSTALL.md"],
    "physical-iPhone test script": ["docs/DEVICE-TEST-SCRIPT.md"],
    "known limitations": ["docs/KNOWN-LIMITS.md"],
    "decisions and progress": ["DECISIONS.md", "PROGRESS.md", "ACCEPTANCE.json"],
    "evidence: unit test logs": ["evidence/swiftpm-unit-*.log", "evidence/xcode-kit-ios.log", "evidence/xcode-app-unit.log"],
    "evidence: real-host integration log": ["evidence/swiftpm-integration-*.log"],
    "evidence: end-to-end run": ["evidence/e2e/xcresult-summary.json", "evidence/e2e/portlight-transcript.log"],
    "screenshots: connection states": [f"evidence/e2e/screenshots/{name}.png" for name in (
        "fixture-saved-form", "fixture-trust-sheet", "fixture-wrong-password", "fixture-refused", "fixture-busy",
        "fixture-silent-host", "fixture-no-route", "fixture-relaunch-list")],
    "screenshots: session states": [f"evidence/e2e/screenshots/{name}.png" for name in (
        "fixture-connected", "fixture-connected-landscape", "fixture-displays-sheet", "fixture-quality",
        "fixture-paused", "fixture-view-only", "fixture-diagnostics", "fixture-app-switcher",
        "fixture-foreground-reconnected")],
    "screenshots: UI gallery (light and dark)": ["evidence/ui-gallery/index.tsv"],
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def run(*command, cwd=None, timeout=20):
    try:
        return subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def files_under(root, skip_dirs):
    for directory, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in skip_dirs and not d.endswith(".xcresult"))
        for name in sorted(names):
            if name not in SKIP_FILES:
                yield os.path.join(directory, name)


def entry(path, base):
    return {"path": os.path.relpath(path, base), "bytes": os.path.getsize(path), "sha256": sha256(path)}


def bundle_bytes(path):
    return sum(os.path.getsize(os.path.join(d, n)) for d, _, names in os.walk(path) for n in names)


def swift_lines(sources):
    areas = {}
    for item in sources:
        if item["path"].endswith(".swift"):
            parts = item["path"].split(os.sep)
            area = os.sep.join(parts[:2]) if parts[0] == "PortlightKit" else parts[0]
            with open(os.path.join(IOS, item["path"]), errors="replace") as handle:
                areas[area] = areas.get(area, 0) + sum(1 for _ in handle)
    return dict(sorted(areas.items()))


def xcode_version():
    local = run("xcodebuild", "-version")
    if local:
        return {"where": "this Mac", "version": local.replace("\n", ", ")}
    studio = run("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "studio", "xcodebuild -version")
    if studio:
        return {"where": "studio (RG Mac Studio, via scripts/studio)", "version": studio.replace("\n", ", ")}
    return {"where": "unavailable", "version": ""}


def main():
    sources = [entry(p, IOS) for p in files_under(IOS, SKIP_DIRS)]
    host_brief = [entry(p, APP) for p in files_under(os.path.join(APP, "docs", "host-next"), set())]
    evidence_root = os.path.join(IOS, "evidence")
    evidence = [entry(p, IOS) for p in files_under(evidence_root, {"attachments"})]
    bundles = [{"path": os.path.relpath(p, IOS), "bytes": bundle_bytes(p)}
               for p in sorted(glob.glob(os.path.join(evidence_root, "*.xcresult")))]

    acceptance = json.load(open(os.path.join(IOS, "ACCEPTANCE.json")))
    counts = {}
    for requirement in acceptance["requirements"]:
        counts[requirement["status"]] = counts.get(requirement["status"], 0) + 1

    new_work = run("git", "status", "--porcelain", "--", "viewer-ios", "docs/host-next", cwd=APP).splitlines()
    everything = run("git", "status", "--porcelain", cwd=APP).splitlines()

    deliverables, missing = {}, []
    for name, patterns in REQUIRED.items():
        found = {pattern: sorted(os.path.relpath(p, IOS) for p in glob.glob(os.path.join(IOS, pattern))) for pattern in patterns}
        deliverables[name] = found
        missing += [f"{name}: {pattern}" for pattern, paths in found.items() if not paths]

    manifest = {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "generator": "viewer-ios/scripts/delivery-manifest.py",
        "sourceIdentity": {
            "portlightCheckoutCommit": run("git", "rev-parse", "HEAD", cwd=APP),
            "newWorkGitStatus": new_work,
            "preexistingChangesElsewhere": len([line for line in everything if line not in new_work]),
            "note": "viewer-ios/ and docs/host-next/ are uncommitted working-tree additions; nothing was committed, "
                    "pushed, published, uploaded or submitted.",
        },
        "toolchains": {
            "swift (this Mac)": run("swift", "--version").splitlines()[0:1],
            "xcode": xcode_version(),
        },
        "acceptance": {
            "counts": dict(sorted(counts.items())),
            "requirements": {r["id"]: r["status"] for r in acceptance["requirements"]},
        },
        "deliverables": deliverables,
        "missingDeliverables": missing,
        "swiftLinesByArea": swift_lines(sources),
        "sources": {"count": len(sources), "bytes": sum(s["bytes"] for s in sources), "files": sources},
        "hostBrief": host_brief,
        "evidence": {"files": evidence, "resultBundles": bundles},
    }
    with open(OUTPUT, "w") as handle:
        json.dump(manifest, handle, indent=1, ensure_ascii=False)
        handle.write("\n")

    print(f"{os.path.relpath(OUTPUT, APP)}: {len(sources)} source files, {len(evidence)} evidence files, "
          f"{len(bundles)} result bundles; acceptance {manifest['acceptance']['counts']}")
    if missing:
        print("MISSING DELIVERABLES:\n  " + "\n  ".join(missing))
        sys.exit(1)
    print("every required deliverable is present")


if __name__ == "__main__":
    main()
