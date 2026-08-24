#!/usr/bin/env python3
"""Derive an SES SMTP password from an IAM secret access key.

AWS's own published algorithm (the same one the SES console's "Create SMTP
credentials" wizard runs internally) -- there is no separate "SMTP secret",
only this deterministic transform of the IAM secret access key. Run this
locally with Terraform's smtp_secret_access_key output; never commit the
result anywhere but SOPS.

Usage:
    python3 scripts/derive_smtp_password.py <secret_access_key> [region]
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import sys

_DATE = "11111111"
_SERVICE = "ses"
_TERMINAL = "aws4_request"
_MESSAGE = "SendRawEmail"
_VERSION = bytes([0x04])


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def derive(secret_access_key: str, region: str) -> str:
    signature = _sign(("AWS4" + secret_access_key).encode("utf-8"), _DATE)
    signature = _sign(signature, region)
    signature = _sign(signature, _SERVICE)
    signature = _sign(signature, _TERMINAL)
    signature = _sign(signature, _MESSAGE)
    return base64.b64encode(_VERSION + signature).decode("utf-8")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(1)
    secret_key = sys.argv[1]
    aws_region = sys.argv[2] if len(sys.argv) == 3 else "eu-central-1"
    print(derive(secret_key, aws_region))
