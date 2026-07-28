import errno
import json
import os
import platform
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class ProbePaths:
    site_packages: str
    mediated_fixture: str
    denied_read_path: str
    denied_write_path: str


def write_inside_workspace() -> bool:
    Path("workspace-write.txt").write_bytes(b"gizmate")
    return True


def permission_error_when_reading(path: str) -> bool:
    try:
        Path(path).read_bytes()
    except OSError as error:
        return error.errno in (errno.EACCES, errno.EPERM)
    return False


def permission_error_when_writing(path: str) -> bool:
    try:
        Path(path).write_bytes(b"outside")
    except OSError as error:
        return error.errno in (errno.EACCES, errno.EPERM)
    return False


def raw_network_is_denied() -> bool:
    try:
        connection = socket.create_connection(("127.0.0.1", 9), timeout=2)
    except OSError as error:
        return error.errno in (errno.EACCES, errno.EPERM)
    connection.close()
    return False


def run_normal(paths: ProbePaths) -> None:
    sys.path.insert(0, paths.site_packages)
    import idna

    report = {
        "workspace_write_succeeded": write_inside_workspace(),
        "host_read_denied": permission_error_when_reading(paths.denied_read_path),
        "host_write_denied": permission_error_when_writing(paths.denied_write_path),
        "raw_network_denied": raw_network_is_denied(),
        "mediated_network_succeeded": Path(paths.mediated_fixture)
        .read_bytes()
        .startswith(b"<!doctype html>"),
        "python_version": platform.python_version(),
        "dependency_version": idna.__version__,
    }
    print(json.dumps(report, separators=(",", ":"), sort_keys=True), flush=True)


def run_timeout() -> None:
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        close_fds=True,
    )
    print(child.pid, flush=True)
    time.sleep(60)


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit(64)
    mode, site_packages, mediated_fixture, denied_read_path, denied_write_path = sys.argv[1:]
    paths = ProbePaths(
        site_packages=site_packages,
        mediated_fixture=mediated_fixture,
        denied_read_path=denied_read_path,
        denied_write_path=denied_write_path,
    )
    if mode == "normal":
        run_normal(paths)
    elif mode == "timeout":
        run_timeout()
    else:
        raise SystemExit(64)


if __name__ == "__main__":
    main()
