"""Include the existing project's AI engines and FFmpeg, keeping their ABI isolated."""
import pathlib
import re
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
project = pathlib.Path(__file__).resolve().parents[2]
source = project / "resources/bin/darwin-arm64"
destination = app / "Contents/Resources/AIEngine"
for name in ["whisper-server", "llama-server"]:
    if not (source / name).is_file():
        raise SystemExit(f"Missing {name}. Build the original project's AI engines first.")
shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)
ffmpeg = project / "node_modules/ffmpeg-static/ffmpeg"
if not ffmpeg.is_file():
    raise SystemExit("Missing ffmpeg-static; install the original project dependencies.")
shutil.copy2(ffmpeg, destination / "ffmpeg")
for name in ["ffmpeg.LICENSE", "ffmpeg.README"]:
    if (ffmpeg.parent / name).is_file():
        shutil.copy2(ffmpeg.parent / name, destination / name)
files = [path for path in destination.iterdir() if path.is_file() and not path.is_symlink() and (path.suffix == ".dylib" or path.name in ["ffmpeg", "whisper-cli", "whisper-server", "llama-server"])]
for path in files:
    path.chmod(0o755)
    subprocess.run(["codesign", "--remove-signature", str(path)], check=False, capture_output=True)
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    first = True
    for line in output.splitlines():
        if " (compatibility version" not in line:
            continue
        dependency = line.strip().split(" (", 1)[0]
        if first and path.suffix == ".dylib":
            first = False
            subprocess.run(["install_name_tool", "-id", f"@rpath/{path.name}", str(path)], check=True)
            continue
        first = False
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        if dependency.startswith("@") and (destination / pathlib.Path(dependency).name).is_file():
            continue
        if dependency.startswith("/") and (destination / pathlib.Path(dependency).name).is_file():
            subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + pathlib.Path(dependency).name, str(path)], check=True)
            continue
        raise SystemExit(f"Unbundled AI dependency: {path.name}: {dependency}")
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    rpaths = set(re.findall(r"path (.+?) \(offset \d+\)", commands))
    for rpath in rpaths:
        if rpath.startswith(("/Users/", "/Applications/", "/opt/", "/usr/local/")):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(path)], check=True)
    if path.name != "ffmpeg" and "@loader_path" not in rpaths:
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", str(path)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
print(f"Bundled {len(files)} AI executable/library files; models remain user-managed.")
