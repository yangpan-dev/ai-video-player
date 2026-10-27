"""Fail if a packaged app still links to IINA, Homebrew or other local files."""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
frameworks = app / "Contents/Frameworks"
binary = app / "Contents/MacOS/PandaPlayer"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
assert (frameworks / "libmpv.2.dylib").is_file(), "Missing bundled libmpv"
files = [binary] + sorted(path for path in frameworks.glob("*.dylib") if not path.is_symlink())
ai_directory = app / "Contents/Resources/AIEngine"
ai_files = [path for path in ai_directory.iterdir() if path.is_file() and not path.is_symlink() and (path.suffix == ".dylib" or path.name in ["ffmpeg", "whisper-cli", "whisper-server", "llama-server"])] if ai_directory.is_dir() else []
files += ai_files
maximum = (0,)
for file in files:
    output = subprocess.check_output(["otool", "-L", str(file)], text=True)
    for line in output.splitlines():
        if " (compatibility version" not in line:
            continue
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        if dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            assert (file.parent / pathlib.Path(dependency).name).is_file() or (frameworks / pathlib.Path(dependency).name).is_file(), (file.name, dependency)
        else:
            raise AssertionError(f"External dependency: {file.name} -> {dependency}")
    commands = subprocess.check_output(["otool", "-l", str(file)], text=True)
    for value in re.findall(r"path (.+?) \(offset \d+\)", commands):
        assert not value.startswith(("/Applications/", "/opt/", "/Users/", "/usr/local/")), f"External rpath: {value}"
    for value in re.findall(r"\bminos ([\d.]+)", commands):
        maximum = max(maximum, tuple(map(int, value.split("."))))
with (app / "Contents/Info.plist").open("rb") as file:
    minimum = tuple(map(int, plistlib.load(file)["LSMinimumSystemVersion"].split(".")))
assert maximum <= minimum, f"Runtime requires macOS {maximum}, plist declares {minimum}"
print(json.dumps({"bundle": str(app), "libraries": len(files) - 1, "externalDependencies": 0, "minimumOS": ".".join(map(str, maximum)), "signature": "valid"}))
