# /// script
# requires-python = ">=3.12"
# dependencies = ["psutil"]
# ///

import json
import os
import platform
import plistlib
import re
import socket
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

import psutil

# diskutil runs in a worker thread across the 1s measurement sleep, so it can
# afford most of that window; 0.4s made it time out on busy days and dropped
# storage to the psutil fallback.
COMMAND_TIMEOUT = 0.9
# One measurement window for CPU and network alike. macOS advances the CPU
# tick counters in coarse batches (~1s apart), so anything much shorter reads
# zeros; anything longer just delays the refresh.
SPAN_SECONDS = 1.0


def format_bytes(value: float) -> str:
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    size = float(max(0, value))
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PB"


def format_rate(value: float) -> str:
    return f"{format_bytes(value)}/s"


def command_output(args: list[str]) -> str:
    try:
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT,
            check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def command_plist(args: list[str]) -> dict:
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            timeout=COMMAND_TIMEOUT,
            check=False,
        )
        if not result.stdout:
            return {}
        value = plistlib.loads(result.stdout)
        return value if isinstance(value, dict) else {}
    except (
        OSError,
        subprocess.SubprocessError,
        plistlib.InvalidFileException,
        ValueError,
    ):
        return {}


def number_from(mapping: dict, *keys: str) -> float | None:
    for key in keys:
        value = mapping.get(key)
        if (
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and value >= 0
        ):
            return float(value)
    return None


def find_apfs_container(node, reference: str) -> dict | None:
    if isinstance(node, dict):
        current_reference = node.get("ContainerReference") or node.get(
            "APFSContainerReference"
        )
        if current_reference == reference:
            total = number_from(node, "CapacityCeiling", "ContainerTotalSpace")
            free = number_from(node, "CapacityFree", "ContainerFreeSpace")
            if total is not None and free is not None:
                return node
        for value in node.values():
            found = find_apfs_container(value, reference)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_apfs_container(value, reference)
            if found is not None:
                return found
    return None


def storage_usage() -> tuple[float, float, float, float]:
    fallback = psutil.disk_usage(os.path.abspath(os.sep))
    total = float(fallback.total)
    free = float(fallback.free)

    if platform.system() == "Darwin":
        target = (
            "/System/Volumes/Data" if os.path.exists("/System/Volumes/Data") else "/"
        )
        info = command_plist(["diskutil", "info", "-plist", target])
        reference = info.get("APFSContainerReference") or info.get("ContainerReference")

        if isinstance(reference, str) and reference:
            apfs = command_plist(["diskutil", "apfs", "list", "-plist"])
            container = find_apfs_container(apfs, reference)
            if container is not None:
                container_total = number_from(
                    container, "CapacityCeiling", "ContainerTotalSpace"
                )
                container_free = number_from(
                    container, "CapacityFree", "ContainerFreeSpace"
                )
                if (
                    container_total
                    and container_free is not None
                    and container_free <= container_total
                ):
                    total, free = container_total, container_free
                else:
                    container = None
            if container is None:
                info_total = number_from(
                    info,
                    "CapacityCeiling",
                    "APFSContainerSize",
                    "ContainerTotalSpace",
                    "TotalSize",
                    "DiskSize",
                    "VolumeSize",
                )
                info_free = number_from(
                    info,
                    "CapacityFree",
                    "APFSContainerFree",
                    "ContainerFreeSpace",
                    "FilesystemFreeSpace",
                    "VolumeFreeSpace",
                    "FreeSpace",
                )
                if info_total and info_free is not None and info_free <= info_total:
                    total, free = info_total, info_free
        else:
            info_total = number_from(info, "TotalSize", "DiskSize", "VolumeSize")
            info_free = number_from(
                info, "FilesystemFreeSpace", "VolumeFreeSpace", "FreeSpace"
            )
            if info_total and info_free is not None and info_free <= info_total:
                total, free = info_total, info_free

    total = max(0.0, total)
    free = min(total, max(0.0, free))
    used = max(0.0, total - free)
    percent = used / total * 100.0 if total else 0.0
    return total, used, free, percent


def mac_power_details() -> dict[str, str]:
    if platform.system() != "Darwin":
        return {}
    text = command_output(["ioreg", "-r", "-c", "AppleSmartBattery"])

    def number(*keys: str) -> int | None:
        for key in keys:
            match = re.search(rf'"{re.escape(key)}"\s*=\s*(\d+)', text)
            if match:
                return int(match.group(1))
        return None

    details: dict[str, str] = {}
    cycles = number("CycleCount")
    maximum = number("AppleRawMaxCapacity", "MaxCapacity")
    design = number("DesignCapacity")
    temperature = number("Temperature")
    if cycles is not None:
        details["cycles"] = str(cycles)
    if maximum and design:
        details["health"] = f"{min(100.0, maximum / design * 100):.1f}%"
    if temperature is not None:
        celsius = temperature / 100.0 if temperature > 100 else float(temperature)
        if 0 < celsius < 100:
            details["temperature"] = f"{celsius:.1f}°C"
    return details


def active_network() -> tuple[str | None, str, str]:
    stats = psutil.net_if_stats()
    addresses = psutil.net_if_addrs()
    candidates: list[tuple[str, str]] = []
    for interface, entries in addresses.items():
        if (
            interface.startswith("lo")
            or not stats.get(interface)
            or not stats[interface].isup
        ):
            continue
        for address in entries:
            if address.family == socket.AF_INET and not address.address.startswith(
                "127."
            ):
                candidates.append((interface, address.address))
                break
    if not candidates:
        return None, "Network", "Unavailable"
    candidates.sort(key=lambda item: (item[0] not in ("en0", "en1"), item[0]))
    interface, ip = candidates[0]
    label = "Wi-Fi" if interface in ("en0", "en1") else interface
    return interface, label, ip


def memory_details() -> dict[str, float]:
    # Activity Monitor's own numbers, from vm_stat: App Memory is anonymous
    # minus purgeable pages, Compressed is the compressor's occupancy. psutil
    # reports neither on macOS (its "compressed" attribute reads 0 here).
    text = command_output(["vm_stat"])
    page_size = 4096
    match = re.search(r"page size of (\d+)", text)
    if match:
        page_size = int(match.group(1))

    def pages(label: str) -> float:
        found = re.search(rf"{re.escape(label)}:\s+([\d]+)", text)
        return float(found.group(1)) * page_size if found else 0.0

    return {
        "app": max(0.0, pages("Anonymous pages") - pages("Pages purgeable")),
        "compressed": pages("Pages occupied by compressor"),
        "wired": pages("Pages wired down"),
    }


def rolling_series(key: str, value: float, cap: int = 60) -> str:
    # Each run is a fresh process, so chart history has to live outside it: a
    # small JSON in the user's temp dir, appended once per refresh. The chart
    # then shows the last ~minute of real readings, not one run's noise.
    path = os.path.join(tempfile.gettempdir(), "gizmate-mac-usage-history.json")
    try:
        with open(path) as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    series = [
        float(v)
        for v in data.get(key, [])
        if isinstance(v, (int, float)) and not isinstance(v, bool)
    ][-(cap - 1) :]
    series.append(round(float(value), 1))
    data[key] = series
    try:
        with open(path, "w") as handle:
            json.dump(data, handle)
    except OSError:
        pass
    return ",".join(str(v) for v in series)


interface, network_label, local_ip = active_network()
battery = psutil.sensors_battery()

with ThreadPoolExecutor(max_workers=2) as executor:
    storage_future = executor.submit(storage_usage)
    power_future = executor.submit(mac_power_details) if battery is not None else None

    net_start = (
        psutil.net_io_counters(pernic=True).get(interface) if interface else None
    )
    span_start_time = time.monotonic()
    cpu_span_start = psutil.cpu_times()
    time.sleep(SPAN_SECONDS)
    cpu_span_end = psutil.cpu_times()
    net_end = psutil.net_io_counters(pernic=True).get(interface) if interface else None
    elapsed = max(0.001, time.monotonic() - span_start_time)

    storage_total, storage_used, storage_free, storage_percent = storage_future.result()
    power = power_future.result() if power_future is not None else {}

upload_rate = 0.0
download_rate = 0.0
if net_start is not None and net_end is not None:
    upload_rate = max(0.0, (net_end.bytes_sent - net_start.bytes_sent) / elapsed)
    download_rate = max(0.0, (net_end.bytes_recv - net_start.bytes_recv) / elapsed)


def span_delta(field: str) -> float:
    return max(
        0.0,
        float(getattr(cpu_span_end, field, 0.0))
        - float(getattr(cpu_span_start, field, 0.0)),
    )


busy_delta = span_delta("user") + span_delta("system") + span_delta("nice")
idle_delta = span_delta("idle")
total_delta = busy_delta + idle_delta
if total_delta > 0.0:
    cpu_percent = round(100.0 * busy_delta / total_delta, 1)
    user_percent = round(
        100.0 * (span_delta("user") + span_delta("nice")) / total_delta, 1
    )
    system_percent = round(100.0 * span_delta("system") / total_delta, 1)
    idle_percent = round(100.0 * idle_delta / total_delta, 1)
else:
    # The counters never moved across the whole span; report idle rather than
    # inventing a number.
    cpu_percent, user_percent, system_percent = 0.0, 0.0, 0.0
    idle_percent = 100.0
memory = psutil.virtual_memory()
# memory.percent is "% used", not macOS memory pressure. kern.memorystatus_level
# is the kernel's own "percentage of memory available", so pressure is its
# complement — the same figure iStat-style strips print.
level_text = command_output(["sysctl", "-n", "kern.memorystatus_level"]).strip()
memory_pressure = f"{100 - int(level_text)}%" if level_text.isdigit() else "Unavailable"
vm = memory_details()
wired = vm["wired"] or float(getattr(memory, "wired", 0))
app_memory = vm["app"] or float(getattr(memory, "active", memory.used))
compressed = vm["compressed"]

rows = [
    {
        "id": "cpu",
        "icon": "cpu",
        "name": f"CPU: {cpu_percent:.1f}%",
        "detail1": f"System: {system_percent:.1f}%  ·  User: {user_percent:.1f}%",
        "chart": rolling_series("cpu", cpu_percent),
    },
    {
        "id": "memory",
        "icon": "memorychip",
        "name": f"Memory: {memory.percent:.1f}%",
        "detail1": f"Pressure: {memory_pressure}  ·  App: {format_bytes(app_memory)}",
        "meter": f"{memory.percent:.1f}%",
    },
    {
        "id": "storage",
        "icon": "internaldrive",
        "name": f"Storage: {storage_percent:.1f}% used",
        "detail1": f"Free: {format_bytes(storage_free)} of {format_bytes(storage_total)}",
        "meter": f"{storage_percent:.1f}%",
    },
]

if battery is not None:
    rows.append(
        {
            "id": "battery",
            "icon": "battery.100percent",
            "name": f"Battery: {battery.percent:.1f}%",
            "detail1": f"{'Power Adapter' if battery.power_plugged else 'Battery'}"
            + f"  ·  {power.get('health', '?')} health  ·  {power.get('cycles', '?')} cycles",
            "meter": f"{battery.percent:.1f}%",
        }
    )
else:
    rows.append(
        {
            "id": "battery",
            "icon": "battery.100percent",
            "name": "Battery: Not available",
            "detail1": "No battery was detected on this Mac",
        }
    )

rows.append(
    {
        "id": "network",
        "icon": "wifi",
        "name": f"Network: {network_label}",
        "detail1": f"↑ {format_rate(upload_rate)}  ·  ↓ {format_rate(download_rate)}",
        "chart": rolling_series("network", (upload_rate + download_rate) / 1024.0),
    }
)

print(json.dumps({"rows": rows}, ensure_ascii=False))
