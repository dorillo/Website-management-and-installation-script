#!/usr/bin/env python3
"""Perform a read-only Remnawave 3.x API and token-scope probe."""

from __future__ import annotations

import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import (
    HTTPRedirectHandler,
    ProxyHandler,
    Request,
    build_opener,
)


PROBE_EMAIL = "vpn-site-manager-probe@example.invalid"
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_SAFE_INTEGER = 9_007_199_254_740_991
COOKIE_NAME_RE = re.compile(r"^[!#$%&'*+.^_`|~@0-9A-Za-z-]+$")


class ProbeError(RuntimeError):
    pass


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


def parse_cookies(raw_value: str) -> dict[str, str]:
    value = raw_value.strip()
    if not value or value == "{}":
        return {}

    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        parsed = value
        # Older manager versions stored the Nginx matcher as {"~*name=value"}.
        if value.startswith("{") and value.endswith("}"):
            inner = value[1:-1].strip()
            try:
                parsed = json.loads(inner)
            except json.JSONDecodeError:
                parsed = inner

    if isinstance(parsed, dict):
        cookies = parsed
    elif isinstance(parsed, str):
        pair = parsed.strip()
        if pair.startswith("~*"):
            pair = pair[2:]
        if "=" not in pair:
            raise ProbeError("invalid Remnawave cookie configuration")
        name, cookie_value = pair.split("=", 1)
        cookies = {name: cookie_value}
    else:
        raise ProbeError("invalid Remnawave cookie configuration")

    if not cookies:
        return {}
    for name, cookie_value in cookies.items():
        if (
            not isinstance(name, str)
            or not COOKIE_NAME_RE.fullmatch(name)
            or not isinstance(cookie_value, str)
            or not cookie_value
            or any(ord(char) < 32 or ord(char) == 127 for char in cookie_value)
            or ";" in cookie_value
        ):
            raise ProbeError("invalid Remnawave cookie configuration")
    return cookies


def build_probe_url(api_url: str) -> str:
    parsed = urlsplit(api_url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ProbeError("invalid Remnawave API URL")
    return (
        f"{api_url.rstrip('/')}/users/stream?"
        + urlencode({"email": PROBE_EMAIL, "size": 1})
    )


def validate_response(payload: bytes) -> None:
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProbeError("Remnawave returned invalid JSON") from error

    response = document.get("response") if isinstance(document, dict) else None
    if not isinstance(response, dict):
        raise ProbeError("Remnawave returned an incompatible response")

    users = response.get("users")
    has_more = response.get("hasMore")
    next_cursor = response.get("nextCursor")
    if (
        not isinstance(users, list)
        or len(users) > 1
        or not isinstance(has_more, bool)
    ):
        raise ProbeError("Remnawave returned an incompatible response")
    if has_more:
        if isinstance(next_cursor, bool) or not (
            isinstance(next_cursor, int)
            or isinstance(next_cursor, str)
            and next_cursor.isascii()
            and next_cursor.isdigit()
        ):
            raise ProbeError("Remnawave returned an incompatible cursor")
        cursor = int(next_cursor)
        if not 1 <= cursor <= MAX_SAFE_INTEGER:
            raise ProbeError("Remnawave returned an incompatible cursor")
    elif next_cursor is not None:
        raise ProbeError("Remnawave returned an incompatible cursor")

    for user in users:
        user_id = user.get("id") if isinstance(user, dict) else None
        email = user.get("email") if isinstance(user, dict) else None
        if (
            isinstance(user_id, bool)
            or not isinstance(user_id, int)
            or not 1 <= user_id <= MAX_SAFE_INTEGER
            or not isinstance(email, str)
            or email.strip().lower() != PROBE_EMAIL
        ):
            raise ProbeError("Remnawave returned an incompatible user")


def probe(api_url: str, token: str, cookie_value: str, opener=None) -> None:
    if not token or any(char.isspace() for char in token):
        raise ProbeError("invalid Remnawave token")

    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    cookies = parse_cookies(cookie_value)
    if cookies:
        headers["Cookie"] = "; ".join(
            f"{name}={value}" for name, value in cookies.items()
        )

    request = Request(build_probe_url(api_url), headers=headers, method="GET")
    client = opener or build_opener(ProxyHandler({}), NoRedirectHandler())
    with client.open(request, timeout=20) as response:
        if response.status != 200:
            raise ProbeError(f"unexpected HTTP status {response.status}")
        payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProbeError("Remnawave response is too large")
    validate_response(payload)


def main() -> int:
    try:
        probe(
            os.environ.get("REMNAWAVE_API_URL", ""),
            os.environ.get("REMNAWAVE_TOKEN", ""),
            os.environ.get("REMNAWAVE_COOKIES_JSON", "{}"),
        )
    except HTTPError as error:
        print(
            f"Remnawave probe failed with HTTP status {error.code}.",
            file=sys.stderr,
        )
        return 1
    except (ProbeError, URLError, OSError, ValueError) as error:
        print(f"Remnawave probe failed: {error}", file=sys.stderr)
        return 1

    print("Remnawave 3.x users/stream probe passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
