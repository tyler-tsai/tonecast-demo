#!/usr/bin/env python3
"""
asc_jwt.py — generate a short-lived JWT for the App Store Connect API.

Reads env vars APP_STORE_KEY_ID / APP_STORE_KEY_ISSUER_ID / APP_STORE_KEY_PATH
and prints the signed token to stdout. Bash scripts pipe this into curl's
Authorization header.

Tokens are valid for 20 minutes (Apple's max for ASC JWTs). Sign each
request fresh — don't try to cache.
"""
import os
import sys
import time
import jwt  # pyjwt
from pathlib import Path


def main() -> int:
    key_id = os.environ.get("APP_STORE_KEY_ID", "").strip()
    issuer = os.environ.get("APP_STORE_KEY_ISSUER_ID", "").strip()
    key_path = os.environ.get("APP_STORE_KEY_PATH", "").strip()

    missing = [
        n for n, v in [
            ("APP_STORE_KEY_ID", key_id),
            ("APP_STORE_KEY_ISSUER_ID", issuer),
            ("APP_STORE_KEY_PATH", key_path),
        ] if not v
    ]
    if missing:
        sys.stderr.write(
            f"asc_jwt.py: missing env var(s): {', '.join(missing)}\n"
            "Source your shell config and try again (e.g. `source ~/.zshrc`).\n"
        )
        return 1

    p = Path(key_path).expanduser()
    if not p.is_file():
        sys.stderr.write(f"asc_jwt.py: key file not found at {p}\n")
        return 1

    key_pem = p.read_bytes()
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": issuer,
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1",
        },
        key_pem,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
    # PyJWT returns str in modern versions; older versions return bytes.
    if isinstance(token, bytes):
        token = token.decode("ascii")
    sys.stdout.write(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
