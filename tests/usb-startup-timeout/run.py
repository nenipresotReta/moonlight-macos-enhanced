#!/usr/bin/env python3
"""Compile the actual forwarding session with a fake tunnel and child-process helper."""
from pathlib import Path
import os
import subprocess
import tempfile

if Path("/Applications/Xcode.app/Contents/Developer").exists():
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

ROOT = Path(__file__).resolve().parents[2]
TEST = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="moonlight-usb-startup-") as temp:
    helper = str(Path(temp) / "helper")
    fixture = str(Path(temp) / "fixture")
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", str(TEST / "helper.c"), "-o", helper], check=True)
    flags = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if os.environ.get("SANITIZE") else []
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    "-Wno-nullability-completeness", "-I", str(ROOT), *flags, str(TEST / "fixture.m"), "-o", fixture], check=True)
    subprocess.run([fixture, helper], check=True, timeout=30)
    viewmodel = str(Path(temp) / "viewmodel")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(Path(temp) / "swift-cache"),
                    str(ROOT / "Limelight/macOS/ViewControllers/RemoteUSBForwardingViewModel.swift"),
                    str(TEST / "viewmodel-fixture.swift"), "-o", viewmodel], check=True)
    subprocess.run([viewmodel], check=True, timeout=5)
    # Exercise the actual Objective-C importer as well as the Swift doubles.
    # Plain Swift closures can hide missing actor annotations on ObjC callbacks.
    stubs = Path(temp) / "importer-stubs.swift"
    stubs.write_text((TEST / "viewmodel-fixture.swift").read_text().split("final class MLRemoteUSBDevice", 1)[0])
    imported = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-typecheck",
                               "-module-cache-path", str(Path(temp) / "swift-cache"),
                               "-import-objc-header", str(ROOT / "Limelight/Network/RemoteUSBForwardingSession.h"),
                               str(stubs), str(ROOT / "Limelight/macOS/ViewControllers/RemoteUSBForwardingViewModel.swift")],
                              check=True, capture_output=True, text=True)
    if "warning:" in imported.stderr:
        raise SystemExit(imported.stderr)
    print("PASS: real Objective-C callback imports preserve main-actor isolation without warnings")
