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
