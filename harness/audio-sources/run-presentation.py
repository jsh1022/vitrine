"""Run the simulator check and retain evidence even for a pre-main crash or timeout."""
from pathlib import Path
import os
import json
import uuid
import shutil
import subprocess
import sys


def as_text(value):
    return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")


def collect(device, output, process="AudioPresentation", bundle="dev.vitrine.audio-presentation"):
    commands = {
        "system.log": ["xcrun", "simctl", "spawn", device, "log", "show", "--last", "5m",
                       "--style", "compact", "--predicate",
                       f'process == "{process}" OR eventMessage CONTAINS "{bundle}"'],
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
            reports = sorted(folder.rglob(f"{process}*"), key=lambda p: p.stat().st_mtime, reverse=True)
            for report in reports[:5]:
                if report.is_file():
                    shutil.copy2(report, output / f"crash-{index}-{report.name}")


def main():
    device, base = sys.argv[1:3]
    handoff = sys.argv[3:] == ["--handoff"]
    redesigned = sys.argv[3:] == ["--redesigned"]
    environment = os.environ.copy()
    run_id = uuid.uuid4().hex
    if not handoff:
        environment["SIMCTL_CHILD_SG_PRESENTATION_RUN_ID"] = run_id
    if redesigned:
        environment["SIMCTL_CHILD_SG_QUALITY_REDESIGNED"] = "1"
    else:
        environment.pop("SIMCTL_CHILD_SG_QUALITY_REDESIGNED", None)
    bundle = "dev.vitrine.lossless-handoff" if handoff else "dev.vitrine.audio-presentation"
    process = "LosslessHandoff" if handoff else "AudioPresentation"
    markers = ("RESULT failures=0", "PASS wired rate negotiation 44.1 to 48 kHz", "PASS restore app rate after wired mode") if handoff else (
        "PASS inline lyric position, delay, seek and track replacement", "PASS audio source presentations:", "PASS unavailable WireGuard:", "PASS playback quality badge and popover", "PASS full-screen static artwork and live option removal")
    output = Path(base) / "diagnostics"
    output.mkdir(parents=True, exist_ok=True)
    receipt_path = None
    if not handoff:
        # Resolve the installed container before launching UIKit. A post-exit
        # simctl lookup can stall even when every app check has finished.
        for attempt in range(3):
            try:
                container = subprocess.run(
                    ["xcrun", "simctl", "get_app_container", device, bundle, "data"],
                    capture_output=True, text=True, timeout=30, check=True)
                container_path = Path(container.stdout.strip())
                if not container.stdout.strip() or not container_path.is_absolute() or not container_path.is_dir():
                    raise ValueError("simctl did not return an existing absolute data-container path")
                receipt_path = container_path / "Documents/presentation-result.json"
                break
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                print(f"Container setup attempt {attempt + 1}/3 failed: {error}", flush=True)
        if receipt_path is None:
            print("FAIL: could not locate test data container before launch", flush=True)
            collect(device, output, process, bundle)
            return 1
    code = 1
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "launch", "--console", device, bundle],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90, env=environment)
        text = as_text(result.stdout)
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        text = as_text(error.stdout) + "\nFAIL: simulator test timed out after 90 seconds.\n"
    (output / ("handoff.log" if handoff else "presentation-redesigned.log" if redesigned else "presentation.log")).write_text(text)
    print(text, flush=True)
    print(f"simctl exit status: {code}", flush=True)
    passed = code == 0 and all(marker in text for marker in markers)
    if not handoff:
        # Read the app's atomic receipt rather than depending on simctl's final stdout relay.
        # A fresh identity rejects files left by an older launch, including the other UI mode.
        receipt_ok = False
        try:
            receipt = json.loads(receipt_path.read_text())
            lines = receipt.get("markers", [])
            receipt_ok = (receipt.get("run") == run_id and receipt.get("passed") is True
                          and isinstance(lines, list) and all(isinstance(line, str) for line in lines)
                          and all(any(line.startswith(marker) for line in lines) for marker in markers))
            (output / ("result-redesigned.json" if redesigned else "result.json")).write_text(json.dumps(receipt, indent=2))
        except (OSError, ValueError, AttributeError, subprocess.SubprocessError) as error:
            print(f"Test result receipt unavailable: {error}", flush=True)
        passed = code == 0 and receipt_ok
        if passed:
            print("PASS persisted completion receipt: all checks verified for this launch", flush=True)
    if not passed:
        print("FAIL: expected test completion markers are missing; collecting diagnostics.", flush=True)
        collect(device, output, process, bundle)
        print("See the audio diagnostics artifacts for app logs, screenshot and crash reports.", flush=True)
    try:
        subprocess.run(["xcrun", "simctl", "terminate", device, bundle],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
