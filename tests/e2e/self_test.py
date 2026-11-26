#!/usr/bin/env python3
"""
Self-test for Milestone E2E-M1 test infrastructure under tests/e2e/.

Validates:
1. Required files, executable permissions, bash -n, py_compile, swiftc -parse
2. harness/build_harness.sh (--if-available) and hls_probe binary
3. Live mock_server.py lifecycle, readiness banner, clean SIGTERM during /lp wait=25
4. Every OAuth, VK API v5.199, error/latency/HTTP-500, rate-limit, Long Poll, Media, and /__admin/* endpoint
5. Live AVFoundation + MediaPlayer playback of mock HLS playlist via hls_probe
6. e2e_common.isolated_home() Keychain & SQLite isolation + app_driver.py checks
7. run_e2e.sh CLI modes (--help, --list, invalid args, sandboxed non-verbose --self-test & --tier) and tier manifest coverage (--strict-tiers)
"""

from __future__ import annotations

import argparse
from collections import Counter
import http.client
import json
import os
from pathlib import Path
import plistlib
import py_compile
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple


E2E_DIR = Path(__file__).resolve().parent
REPO_ROOT = E2E_DIR.parent.parent
LIB_DIR = E2E_DIR / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from app_driver import VKMacAppDriver, launch_via_open  # noqa: E402
from e2e_common import (  # noqa: E402
    MockAdminClient,
    assert_eq,
    assert_in,
    assert_raises,
    assert_rate_limit,
    assert_true,
    isolated_home,
    run_hls_probe,
)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def _http_call(
    method: str,
    url: str,
    data: Optional[bytes] = None,
    headers: Optional[Dict[str, str]] = None,
    follow_redirects: bool = True,
    timeout: float = 10.0,
) -> Tuple[int, Dict[str, str], bytes]:
    handlers: List[Any] = [urllib.request.ProxyHandler({})]
    if not follow_redirects:
        handlers.append(_NoRedirect())
    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with opener.open(req, timeout=timeout) as resp:
            hdrs = {k.lower(): v for k, v in resp.headers.items()}
            return resp.status, hdrs, resp.read()
    except urllib.error.HTTPError as err:
        hdrs = {k.lower(): v for k, v in err.headers.items()}
        return err.code, hdrs, err.read()


def _http_json(
    method: str,
    url: str,
    form: Optional[Dict[str, Any]] = None,
    json_body: Optional[Any] = None,
) -> Tuple[int, Any]:
    headers: Dict[str, str] = {}
    body: Optional[bytes] = None
    if json_body is not None:
        body = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif form is not None:
        body = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    status, _, raw = _http_call(method, url, data=body, headers=headers)
    return status, json.loads(raw.decode("utf-8")) if raw else None


def check_static_and_syntax() -> None:
    required_files = [
        E2E_DIR / "run_e2e.sh",
        E2E_DIR / "mock_server.py",
        E2E_DIR / "self_test.py",
        E2E_DIR / "README.md",
        E2E_DIR / "lib" / "__init__.py",
        E2E_DIR / "lib" / "e2e_common.py",
        E2E_DIR / "lib" / "app_driver.py",
        E2E_DIR / "harness" / "build_harness.sh",
        E2E_DIR / "harness" / "main.swift",
        E2E_DIR / "harness" / "hls_probe.swift",
    ]
    for path in required_files:
        assert_true(path.is_file(), f"Missing required E2E-M1 file: {path}")

    for exe in (E2E_DIR / "run_e2e.sh", E2E_DIR / "harness" / "build_harness.sh"):
        assert_true(os.access(exe, os.X_OK), f"Script must be executable: {exe}")
        res = subprocess.run(["/bin/bash", "-n", str(exe)], capture_output=True, text=True, timeout=10.0)
        assert_eq(res.returncode, 0, f"bash -n failed for {exe}: {res.stderr}")

    for py_file in sorted(E2E_DIR.rglob("*.py")):
        py_compile.compile(str(py_file), doraise=True)

    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    arch = os.uname().machine
    target = f"{arch}-apple-macosx13.0"
    for swift_file, extra in [
        (E2E_DIR / "harness" / "main.swift", ["-parse-as-library"]),
        (E2E_DIR / "harness" / "hls_probe.swift", []),
    ]:
        cmd = ["swiftc", "-parse", *extra, "-sdk", sdk, "-target", target, str(swift_file)]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=60.0)
        assert_eq(res.returncode, 0, f"swiftc -parse failed for {swift_file}: {res.stderr}")


def check_harness_build() -> None:
    build_sh = E2E_DIR / "harness" / "build_harness.sh"
    res = subprocess.run([str(build_sh), "--if-available"], capture_output=True, text=True, timeout=180.0)
    assert_eq(res.returncode, 0, f"build_harness.sh --if-available failed: {res.stderr}\n{res.stdout}")

    hls_bin = E2E_DIR / "harness" / "bin" / "hls_probe"
    assert_true(hls_bin.is_file() and os.access(hls_bin, os.X_OK), "hls_probe binary missing or not executable")

    # Verify incremental build skips redundant recompile and preserves mtime
    mtime_before = hls_bin.stat().st_mtime_ns
    res2 = subprocess.run([str(build_sh), "--if-available"], capture_output=True, text=True, timeout=60.0)
    assert_eq(res2.returncode, 0, f"second build_harness.sh --if-available failed: {res2.stderr}\n{res2.stdout}")
    assert_in("hls_probe is up to date", res2.stdout)
    assert_eq(hls_bin.stat().st_mtime_ns, mtime_before, "hls_probe mtime changed on incremental up-to-date check")

    help_res = subprocess.run([str(hls_bin), "--help"], capture_output=True, text=True, timeout=30.0)
    assert_eq(help_res.returncode, 0, f"hls_probe --help failed: {help_res.stderr}")

    # Verify CLI error handling for empty --url and invalid --timeout
    empty_url_res = subprocess.run([str(hls_bin), "--url", ""], capture_output=True, text=True, timeout=30.0)
    assert_eq(empty_url_res.returncode, 2, f"hls_probe --url '' should exit 2, got {empty_url_res.returncode}")
    assert_eq(empty_url_res.stdout.strip(), "", "hls_probe --url '' should emit empty stdout")
    assert_in("Invalid or empty URL", empty_url_res.stderr)

    bad_to_res = subprocess.run(
        [str(hls_bin), "--timeout", "-1", "--url", "http://127.0.0.1/a.m3u8"],
        capture_output=True,
        text=True,
        timeout=30.0,
    )
    assert_eq(bad_to_res.returncode, 2, f"hls_probe --timeout -1 should exit 2, got {bad_to_res.returncode}")

    # Verify strict mode fails cleanly if UniFFI artifacts are absent
    cvk_hdr = REPO_ROOT / "VKMac" / "Generated" / "CVkCore" / "vk_coreFFI.h"
    if not cvk_hdr.exists():
        strict_res = subprocess.run([str(build_sh)], capture_output=True, text=True, timeout=180.0)
        assert_true(strict_res.returncode != 0, "build_harness.sh strict mode must fail when UniFFI artifacts missing")


def start_mock_subprocess() -> Tuple[subprocess.Popen, str, int]:
    proc = subprocess.Popen(
        [sys.executable, str(E2E_DIR / "mock_server.py"), "--host", "127.0.0.1", "--port", "0", "--quiet"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    line = proc.stdout.readline()
    assert_true(bool(line), "mock_server.py did not emit readiness banner")
    banner = json.loads(line)
    assert_eq(banner.get("status"), "ready", "readiness status")
    port = int(banner["port"])
    base_url = str(banner["base_url"])
    assert_true(port > 0, "ephemeral port must be > 0")
    assert_eq(base_url, f"http://127.0.0.1:{port}", "base_url format")
    return proc, base_url, port


def check_mock_server_and_hls() -> None:
    proc, base_url, _ = start_mock_subprocess()
    try:
        admin = MockAdminClient(base_url)
        health = admin.health()
        assert_eq(health["status"], "ok")

        # 1. OAuth /token flows
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "ok", "password": "pw"},
        )
        assert_eq(st, 200)
        assert_eq(body["access_token"], "vk_e2e_token_10001")
        assert_eq(body["user_id"], 10001)

        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "invalid_client", "username": "ok", "password": "pw"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "invalid_client")

        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "bad_user", "password": "wrong"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "invalid_grant")

        # 2FA challenge + recovery
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "user_2fa", "password": "pw"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "need_validation")
        assert_in("phone_mask", body)
        assert_in("validation_type", body)

        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "user_2fa", "password": "pw", "code": "123456"},
        )
        assert_eq(st, 200)
        assert_eq(body["access_token"], "vk_e2e_token_10001")

        # Captcha challenge + recovery
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "user_captcha", "password": "pw"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "need_captcha")
        assert_in("captcha_sid", body)
        assert_in("captcha_img", body)

        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={
                "grant_type": "password",
                "client_id": "2274003",
                "username": "user_captcha",
                "password": "pw",
                "captcha_sid": body["captcha_sid"],
                "captcha_key": "e2e_ok",
            },
        )
        assert_eq(st, 200)

        # Scenario once flag
        admin.set_scenario({"oauth": {"mode": "need_validation", "once": True}})
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "regular", "password": "pw"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "need_validation")
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "regular", "password": "pw"},
        )
        assert_eq(st, 200)

        # OAuth remaining_count=1 parity
        admin.set_scenario({"oauth": {"mode": "invalid_grant", "remaining_count": 1}})
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "regular", "password": "pw"},
        )
        assert_eq(st, 401)
        assert_eq(body["error"], "invalid_grant")
        st, body = _http_json(
            "POST",
            f"{base_url}/token",
            form={"grant_type": "password", "client_id": "2274003", "username": "regular", "password": "pw"},
        )
        assert_eq(st, 200)

        # /authorize redirect + /blank.html
        st, hdrs, _ = _http_call(
            "GET",
            f"{base_url}/authorize?client_id=2274003&redirect_uri=https://oauth.vk.com/blank.html&state=xyz",
            follow_redirects=False,
        )
        assert_eq(st, 302)
        loc = hdrs.get("location", "")
        assert_true(loc.startswith(f"{base_url}/blank.html#access_token=vk_e2e_token_10001"), f"Unexpected Location: {loc}")
        assert_in("state=xyz", loc)

        st, hdrs, html = _http_call("GET", f"{base_url}/blank.html")
        assert_eq(st, 200)
        assert_in(b"OK", html)

        # 2. VK API v5.199 + duplicate slash normalization
        admin.reset()
        st, body = _http_json("GET", f"{base_url}/method//users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_eq(st, 200)
        assert_eq(body["response"][0]["id"], 10001)

        st, body = _http_json(
            "POST",
            f"{base_url}/method/messages.getConversations",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "offset": 0, "count": 20},
        )
        assert_eq(st, 200)
        assert_eq(body["response"]["count"], 3)
        assert_true(len(body["response"]["profiles"]) >= 2)
        assert_true(len(body["response"]["groups"]) >= 1)

        st, body = _http_json(
            "POST",
            f"{base_url}/method/messages.getHistory",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "peer_id": 20001, "offset": 0, "count": 50},
        )
        assert_eq(st, 200)
        att_types = {
            att["type"]
            for msg in body["response"]["items"]
            for att in msg.get("attachments", [])
        }
        assert_eq(att_types, {"photo", "audio", "doc", "sticker", "link"})

        st, body = _http_json(
            "POST",
            f"{base_url}/method/messages.send",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "peer_id": 20001, "message": "SelfTest Msg", "random_id": 42},
        )
        assert_eq(st, 200)
        new_msg_id = body["response"]
        assert_true(isinstance(new_msg_id, int) and new_msg_id > 0)

        st, body = _http_json(
            "POST",
            f"{base_url}/method/newsfeed.get",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199"},
        )
        assert_eq(st, 200)
        assert_eq(body["response"]["next_from"], "page_2")
        st, body2 = _http_json(
            "POST",
            f"{base_url}/method/newsfeed.get",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "start_from": "page_2"},
        )
        assert_eq(st, 200)
        assert_true("next_from" not in body2["response"])

        # Stateful likes.add / likes.delete
        st, add_res = _http_json(
            "POST",
            f"{base_url}/method/likes.add",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "type": "post", "owner_id": 20001, "item_id": 7001},
        )
        assert_eq(add_res["response"]["likes"], 11)
        st, del_res = _http_json(
            "POST",
            f"{base_url}/method/likes.delete",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "type": "post", "owner_id": 20001, "item_id": 7001},
        )
        assert_eq(del_res["response"]["likes"], 10)

        # audio.get & audio.search
        st, aud = _http_json("POST", f"{base_url}/method/audio.get", form={"access_token": "vk_e2e_token_10001", "v": "5.199"})
        assert_eq(st, 200)
        assert_true(len(aud["response"]["items"]) >= 3)
        assert_true(aud["response"]["items"][0]["url"].endswith("/media/playlist.m3u8"))
        assert_eq(aud["response"]["items"][2]["url"], "")

        st, search_res = _http_json(
            "POST",
            f"{base_url}/method/audio.search",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199", "q": "WAVE"},
        )
        assert_eq(search_res["response"]["count"], 1)
        assert_eq(search_res["response"]["items"][0]["id"], 5002)

        # 3. Error / Latency / HTTP 500 / Token Revocation injection
        for code in (5, 6, 14, 17, 999):
            admin.set_scenario({"api": {"users.get": {"error_code": code, "remaining_count": 1}}})
            _, err_body = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
            assert_eq(err_body["error"]["error_code"], code)
        # Auto-expired after remaining_count=1:
        _, ok_body = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_in("response", ok_body)

        admin.set_scenario({"api": {"*": {"http_status": 500, "remaining_count": 1}}})
        st500, _ = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_eq(st500, 500)

        admin.set_scenario({"api": {"users.get": {"latency_ms": 120, "remaining_count": 1}}})
        t0 = time.monotonic()
        st_lat, _ = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_eq(st_lat, 200)
        assert_true((time.monotonic() - t0) >= 0.10, "latency_ms scenario did not delay response")

        admin.set_scenario({"strict_tokens": True, "revoke_token": "vk_e2e_token_10001"})
        _, rev_body = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_eq(rev_body["error"]["error_code"], 5)

        # 4. Rate-limit request recording check
        admin.reset()
        admin.clear_requests()
        for _ in range(4):
            _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        reqs = admin.get_requests(vk_method="users.get")
        assert_eq(len(reqs), 4)
        assert_raises(AssertionError, assert_rate_limit, reqs, 3.0, 1.0, 0.05)

        # 4b. Regression: atomic API remaining_count=1 under concurrent latency_ms
        admin.reset()
        admin.set_scenario({"api": {"users.get": {"error_code": 6, "remaining_count": 1, "latency_ms": 80}}})
        barrier = threading.Barrier(8)
        conc_errs: List[bool] = []
        conc_lock = threading.Lock()

        def _conc_worker() -> None:
            barrier.wait(timeout=5.0)
            _, c_body = _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
            with conc_lock:
                conc_errs.append("error" in c_body)

        conc_threads = [threading.Thread(target=_conc_worker, daemon=True) for _ in range(8)]
        for th in conc_threads:
            th.start()
        for th in conc_threads:
            th.join(timeout=5.0)
        assert_eq(len(conc_errs), 8, "Not all concurrent workers finished")
        assert_eq(sum(conc_errs), 1, f"Expected exactly 1/8 injected errors under concurrency, got {sum(conc_errs)}/8")

        # Latency-only remaining_count=1 must also expire after 1 call
        admin.set_scenario({"api": {"users.get": {"latency_ms": 100, "remaining_count": 1}}})
        t_lat1 = time.monotonic()
        _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_true((time.monotonic() - t_lat1) >= 0.08, "latency-only remaining_count=1 first call not delayed")
        t_lat2 = time.monotonic()
        _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199")
        assert_true((time.monotonic() - t_lat2) < 0.08, "latency-only remaining_count=1 did not expire after 1 call")

        # 4c. Regression: mixed-latency /__admin/requests arrival ordering & raw //__admin/scenario
        admin.reset()
        admin.set_scenario({"api": {"users.get": {"latency_ms": 150, "remaining_count": 1}}})
        t_slow = threading.Thread(
            target=lambda: _http_json("GET", f"{base_url}/method/users.get?access_token=vk_e2e_token_10001&v=5.199"),
            daemon=True,
        )
        t_slow.start()
        time.sleep(0.03)
        _http_json("GET", f"{base_url}/method/newsfeed.get?access_token=vk_e2e_token_10001&v=5.199")
        t_slow.join(timeout=5.0)
        ordered_reqs = admin.get_requests()
        assert_eq(
            [r["vk_method"] for r in ordered_reqs],
            ["users.get", "newsfeed.get"],
            f"Requests out of arrival order: {ordered_reqs}",
        )
        assert_true(
            ordered_reqs[0]["timestamp"] <= ordered_reqs[1]["timestamp"],
            f"Request timestamps not monotonic: {ordered_reqs}",
        )

        # Raw socket test for POST //__admin/scenario (non-normalized duplicate slash)
        parsed_base = urllib.parse.urlsplit(base_url)
        raw_body = json.dumps({"strict_tokens": False}).encode("utf-8")
        with socket.create_connection((parsed_base.hostname, parsed_base.port), timeout=5.0) as sock:
            sock.sendall(
                (
                    f"POST //__admin/scenario HTTP/1.0\r\n"
                    f"Content-Type: application/json\r\n"
                    f"Content-Length: {len(raw_body)}\r\n\r\n"
                ).encode("ascii")
                + raw_body
            )
            raw_resp = sock.recv(4096)
            assert_in(b"200 OK", raw_resp)

        # 5. Long Poll push & failed: 1..4
        st, lp_srv = _http_json(
            "POST",
            f"{base_url}/method/messages.getLongPollServer",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199"},
        )
        lp_key = lp_srv["response"]["key"]
        lp_ts = lp_srv["response"]["ts"]

        for failed_code in (1, 2, 3, 4):
            admin.set_scenario({"lp": {"failed": failed_code, "once": True}})
            _, lp_err = _http_json("GET", f"{base_url}/lp?act=a_check&key={lp_key}&ts={lp_ts}&wait=1")
            assert_eq(lp_err["failed"], failed_code)
            if failed_code in (2, 3):
                _, lp_srv = _http_json(
                    "POST",
                    f"{base_url}/method/messages.getLongPollServer",
                    form={"access_token": "vk_e2e_token_10001", "v": "5.199"},
                )
                lp_key = lp_srv["response"]["key"]
                lp_ts = lp_srv["response"]["ts"]

        lp_result_box: Dict[str, Any] = {}

        def _bg_lp() -> None:
            _, res = _http_json("GET", f"{base_url}/lp?act=a_check&key={lp_key}&ts={lp_ts}&wait=10")
            lp_result_box["data"] = res

        t = threading.Thread(target=_bg_lp, daemon=True)
        t.start()
        time.sleep(0.15)
        pushed_events = [
            [4, 9001, 1, 20001, int(time.time()), "Live LP Hello"],
            [5, 9001, 1, 20001, int(time.time()), "Live LP Edited"],
            [6, 20001, 9001],
            [7, 20001, 9001],
            [61, 20001, 1],
            [62, 1, 20001],
        ]
        admin.push_lp(pushed_events)
        t.join(timeout=3.0)
        assert_true(not t.is_alive(), "Long Poll request did not wake on push_lp")
        assert_eq(len(lp_result_box["data"]["updates"]), 6)

        # 5b. Regression: concurrent blocked /lp woken by failed: 2 and failed: 3 (once: True)
        for fail_code in (2, 3):
            admin.reset()
            _, srv_c = _http_json(
                "POST",
                f"{base_url}/method/messages.getLongPollServer",
                form={"access_token": "vk_e2e_token_10001", "v": "5.199"},
            )
            c_key = srv_c["response"]["key"]
            c_ts = srv_c["response"]["ts"]
            c_outs: List[Any] = []
            c_lock = threading.Lock()

            def _lp_conc_wait() -> None:
                _, res_c = _http_json("GET", f"{base_url}/lp?act=a_check&key={c_key}&ts={c_ts}&wait=5")
                with c_lock:
                    c_outs.append(res_c)

            lp_threads = [threading.Thread(target=_lp_conc_wait, daemon=True) for _ in range(3)]
            for th in lp_threads:
                th.start()
            time.sleep(0.15)
            admin.set_scenario({"lp": {"failed": fail_code, "once": True}})
            for th in lp_threads:
                th.join(timeout=3.0)
                assert_true(not th.is_alive(), f"Concurrent /lp thread hung on failed={fail_code}")
            assert_eq(c_outs, [{"failed": fail_code}] * 3, f"Concurrent /lp failed={fail_code} mismatch: {c_outs}")

        # Refresh lp_key/lp_ts after concurrent LP tests
        _, lp_srv_after = _http_json(
            "POST",
            f"{base_url}/method/messages.getLongPollServer",
            form={"access_token": "vk_e2e_token_10001", "v": "5.199"},
        )
        lp_key = lp_srv_after["response"]["key"]
        lp_ts = lp_srv_after["response"]["ts"]

        # 6. Media & live hls_probe playback
        st, hdrs, m3u8 = _http_call("GET", f"{base_url}/media/playlist.m3u8")
        assert_eq(st, 200)
        assert_in("mpegurl", hdrs.get("content-type", ""))
        assert_in(b"segment0.ts", m3u8)

        st, hdrs, ts_bytes = _http_call("GET", f"{base_url}/media/segment0.ts")
        assert_eq(st, 200)
        assert_eq(hdrs.get("content-type"), "video/mp2t")
        assert_eq(hdrs.get("accept-ranges"), "bytes")
        assert_eq(len(ts_bytes), 17296)

        st_rng, hdrs_rng, ts_rng = _http_call("GET", f"{base_url}/media/segment0.ts", headers={"Range": "bytes=0-187"})
        assert_eq(st_rng, 206)
        assert_eq(len(ts_rng), 188)
        assert_in("bytes 0-187/17296", hdrs_rng.get("content-range", ""))

        # RFC 9110 suffix range, open-ended range, and 416 unsatisfiable range
        st_suf, hdrs_suf, ts_suf = _http_call("GET", f"{base_url}/media/segment0.ts", headers={"Range": "bytes=-188"})
        assert_eq(st_suf, 206)
        assert_eq(len(ts_suf), 188)
        assert_eq(ts_suf, ts_bytes[-188:])
        assert_eq(hdrs_suf.get("content-range"), "bytes 17108-17295/17296")

        st_open, hdrs_open, ts_open = _http_call("GET", f"{base_url}/media/segment0.ts", headers={"Range": "bytes=17108-"})
        assert_eq(st_open, 206)
        assert_eq(len(ts_open), 188)
        assert_eq(hdrs_open.get("content-range"), "bytes 17108-17295/17296")

        st_416, hdrs_416, _ = _http_call("GET", f"{base_url}/media/segment0.ts", headers={"Range": "bytes=999999-1000500"})
        assert_eq(st_416, 416)
        assert_eq(hdrs_416.get("content-range"), "bytes */17296")

        st, hdrs, png_bytes = _http_call("GET", f"{base_url}/media/avatar.png")
        assert_eq(st, 200)
        assert_eq(hdrs.get("content-type"), "image/png")
        assert_true(png_bytes.startswith(b"\x89PNG\r\n\x1a\n"))

        st, hdrs, jpg_bytes = _http_call("GET", f"{base_url}/media/cover1.jpg")
        assert_eq(st, 200)
        assert_eq(hdrs.get("content-type"), "image/jpeg")
        assert_true(jpg_bytes.startswith(b"\xff\xd8\xff"))

        # Admin state check
        state_snap = admin.get_state()
        assert_eq(state_snap["conversations_count"], 3)

        # Live AVPlayer HLS probe
        rc, probe_json, probe_out, probe_err = run_hls_probe(f"{base_url}/media/playlist.m3u8", timeout=15.0)
        assert_eq(rc, 0, f"hls_probe failed: stdout={probe_out} stderr={probe_err}")
        assert_eq(probe_json["ok"], True)
        assert_eq(probe_json["status"], "readyToPlay")
        assert_true(float(probe_json["duration_sec"]) > 1.5, f"Unexpected duration: {probe_json}")
        assert_eq(probe_json["ended"], True)
        assert_eq(probe_json["now_playing_state"], 1)
        assert_eq(probe_json["remote_commands_registered"], True)

        # 7. Clean SIGTERM shutdown while a /lp wait=25 request is blocked
        lp_stop_box: Dict[str, Any] = {}

        def _bg_lp_block() -> None:
            try:
                st_b, b_body = _http_json("GET", f"{base_url}/lp?act=a_check&key={lp_key}&ts={lp_ts}&wait=25")
                lp_stop_box["status"] = st_b
                lp_stop_box["body"] = b_body
            except Exception as exc:
                lp_stop_box["exc"] = str(exc)

        t_blk = threading.Thread(target=_bg_lp_block, daemon=True)
        t_blk.start()
        time.sleep(0.15)
        t_sig = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        rc_srv = proc.wait(timeout=4.0)
        elapsed_stop = time.monotonic() - t_sig
        assert_eq(rc_srv, 0, f"mock_server.py exited {rc_srv} on SIGTERM")
        assert_true(elapsed_stop < 3.0, f"SIGTERM took too long ({elapsed_stop:.2f}s) with active /lp")
        t_blk.join(timeout=2.0)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=3.0)


def _build_dummy_app_bundle(tmp_root: Path, bundle_id: str = "com.vkmac.client.selftest") -> Path:
    app_dir = tmp_root / "VKMac.app"
    macos_dir = app_dir / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)
    src_path = tmp_root / "dummy_app.m"
    bin_path = macos_dir / "VKMac"
    plist_path = app_dir / "Contents" / "Info.plist"

    src_path.write_text(
        """#import <Cocoa/Cocoa.h>
#include <signal.h>
#include <unistd.h>

static void handle_term(int sig) {
    (void)sig;
    _exit(0);
}

@interface SelfTestDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@end

@implementation SelfTestDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSRect frame = NSMakeRect(100, 100, 320, 240);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [self.window setTitle:@"VKMac SelfTest"];
    [self.window makeKeyAndOrderFront:nil];
}
@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    signal(SIGTERM, handle_term);
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        SelfTestDelegate *delegate = [[SelfTestDelegate alloc] init];
        [app setDelegate:delegate];
        [app finishLaunching];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
""",
        encoding="utf-8",
    )

    with open(plist_path, "wb") as fp:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "VKMac",
                "CFBundleIdentifier": bundle_id,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "VKMac",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0",
                "NSPrincipalClass": "NSApplication",
            },
            fp,
        )

    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    arch = os.uname().machine
    target = f"{arch}-apple-macosx13.0"
    compile_res = subprocess.run(
        [
            "clang",
            "-O0",
            "-fobjc-arc",
            "-isysroot",
            sdk,
            "-target",
            target,
            "-framework",
            "Cocoa",
            str(src_path),
            "-o",
            str(bin_path),
        ],
        capture_output=True,
        text=True,
        timeout=60.0,
    )
    assert_eq(compile_res.returncode, 0, f"clang failed compiling dummy AppKit app: {compile_res.stderr}")
    return app_dir


def check_isolated_home_and_app_driver() -> None:
    # Verify real user keychain has no polluted com.vkmac.client test entry before/after
    real_before = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", "com.vkmac.client", "-a", "e2e_self_test_probe"],
        capture_output=True,
        text=True,
        timeout=10.0,
    )
    assert_eq(real_before.returncode, 44, "Real user keychain unexpectedly contains test item before test")

    with isolated_home() as iso:
        assert_true(iso.keychain_path.is_file(), "Isolated login.keychain-db was not created")
        found_before, rc_before, _ = iso.keychain_find("com.vkmac.client", "e2e_self_test_probe")
        assert_true(not found_before and rc_before == 44, f"Expected rc=44 before insert, got {rc_before}")

        iso.keychain_set("com.vkmac.client", "e2e_self_test_probe", "tok_isolated_123")
        found_after, rc_after, meta = iso.keychain_find("com.vkmac.client", "e2e_self_test_probe")
        assert_true(found_after and rc_after == 0, f"Expected item in isolated keychain, got rc={rc_after}: {meta}")

        del_rc = iso.keychain_delete("com.vkmac.client", "e2e_self_test_probe")
        assert_eq(del_rc, 0)
        found_gone, rc_gone, _ = iso.keychain_find("com.vkmac.client", "e2e_self_test_probe")
        assert_true(not found_gone and rc_gone == 44)

        # SQLite read-only query helper check
        iso.data_dir.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(iso.cache_db))
        conn.execute("PRAGMA user_version = 1")
        conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        conn.execute("INSERT INTO users (id, name) VALUES (10001, 'Pavel')")
        conn.commit()
        conn.close()

        assert_eq(iso.sqlite_user_version(), 1)
        assert_eq(iso.sqlite_tables(), ["users"])
        rows = iso.sqlite_query("SELECT name FROM users WHERE id = ?", (10001,))
        assert_eq(rows, [("Pavel",)])

    real_after = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", "com.vkmac.client", "-a", "e2e_self_test_probe"],
        capture_output=True,
        text=True,
        timeout=10.0,
    )
    assert_eq(real_after.returncode, 44, "Real user keychain was polluted by isolated_home test!")

    # App driver error handling & bounded osascript check
    missing_app = Path(tempfile.gettempdir()) / "nonexistent_vkmac_e2e.app"
    drv = VKMacAppDriver(missing_app)
    assert_raises(FileNotFoundError, drv.launch)
    rc_os, out_os, _ = drv.run_applescript('return "ok"', timeout=3.0)
    assert_eq(rc_os, 0)
    assert_eq(out_os, "ok")

    # Live temporary AppKit .app bundle test (wait_ready, wait_for_window, quit, DEVNULL, launch_via_open)
    bundle_id = "com.vkmac.client.selftest"
    with tempfile.TemporaryDirectory(prefix="vkmac_e2e_app_") as tmp_str:
        tmp_root = Path(tmp_str)
        dummy_app = _build_dummy_app_bundle(tmp_root, bundle_id=bundle_id)

        # 1. With log_dir
        drv_live = VKMacAppDriver(
            dummy_app,
            log_dir=tmp_root / "logs",
            expected_bundle_id=bundle_id,
        )
        pid = 0
        try:
            pid = drv_live.launch()
            assert_true(pid > 0, f"Expected positive PID, got {pid}")
            assert_true(drv_live.is_running(), "Dummy app not running immediately after launch")
            ready = drv_live.wait_ready(timeout=20.0)
            assert_eq(ready["pid"], pid)
            assert_eq(ready["bundle_id"], bundle_id)
            assert_eq(ready["type"], "Foreground")
            win = drv_live.wait_for_window(timeout=10.0)
            assert_eq(win["ok"], True)
            assert_true(int(win["window_count"]) >= 1, f"Expected >= 1 window, got {win}")
        finally:
            drv_live.quit(timeout=5.0)
        assert_true(not drv_live.is_running(), "Dummy app still running after quit()")

        # 2. With log_dir=None (subprocess.DEVNULL)
        drv_devnull = VKMacAppDriver(
            dummy_app,
            log_dir=None,
            expected_bundle_id=bundle_id,
        )
        try:
            pid2 = drv_devnull.launch()
            assert_true(pid2 > 0)
            ready2 = drv_devnull.wait_ready(timeout=20.0)
            assert_eq(ready2["bundle_id"], bundle_id)
        finally:
            drv_devnull.quit(timeout=5.0)
        assert_true(not drv_devnull.is_running(), "Dummy DEVNULL app still running after quit()")

        # 3. launch_via_open PID resolution
        opened_pid = 0
        try:
            opened_pid = launch_via_open(dummy_app, {"VK_E2E_SELFTEST": "1"}, timeout=15.0)
            assert_true(opened_pid > 0, f"launch_via_open returned invalid PID: {opened_pid}")
            assert_true(opened_pid != pid, f"launch_via_open returned stale PID {opened_pid}")
        finally:
            if opened_pid > 0:
                try:
                    os.kill(opened_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    try:
                        os.kill(opened_pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                else:
                    try:
                        os.kill(opened_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


def _smoke_test_run_e2e_cli() -> None:
    runner_src = E2E_DIR / "run_e2e.sh"

    # 1. Direct non-recursive CLI checks on real run_e2e.sh
    help_res = subprocess.run([str(runner_src), "--help"], capture_output=True, text=True, timeout=15.0)
    assert_eq(help_res.returncode, 0, f"run_e2e.sh --help failed: {help_res.stderr}")
    assert_in("Modes", help_res.stdout)
    assert_in("--self-test", help_res.stdout)

    list_res = subprocess.run([str(runner_src), "--list"], capture_output=True, text=True, timeout=30.0)
    assert_eq(list_res.returncode, 0, f"run_e2e.sh --list failed: {list_res.stderr}")
    assert_in("E2E Test Suite", list_res.stdout)

    noarg_res = subprocess.run([str(runner_src)], capture_output=True, text=True, timeout=15.0)
    assert_eq(noarg_res.returncode, 2, f"run_e2e.sh without mode should exit 2, got {noarg_res.returncode}")

    bad_tier_res = subprocess.run([str(runner_src), "--tier", "99"], capture_output=True, text=True, timeout=15.0)
    assert_eq(bad_tier_res.returncode, 2, f"run_e2e.sh --tier 99 should exit 2, got {bad_tier_res.returncode}")

    # 2. Sandboxed /tmp checks under macOS /bin/bash (3.2) for non-verbose & verbose --self-test and --tier
    with tempfile.TemporaryDirectory(prefix="vkmac_e2e_runner_smoke_") as tmp_str:
        tmp_root = Path(tmp_str)
        sandbox_e2e = tmp_root / "tests" / "e2e"
        (sandbox_e2e / "harness").mkdir(parents=True)
        run_tmp_parent = tmp_root / "run_tmp"
        run_tmp_parent.mkdir(parents=True)

        sandbox_runner = sandbox_e2e / "run_e2e.sh"
        shutil.copy2(runner_src, sandbox_runner)
        shutil.copy2(E2E_DIR / "mock_server.py", sandbox_e2e / "mock_server.py")

        stub_build = sandbox_e2e / "harness" / "build_harness.sh"
        stub_build.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        stub_build.chmod(0o755)

        stub_self_test = sandbox_e2e / "self_test.py"
        stub_self_test.write_text(
            "import json, os, sys\n"
            "print(json.dumps({'argv': sys.argv[1:], 'e2e_verbose': os.environ.get('E2E_VERBOSE')}))\n",
            encoding="utf-8",
        )

        for t_num in (1, 2, 3, 4):
            t_dir = sandbox_e2e / "tiers" / f"tier{t_num}"
            t_dir.mkdir(parents=True)
            (t_dir / "run_tier.py").write_text(
                "import json, os, pathlib, sys\n"
                "assert os.environ.get('VK_API_BASE_URL', '').endswith('/method/')\n"
                "assert os.environ.get('VK_OAUTH_TOKEN_URL', '').endswith('/token')\n"
                "assert os.environ.get('VK_OAUTH_AUTHORIZE_URL', '').endswith('/authorize')\n"
                "assert pathlib.Path(os.environ['E2E_RUN_TMP']).is_dir()\n"
                "print(json.dumps({'tier': " + str(t_num) + ", 'argv': sys.argv[1:], 'e2e_verbose': os.environ.get('E2E_VERBOSE')}))\n",
                encoding="utf-8",
            )

        sb_env = os.environ.copy()
        sb_env["TMPDIR"] = str(run_tmp_parent)

        # 2a. --self-test WITHOUT --verbose (must not hit Bash 3.2 unbound variable)
        st_plain = subprocess.run(
            ["/bin/bash", str(sandbox_runner), "--self-test"],
            env=sb_env,
            capture_output=True,
            text=True,
            timeout=15.0,
        )
        assert_eq(st_plain.returncode, 0, f"Sandboxed --self-test failed: {st_plain.stderr}\n{st_plain.stdout}")
        st_plain_json = json.loads(st_plain.stdout.strip().splitlines()[-1])
        assert_eq(st_plain_json, {"argv": [], "e2e_verbose": "0"})

        # 2b. --self-test WITH --verbose
        st_verb = subprocess.run(
            ["/bin/bash", str(sandbox_runner), "--self-test", "--verbose"],
            env=sb_env,
            capture_output=True,
            text=True,
            timeout=15.0,
        )
        assert_eq(st_verb.returncode, 0, f"Sandboxed --self-test --verbose failed: {st_verb.stderr}\n{st_verb.stdout}")
        st_verb_json = json.loads(st_verb.stdout.strip().splitlines()[-1])
        assert_eq(st_verb_json, {"argv": ["--verbose"], "e2e_verbose": "1"})

        # 2c. --tier all WITHOUT --verbose (exercises TIER_ARGS=() & --quiet mock_server under Bash 3.2)
        tier_plain = subprocess.run(
            ["/bin/bash", str(sandbox_runner), "--tier", "all"],
            env=sb_env,
            capture_output=True,
            text=True,
            timeout=30.0,
        )
        assert_eq(tier_plain.returncode, 0, f"Sandboxed --tier all failed: {tier_plain.stderr}\n{tier_plain.stdout}")
        for t_num in (1, 2, 3, 4):
            assert_in(f"=== Running Tier {t_num} ===", tier_plain.stdout)
            assert_in(json.dumps({"tier": t_num, "argv": [], "e2e_verbose": "0"}), tier_plain.stdout)
        assert_eq(list(run_tmp_parent.iterdir()), [], "run_e2e.sh cleanup trap left E2E_RUN_TMP behind")

        # 2d. --tier 1 WITH --verbose
        tier_verb = subprocess.run(
            ["/bin/bash", str(sandbox_runner), "--tier", "1", "--verbose"],
            env=sb_env,
            capture_output=True,
            text=True,
            timeout=30.0,
        )
        assert_eq(tier_verb.returncode, 0, f"Sandboxed --tier 1 --verbose failed: {tier_verb.stderr}\n{tier_verb.stdout}")
        assert_in(json.dumps({"tier": 1, "argv": ["--verbose"], "e2e_verbose": "1"}), tier_verb.stdout)
        assert_eq(list(run_tmp_parent.iterdir()), [], "run_e2e.sh cleanup trap left E2E_RUN_TMP behind")


def check_runner_and_tiers(strict_tiers: bool, verbose: bool) -> None:
    _smoke_test_run_e2e_cli()

    tier_expectations = {
        1: 95,
        2: 95,
        3: 19,
        4: 10,
    }
    all_ids: set[str] = set()
    total_cases = 0

    for tier_num, min_count in tier_expectations.items():
        runner = E2E_DIR / "tiers" / f"tier{tier_num}" / "run_tier.py"
        if not runner.exists():
            if strict_tiers:
                raise AssertionError(f"Missing tier runner in --strict-tiers mode: {runner}")
            if verbose:
                print(f"[INFO] Tier {tier_num} not present yet (deferred to E2E-M2/M3)")
            continue

        list_res = subprocess.run(
            [sys.executable, str(runner), "--list", "--json"],
            capture_output=True,
            text=True,
            timeout=20.0,
        )
        assert_eq(list_res.returncode, 0, f"tier{tier_num}/run_tier.py --list --json failed: {list_res.stderr}")
        manifest = json.loads(list_res.stdout)
        cases = manifest["cases"]
        assert_true(len(cases) >= min_count, f"Tier {tier_num} has {len(cases)} cases, expected >= {min_count}")

        for c in cases:
            cid = c["id"]
            assert_true(cid not in all_ids, f"Duplicate test ID across tiers: {cid}")
            all_ids.add(cid)
        total_cases += len(cases)

        if tier_num in (1, 2):
            feat_counts = Counter(c["feature"] for c in cases)
            for idx in range(1, 20):
                feat = f"F{idx}"
                assert_true(
                    feat_counts[feat] >= 5,
                    f"Tier {tier_num} feature {feat} has {feat_counts[feat]} cases, expected >= 5",
                )

    if strict_tiers:
        assert_true(total_cases >= 219, f"Total test cases {total_cases} < 219")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Self-test for tests/e2e/ infrastructure")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--strict-tiers", action="store_true", help="Require all Tier 1-4 manifests to exist and meet coverage")
    args = parser.parse_args(argv)

    steps: List[Tuple[str, Callable[[], None]]] = [
        ("static_and_syntax", check_static_and_syntax),
        ("harness_build", check_harness_build),
        ("mock_server_and_hls", check_mock_server_and_hls),
        ("isolated_home_and_app_driver", check_isolated_home_and_app_driver),
        ("runner_and_tiers", lambda: check_runner_and_tiers(args.strict_tiers, args.verbose)),
    ]

    passed = 0
    for name, fn in steps:
        t0 = time.monotonic()
        fn()
        ms = int((time.monotonic() - t0) * 1000)
        print(f"[PASS] self_test::{name} ({ms}ms)", flush=True)
        passed += 1

    print(f"E2E self-test: {passed}/{len(steps)} checks passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
