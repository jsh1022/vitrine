"""Run the simulator check and retain evidence even for a pre-main crash or timeout."""
from pathlib import Path
import shutil
import subprocess
import sys


def as_text(value):
    return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")


def collect(device, output):
    commands = {
        "system.log": ["xcrun", "simctl", "spawn", device, "log", "show", "--last", "5m",
                       "--style", "compact", "--predicate",
                       'process == "AudioPresentation" OR eventMessage CONTAINS "dev.vitrine.audio-presentation"'],
        "simulator.json": ["xcrun", "simctl", "list", "devices", "available", "-j"],
    }
    for name, command in commands.items():
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            (output / name).write_text(result.stdout + result.stderr)
        except (OSError, subprocess.TimeoutExpired) as error:
            (output / name).write_text(str(error))
    try:
        subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output / "screen.png")],
                       capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        pass
    folders = [Path.home() / "Library/Logs/DiagnosticReports",
               Path.home() / "Library/Developer/CoreSimulator/Devices" / device / "data/Library/Logs/CrashReporter"]
    for index, folder in enumerate(folders):
        if folder.exists():
            reports = sorted(folder.rglob("AudioPresentation*"), key=lambda p: p.stat().st_mtime, reverse=True)
            for report in reports[:5]:
                if report.is_file():
                    shutil.copy2(report, output / f"crash-{index}-{report.name}")


def main():
    device, base = sys.argv[1:]
    output = Path(base) / "diagnostics"
    output.mkdir(parents=True, exist_ok=True)
    code = 1
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "launch", "--console", device, "dev.vitrine.audio-presentation"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
        text = as_text(result.stdout)
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        text = as_text(error.stdout) + "\nFAIL: simulator test timed out after 90 seconds.\n"
    (output / "presentation.log").write_text(text)
    print(text, flush=True)
    print(f"simctl exit status: {code}", flush=True)
    passed = code == 0 and all(marker in text for marker in (
        "PASS audio source presentations:", "PASS unavailable WireGuard:"))
    if not passed:
        print("FAIL: expected test completion markers are missing; collecting diagnostics.", flush=True)
        collect(device, output)
        print("See the audio-presentation-diagnostics artifact for app logs, screenshot and crash reports.", flush=True)
    try:
        subprocess.run(["xcrun", "simctl", "terminate", device, "dev.vitrine.audio-presentation"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
