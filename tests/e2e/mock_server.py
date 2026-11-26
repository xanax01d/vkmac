#!/usr/bin/env python3
"""
Local opaque-box Mock VK Server for vk-mac E2E tests.

Zero third-party dependencies (Python 3 stdlib only).
Emulates:
- VK OAuth: POST|GET /token, GET /authorize, GET /blank.html
- VK API v5.199: POST|GET /method/<name>
- Long Poll: GET|POST /lp (Condition-backed blocking)
- Media & HLS: /media/playlist.m3u8, /media/segment0.ts, /media/*.png, /media/*.jpg, /media/doc.pdf
- Admin control & instrumentation: /__admin/{health,reset,scenario,push_lp,requests,state}
"""

from __future__ import annotations

import argparse
import base64
import copy
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import signal
import struct
import sys
import threading
import time
import urllib.parse
import zlib
from typing import Any, Dict, List, Optional, Tuple


# 11-byte silent AAC-LC 44100 Hz mono ADTS frame verified against AppleCoreMedia / AVPlayer
_SILENT_ADTS_FRAME = bytes.fromhex("fff9506001600000d00007")

# 777-byte valid 1x1 JPEG verified with AppKit.NSImage
_TINY_JPEG_B64 = (
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAA"
    "AAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9z"
    "aG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgA"
    "AQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIB"
    "AwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYX"
    "GBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeI"
    "iYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn"
    "6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIB"
    "AgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDTh"
    "JfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWG"
    "h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm"
    "5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgK"
    "CgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwD"
    "AQACEQMRAD8A+L6KKK/lM/38P//Z"
)
_TINY_JPEG_BYTES = base64.b64decode(_TINY_JPEG_B64)

_TINY_PDF_BYTES = (
    b"%PDF-1.4\n"
    b"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    b"2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj\n"
    b"3 0 obj<</Type/Page/MediaBox[0 0 200 200]/Parent 2 0 R>>endobj\n"
    b"xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n"
    b"0000000052 00000 n \n0000000101 00000 n \n"
    b"trailer<</Size 4/Root 1 0 R>>\nstartxref\n169\n%%EOF\n"
)


def _mpeg2_crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


def _encode_pts_33(pts: int) -> bytes:
    pts &= 0x1FFFFFFFF
    return bytes([
        0x21 | (((pts >> 30) & 0x07) << 1),
        (pts >> 22) & 0xFF,
        0x01 | (((pts >> 15) & 0x7F) << 1),
        (pts >> 7) & 0xFF,
        0x01 | ((pts & 0x7F) << 1),
    ])


def _encode_pcr(pcr_base: int, pcr_ext: int = 0) -> bytes:
    pcr_base &= 0x1FFFFFFFF
    pcr_ext &= 0x1FF
    return bytes([
        (pcr_base >> 25) & 0xFF,
        (pcr_base >> 17) & 0xFF,
        (pcr_base >> 9) & 0xFF,
        (pcr_base >> 1) & 0xFF,
        ((pcr_base & 0x01) << 7) | 0x7E | ((pcr_ext >> 8) & 0x01),
        pcr_ext & 0xFF,
    ])


def build_silent_mpegts(num_frames: int = 90) -> bytes:
    """Build a valid 188-byte-aligned MPEG-TS stream with PAT + PMT + ADTS AAC PES."""
    packets: List[bytes] = []

    # 1. PAT (PID 0x0000) -> program 1 maps to PMT PID 0x1000
    pat_section_body = bytes([
        0x00,        # table_id
        0xB0, 0x0D,  # section_syntax_indicator=1, section_length=13
        0x00, 0x01,  # transport_stream_id = 1
        0xC1,        # version=0, current_next=1
        0x00, 0x00,  # section_number=0, last_section_number=0
        0x00, 0x01,  # program_number = 1
        0xF0, 0x00,  # reserved + program_map_PID = 0x1000
    ])
    pat_crc = struct.pack(">I", _mpeg2_crc32(pat_section_body))
    pat_payload = b"\x00" + pat_section_body + pat_crc
    pat_pkt = bytes([0x47, 0x40, 0x00, 0x10]) + pat_payload
    packets.append(pat_pkt + b"\xFF" * (188 - len(pat_pkt)))

    # 2. PMT (PID 0x1000) -> PCR_PID 0x0100, stream_type 0x0F (ADTS AAC) on PID 0x0100
    pmt_section_body = bytes([
        0x02,        # table_id
        0xB0, 0x12,  # section_syntax_indicator=1, section_length=18
        0x00, 0x01,  # program_number = 1
        0xC1,        # version=0, current_next=1
        0x00, 0x00,  # section_number=0, last_section_number=0
        0xE1, 0x00,  # PCR_PID = 0x0100
        0xF0, 0x00,  # program_info_length = 0
        0x0F,        # stream_type = 0x0F (ISO/IEC 13818-7 ADTS AAC)
        0xE1, 0x00,  # elementary_PID = 0x0100
        0xF0, 0x00,  # ES_info_length = 0
    ])
    pmt_crc = struct.pack(">I", _mpeg2_crc32(pmt_section_body))
    pmt_payload = b"\x00" + pmt_section_body + pmt_crc
    pmt_pkt = bytes([0x47, 0x50, 0x00, 0x10]) + pmt_payload
    packets.append(pmt_pkt + b"\xFF" * (188 - len(pmt_pkt)))

    # 3. Audio PES packets (PID 0x0100)
    frame = _SILENT_ADTS_FRAME
    pes_len = 8 + len(frame)
    for idx in range(num_frames):
        pts = (idx * 1024 * 90000) // 44100
        pes_header = (
            b"\x00\x00\x01\xC0"
            + struct.pack(">H", pes_len)
            + b"\x80\x80\x05"
            + _encode_pts_33(pts)
        )
        pes_payload = pes_header + frame
        adapt_total = 184 - len(pes_payload)
        adapt_len = adapt_total - 1
        if idx == 0:
            pcr_bytes = _encode_pcr(pts, 0)
            adapt = bytes([adapt_len, 0x10]) + pcr_bytes + b"\xFF" * (adapt_len - 1 - len(pcr_bytes))
        else:
            adapt = bytes([adapt_len, 0x00]) + b"\xFF" * (adapt_len - 1)
        ts_header = bytes([0x47, 0x41, 0x00, 0x30 | (idx & 0x0F)])
        pkt = ts_header + adapt + pes_payload
        assert len(pkt) == 188
        packets.append(pkt)

    return b"".join(packets)


def build_tiny_png(rgba: Tuple[int, int, int, int] = (0, 122, 255, 255)) -> bytes:
    """Build a valid 70-byte 1x1 RGBA PNG using Python stdlib struct + zlib."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    raw_scanline = b"\x00" + bytes(rgba)
    idat = zlib.compress(raw_scanline, 9)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


_SEGMENT0_TS = build_silent_mpegts(90)
_TINY_PNG_BYTES = build_tiny_png()


class MockVKState:
    """Thread-safe mutable state for MockVKServer."""

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url
        self.lock = threading.RLock()
        self.lp_condition = threading.Condition(self.lock)
        self.started_at = time.monotonic()
        self.stopping = False
        self._requests_epoch = 0
        self.reset()

    def set_base_url(self, base_url: str) -> None:
        with self.lock:
            self.base_url = base_url
            self._seed_data_locked()

    def set_stopping(self) -> None:
        with self.lp_condition:
            self.stopping = True
            self.lp_condition.notify_all()

    def reset(self) -> None:
        with self.lp_condition:
            self.oauth_scenario: Dict[str, Any] = {"mode": "normal"}
            self.api_scenarios: Dict[str, Dict[str, Any]] = {}
            self.lp_scenario: Dict[str, Any] = {}
            self.strict_tokens: bool = False
            self.valid_tokens: set[str] = {"vk_e2e_token_10001"}
            self.revoked_tokens: set[str] = set()
            self.requests: List[Dict[str, Any]] = []
            self._requests_epoch += 1
            self._next_req_id = 1
            self._next_msg_id = 1000
            self._lp_key_seq = 0
            self.lp_key = "lp_key_e2e_initial"
            self.lp_key_failures: Dict[str, int] = {}
            self.lp_ts = 100
            self.lp_events: List[Tuple[int, List[Any]]] = []
            self.extra_likes: Dict[Tuple[int, int], Tuple[int, bool]] = {}
            self._seed_data_locked()
            self.lp_condition.notify_all()

    def _seed_data_locked(self) -> None:
        b = self.base_url
        now = int(time.time())

        self.profiles: Dict[int, Dict[str, Any]] = {
            10001: {
                "id": 10001,
                "first_name": "Pavel",
                "last_name": "Tester",
                "photo_100": f"{b}/media/avatar_10001.png",
                "photo_200": f"{b}/media/avatar_10001.png",
                "online": 1,
            },
            20001: {
                "id": 20001,
                "first_name": "Alice",
                "last_name": "MacUser",
                "photo_100": f"{b}/media/avatar_20001.jpg",
                "photo_200": f"{b}/media/avatar_20001.jpg",
                "online": 1,
            },
            20002: {
                "id": 20002,
                "first_name": "Bob",
                "last_name": "Rustacean",
                "photo_100": f"{b}/media/avatar_20002.png",
                "photo_200": f"{b}/media/avatar_20002.png",
                "online": 0,
            },
        }

        self.groups: Dict[int, Dict[str, Any]] = {
            123456: {
                "id": 123456,
                "name": "VK Mac Developers",
                "screen_name": "vkmac_dev",
                "photo_100": f"{b}/media/group_123456.png",
                "photo_200": f"{b}/media/group_123456.png",
            }
        }

        # Messages for peer_id 20001 include all 5 attachment types (newest-first internally or sorted on query)
        self.messages: Dict[int, List[Dict[str, Any]]] = {
            20001: [
                {
                    "id": 105,
                    "peer_id": 20001,
                    "from_id": 20001,
                    "date": now - 60,
                    "out": 0,
                    "text": "Check out this link and sticker!",
                    "attachments": [
                        {
                            "type": "link",
                            "link": {
                                "url": f"{b}/blank.html?ref=e2e_link",
                                "title": "VK Mac Reference",
                                "description": "Reference documentation link",
                            },
                        },
                        {
                            "type": "sticker",
                            "sticker": {
                                "product_id": 1,
                                "sticker_id": 9001,
                                "images": [{"url": f"{b}/media/sticker1.png", "width": 128, "height": 128}],
                                "images_with_background": [{"url": f"{b}/media/sticker1.png", "width": 128, "height": 128}],
                            },
                        },
                    ],
                },
                {
                    "id": 104,
                    "peer_id": 20001,
                    "from_id": 10001,
                    "date": now - 120,
                    "out": 1,
                    "text": "Here is the spec PDF",
                    "attachments": [
                        {
                            "type": "doc",
                            "doc": {
                                "id": 6001,
                                "owner_id": 10001,
                                "title": "spec.pdf",
                                "size": len(_TINY_PDF_BYTES),
                                "ext": "pdf",
                                "url": f"{b}/media/doc.pdf",
                            },
                        }
                    ],
                },
                {
                    "id": 103,
                    "peer_id": 20001,
                    "from_id": 20001,
                    "date": now - 180,
                    "out": 0,
                    "text": "Listen to this track",
                    "attachments": [
                        {
                            "type": "audio",
                            "audio": {
                                "id": 5001,
                                "owner_id": 10001,
                                "artist": "E2E Synth",
                                "title": "Mock Track One",
                                "duration": 2,
                                "url": f"{b}/media/playlist.m3u8",
                            },
                        }
                    ],
                },
                {
                    "id": 102,
                    "peer_id": 20001,
                    "from_id": 20001,
                    "date": now - 240,
                    "out": 0,
                    "text": "Photo attached",
                    "attachments": [
                        {
                            "type": "photo",
                            "photo": {
                                "id": 4001,
                                "owner_id": 20001,
                                "sizes": [
                                    {"type": "m", "url": f"{b}/media/photo_m.jpg", "width": 130, "height": 130},
                                    {"type": "x", "url": f"{b}/media/photo_x.jpg", "width": 604, "height": 604},
                                ],
                            },
                        }
                    ],
                },
                {
                    "id": 101,
                    "peer_id": 20001,
                    "from_id": 20001,
                    "date": now - 300,
                    "out": 0,
                    "text": "Hello from Alice!",
                    "attachments": [],
                },
            ],
            2000000001: [
                {
                    "id": 201,
                    "peer_id": 2000000001,
                    "from_id": 20002,
                    "date": now - 400,
                    "out": 0,
                    "text": "Welcome to the Swift + Rust chat",
                    "attachments": [],
                }
            ],
            -123456: [
                {
                    "id": 301,
                    "peer_id": -123456,
                    "from_id": -123456,
                    "date": now - 500,
                    "out": 0,
                    "text": "Release notes published",
                    "attachments": [],
                }
            ],
        }

        self.conversations: List[Dict[str, Any]] = [
            {
                "conversation": {
                    "peer": {"id": 20001, "type": "user", "local_id": 20001},
                    "last_message_id": 105,
                    "unread_count": 2,
                    "push_settings": {"disabled_forever": False},
                },
                "last_message": copy.deepcopy(self.messages[20001][0]),
            },
            {
                "conversation": {
                    "peer": {"id": 2000000001, "type": "chat", "local_id": 1},
                    "last_message_id": 201,
                    "unread_count": 0,
                    "push_settings": {"disabled_forever": True},
                    "chat_settings": {
                        "title": "VK Mac Group Chat",
                        "members_count": 4,
                        "state": "in",
                        "photo": {
                            "photo_50": f"{b}/media/chat_50.png",
                            "photo_100": f"{b}/media/chat_100.png",
                            "photo_200": f"{b}/media/chat_200.png",
                        },
                    },
                },
                "last_message": copy.deepcopy(self.messages[2000000001][0]),
            },
            {
                "conversation": {
                    "peer": {"id": -123456, "type": "group", "local_id": 123456},
                    "last_message_id": 301,
                    "unread_count": 0,
                    "push_settings": {"disabled_forever": False},
                },
                "last_message": copy.deepcopy(self.messages[-123456][0]),
            },
        ]

        self.newsfeed_page1: List[Dict[str, Any]] = [
            {
                "post_id": 7001,
                "source_id": 20001,
                "date": now - 900,
                "type": "post",
                "text": "First newsfeed post with photo",
                "attachments": [
                    {
                        "type": "photo",
                        "photo": {
                            "id": 7101,
                            "owner_id": 20001,
                            "sizes": [
                                {"type": "m", "url": f"{b}/media/feed1_m.jpg", "width": 130, "height": 130},
                                {"type": "x", "url": f"{b}/media/feed1_x.jpg", "width": 604, "height": 604},
                            ],
                        },
                    }
                ],
                "likes": {"count": 10, "user_likes": 0, "can_like": 1},
                "comments": {"count": 2, "can_post": 1},
                "reposts": {"count": 1, "user_reposted": 0},
            },
            {
                "post_id": 7002,
                "source_id": -123456,
                "date": now - 1800,
                "type": "post",
                "text": "Community update post",
                "attachments": [],
                "likes": {"count": 42, "user_likes": 1, "can_like": 1},
                "comments": {"count": 5, "can_post": 1},
                "reposts": {"count": 3, "user_reposted": 0},
            },
        ]

        self.newsfeed_page2: List[Dict[str, Any]] = [
            {
                "post_id": 7003,
                "source_id": 20002,
                "date": now - 3600,
                "type": "post",
                "text": "Second page post from pagination",
                "attachments": [
                    {
                        "type": "photo",
                        "photo": {
                            "id": 7102,
                            "owner_id": 20002,
                            "sizes": [
                                {"type": "x", "url": f"{b}/media/feed2_x.png", "width": 500, "height": 500},
                            ],
                        },
                    }
                ],
                "likes": {"count": 3, "user_likes": 0, "can_like": 1},
                "comments": {"count": 0, "can_post": 1},
                "reposts": {"count": 0, "user_reposted": 0},
            }
        ]

        self.audio_tracks: List[Dict[str, Any]] = [
            {
                "id": 5001,
                "owner_id": 10001,
                "artist": "E2E Synth",
                "title": "Mock Track One",
                "duration": 2,
                "url": f"{b}/media/playlist.m3u8",
                "album": {
                    "id": 10,
                    "title": "E2E Album",
                    "thumb": {
                        "photo_135": f"{b}/media/cover1.jpg",
                        "photo_270": f"{b}/media/cover1.jpg",
                        "photo_300": f"{b}/media/cover1.jpg",
                        "photo_600": f"{b}/media/cover1.jpg",
                    },
                },
            },
            {
                "id": 5002,
                "owner_id": 10001,
                "artist": "Rust Beats",
                "title": "Second HLS Wave",
                "duration": 2,
                "url": f"{b}/media/playlist.m3u8",
                "album": {
                    "id": 11,
                    "title": "E2E Album II",
                    "thumb": {
                        "photo_135": f"{b}/media/cover2.jpg",
                        "photo_270": f"{b}/media/cover2.jpg",
                        "photo_300": f"{b}/media/cover2.jpg",
                        "photo_600": f"{b}/media/cover2.jpg",
                    },
                },
            },
            {
                "id": 5003,
                "owner_id": 10001,
                "artist": "Unavailable Artist",
                "title": "Empty URL Track",
                "duration": 180,
                "url": "",
            },
        ]

    def begin_request(self) -> Tuple[int, int, float]:
        with self.lock:
            epoch = self._requests_epoch
            req_id = self._next_req_id
            self._next_req_id += 1
            arrived_mono = time.monotonic()
            return epoch, req_id, arrived_mono

    def clear_requests(self) -> None:
        with self.lock:
            self.requests.clear()
            self._requests_epoch += 1

    def record_request(
        self,
        epoch: int,
        req_id: int,
        timestamp_mono: float,
        http_method: str,
        path: str,
        vk_method: Optional[str],
        query: Dict[str, str],
        params: Dict[str, Any],
        status: int,
    ) -> None:
        with self.lock:
            if epoch != self._requests_epoch:
                return
            entry = {
                "id": req_id,
                "timestamp": timestamp_mono,
                "wall_time": time.time(),
                "iso": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
                "http_method": http_method,
                "path": path,
                "vk_method": vk_method,
                "query": query,
                "params": params,
                "status": status,
            }
            sort_key = (timestamp_mono, req_id)
            if not self.requests or sort_key >= (self.requests[-1]["timestamp"], self.requests[-1]["id"]):
                self.requests.append(entry)
            else:
                idx = len(self.requests) - 1
                while idx > 0 and (self.requests[idx - 1]["timestamp"], self.requests[idx - 1]["id"]) > sort_key:
                    idx -= 1
                self.requests.insert(idx, entry)


class _MockThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address: Tuple[str, int], handler_cls: type, state: MockVKState, quiet: bool) -> None:
        self.state = state
        self.quiet = quiet
        super().__init__(server_address, handler_cls)


class MockVKRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    @property
    def state(self) -> MockVKState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        if getattr(self.server, "quiet", False):
            return
        sys.stderr.write(f"[mock_vk] {self.address_string()} - {format % args}\n")
        sys.stderr.flush()

    def _send_bytes(
        self,
        status: int,
        content_type: str,
        body: bytes,
        extra_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: Any, extra_headers: Optional[Dict[str, str]] = None) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", raw, extra_headers)

    def _read_body_bytes(self) -> bytes:
        length_hdr = self.headers.get("Content-Length")
        if not length_hdr:
            return b""
        try:
            length = max(0, int(length_hdr))
        except ValueError:
            return b""
        return self.rfile.read(length)

    def _parse_params(self) -> Tuple[str, Dict[str, str], Dict[str, Any]]:
        parsed = urllib.parse.urlsplit(self.path)
        norm_path = re.sub(r"/+", "/", parsed.path or "/")
        query_raw = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        query_flat: Dict[str, str] = {k: vals[-1] for k, vals in query_raw.items() if vals}
        params: Dict[str, Any] = dict(query_flat)

        body = self._read_body_bytes()
        if body:
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "application/json" in ctype:
                try:
                    decoded = json.loads(body.decode("utf-8"))
                    if isinstance(decoded, dict):
                        params.update(decoded)
                except Exception:
                    pass
            else:
                form = urllib.parse.parse_qs(body.decode("utf-8", errors="replace"), keep_blank_values=True)
                for k, vals in form.items():
                    if vals:
                        params[k] = vals[-1]

        auth_hdr = self.headers.get("Authorization") or ""
        if auth_hdr.lower().startswith("bearer ") and "access_token" not in params:
            params["access_token"] = auth_hdr[7:].strip()

        return norm_path, query_flat, params

    def _parse_json_body(self) -> Any:
        raw = self._read_body_bytes()
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    # HTTP method dispatchers
    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def do_HEAD(self) -> None:
        self._dispatch("HEAD")

    def _dispatch(self, http_method: str) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        norm_path = re.sub(r"/+", "/", parsed.path or "/")

        # Admin routes (not recorded in non-admin request log; avoid pre-reading JSON body)
        if norm_path == "/__admin" or norm_path.startswith("/__admin/"):
            query_raw = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            query = {k: vals[-1] for k, vals in query_raw.items() if vals}
            self._handle_admin(http_method, norm_path, query)
            return

        epoch, req_id, arrived_mono = self.state.begin_request()
        norm_path, query, params = self._parse_params()

        # OAuth routes
        if norm_path == "/token":
            status = self._handle_oauth_token(params)
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, None, query, params, status)
            return
        if norm_path == "/authorize":
            status = self._handle_oauth_authorize(params)
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, None, query, params, status)
            return
        if norm_path == "/blank.html":
            self._send_bytes(
                200,
                "text/html; charset=utf-8",
                b"<!doctype html><html><head><title>VK OAuth Blank</title></head><body>OK</body></html>",
            )
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, None, query, params, 200)
            return

        # VK API /method/<name>
        if norm_path.startswith("/method/"):
            vk_method = norm_path[len("/method/"):].strip("/")
            status = self._handle_vk_method(vk_method, params)
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, vk_method, query, params, status)
            return

        # Long Poll /lp
        if norm_path == "/lp":
            status = self._handle_longpoll(params)
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, "lp", query, params, status)
            return

        # Media & HLS
        if norm_path.startswith("/media/"):
            status = self._handle_media(norm_path)
            self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, None, query, params, status)
            return

        self._send_json(404, {"error": "not_found", "path": norm_path})
        self.state.record_request(epoch, req_id, arrived_mono, http_method, norm_path, None, query, params, 404)

    # ------------------------------------------------------------------
    # Admin API
    # ------------------------------------------------------------------
    def _handle_admin(self, http_method: str, norm_path: str, query: Dict[str, str]) -> None:
        if norm_path == "/__admin/health" and http_method == "GET":
            with self.state.lock:
                uptime = round(time.monotonic() - self.state.started_at, 3)
                base_url = self.state.base_url
            self._send_json(200, {"status": "ok", "base_url": base_url, "uptime_sec": uptime})
            return

        if norm_path == "/__admin/reset" and http_method == "POST":
            self.state.reset()
            self._send_json(200, {"status": "reset"})
            return

        if norm_path == "/__admin/scenario" and http_method == "POST":
            try:
                body = self._parse_json_body()
            except Exception as exc:
                self._send_json(400, {"error": f"invalid json: {exc}"})
                return
            if not isinstance(body, dict):
                self._send_json(400, {"error": "body must be a JSON object"})
                return

            with self.state.lp_condition:
                if body.get("reset"):
                    self.state.oauth_scenario = {"mode": "normal"}
                    self.state.api_scenarios = {}
                    self.state.lp_scenario = {}
                if "oauth" in body and isinstance(body["oauth"], dict):
                    self.state.oauth_scenario = copy.deepcopy(body["oauth"])
                if "api" in body and isinstance(body["api"], dict):
                    for m_name, rule in body["api"].items():
                        if rule is None:
                            self.state.api_scenarios.pop(m_name, None)
                        elif isinstance(rule, dict):
                            self.state.api_scenarios[m_name] = copy.deepcopy(rule)
                if "method" in body and isinstance(body["method"], str):
                    rule = {k: v for k, v in body.items() if k != "method"}
                    self.state.api_scenarios[body["method"]] = rule
                if "lp" in body and isinstance(body["lp"], dict):
                    self.state.lp_scenario = copy.deepcopy(body["lp"])
                    self.state.lp_condition.notify_all()
                if "strict_tokens" in body:
                    self.state.strict_tokens = bool(body["strict_tokens"])
                if "revoke_token" in body and isinstance(body["revoke_token"], str):
                    self.state.revoked_tokens.add(body["revoke_token"])
                if "revoke_tokens" in body and isinstance(body["revoke_tokens"], list):
                    for tok in body["revoke_tokens"]:
                        self.state.revoked_tokens.add(str(tok))
                if "add_valid_token" in body and isinstance(body["add_valid_token"], str):
                    tok = body["add_valid_token"]
                    self.state.valid_tokens.add(tok)
                    self.state.revoked_tokens.discard(tok)
                snapshot = {
                    "oauth": copy.deepcopy(self.state.oauth_scenario),
                    "api": copy.deepcopy(self.state.api_scenarios),
                    "lp": copy.deepcopy(self.state.lp_scenario),
                    "strict_tokens": self.state.strict_tokens,
                }
            self._send_json(200, {"status": "ok", "scenarios": snapshot})
            return

        if norm_path == "/__admin/push_lp" and http_method == "POST":
            try:
                body = self._parse_json_body()
            except Exception as exc:
                self._send_json(400, {"error": f"invalid json: {exc}"})
                return
            updates = body.get("updates")
            if updates is None:
                updates = body.get("events")
            if updates is None and "update" in body:
                updates = [body["update"]]
            if not isinstance(updates, list):
                self._send_json(400, {"error": "updates must be a list"})
                return

            with self.state.lp_condition:
                for upd in updates:
                    self.state.lp_ts += 1
                    self.state.lp_events.append((self.state.lp_ts, copy.deepcopy(upd)))
                    # Mirror incoming LP new-message events [4, msg_id, flags, peer_id, ts, text, ...]
                    if isinstance(upd, list) and len(upd) >= 6 and upd[0] == 4:
                        try:
                            msg_id = int(upd[1])
                            flags = int(upd[2])
                            peer_id = int(upd[3])
                            ts_val = int(upd[4])
                            text = str(upd[5])
                            is_out = 1 if (flags & 2) else 0
                            from_id = 10001 if is_out else peer_id
                            msg_obj = {
                                "id": msg_id,
                                "peer_id": peer_id,
                                "from_id": from_id,
                                "date": ts_val,
                                "out": is_out,
                                "text": text,
                                "attachments": [],
                            }
                            msgs = self.state.messages.setdefault(peer_id, [])
                            if not any(m.get("id") == msg_id for m in msgs):
                                msgs.insert(0, msg_obj)
                            for conv in self.state.conversations:
                                if conv["conversation"]["peer"]["id"] == peer_id:
                                    conv["last_message"] = copy.deepcopy(msg_obj)
                                    conv["conversation"]["last_message_id"] = msg_id
                                    if not is_out:
                                        conv["conversation"]["unread_count"] = (
                                            int(conv["conversation"].get("unread_count", 0)) + 1
                                        )
                        except (TypeError, ValueError):
                            pass
                new_ts = self.state.lp_ts
                self.state.lp_condition.notify_all()
            self._send_json(200, {"status": "ok", "ts": new_ts, "queued": len(updates)})
            return

        if norm_path == "/__admin/requests":
            if http_method == "GET":
                vk_filter = query.get("vk_method")
                prefix_filter = query.get("path_prefix")
                with self.state.lock:
                    reqs = list(self.state.requests)
                if vk_filter:
                    reqs = [r for r in reqs if r.get("vk_method") == vk_filter]
                if prefix_filter:
                    reqs = [r for r in reqs if str(r.get("path", "")).startswith(prefix_filter)]
                self._send_json(200, {"count": len(reqs), "requests": reqs})
                return
            if http_method == "DELETE":
                self.state.clear_requests()
                self._send_json(200, {"status": "cleared"})
                return

        if norm_path == "/__admin/state" and http_method == "GET":
            with self.state.lock:
                payload = {
                    "base_url": self.state.base_url,
                    "lp_key": self.state.lp_key,
                    "lp_ts": self.state.lp_ts,
                    "lp_events_count": len(self.state.lp_events),
                    "strict_tokens": self.state.strict_tokens,
                    "valid_tokens": sorted(self.state.valid_tokens),
                    "revoked_tokens": sorted(self.state.revoked_tokens),
                    "oauth_scenario": copy.deepcopy(self.state.oauth_scenario),
                    "api_scenarios": copy.deepcopy(self.state.api_scenarios),
                    "lp_scenario": copy.deepcopy(self.state.lp_scenario),
                    "requests_count": len(self.state.requests),
                    "conversations_count": len(self.state.conversations),
                    "audio_tracks_count": len(self.state.audio_tracks),
                }
            self._send_json(200, payload)
            return

        self._send_json(404, {"error": "unknown_admin_endpoint", "path": norm_path})

    # ------------------------------------------------------------------
    # OAuth Endpoints
    # ------------------------------------------------------------------
    def _consume_oauth_scenario_locked(self) -> None:
        cur = self.state.oauth_scenario
        if not cur:
            return
        if "remaining_count" in cur and cur["remaining_count"] is not None:
            cur["remaining_count"] = int(cur["remaining_count"]) - 1
            if cur["remaining_count"] <= 0:
                self.state.oauth_scenario = {"mode": "normal"}
        elif cur.get("once"):
            self.state.oauth_scenario = {"mode": "normal"}

    def _handle_oauth_token(self, params: Dict[str, Any]) -> int:
        with self.state.lock:
            scenario = copy.deepcopy(self.state.oauth_scenario)
            base_url = self.state.base_url
            self._consume_oauth_scenario_locked()

        latency_ms = float(scenario.get("latency_ms", 0) or 0)
        if latency_ms > 0:
            time.sleep(latency_ms / 1000.0)

        if scenario.get("http_status"):
            st = int(scenario["http_status"])
            self._send_json(st, {"error": "injected_http_error", "status": st})
            return st

        mode = str(scenario.get("mode", "normal"))
        client_id = str(params.get("client_id", "") or "")
        username = str(params.get("username", "") or "")
        password = str(params.get("password", "") or "")
        code = str(params.get("code", "") or "")
        captcha_key = str(params.get("captcha_key", "") or "")

        if mode == "invalid_client" or client_id == "invalid_client" or not client_id:
            self._send_json(401, {"error": "invalid_client", "error_description": "client_id is undefined"})
            return 401

        if mode == "need_validation" or username == "user_2fa":
            valid_code = str(scenario.get("valid_code", "123456"))
            if code:
                if code == valid_code:
                    return self._issue_oauth_token(scenario)
                self._send_json(401, {"error": "invalid_grant", "error_description": "Invalid 2FA code"})
                return 401
            self._send_json(
                401,
                {
                    "error": "need_validation",
                    "error_description": "Two-factor authentication is required",
                    "validation_type": str(scenario.get("validation_type", "2fa_sms")),
                    "validation_sid": str(scenario.get("validation_sid", "val_sid_e2e_001")),
                    "phone_mask": str(scenario.get("phone_mask", "+7 *** *** ** 89")),
                    "redirect_uri": f"{base_url}/blank.html",
                },
            )
            return 401

        if mode == "need_captcha" or username == "user_captcha":
            valid_captcha = str(scenario.get("valid_captcha", "e2e_ok"))
            cap_sid = str(scenario.get("captcha_sid", "cap_sid_e2e_001"))
            if captcha_key and captcha_key == valid_captcha:
                return self._issue_oauth_token(scenario)
            self._send_json(
                401,
                {
                    "error": "need_captcha",
                    "error_description": "Captcha needed",
                    "captcha_sid": cap_sid,
                    "captcha_img": f"{base_url}/media/captcha.png?sid={urllib.parse.quote(cap_sid)}",
                },
            )
            return 401

        if mode == "invalid_grant" or username == "bad_user" or password == "wrong" or not username or not password:
            self._send_json(
                401,
                {"error": "invalid_grant", "error_description": "Username or password is incorrect"},
            )
            return 401

        return self._issue_oauth_token(scenario)

    def _issue_oauth_token(self, scenario: Dict[str, Any]) -> int:
        token = str(scenario.get("access_token", "vk_e2e_token_10001"))
        user_id = int(scenario.get("user_id", 10001))
        expires_in = int(scenario.get("expires_in", 0))
        with self.state.lock:
            self.state.valid_tokens.add(token)
            self.state.revoked_tokens.discard(token)
        self._send_json(200, {"access_token": token, "expires_in": expires_in, "user_id": user_id})
        return 200

    def _handle_oauth_authorize(self, params: Dict[str, Any]) -> int:
        with self.state.lock:
            scenario = copy.deepcopy(self.state.oauth_scenario)
            base_url = self.state.base_url
            self._consume_oauth_scenario_locked()

        redirect_uri = str(params.get("redirect_uri", "") or "")
        state_param = str(params.get("state", "") or "")
        if (
            not redirect_uri
            or redirect_uri.startswith("https://oauth.vk.com/blank.html")
            or redirect_uri.startswith("http://oauth.vk.com/blank.html")
        ):
            target = f"{base_url}/blank.html"
        else:
            target = redirect_uri

        if scenario.get("mode") == "authorize_error":
            fragment = "error=access_denied&error_description=User+denied"
        else:
            token = str(scenario.get("access_token", "vk_e2e_token_10001"))
            user_id = int(scenario.get("user_id", 10001))
            with self.state.lock:
                self.state.valid_tokens.add(token)
                self.state.revoked_tokens.discard(token)
            fragment = f"access_token={urllib.parse.quote(token)}&expires_in=0&user_id={user_id}"

        if state_param:
            fragment += f"&state={urllib.parse.quote(state_param)}"

        location = f"{target}#{fragment}"
        self._send_bytes(302, "text/plain; charset=utf-8", b"", extra_headers={"Location": location})
        return 302

    # ------------------------------------------------------------------
    # VK API v5.199 Methods
    # ------------------------------------------------------------------
    def _build_request_params_list(self, method_name: str, params: Dict[str, Any]) -> List[Dict[str, str]]:
        out = [{"key": "method", "value": method_name}]
        for k, v in params.items():
            if k != "access_token":
                out.append({"key": str(k), "value": str(v)})
        return out

    def _vk_error_payload(self, code: int, msg: str, method_name: str, params: Dict[str, Any], base_url: str) -> Dict[str, Any]:
        err: Dict[str, Any] = {
            "error_code": code,
            "error_msg": msg,
            "request_params": self._build_request_params_list(method_name, params),
        }
        if code == 14:
            sid = "api_cap_sid_001"
            err["captcha_sid"] = sid
            err["captcha_img"] = f"{base_url}/media/captcha.png?sid={sid}"
        elif code == 17:
            err["redirect_uri"] = f"{base_url}/blank.html?validation=1"
        return {"error": err}

    def _handle_vk_method(self, method_name: str, params: Dict[str, Any]) -> int:
        rule: Optional[Dict[str, Any]] = None
        inject_http_status: Optional[int] = None
        inject_error: Optional[Tuple[int, str]] = None
        disable_auth = False

        with self.state.lock:
            base_url = self.state.base_url
            scenario_key: Optional[str] = None
            if method_name in self.state.api_scenarios:
                scenario_key = method_name
            elif "*" in self.state.api_scenarios:
                scenario_key = "*"

            if scenario_key is not None:
                rule = copy.deepcopy(self.state.api_scenarios[scenario_key])
                disable_auth = bool(rule.get("disable_auth_check", False))
                consume = False

                if rule.get("http_status") is not None:
                    inject_http_status = int(rule["http_status"])
                    consume = True
                elif rule.get("error_code") is not None:
                    code = int(rule["error_code"])
                    valid_cap = str(rule.get("valid_captcha", "e2e_ok"))
                    if code == 14 and str(params.get("captcha_key", "")) == valid_cap:
                        consume = False  # Captcha solved -> bypass without consuming error rule
                    else:
                        default_msgs = {
                            5: "User authorization failed: invalid access_token (4).",
                            6: "Too many requests per second",
                            14: "Captcha needed",
                            17: "Validation required: please open redirect_uri",
                        }
                        msg = str(rule.get("error_msg") or default_msgs.get(code, f"Injected VK error {code}"))
                        inject_error = (code, msg)
                        consume = True
                else:
                    # Latency-only or disable_auth_check-only rules still honor remaining_count / once
                    consume = True

                if consume:
                    self._consume_api_scenario_locked(scenario_key)

        latency_ms = float(rule.get("latency_ms", 0) or 0) if rule else 0.0
        if latency_ms > 0:
            time.sleep(latency_ms / 1000.0)

        if inject_http_status is not None:
            self._send_json(inject_http_status, {"error": "injected_http_error", "status": inject_http_status})
            return inject_http_status

        if inject_error is not None:
            code, msg = inject_error
            self._send_json(200, self._vk_error_payload(code, msg, method_name, params, base_url))
            return 200

        # Token validation
        if not disable_auth:
            token = str(params.get("access_token", "") or "")
            with self.state.lock:
                invalid = (
                    not token
                    or token in self.state.revoked_tokens
                    or (self.state.strict_tokens and token not in self.state.valid_tokens)
                )
            if invalid:
                self._send_json(
                    200,
                    self._vk_error_payload(
                        5,
                        "User authorization failed: invalid access_token (4).",
                        method_name,
                        params,
                        base_url,
                    ),
                )
                return 200

        # Dispatch method
        with self.state.lock:
            resp_obj = self._dispatch_vk_method_locked(method_name, params)

        self._send_json(200, resp_obj)
        return 200

    def _consume_api_scenario_locked(self, key: Optional[str]) -> None:
        if not key:
            return
        cur = self.state.api_scenarios.get(key)
        if not cur:
            return
        if "remaining_count" in cur and cur["remaining_count"] is not None:
            cur["remaining_count"] = int(cur["remaining_count"]) - 1
            if cur["remaining_count"] <= 0:
                self.state.api_scenarios.pop(key, None)
        elif cur.get("once"):
            self.state.api_scenarios.pop(key, None)

    def _dispatch_vk_method_locked(self, method_name: str, params: Dict[str, Any]) -> Dict[str, Any]:
        b = self.state.base_url

        if method_name == "messages.getConversations":
            offset = max(0, int(params.get("offset", 0) or 0))
            count = max(0, int(params.get("count", 20) or 20))
            items = copy.deepcopy(self.state.conversations[offset : offset + count])
            unread_convs = sum(
                1 for c in self.state.conversations if int(c["conversation"].get("unread_count", 0)) > 0
            )
            return {
                "response": {
                    "count": len(self.state.conversations),
                    "unread_count": unread_convs,
                    "items": items,
                    "profiles": copy.deepcopy(list(self.state.profiles.values())),
                    "groups": copy.deepcopy(list(self.state.groups.values())),
                }
            }

        if method_name == "messages.getHistory":
            peer_id = int(params.get("peer_id", 20001) or 20001)
            offset = max(0, int(params.get("offset", 0) or 0))
            count = max(0, int(params.get("count", 50) or 50))
            rev = int(params.get("rev", 0) or 0)
            msgs = list(self.state.messages.get(peer_id, []))
            if rev == 1:
                msgs = list(reversed(msgs))
            sliced = copy.deepcopy(msgs[offset : offset + count])
            return {
                "response": {
                    "count": len(msgs),
                    "items": sliced,
                    "profiles": copy.deepcopy(list(self.state.profiles.values())),
                    "groups": copy.deepcopy(list(self.state.groups.values())),
                }
            }

        if method_name == "messages.send":
            peer_id = int(params.get("peer_id", 20001) or 20001)
            text = str(params.get("message", "") or "")
            self.state._next_msg_id += 1
            msg_id = self.state._next_msg_id
            msg_obj = {
                "id": msg_id,
                "peer_id": peer_id,
                "from_id": 10001,
                "date": int(time.time()),
                "out": 1,
                "text": text,
                "attachments": [],
            }
            self.state.messages.setdefault(peer_id, []).insert(0, msg_obj)
            found = False
            for conv in self.state.conversations:
                if conv["conversation"]["peer"]["id"] == peer_id:
                    conv["last_message"] = copy.deepcopy(msg_obj)
                    conv["conversation"]["last_message_id"] = msg_id
                    found = True
                    break
            if not found:
                peer_type = "group" if peer_id < 0 else ("chat" if peer_id >= 2000000000 else "user")
                self.state.conversations.insert(
                    0,
                    {
                        "conversation": {
                            "peer": {"id": peer_id, "type": peer_type, "local_id": abs(peer_id)},
                            "last_message_id": msg_id,
                            "unread_count": 0,
                            "push_settings": {"disabled_forever": False},
                        },
                        "last_message": copy.deepcopy(msg_obj),
                    },
                )
            return {"response": msg_id}

        if method_name == "newsfeed.get":
            start_from = str(params.get("start_from", "") or "")
            count = max(1, int(params.get("count", 10) or 10))
            if start_from == "page_2":
                items = copy.deepcopy(self.state.newsfeed_page2[:count])
                resp: Dict[str, Any] = {
                    "items": items,
                    "profiles": copy.deepcopy(list(self.state.profiles.values())),
                    "groups": copy.deepcopy(list(self.state.groups.values())),
                }
                return {"response": resp}
            items = copy.deepcopy(self.state.newsfeed_page1[:count])
            return {
                "response": {
                    "items": items,
                    "profiles": copy.deepcopy(list(self.state.profiles.values())),
                    "groups": copy.deepcopy(list(self.state.groups.values())),
                    "next_from": "page_2",
                }
            }

        if method_name in ("likes.add", "likes.delete"):
            owner_id = int(params.get("owner_id", 0) or 0)
            item_id = int(params.get("item_id", 0) or 0)
            adding = method_name == "likes.add"
            for post in self.state.newsfeed_page1 + self.state.newsfeed_page2:
                if post["source_id"] == owner_id and post["post_id"] == item_id:
                    likes = post["likes"]
                    currently_liked = bool(likes.get("user_likes", 0))
                    if adding and not currently_liked:
                        likes["count"] = int(likes["count"]) + 1
                        likes["user_likes"] = 1
                    elif (not adding) and currently_liked:
                        likes["count"] = max(0, int(likes["count"]) - 1)
                        likes["user_likes"] = 0
                    return {"response": {"likes": int(likes["count"])}}
            key = (owner_id, item_id)
            cur_cnt, cur_liked = self.state.extra_likes.get(key, (0, False))
            if adding and not cur_liked:
                cur_cnt += 1
                cur_liked = True
            elif (not adding) and cur_liked:
                cur_cnt = max(0, cur_cnt - 1)
                cur_liked = False
            self.state.extra_likes[key] = (cur_cnt, cur_liked)
            return {"response": {"likes": cur_cnt}}

        if method_name == "audio.get":
            offset = max(0, int(params.get("offset", 0) or 0))
            count = max(0, int(params.get("count", 50) or 50))
            items = copy.deepcopy(self.state.audio_tracks[offset : offset + count])
            return {"response": {"count": len(self.state.audio_tracks), "items": items}}

        if method_name == "audio.search":
            q = str(params.get("q", "") or "").strip().lower()
            offset = max(0, int(params.get("offset", 0) or 0))
            count = max(0, int(params.get("count", 50) or 50))
            matched = [
                t
                for t in self.state.audio_tracks
                if (not q) or (q in t["artist"].lower()) or (q in t["title"].lower())
            ]
            return {"response": {"count": len(matched), "items": copy.deepcopy(matched[offset : offset + count])}}

        if method_name == "users.get":
            raw_ids = str(params.get("user_ids", "") or "").strip()
            if not raw_ids:
                ids = [10001]
            else:
                ids = []
                for part in raw_ids.split(","):
                    part = part.strip()
                    if not part:
                        continue
                    try:
                        ids.append(int(part))
                    except ValueError:
                        pass
            out = []
            for uid in ids:
                if uid in self.state.profiles:
                    out.append(copy.deepcopy(self.state.profiles[uid]))
            return {"response": out}

        if method_name == "messages.getLongPollServer":
            return {
                "response": {
                    "key": self.state.lp_key,
                    "server": f"{b}/lp",
                    "ts": self.state.lp_ts,
                }
            }

        return self._vk_error_payload(3, f"Unknown method passed: {method_name}", method_name, params, b)

    # ------------------------------------------------------------------
    # Long Poll (/lp)
    # ------------------------------------------------------------------
    def _eval_lp_scenario_locked(self) -> Optional[Dict[str, Any]]:
        if not self.state.lp_scenario:
            return None
        scen = copy.deepcopy(self.state.lp_scenario)
        if "remaining_count" in self.state.lp_scenario and self.state.lp_scenario["remaining_count"] is not None:
            self.state.lp_scenario["remaining_count"] = int(self.state.lp_scenario["remaining_count"]) - 1
            if self.state.lp_scenario["remaining_count"] <= 0:
                self.state.lp_scenario = {}
        elif scen.get("once"):
            self.state.lp_scenario = {}

        failed = scen.get("failed")
        if failed is None:
            return None
        f_code = int(failed)
        if f_code == 1:
            return {"failed": 1, "ts": self.state.lp_ts}
        if f_code == 2:
            self.state.lp_key_failures[self.state.lp_key] = 2
            self.state._lp_key_seq += 1
            self.state.lp_key = f"lp_key_e2e_{self.state._lp_key_seq}"
            return {"failed": 2}
        if f_code == 3:
            self.state.lp_key_failures[self.state.lp_key] = 3
            self.state._lp_key_seq += 1
            self.state.lp_key = f"lp_key_e2e_{self.state._lp_key_seq}"
            self.state.lp_ts += 1
            return {"failed": 3}
        if f_code == 4:
            return {"failed": 4, "min_version": 2, "max_version": 3}
        return {"failed": f_code}

    def _handle_longpoll(self, params: Dict[str, Any]) -> int:
        key = str(params.get("key", "") or "")
        try:
            wait_sec = min(25.0, max(0.0, float(params.get("wait", 25) or 0)))
        except (TypeError, ValueError):
            wait_sec = 25.0

        resp_payload: Optional[Dict[str, Any]] = None
        with self.state.lp_condition:
            # 1. Immediate scenario failure injection
            scen_resp = self._eval_lp_scenario_locked()
            if scen_resp is not None:
                resp_payload = scen_resp
            elif not key or key != self.state.lp_key:
                fail_code = self.state.lp_key_failures.get(key, 2) if key else 2
                resp_payload = {"failed": fail_code}
            else:
                try:
                    client_ts = int(params.get("ts", self.state.lp_ts))
                except (TypeError, ValueError):
                    client_ts = self.state.lp_ts

                deadline = time.monotonic() + wait_sec
                while not self.state.stopping:
                    if self.state.lp_scenario:
                        scen_resp = self._eval_lp_scenario_locked()
                        if scen_resp is not None:
                            resp_payload = scen_resp
                            break
                    if key != self.state.lp_key:
                        fail_code = self.state.lp_key_failures.get(key, 2)
                        resp_payload = {"failed": fail_code}
                        break
                    matching = [copy.deepcopy(ev) for ev_ts, ev in self.state.lp_events if ev_ts > client_ts]
                    if matching:
                        resp_payload = {"ts": self.state.lp_ts, "updates": matching}
                        break
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    self.state.lp_condition.wait(timeout=remaining)

                if resp_payload is None:
                    if self.state.stopping:
                        resp_payload = {"ts": self.state.lp_ts, "updates": []}
                    else:
                        matching = [copy.deepcopy(ev) for ev_ts, ev in self.state.lp_events if ev_ts > client_ts]
                        resp_payload = {"ts": self.state.lp_ts, "updates": matching}

        self._send_json(200, resp_payload)
        return 200

    # ------------------------------------------------------------------
    # Media & HLS
    # ------------------------------------------------------------------
    @staticmethod
    def _parse_byte_range(range_hdr: str, total: int) -> Tuple[str, int, int]:
        unit, sep, spec = range_hdr.strip().partition("=")
        if not sep or unit.strip().lower() != "bytes" or "," in spec:
            return ("ignore", 0, 0)
        first_str, dash, last_str = spec.strip().partition("-")
        if not dash or (not first_str and not last_str):
            return ("ignore", 0, 0)
        # Suffix byte range: bytes=-N
        if not first_str and last_str:
            if not last_str.isdigit():
                return ("ignore", 0, 0)
            suffix_len = int(last_str)
            if suffix_len == 0 or total == 0:
                return ("unsatisfiable", 0, 0)
            start = max(0, total - suffix_len)
            return ("ok", start, total - 1)
        # Open-ended byte range: bytes=start-
        if first_str and not last_str:
            if not first_str.isdigit():
                return ("ignore", 0, 0)
            start = int(first_str)
            if start >= total:
                return ("unsatisfiable", 0, 0)
            return ("ok", start, total - 1)
        # Closed byte range: bytes=start-end
        if not (first_str.isdigit() and last_str.isdigit()):
            return ("ignore", 0, 0)
        start = int(first_str)
        req_end = int(last_str)
        if start > req_end:
            return ("ignore", 0, 0)
        if start >= total:
            return ("unsatisfiable", 0, 0)
        return ("ok", start, min(req_end, total - 1))

    def _handle_media(self, norm_path: str) -> int:
        if norm_path == "/media/playlist.m3u8":
            playlist = (
                "#EXTM3U\n"
                "#EXT-X-VERSION:3\n"
                "#EXT-X-TARGETDURATION:3\n"
                "#EXT-X-MEDIA-SEQUENCE:0\n"
                "#EXTINF:2.090,\n"
                "segment0.ts\n"
                "#EXT-X-ENDLIST\n"
            ).encode("utf-8")
            self._send_bytes(200, "application/vnd.apple.mpegurl", playlist)
            return 200

        if norm_path == "/media/segment0.ts":
            data = _SEGMENT0_TS
            total = len(data)
            range_hdr = self.headers.get("Range")
            if range_hdr:
                kind, start, end = self._parse_byte_range(range_hdr, total)
                if kind == "ok":
                    chunk = data[start : end + 1]
                    self._send_bytes(
                        206,
                        "video/mp2t",
                        chunk,
                        extra_headers={
                            "Accept-Ranges": "bytes",
                            "Content-Range": f"bytes {start}-{end}/{total}",
                        },
                    )
                    return 206
                if kind == "unsatisfiable":
                    self._send_bytes(
                        416,
                        "text/plain; charset=utf-8",
                        b"",
                        extra_headers={
                            "Accept-Ranges": "bytes",
                            "Content-Range": f"bytes */{total}",
                        },
                    )
                    return 416
            self._send_bytes(
                200,
                "video/mp2t",
                data,
                extra_headers={"Accept-Ranges": "bytes"},
            )
            return 200

        if norm_path.endswith(".png"):
            self._send_bytes(200, "image/png", _TINY_PNG_BYTES)
            return 200

        if norm_path.endswith(".jpg") or norm_path.endswith(".jpeg"):
            self._send_bytes(200, "image/jpeg", _TINY_JPEG_BYTES)
            return 200

        if norm_path.endswith(".pdf"):
            self._send_bytes(200, "application/pdf", _TINY_PDF_BYTES)
            return 200

        self._send_json(404, {"error": "media_not_found", "path": norm_path})
        return 404


class MockVKServer:
    """Programmatic wrapper around _MockThreadingHTTPServer for self_test / embedded runs."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0, quiet: bool = True) -> None:
        self.host = host
        self.requested_port = port
        self.quiet = quiet
        self.state = MockVKState(f"http://{host}:{port}")
        self.httpd: Optional[_MockThreadingHTTPServer] = None
        self.thread: Optional[threading.Thread] = None
        self.port: int = 0
        self.base_url: str = ""

    def start(self) -> Dict[str, Any]:
        self.httpd = _MockThreadingHTTPServer((self.host, self.requested_port), MockVKRequestHandler, self.state, self.quiet)
        self.port = int(self.httpd.server_address[1])
        self.base_url = f"http://{self.host}:{self.port}"
        self.state.set_base_url(self.base_url)
        self.thread = threading.Thread(target=self.httpd.serve_forever, name="MockVKServer", daemon=True)
        self.thread.start()
        return {"status": "ready", "host": self.host, "port": self.port, "base_url": self.base_url}

    def stop(self) -> None:
        self.state.set_stopping()
        if self.httpd is not None:
            try:
                self.httpd.shutdown()
                self.httpd.server_close()
            except Exception:
                pass
            self.httpd = None
        if self.thread is not None:
            self.thread.join(timeout=3.0)
            self.thread = None

    def __enter__(self) -> "MockVKServer":
        self.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.stop()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Local Mock VK Server for vk-mac E2E testing")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=0, help="Bind port (default: 0 for ephemeral)")
    parser.add_argument("--quiet", action="store_true", help="Suppress HTTP request logging on stderr")
    args = parser.parse_args(argv)

    state = MockVKState(f"http://{args.host}:{args.port}")
    httpd = _MockThreadingHTTPServer((args.host, args.port), MockVKRequestHandler, state, args.quiet)
    actual_port = int(httpd.server_address[1])
    base_url = f"http://{args.host}:{actual_port}"
    state.set_base_url(base_url)

    def _handle_sig(signum: int, frame: Any) -> None:
        state.set_stopping()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _handle_sig)
    signal.signal(signal.SIGTERM, _handle_sig)

    banner = {"status": "ready", "host": args.host, "port": actual_port, "base_url": base_url}
    sys.stdout.write(json.dumps(banner) + "\n")
    sys.stdout.flush()

    try:
        httpd.serve_forever(poll_interval=0.2)
    finally:
        state.set_stopping()
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
