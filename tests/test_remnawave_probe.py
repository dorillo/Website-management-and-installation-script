from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import ProxyHandler


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "remnawave_probe",
    ROOT / "bin" / "remnawave_probe.py",
)
assert SPEC is not None and SPEC.loader is not None
remnawave_probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remnawave_probe)


class FakeResponse:
    def __init__(self, document: dict, status: int = 200) -> None:
        self.status = status
        self.payload = json.dumps(document).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, limit: int) -> bytes:
        return self.payload[:limit]


class FakeOpener:
    def __init__(self, response: FakeResponse) -> None:
        self.response = response
        self.request = None
        self.timeout = None

    def open(self, request, timeout: int):
        self.request = request
        self.timeout = timeout
        return self.response


class RemnawaveProbeTests(unittest.TestCase):
    def test_accepts_remnawave_v3_stream_response(self) -> None:
        opener = FakeOpener(FakeResponse({
            "response": {"users": [], "hasMore": False, "nextCursor": None}
        }))

        remnawave_probe.probe(
            "https://panel.example.test/api",
            "a" * 32,
            '{"access":"cookie-value"}',
            opener=opener,
        )

        self.assertIn("/api/users/stream?", opener.request.full_url)
        self.assertEqual(
            opener.request.get_header("Authorization"),
            f"Bearer {'a' * 32}",
        )
        self.assertEqual(opener.request.get_header("Cookie"), "access=cookie-value")
        self.assertEqual(opener.timeout, 20)

    def test_rejects_legacy_uuid_user_response(self) -> None:
        document = {
            "response": {
                "users": [{
                    "uuid": "eb41094b-a1c5-4554-b6d5-64f61d018733",
                    "email": remnawave_probe.PROBE_EMAIL,
                }],
                "hasMore": False,
                "nextCursor": None,
            }
        }
        with self.assertRaises(remnawave_probe.ProbeError):
            remnawave_probe.probe(
                "https://panel.example.test/api",
                "a" * 32,
                "{}",
                opener=FakeOpener(FakeResponse(document)),
            )

    def test_rejects_redirect_status(self) -> None:
        document = {
            "response": {"users": [], "hasMore": False, "nextCursor": None}
        }
        with self.assertRaises(remnawave_probe.ProbeError):
            remnawave_probe.probe(
                "https://panel.example.test/api",
                "a" * 32,
                "{}",
                opener=FakeOpener(FakeResponse(document, status=302)),
            )

    def test_rejects_cookie_header_injection(self) -> None:
        with self.assertRaises(remnawave_probe.ProbeError):
            remnawave_probe.parse_cookies("access=value; injected=1")

    def test_accepts_legacy_nginx_cookie_matcher(self) -> None:
        self.assertEqual(
            remnawave_probe.parse_cookies('{"~*access@edge=cookie-value"}'),
            {"access@edge": "cookie-value"},
        )

    def test_probe_ignores_ambient_proxy_configuration(self) -> None:
        opener = FakeOpener(FakeResponse({
            "response": {"users": [], "hasMore": False, "nextCursor": None}
        }))

        with patch.object(
            remnawave_probe,
            "build_opener",
            return_value=opener,
        ) as build_opener:
            remnawave_probe.probe(
                "https://panel.example.test/api",
                "a" * 32,
                "{}",
            )

        handlers = build_opener.call_args.args
        self.assertIsInstance(handlers[0], ProxyHandler)
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(
            handlers[1],
            remnawave_probe.NoRedirectHandler,
        )


if __name__ == "__main__":
    unittest.main()
