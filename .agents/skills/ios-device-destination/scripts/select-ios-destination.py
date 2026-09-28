#!/usr/bin/env python3
"""Select an iOS xcodebuild destination: wired device first, simulator last."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Any


def run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def load_devicectl_devices() -> list[dict[str, Any]]:
    fd, path = tempfile.mkstemp(prefix="devicectl-devices-", suffix=".json")
    os.close(fd)
    try:
        proc = run(
            [
                "xcrun",
                "devicectl",
                "list",
                "devices",
                "--quiet",
                "--json-output",
                path,
            ]
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"devicectl list devices failed ({proc.returncode}): {proc.stderr.strip()}"
            )
        data = json.loads(open(path, encoding="utf-8").read())
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return list((data.get("result") or {}).get("devices") or [])


def record(dev: dict[str, Any]) -> dict[str, Any]:
    hw = dev.get("hardwareProperties") or {}
    conn = dev.get("connectionProperties") or {}
    props = dev.get("deviceProperties") or {}
    udid = hw.get("udid") or ""
    reality = hw.get("reality")
    is_sim = reality == "simulated" or conn.get("transportType") == "sameMachine"
    is_physical = (not is_sim) and (
        reality == "physical" or str(udid).startswith("0000")
    )
    return {
        "name": props.get("name") or "unknown",
        "udid": udid,
        "core_device_identifier": dev.get("identifier") or "",
        "reality": reality,
        "is_physical": is_physical,
        "is_simulator": is_sim,
        "transport": conn.get("transportType"),
        "tunnel": conn.get("tunnelState"),
        "pair": conn.get("pairingState"),
        "platform": hw.get("platform"),
        "product_type": hw.get("productType"),
    }


def hyphenless(value: str) -> str:
    return re.sub(r"[^0-9A-Fa-f]", "", value).upper()


def usb_serials() -> set[str]:
    proc = run(["ioreg", "-p", "IOUSB", "-w", "0", "-l"])
    if proc.returncode != 0:
        return set()
    found: set[str] = set()
    for match in re.finditer(
        r'"USB Serial Number"\s*=\s*"([0-9A-Fa-f]+)"', proc.stdout
    ):
        found.add(match.group(1).upper())
    return found


def parse_showdestinations(text: str) -> dict[str, dict[str, str]]:
    """Map destination id -> {platform, name, error}."""
    result: dict[str, dict[str, str]] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("{") or "id:" not in line:
            continue
        ident = re.search(r"\bid:([^,}]+)", line)
        if not ident:
            continue
        dest_id = ident.group(1).strip()
        platform_m = re.search(r"platform:([^,}]+)", line)
        name_m = re.search(r"name:([^}]+)", line)
        error_m = re.search(r"\berror:(.+)$", line)
        name = (name_m.group(1) if name_m else "").strip()
        if name.endswith("}"):
            name = name[:-1].strip()
        result[dest_id] = {
            "platform": (platform_m.group(1) if platform_m else "").strip(),
            "name": name,
            "error": (error_m.group(1).strip() if error_m else ""),
            "raw": line,
        }
    return result


def showdestinations(project: str | None, scheme: str | None) -> dict[str, dict[str, str]]:
    if not project or not scheme:
        return {}
    cmd = ["xcodebuild", "-scheme", scheme, "-showdestinations"]
    if project.endswith(".xcworkspace"):
        cmd[1:1] = ["-workspace", project]
    else:
        cmd[1:1] = ["-project", project]
    proc = run(cmd)
    return parse_showdestinations(proc.stdout + "\n" + proc.stderr)


def destination_ok(
    rec: dict[str, Any],
    dests: dict[str, dict[str, str]],
    *,
    min_ios: int,
    want_simulator: bool,
) -> tuple[bool, str]:
    udid = rec["udid"]
    if dests:
        meta = dests.get(udid)
        if meta is None:
            return False, "not listed in xcodebuild -showdestinations"
        if meta.get("error"):
            return False, meta["error"]
        platform = meta.get("platform", "")
        if want_simulator and platform != "iOS Simulator":
            return False, f"unexpected platform {platform}"
        if not want_simulator and platform != "iOS":
            return False, f"unexpected platform {platform}"
        return True, ""
    # Without a project, skip clearly-old sims if we can read simctl later.
    _ = min_ios
    return True, ""


def simctl_iphones() -> list[dict[str, Any]]:
    proc = run(["xcrun", "simctl", "list", "devices", "-j"])
    if proc.returncode != 0:
        return []
    data = json.loads(proc.stdout)
    devices: list[dict[str, Any]] = []
    runtime_re = re.compile(r"iOS-(\d+)-")
    for runtime, items in (data.get("devices") or {}).items():
        major = 0
        m = runtime_re.search(runtime.replace(".", "-"))
        if m:
            major = int(m.group(1))
        elif "iOS" in runtime:
            num = re.search(r"iOS[^\d]*(\d+)", runtime)
            if num:
                major = int(num.group(1))
        for item in items:
            name = item.get("name") or ""
            if "iPhone" not in name:
                continue
            devices.append(
                {
                    "udid": item.get("udid") or "",
                    "name": name,
                    "state": item.get("state") or "",
                    "isAvailable": item.get("isAvailable", True),
                    "runtime": runtime,
                    "os_major": major,
                }
            )
    return devices


def boot_one_simulator(min_ios: int) -> dict[str, Any] | None:
    sims = [
        s
        for s in simctl_iphones()
        if s["isAvailable"] and s["os_major"] >= min_ios and s["udid"]
    ]
    booted = [s for s in sims if s["state"] == "Booted"]
    if booted:
        return booted[0]
    shutdown = [s for s in sims if s["state"] == "Shutdown"]
    # Prefer highest OS, then name containing a recent marketing number is irrelevant;
    # stable pick: highest os_major then name.
    shutdown.sort(key=lambda s: (s["os_major"], s["name"]), reverse=True)
    if not shutdown:
        return None
    chosen = shutdown[0]
    proc = run(["xcrun", "simctl", "boot", chosen["udid"]])
    if proc.returncode != 0:
        raise RuntimeError(f"simctl boot failed: {proc.stderr.strip() or proc.stdout}")
    return {**chosen, "state": "Booted", "did_boot": True}


def payload(
    *,
    kind: str,
    rec: dict[str, Any] | None,
    sim: dict[str, Any] | None,
    did_boot: bool,
    reason: str,
) -> dict[str, Any]:
    if rec is not None:
        platform = "iOS Simulator" if rec.get("is_simulator") else "iOS"
        udid = rec["udid"]
        return {
            "ok": True,
            "kind": kind,
            "name": rec["name"],
            "udid": udid,
            "core_device_identifier": rec.get("core_device_identifier") or udid,
            "xcodebuild_destination": f"platform={platform},id={udid}",
            "transport": rec.get("transport"),
            "tunnel": rec.get("tunnel"),
            "did_boot_simulator": did_boot,
            "reason": reason,
        }
    assert sim is not None
    udid = sim["udid"]
    return {
        "ok": True,
        "kind": kind,
        "name": sim["name"],
        "udid": udid,
        "core_device_identifier": udid,
        "xcodebuild_destination": f"platform=iOS Simulator,id={udid}",
        "transport": "sameMachine",
        "tunnel": "connected",
        "did_boot_simulator": did_boot,
        "os_major": sim.get("os_major"),
        "reason": reason,
    }


def fail(message: str, code: int = 2) -> None:
    json.dump({"ok": False, "error": message}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    raise SystemExit(code)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pick an iOS destination: wired device first, then simulator."
    )
    parser.add_argument("--project", help="xcodeproj or xcworkspace for showdestinations")
    parser.add_argument("--scheme", help="scheme name; required with --project")
    parser.add_argument("--min-ios", type=int, default=26, dest="min_ios")
    parser.add_argument(
        "--allow-boot",
        action="store_true",
        help="If no device and no booted sim, boot one existing iPhone simulator",
    )
    parser.add_argument(
        "--print-destination",
        action="store_true",
        help="Print only xcodebuild_destination on success",
    )
    args = parser.parse_args()
    if args.project and not args.scheme:
        fail("--scheme is required when --project is set")

    dests = showdestinations(args.project, args.scheme)
    devices = [record(d) for d in load_devicectl_devices()]
    usb = usb_serials()

    wired: list[dict[str, Any]] = []
    network: list[dict[str, Any]] = []
    for rec in devices:
        if not rec["is_physical"]:
            continue
        if rec["pair"] not in (None, "paired"):
            continue
        if rec["transport"] == "wired" and rec["tunnel"] == "connected":
            wired.append(rec)
        elif rec["transport"] == "localNetwork" and rec["tunnel"] == "connected":
            network.append(rec)

    def prefer_usb(cands: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not usb:
            return cands
        hit = [c for c in cands if hyphenless(c["udid"]) in usb]
        return hit or cands

    for kind, group, reason in (
        (
            "physical_wired",
            prefer_usb(wired),
            "wired physical device with connected tunnel",
        ),
        (
            "physical_network",
            network,
            "network physical device with connected tunnel (no wired device)",
        ),
    ):
        for rec in group:
            ok, why = destination_ok(rec, dests, min_ios=args.min_ios, want_simulator=False)
            if ok:
                result = payload(
                    kind=kind, rec=rec, sim=None, did_boot=False, reason=reason
                )
                emit(result, print_destination=args.print_destination)
                return
            rec["_skip"] = why

    sims = [
        s
        for s in simctl_iphones()
        if s["isAvailable"] and s["os_major"] >= args.min_ios and s["state"] == "Booted"
    ]
    for sim in sims:
        fake = {
            "udid": sim["udid"],
            "name": sim["name"],
            "is_simulator": True,
        }
        ok, why = destination_ok(fake, dests, min_ios=args.min_ios, want_simulator=True)
        if ok:
            result = payload(
                kind="simulator_booted",
                rec=None,
                sim=sim,
                did_boot=False,
                reason="no available physical device; reusing already-booted simulator",
            )
            emit(result, print_destination=args.print_destination)
            return

    if not args.allow_boot:
        fail(
            "没有可用真机，也没有已启动且满足 min-ios 的模拟器。"
            "不要自行 simctl boot。需要时再加 --allow-boot（只会启动一台现有 iPhone 模拟器）。"
        )

    booted = boot_one_simulator(args.min_ios)
    if not booted:
        fail("没有可用真机，且没有 OS 满足 min-ios 的现成 iPhone 模拟器可 boot")
    fake = {
        "udid": booted["udid"],
        "name": booted["name"],
        "is_simulator": True,
    }
    ok, why = destination_ok(fake, dests, min_ios=args.min_ios, want_simulator=True)
    if dests and not ok:
        fail(f"boot 了模拟器但 xcodebuild 不可用: {why}")
    result = payload(
        kind="simulator_booted_after_boot",
        rec=None,
        sim=booted,
        did_boot=True,
        reason="no available physical device; booted one existing iPhone simulator",
    )
    emit(result, print_destination=args.print_destination)


def emit(result: dict[str, Any], *, print_destination: bool) -> None:
    if print_destination:
        sys.stdout.write(result["xcodebuild_destination"] + "\n")
        return
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        fail(str(exc))
