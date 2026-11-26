#!/usr/bin/env python3
"""
Process, lsappinfo, CoreGraphics window, and bounded-AppleScript lifecycle driver
for packaged build/VKMac.app bundles.

Zero third-party dependencies (Python 3 stdlib only).
"""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time
from typing import Any, Dict, IO, List, Optional, Set, Tuple

from e2e_common import check_window, resolve_hls_probe_bin


class AppLaunchError(RuntimeError):
    """Raised when VKMac.app fails to launch, register, or stay alive."""


def _lsappinfo_find_pid(pid: int) -> Optional[str]:
    res = subprocess.run(
        ["/usr/bin/lsappinfo", "find", f"pid={pid}"],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    if res.returncode != 0:
        return None
    out = res.stdout.strip()
    if not out or out == "[ NULL ]" or not out.startswith("ASN:"):
        return None
    return out


def _lsappinfo_info(asn: str) -> Dict[str, str]:
    res = subprocess.run(
        ["/usr/bin/lsappinfo", "info", "-only", "ApplicationType,CFBundleIdentifier,pid,LSDisplayName", asn],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    info: Dict[str, str] = {}
    if res.returncode != 0:
        return info
    for line in res.stdout.splitlines():
        m = re.match(r'\s*"([^"]+)"\s*=\s*(.+?)\s*$', line)
        if m:
            key = m.group(1)
            val = m.group(2).strip()
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            info[key] = val
    return info


class VKMacAppDriver:
    """
    Launches build/VKMac.app/Contents/MacOS/VKMac directly with isolated env,
    verifies readiness via lsappinfo, optionally checks CGWindowListCopyWindowInfo,
    and guarantees SIGTERM -> SIGKILL process-group cleanup.
    """

    def __init__(
        self,
        app_path: Path,
        env: Optional[Dict[str, str]] = None,
        log_dir: Optional[Path] = None,
        expected_bundle_id: str = "com.vkmac.client",
    ) -> None:
        self.app_path = Path(app_path)
        self.exec_path = self.app_path / "Contents" / "MacOS" / "VKMac"
        self.env = env if env is not None else os.environ.copy()
        self.log_dir = Path(log_dir) if log_dir is not None else None
        self.expected_bundle_id = expected_bundle_id

        self.proc: Optional[subprocess.Popen] = None
        self.pid: Optional[int] = None
        self.stdout_path: Optional[Path] = None
        self.stderr_path: Optional[Path] = None
        self._stdout_fp: Optional[IO[str]] = None
        self._stderr_fp: Optional[IO[str]] = None

    def launch(self) -> int:
        if not self.app_path.exists():
            raise FileNotFoundError(f"VKMac.app bundle does not exist: {self.app_path}")
        if not self.exec_path.exists() or not os.access(self.exec_path, os.X_OK):
            raise FileNotFoundError(f"VKMac executable missing or not executable: {self.exec_path}")

        stdout_target: Any = subprocess.DEVNULL
        stderr_target: Any = subprocess.DEVNULL
        if self.log_dir is not None:
            self.log_dir.mkdir(parents=True, exist_ok=True)
            self.stdout_path = self.log_dir / "vkmac_stdout.log"
            self.stderr_path = self.log_dir / "vkmac_stderr.log"
            self._stdout_fp = open(self.stdout_path, "w", encoding="utf-8")
            self._stderr_fp = open(self.stderr_path, "w", encoding="utf-8")
            stdout_target = self._stdout_fp
            stderr_target = self._stderr_fp

        self.proc = subprocess.Popen(
            [str(self.exec_path)],
            env=self.env,
            stdout=stdout_target,
            stderr=stderr_target,
            start_new_session=True,
        )
        self.pid = self.proc.pid
        return self.pid

    def is_running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def read_logs(self) -> Tuple[str, str]:
        out = ""
        err = ""
        if self.stdout_path and self.stdout_path.exists():
            out = self.stdout_path.read_text(encoding="utf-8", errors="replace")
        if self.stderr_path and self.stderr_path.exists():
            err = self.stderr_path.read_text(encoding="utf-8", errors="replace")
        return out, err

    def wait_ready(
        self,
        timeout: float = 10.0,
        require_foreground: bool = True,
    ) -> Dict[str, Any]:
        if self.proc is None or self.pid is None:
            raise AppLaunchError("wait_ready called before launch()")

        deadline = time.monotonic() + timeout
        last_info: Dict[str, str] = {}
        while time.monotonic() < deadline:
            rc = self.proc.poll()
            if rc is not None:
                out, err = self.read_logs()
                raise AppLaunchError(
                    f"VKMac exited prematurely with code {rc}.\nstdout: {out[-500:]}\nstderr: {err[-500:]}"
                )
            asn = _lsappinfo_find_pid(self.pid)
            if asn:
                last_info = _lsappinfo_info(asn)
                bundle_id = last_info.get("CFBundleIdentifier") or last_info.get("bundleID")
                type_val = last_info.get("ApplicationType") or last_info.get("type", "")
                if type_val == "[ NULL ]":
                    type_val = ""
                bundle_ok = bundle_id == self.expected_bundle_id
                type_ok = (type_val == "Foreground") if require_foreground else bool(type_val)
                if bundle_ok and type_ok:
                    return {
                        "pid": self.pid,
                        "asn": asn,
                        "bundle_id": bundle_id,
                        "type": type_val,
                        "display_name": last_info.get("LSDisplayName") or last_info.get("name"),
                    }
            time.sleep(0.15)

        out, err = self.read_logs()
        raise TimeoutError(
            f"Timed out waiting for VKMac lsappinfo readiness after {timeout}s "
            f"(pid={self.pid}, last_info={last_info}, stderr={err[-500:]})"
        )

    def wait_for_window(self, timeout: float = 5.0) -> Dict[str, Any]:
        if self.pid is None:
            raise AppLaunchError("wait_for_window called before launch()")
        if not resolve_hls_probe_bin().exists():
            raise FileNotFoundError("hls_probe binary missing; cannot check window via CoreGraphics")

        deadline = time.monotonic() + timeout
        last_res: Dict[str, Any] = {}
        while time.monotonic() < deadline:
            if not self.is_running():
                raise AppLaunchError("VKMac exited while waiting for onscreen window")
            rc, parsed = check_window(self.pid)
            last_res = parsed
            if rc == 0 and int(parsed.get("window_count", 0)) > 0:
                return parsed
            time.sleep(0.2)
        raise TimeoutError(f"No onscreen window found for pid={self.pid} within {timeout}s: {last_res}")

    def run_applescript(self, script: str, timeout: float = 3.0) -> Tuple[int, str, str]:
        """Execute AppleScript with a strict timeout so TCC prompts never deadlock."""
        res = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()

    def quit(self, timeout: float = 5.0) -> Optional[int]:
        if self.proc is None:
            return None
        pid = self.proc.pid
        rc = self.proc.poll()
        if rc is None:
            try:
                pgid = os.getpgid(pid)
                os.killpg(pgid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                self.proc.terminate()

            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                rc = self.proc.poll()
                if rc is not None:
                    break
                time.sleep(0.1)

            if self.proc.poll() is None:
                try:
                    pgid = os.getpgid(pid)
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    self.proc.kill()
                try:
                    rc = self.proc.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    rc = None

        for fp_name in ("_stdout_fp", "_stderr_fp"):
            fp = getattr(self, fp_name)
            if fp is not None:
                try:
                    fp.close()
                except Exception:
                    pass
                setattr(self, fp_name, None)

        self.proc = None
        return rc

    def __enter__(self) -> "VKMacAppDriver":
        self.launch()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.quit()


def _bundle_executable_path(app_path: Path) -> Path:
    exec_name = "VKMac"
    plist_path = app_path / "Contents" / "Info.plist"
    if plist_path.is_file():
        with open(plist_path, "rb") as fp:
            plist_data = plistlib.load(fp)
        raw_exec = plist_data.get("CFBundleExecutable")
        if isinstance(raw_exec, str) and raw_exec.strip():
            exec_name = raw_exec.strip()
    return app_path / "Contents" / "MacOS" / exec_name


def _find_pids_by_exec(exec_real: str) -> Set[int]:
    res = subprocess.run(
        ["/bin/ps", "-axo", "pid=,comm="],
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    if res.returncode != 0:
        return set()
    exec_name = os.path.basename(exec_real)
    pids: Set[int] = set()
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        comm = parts[1].strip()
        if comm == exec_real or (
            os.path.isabs(comm)
            and os.path.basename(comm) == exec_name
            and os.path.realpath(comm) == exec_real
        ):
            pids.add(pid)
    return pids


def launch_via_open(
    app_path: Path,
    env_vars: Dict[str, str],
    extra_args: Optional[List[str]] = None,
    timeout: float = 10.0,
) -> int:
    """Optional `open -n -g -F --env ...` launcher returning resolved PID."""
    app_path = Path(app_path)
    if not app_path.exists():
        raise FileNotFoundError(f"App bundle not found: {app_path}")
    exec_path = _bundle_executable_path(app_path)
    if not exec_path.exists() or not os.access(exec_path, os.X_OK):
        raise FileNotFoundError(f"App executable missing or not executable: {exec_path}")

    exec_real = os.path.realpath(str(exec_path))
    before_pids = _find_pids_by_exec(exec_real)

    cmd: List[str] = ["/usr/bin/open", "-n", "-g", "-F"]
    for k, v in env_vars.items():
        cmd.extend(["--env", f"{k}={v}"])
    cmd.append(str(app_path))
    if extra_args:
        cmd.append("--args")
        cmd.extend(extra_args)

    start = time.monotonic()
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if res.returncode != 0:
        raise AppLaunchError(f"open failed (rc={res.returncode}): {res.stderr.strip()}")

    poll_deadline = max(start + timeout, time.monotonic() + 2.0)
    while time.monotonic() < poll_deadline:
        after_pids = _find_pids_by_exec(exec_real)
        new_pids = sorted(after_pids - before_pids)
        if new_pids:
            return int(new_pids[-1])
        time.sleep(0.05)

    raise AppLaunchError(f"open succeeded for {app_path}, but failed to resolve launched PID for {exec_real}")
