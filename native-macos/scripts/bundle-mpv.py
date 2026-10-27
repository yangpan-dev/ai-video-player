"""Bundle a complete libmpv runtime, recording original library provenance.

Only reachable libraries are copied; no source app code or assets are included.
This local packaging step does not publish binaries to any external service.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(sys.argv[2]).resolve()
architecture = os.environ.get("PANDAPLAYER_ARCH", "arm64")
if not root.is_file():
    raise SystemExit(f"libmpv does not exist: {root}")
dest = app / "Contents/Frameworks"
notices = app / "Contents/Resources/PlaybackRuntime"
visited, names, records = {}, {}, []


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def dependencies(path):
    return list(dict.fromkeys(line.strip().split(" (", 1)[0] for line in run("otool", "-arch", architecture, "-L", path).splitlines() if " (compatibility version" in line))


def resolve(dependency, parent):
    if dependency.startswith("@loader_path/"):
        candidate = parent / dependency.removeprefix("@loader_path/")
        if candidate.is_file():
            return candidate
    if dependency.startswith("@"):
        for folder in [parent, root.parent, pathlib.Path("/opt/homebrew/lib"), pathlib.Path("/usr/local/lib")]:
            candidate = folder / pathlib.Path(dependency).name
            if candidate.is_file():
                return candidate
        return None
    return pathlib.Path(dependency)


def bundle(path):
    path = path.resolve()
    if path in visited:
        return visited[path]
    if path.name in names and names[path.name] != path:
        raise SystemExit(f"Conflicting runtime names: {path.name}")
    target = dest / path.name
    visited[path], names[path.name] = target, path
    architectures = run("lipo", "-archs", path).split()
    if architecture not in architectures:
        raise SystemExit(f"{path} does not support {architecture}")
    if len(architectures) > 1:
        subprocess.run(["lipo", str(path), "-thin", architecture, "-output", str(target)], check=True)
    else:
        shutil.copy2(path, target)
    target.chmod(0o755)
    subprocess.run(["codesign", "--remove-signature", str(target)], check=False, capture_output=True)
    for dependency in dependencies(path):
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        resolved = resolve(dependency, path.parent)
        if resolved is None and pathlib.Path(dependency).name.startswith("libswift"):
            replacement = "/usr/lib/swift/" + pathlib.Path(dependency).name
        else:
            if resolved is None or not resolved.is_file():
                raise SystemExit(f"Unresolved dependency: {dependency} (required by {path})")
            if resolved.resolve() != path:
                bundle(resolved)
            replacement = f"@loader_path/{resolved.resolve().name}"
        subprocess.run(["install_name_tool", "-change", dependency, replacement, str(target)], check=True)
    subprocess.run(["install_name_tool", "-id", f"@rpath/{target.name}", str(target)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
    records.append({"name": target.name, "source": str(path), "architecture": architecture,
                    "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "bundledSHA256": hashlib.sha256(target.read_bytes()).hexdigest()})
    return target


if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)
notices.mkdir(parents=True, exist_ok=True)
bundled_root = bundle(root)
if root.name != "libmpv.2.dylib":
    (dest / "libmpv.2.dylib").symlink_to(bundled_root.name)
source = {"runtime": str(root), "upstream": "https://github.com/mpv-player/mpv",
          "buildRecipes": "https://github.com/iina/iina/tree/develop/deps",
          "architecture": architecture, "libraries": sorted(records, key=lambda record: record["name"])}
if "/IINA.app/" in str(root):
    source_app = next(parent for parent in root.parents if parent.suffix == ".app")
    with (source_app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    source["provider"] = {"name": "IINA", "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "source": "https://github.com/iina/iina"}
    credits = source_app / "Contents/Resources/Credits.rtf"
    if credits.is_file():
        shutil.copy2(credits, notices / "OriginalDependencyCredits.rtf")
(notices / "manifest.json").write_text(json.dumps(source, indent=2) + "\n")
(notices / "NOTICE.txt").write_text(
    "This local package contains libmpv and its runtime dependencies.\n"
    "No IINA application code, interface, icons or updater is included.\n"
    "The manifest records original library provenance and checksums.\n"
    "Dependencies retain their own licenses; see THIRD_PARTY.md in Resources.\n"
    "This local build is not a notarized public release. Before publishing,\n"
    "provide all notices and corresponding source required by the actual builds.\n")
print(f"Bundled {len(visited)} {architecture} playback libraries.")
