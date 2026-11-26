#!/usr/bin/env python3
"""
Shared test registry, assertions, MockAdminClient, isolated_home() (Keychain + SQLite),
bundle inspection, and Swift UniFFI / HLS probe helpers for vk-mac E2E tests.

Zero third-party dependencies (Python 3 stdlib only).
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, Iterator, List, Optional, Sequence, Tuple


# ---------------------------------------------------------------------------
# Test Registry & Runner CLI
# ---------------------------------------------------------------------------

@dataclass
class TestCaseEntry:
    id: str
    feature: str
    title: str
    tier: int
    fn: Callable[[], None]
    tags: List[str] = field(default_factory=list)


class TestRegistry:
    """Ordered registry of E2E test cases for a tier."""

    def __init__(self, tier: Optional[int] = None) -> None:
        self.tier = tier
        self._cases: List[TestCaseEntry] = []
        self._seen_ids: set[str] = set()

    def add(self, entry: TestCaseEntry) -> None:
        if entry.id in self._seen_ids:
            raise ValueError(f"Duplicate test case ID: {entry.id}")
        self._seen_ids.add(entry.id)
        self._cases.append(entry)

    def test_case(
        self,
        id: str,
        feature: str,
        title: str,
        tier: Optional[int] = None,
        tags: Optional[Sequence[str]] = None,
    ) -> Callable[[Callable[[], None]], Callable[[], None]]:
        resolved_tier = tier if tier is not None else (self.tier if self.tier is not None else 0)

        def decorator(fn: Callable[[], None]) -> Callable[[], None]:
            self.add(
                TestCaseEntry(
                    id=id,
                    feature=feature,
                    title=title,
                    tier=resolved_tier,
                    fn=fn,
                    tags=list(tags or []),
                )
            )
            return fn

        return decorator

    @property
    def cases(self) -> List[TestCaseEntry]:
        return list(self._cases)


def test_case(
    id: str,
    feature: str,
    title: str,
    tier: int,
    tags: Optional[Sequence[str]] = None,
    registry: Optional[TestRegistry] = None,
) -> Callable[[Callable[[], None]], Callable[[], None]]:
    """Decorator attaching metadata to a test function and optionally registering it."""
    def decorator(fn: Callable[[], None]) -> Callable[[], None]:
        entry = TestCaseEntry(
            id=id,
            feature=feature,
            title=title,
            tier=tier,
            fn=fn,
            tags=list(tags or []),
        )
        setattr(fn, "_e2e_test_case", entry)
        if registry is not None:
            registry.add(entry)
        return fn

    return decorator


def run_tier_cli(
    tier: int,
    registry: TestRegistry,
    argv: Optional[List[str]] = None,
) -> int:
    parser = argparse.ArgumentParser(description=f"Run E2E Tier {tier} tests")
    parser.add_argument("--list", action="store_true", help="List test cases without executing")
    parser.add_argument("--json", action="store_true", help="Emit JSON output with --list")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print verbose failure tracebacks")
    parser.add_argument("--filter", default="", help="Substring filter on id/feature/title/tag")
    args = parser.parse_args(argv)

    cases = registry.cases
    if args.filter:
        needle = args.filter.lower()
        cases = [
            c
            for c in cases
            if needle in c.id.lower()
            or needle in c.feature.lower()
            or needle in c.title.lower()
            or any(needle in t.lower() for t in c.tags)
        ]

    if args.list:
        if args.json:
            payload = {
                "tier": tier,
                "count": len(cases),
                "cases": [
                    {
                        "id": c.id,
                        "feature": c.feature,
                        "title": c.title,
                        "tags": c.tags,
                    }
                    for c in cases
                ],
            }
            print(json.dumps(payload, indent=2))
        else:
            print(f"Tier {tier}: {len(cases)} test cases")
            for c in cases:
                tag_str = f" [{', '.join(c.tags)}]" if c.tags else ""
                print(f"  {c.id} ({c.feature}): {c.title}{tag_str}")
        return 0

    mock_url = os.environ.get("E2E_MOCK_URL") or os.environ.get("E2E_MOCK_BASE_URL")
    admin = MockAdminClient(mock_url) if mock_url else None
    verbose = args.verbose or os.environ.get("E2E_VERBOSE") == "1"

    passed = 0
    failed = 0
    for c in cases:
        t0 = time.monotonic()
        try:
            if admin is not None:
                admin.reset()
            c.fn()
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            print(f"[PASS] {c.id} ({c.feature}): {c.title} ({elapsed_ms}ms)", flush=True)
            passed += 1
        except Exception as exc:
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            print(f"[FAIL] {c.id} ({c.feature}): {c.title} ({elapsed_ms}ms)", flush=True)
            print(f"  {exc}", flush=True)
            if verbose:
                tb = traceback.format_exc()
                for line in tb.rstrip().splitlines():
                    print(f"    {line}", flush=True)
            failed += 1

    total = passed + failed
    print(f"Tier {tier}: {passed}/{total} passed, {failed} failed", flush=True)
    return 0 if (failed == 0 and total > 0) else 1


# ---------------------------------------------------------------------------
# Mock Server Admin Client
# ---------------------------------------------------------------------------

class MockAdminClient:
    """Proxy-safe urllib client for mock_server.py /__admin/* endpoints."""

    def __init__(self, base_url: Optional[str] = None, timeout: float = 10.0) -> None:
        resolved = base_url or os.environ.get("E2E_MOCK_URL") or os.environ.get("E2E_MOCK_BASE_URL")
        if not resolved:
            raise ValueError("Mock server base_url not provided and E2E_MOCK_URL is unset")
        self.base_url = resolved.rstrip("/")
        self.timeout = timeout
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _request(self, method: str, path: str, body: Optional[Any] = None) -> Tuple[int, Any]:
        url = f"{self.base_url}{path}"
        data: Optional[bytes] = None
        headers: Dict[str, str] = {}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as err:
            raw = err.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else None
            except Exception:
                parsed = raw
            raise RuntimeError(f"Admin {method} {path} returned HTTP {err.code}: {parsed}") from err

    def health(self) -> Dict[str, Any]:
        _, data = self._request("GET", "/__admin/health")
        return data

    def reset(self) -> Dict[str, Any]:
        _, data = self._request("POST", "/__admin/reset", {})
        return data

    def set_scenario(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        _, data = self._request("POST", "/__admin/scenario", payload)
        return data

    def push_lp(self, updates: List[Any]) -> Dict[str, Any]:
        _, data = self._request("POST", "/__admin/push_lp", {"updates": updates})
        return data

    def get_requests(
        self,
        vk_method: Optional[str] = None,
        path_prefix: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        params: Dict[str, str] = {}
        if vk_method:
            params["vk_method"] = vk_method
        if path_prefix:
            params["path_prefix"] = path_prefix
        qs = f"?{urllib.parse.urlencode(params)}" if params else ""
        _, data = self._request("GET", f"/__admin/requests{qs}")
        return list(data.get("requests", []))

    def clear_requests(self) -> Dict[str, Any]:
        _, data = self._request("DELETE", "/__admin/requests")
        return data

    def get_state(self) -> Dict[str, Any]:
        _, data = self._request("GET", "/__admin/state")
        return data


# ---------------------------------------------------------------------------
# Isolated HOME, Keychain (-p ""), and SQLite Inspection
# ---------------------------------------------------------------------------

def _run_security(args: List[str], home_dir: Path, timeout: float = 15.0) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["HOME"] = str(home_dir)
    return subprocess.run(
        ["/usr/bin/security", *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class IsolatedEnv:
    """Isolated temporary HOME with pre-initialized empty-password login.keychain-db."""

    def __init__(self, root_dir: Path) -> None:
        self.home = root_dir
        self.data_dir = root_dir / "Library" / "Application Support" / "VKMac"
        self.keychain_dir = root_dir / "Library" / "Keychains"
        self.keychain_path = self.keychain_dir / "login.keychain-db"
        self.cache_db = self.data_dir / "cache.db"
        self.oauth_config_json = self.data_dir / "oauth_config.json"

    def init_keychain(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.keychain_dir.mkdir(parents=True, exist_ok=True)
        kc = str(self.keychain_path)

        cmds = [
            ["create-keychain", "-p", "", kc],
            ["set-keychain-settings", kc],
            ["unlock-keychain", "-p", "", kc],
            ["list-keychains", "-d", "user", "-s", kc],
            ["default-keychain", "-d", "user", "-s", kc],
        ]
        for cmd in cmds:
            res = _run_security(cmd, self.home)
            if res.returncode != 0:
                raise RuntimeError(
                    f"security {' '.join(cmd)} failed (rc={res.returncode}): {res.stderr.strip()}"
                )

    def env(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        out = os.environ.copy()
        out["HOME"] = str(self.home)
        if extra:
            for k, v in extra.items():
                if v is None:
                    out.pop(k, None)
                else:
                    out[k] = str(v)
        return out

    def keychain_find(
        self,
        service: str = "com.vkmac.client",
        account: Optional[str] = None,
    ) -> Tuple[bool, int, str]:
        """Inspect keychain item WITHOUT -w (avoids macOS cross-binary ACL prompt hangs)."""
        args = ["find-generic-password", "-s", service]
        if account is not None:
            args.extend(["-a", account])
        args.append(str(self.keychain_path))
        res = _run_security(args, self.home)
        combined = (res.stdout or "") + (res.stderr or "")
        return res.returncode == 0, res.returncode, combined.strip()

    def keychain_set(
        self,
        service: str,
        account: str,
        secret: str,
    ) -> None:
        res = _run_security(
            ["add-generic-password", "-U", "-s", service, "-a", account, "-w", secret, str(self.keychain_path)],
            self.home,
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"keychain_set failed (rc={res.returncode}): {res.stderr.strip()}"
            )

    def keychain_delete(
        self,
        service: str = "com.vkmac.client",
        account: Optional[str] = None,
    ) -> int:
        args = ["delete-generic-password", "-s", service]
        if account is not None:
            args.extend(["-a", account])
        args.append(str(self.keychain_path))
        res = _run_security(args, self.home)
        return res.returncode

    def sqlite_query(
        self,
        sql: str,
        params: Sequence[Any] = (),
        db_path: Optional[Path] = None,
    ) -> List[Tuple[Any, ...]]:
        target = db_path or self.cache_db
        if not target.exists():
            raise FileNotFoundError(f"SQLite DB not found: {target}")
        conn = sqlite3.connect(f"file:{target}?mode=ro", uri=True)
        try:
            cur = conn.execute(sql, tuple(params))
            return cur.fetchall()
        finally:
            conn.close()

    def sqlite_tables(self, db_path: Optional[Path] = None) -> List[str]:
        rows = self.sqlite_query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            db_path=db_path,
        )
        return [str(r[0]) for r in rows]

    def sqlite_user_version(self, db_path: Optional[Path] = None) -> int:
        rows = self.sqlite_query("PRAGMA user_version", db_path=db_path)
        return int(rows[0][0]) if rows else 0


@contextmanager
def isolated_home(keep: bool = False) -> Iterator[IsolatedEnv]:
    """Create an isolated temporary HOME with a pre-initialized empty-password login.keychain-db."""
    tmp = Path(tempfile.mkdtemp(prefix="vkmac_e2e_home_")).resolve()
    iso = IsolatedEnv(tmp)
    try:
        iso.init_keychain()
        yield iso
    finally:
        keep_env = keep or (os.environ.get("E2E_KEEP_TMP") == "1")
        if not keep_env:
            shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Bundle, Codesign, otool, and Plist Helpers
# ---------------------------------------------------------------------------

def verify_codesign(target_path: Path) -> Tuple[bool, str]:
    res = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(target_path)],
        capture_output=True,
        text=True,
        timeout=30.0,
    )
    return res.returncode == 0, (res.stdout + res.stderr).strip()


def otool_deps(binary_path: Path) -> List[str]:
    res = subprocess.run(
        ["/usr/bin/otool", "-L", str(binary_path)],
        capture_output=True,
        text=True,
        check=True,
        timeout=15.0,
    )
    deps: List[str] = []
    for line in res.stdout.splitlines()[1:]:
        stripped = line.strip()
        if stripped:
            deps.append(stripped.split(" (", 1)[0])
    return deps


def otool_rpaths(binary_path: Path) -> List[str]:
    res = subprocess.run(
        ["/usr/bin/otool", "-l", str(binary_path)],
        capture_output=True,
        text=True,
        check=True,
        timeout=15.0,
    )
    rpaths: List[str] = []
    lines = res.stdout.splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for j in range(i + 1, min(i + 6, len(lines))):
                m = re.search(r"path\s+(.+?)\s+\(offset", lines[j])
                if m:
                    rpaths.append(m.group(1))
                    break
    return rpaths


def verify_plist(plist_path: Path) -> Tuple[bool, str]:
    res = subprocess.run(
        ["/usr/bin/plutil", "-lint", str(plist_path)],
        capture_output=True,
        text=True,
        timeout=15.0,
    )
    return res.returncode == 0, (res.stdout + res.stderr).strip()


def read_plist(plist_path: Path) -> Dict[str, Any]:
    with open(plist_path, "rb") as fp:
        data = plistlib.load(fp)
    if not isinstance(data, dict):
        raise ValueError(f"Expected dict plist at {plist_path}")
    return data


# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

def assert_eq(actual: Any, expected: Any, msg: str = "") -> None:
    if actual != expected:
        prefix = f"{msg}: " if msg else ""
        raise AssertionError(f"{prefix}expected {expected!r}, got {actual!r}")


def assert_ne(actual: Any, unexpected: Any, msg: str = "") -> None:
    if actual == unexpected:
        prefix = f"{msg}: " if msg else ""
        raise AssertionError(f"{prefix}expected value != {unexpected!r}")


def assert_true(cond: Any, msg: str = "Condition was falsy") -> None:
    if not cond:
        raise AssertionError(msg)


def assert_in(member: Any, container: Any, msg: str = "") -> None:
    if member not in container:
        prefix = f"{msg}: " if msg else ""
        raise AssertionError(f"{prefix}{member!r} not found in {container!r}")


def assert_raises(exc_type: type, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> BaseException:
    try:
        fn(*args, **kwargs)
    except exc_type as exc:
        return exc
    raise AssertionError(f"Expected {exc_type.__name__} to be raised by {fn!r}")


def assert_rate_limit(
    requests: Sequence[Dict[str, Any]],
    max_per_sec: float = 3.0,
    window_sec: float = 1.0,
    tolerance: float = 0.05,
) -> None:
    """Assert sliding-window request rate <= max_per_sec using monotonic timestamps."""
    timestamps = sorted(float(r["timestamp"]) for r in requests)
    max_in_window = int(max_per_sec * window_sec)
    if len(timestamps) <= max_in_window:
        return
    min_span = max(0.0, window_sec - tolerance)
    for i in range(len(timestamps) - max_in_window):
        span = timestamps[i + max_in_window] - timestamps[i]
        if span < min_span:
            raise AssertionError(
                f"Rate limit violated: {max_in_window + 1} requests within {span:.4f}s "
                f"(minimum allowed span for {max_per_sec} req/s is {min_span:.4f}s)"
            )


# ---------------------------------------------------------------------------
# Swift Harness & HLS Probe Invokers
# ---------------------------------------------------------------------------

def default_e2e_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def resolve_harness_bin(harness_bin: Optional[Path] = None) -> Path:
    if harness_bin is not None:
        return Path(harness_bin)
    env_bin = os.environ.get("E2E_HARNESS_BIN")
    if env_bin:
        return Path(env_bin)
    return default_e2e_dir() / "harness" / "bin" / "vk_e2e_harness"


def resolve_hls_probe_bin(probe_bin: Optional[Path] = None) -> Path:
    if probe_bin is not None:
        return Path(probe_bin)
    env_bin = os.environ.get("E2E_HLS_PROBE_BIN")
    if env_bin:
        return Path(env_bin)
    return default_e2e_dir() / "harness" / "bin" / "hls_probe"


def run_harness(
    payload: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    timeout: float = 30.0,
    harness_bin: Optional[Path] = None,
) -> Tuple[int, Dict[str, Any], str, str]:
    bin_path = resolve_harness_bin(harness_bin)
    if not bin_path.exists():
        raise FileNotFoundError(
            f"vk_e2e_harness binary not found at {bin_path}. Run tests/e2e/harness/build_harness.sh first."
        )
    run_env = env if env is not None else os.environ.copy()
    raw_input = json.dumps(payload)
    proc = subprocess.run(
        [str(bin_path)],
        input=raw_input,
        env=run_env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    parsed: Dict[str, Any] = {}
    if proc.stdout.strip():
        last_line = proc.stdout.strip().splitlines()[-1]
        try:
            parsed = json.loads(last_line)
        except json.JSONDecodeError:
            parsed = {"ok": False, "error_kind": "HarnessInvalidJSON", "raw_stdout": proc.stdout}
    return proc.returncode, parsed, proc.stdout, proc.stderr


def run_hls_probe(
    url: str,
    timeout: float = 15.0,
    probe_bin: Optional[Path] = None,
) -> Tuple[int, Dict[str, Any], str, str]:
    bin_path = resolve_hls_probe_bin(probe_bin)
    if not bin_path.exists():
        raise FileNotFoundError(
            f"hls_probe binary not found at {bin_path}. Run tests/e2e/harness/build_harness.sh first."
        )
    proc = subprocess.run(
        [str(bin_path), "--url", url, "--timeout", str(timeout)],
        capture_output=True,
        text=True,
        timeout=max(30.0, timeout + 20.0),
    )
    parsed: Dict[str, Any] = {}
    if proc.stdout.strip():
        parsed = json.loads(proc.stdout.strip().splitlines()[-1])
    return proc.returncode, parsed, proc.stdout, proc.stderr


def check_window(
    pid: int,
    probe_bin: Optional[Path] = None,
) -> Tuple[int, Dict[str, Any]]:
    bin_path = resolve_hls_probe_bin(probe_bin)
    if not bin_path.exists():
        raise FileNotFoundError(f"hls_probe binary not found at {bin_path}")
    proc = subprocess.run(
        [str(bin_path), "--check-window", str(pid)],
        capture_output=True,
        text=True,
        timeout=30.0,
    )
    parsed: Dict[str, Any] = {}
    if proc.stdout.strip():
        parsed = json.loads(proc.stdout.strip().splitlines()[-1])
    return proc.returncode, parsed
