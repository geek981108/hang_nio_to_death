#!/usr/bin/env python3
"""Decrypt rows of public.tenant_configs written by backend/src/tenant_config.rs.

Scheme (see ConfigCipher::seal / open):
    ciphertext = AES-256-GCM(key = NIO_CONFIG_MASTER_KEY, nonce = config_nonce,
                             aad = b"nio-tenant-config-v1:" + slug)
    stored as Base64( ciphertext || 16-byte tag )
    nonce stored as Base64(12 random bytes)
    api_key_sha256 = hex(SHA-256(api_key))   (lookup only, not used for decryption)

Usage:
    export NIO_CONFIG_MASTER_KEY=<64 hex chars>
    ./decrypt_tenant_config.py --database-url "$DATABASE_URL"              # all tenants
    ./decrypt_tenant_config.py --database-url "$DATABASE_URL" --slug alice
    ./decrypt_tenant_config.py --stdin < rows.tsv                          # slug<TAB>nonce<TAB>ct
    ./decrypt_tenant_config.py --self-test

Rows can be produced with:
    psql "$DATABASE_URL" -At -F $'\t' \
      -c 'SELECT slug, config_nonce, config_ciphertext FROM public.tenant_configs ORDER BY slug'

The plaintext is secret. Output goes to stdout; redirect it somewhere private and delete it.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from typing import Any, Iterable

AAD_PREFIX = "nio-tenant-config-v1:"
SLUG_RE = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
ENV_ORDER = [
    ("api_key", "API_KEY"),
    ("nio_bearer_token", "NIO_BEARER_TOKEN"),
    ("nio_vehicle_id", "NIO_VEHICLE_ID"),
    ("nio_device_id", "NIO_DEVICE_ID"),
    ("nio_app_id", "NIO_APP_ID"),
    ("nio_app_version", "NIO_APP_VERSION"),
    ("nio_region", "NIO_REGION"),
    ("nio_language", "NIO_LANGUAGE"),
    ("nio_refresh_token", "NIO_REFRESH_TOKEN"),
]

# Known-answer test: produced by ring's AES_256_GCM seal_in_place_append_tag with
# key = 0x11 * 32, nonce = 0x22 * 12, aad = "nio-tenant-config-v1:default".
KAT_KEY = bytes([0x11]) * 32
KAT_NONCE = "IiIiIiIiIiIiIiIi"
KAT_CIPHERTEXT = (
    "bNVmOamQ9DqcHeQeeJfb5ium+9VSuM0pMStvjjnQVzBxSp01a5GYvC08iEvEdGtb2r3BAPATCJvGK56WiQ6B"
    "kEKuaFc62jRqigxG/XLL0i6L1MxhdYuzOjpttPVXxiPuqjc2dhA05ytxrc87VjX2Sjx9j9E5TKJi6l9FFDPf"
    "Jep3rNXJrjkREn4jZrCff18uOzE40a3KBGJu9gEkDTAYL3UZNFg5wkvSnEBQci/Mr0mFcLGONbgbfudHkI7R"
    "FqYYm+itr3YKfj+28VgnH8P2EpMETzEsgY4L6yRLvzWtJRdXArqBjQdOxgy56kk1A0Q8B1QBM0gseWNxGHn+4"
    "7dokbCiQ7DMuoFlH5oXf4aTkmwQVZdlEsyBdF0u3MVKcRkuAVpiRMoeGEZsuJ6QbYM6CN3cdx3J9PzC"
)
KAT_API_KEY_SHA256 = "3eb1bd439947eb762998e566ccc2e099c791118b2f40579cc4f7da2b5061b7f9"


class DecryptError(Exception):
    pass


def load_master_key() -> bytes:
    raw = os.environ.get("NIO_CONFIG_MASTER_KEY", "")
    if not raw:
        raise DecryptError("NIO_CONFIG_MASTER_KEY is not set")
    # Match ConfigCipher::from_env exactly: exactly 64 hex digits, no whitespace.
    # (bytes.fromhex alone is laxer: it skips whitespace and accepts shorter input.)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", raw):
        size = len(raw.encode())
        if size != 64:
            detail = f"got {size} bytes"
        else:
            bad = next(c for c in raw if c not in "0123456789abcdefABCDEF")
            detail = f"found {bad!r}; whitespace and non-hex characters are rejected"
        raise DecryptError(
            f"NIO_CONFIG_MASTER_KEY must be exactly 64 hexadecimal characters; {detail}"
        )
    return bytes.fromhex(raw)


def b64_decode(value: str, what: str) -> bytes:
    try:
        return base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise DecryptError(f"{what} is not valid Base64: {exc}") from exc


def decrypt_row(key: bytes, slug: str, nonce_b64: str, ciphertext_b64: str) -> dict[str, Any]:
    if not SLUG_RE.match(slug):
        raise DecryptError(f"invalid slug {slug!r}")
    nonce = b64_decode(nonce_b64, "config_nonce")
    if len(nonce) != 12:
        raise DecryptError(f"config_nonce must decode to 12 bytes, got {len(nonce)}")
    blob = b64_decode(ciphertext_b64, "config_ciphertext")
    if len(blob) < 16:
        raise DecryptError("config_ciphertext is shorter than the 16-byte GCM tag")

    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:  # pragma: no cover
        raise DecryptError(
            "python 'cryptography' package is required (pip install cryptography)"
        ) from exc

    aad = (AAD_PREFIX + slug).encode()
    try:
        plaintext = AESGCM(key).decrypt(nonce, blob, aad)
    except Exception as exc:  # InvalidTag
        raise DecryptError(
            f"{slug}: authentication failed (wrong master key, wrong slug, or tampered row)"
        ) from exc

    try:
        config = json.loads(plaintext)
    except json.JSONDecodeError as exc:
        raise DecryptError(f"{slug}: decrypted payload is not JSON: {exc}") from exc
    if not isinstance(config, dict):
        raise DecryptError(f"{slug}: decrypted payload is not a JSON object")
    return config


def verify_api_key(slug: str, config: dict[str, Any], expected: str) -> None:
    api_key = config.get("api_key")
    if not isinstance(api_key, str):
        raise DecryptError(f"{slug}: decrypted config has no api_key")
    actual = hashlib.sha256(api_key.encode()).hexdigest()
    if actual != expected.strip().lower():
        raise DecryptError(
            f"{slug}: api_key_sha256 mismatch (row {expected}, decrypted {actual})"
        )


def parse_tsv(lines: Iterable[str]) -> list[tuple[str, str, str, str | None]]:
    rows = []
    for number, line in enumerate(lines, 1):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            raise DecryptError(f"line {number}: expected slug<TAB>nonce<TAB>ciphertext[<TAB>sha256]")
        rows.append(
            (
                parts[0].strip(),
                parts[1].strip(),
                parts[2].strip(),
                parts[3].strip() if len(parts) > 3 and parts[3].strip() else None,
            )
        )
    return rows


def parse_json_rows(text: str) -> list[tuple[str, str, str, str | None]]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise DecryptError(f"invalid JSON input: {exc}") from exc
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        raise DecryptError("JSON input must be an object or an array of objects")
    rows = []
    for item in data:
        if not isinstance(item, dict):
            raise DecryptError("JSON rows must be objects")
        try:
            rows.append(
                (
                    str(item["slug"]),
                    str(item["config_nonce"]),
                    str(item["config_ciphertext"]),
                    str(item["api_key_sha256"]) if item.get("api_key_sha256") else None,
                )
            )
        except KeyError as exc:
            raise DecryptError(f"JSON row is missing {exc}") from exc
    return rows


def fetch_rows(database_url: str, slug: str | None) -> list[tuple[str, str, str, str | None]]:
    psql = shutil.which("psql")
    if not psql:
        raise DecryptError("psql not found on PATH; pass --stdin instead")
    sql = (
        "SELECT slug, config_nonce, config_ciphertext, api_key_sha256 "
        "FROM public.tenant_configs"
    )
    if slug:
        if not SLUG_RE.match(slug):
            raise DecryptError(f"invalid slug {slug!r}")
        sql += f" WHERE slug = '{slug}'"
    sql += " ORDER BY slug"
    result = subprocess.run(
        [psql, database_url, "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise DecryptError(f"psql failed: {result.stderr.strip()}")
    return parse_tsv(result.stdout.splitlines())


def emit_env(config: dict[str, Any]) -> str:
    lines = []
    for field, name in ENV_ORDER:
        value = config.get(field)
        if value is None:
            continue
        lines.append(f"{name}={quote_env(str(value))}")
    extra = config.get("extra") or {}
    if isinstance(extra, dict):
        for name in sorted(extra):
            lines.append(f"{name}={quote_env(str(extra[name]))}")
    return "\n".join(lines)


def quote_env(value: str) -> str:
    """Quote for TenantCredentials::from_input.

    That parser trims the raw value and strips one matching pair of surrounding
    quotes, but performs no unescaping, so backslash escapes would corrupt data.
    """
    if "\n" in value or "\r" in value:
        print("warning: value contains a newline; re-import cannot round-trip it", file=sys.stderr)
        return value
    stripped = value.strip()
    if stripped != value:
        print("warning: value has leading/trailing whitespace; re-import trims it", file=sys.stderr)
    if '"' in stripped and "'" in stripped:
        print("warning: value contains both quote characters; re-import cannot round-trip it",
              file=sys.stderr)
        return stripped
    if "'" in stripped:
        return f'"{stripped}"'
    if '"' in stripped:
        return f"'{stripped}'"
    return stripped


def self_test() -> int:
    config = decrypt_row(KAT_KEY, "default", KAT_NONCE, KAT_CIPHERTEXT)
    verify_api_key("default", config, KAT_API_KEY_SHA256)
    try:
        decrypt_row(KAT_KEY, "other", KAT_NONCE, KAT_CIPHERTEXT)
    except DecryptError:
        pass
    else:
        print("self-test FAILED: AAD is not bound to the slug", file=sys.stderr)
        return 1
    print("self-test OK (ring-compatible vector, slug binding enforced)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Decrypt public.tenant_configs rows (AES-256-GCM).",
        epilog="Master key is read from NIO_CONFIG_MASTER_KEY.",
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--database-url", help="PostgreSQL URL for psql; defaults to $DATABASE_URL")
    source.add_argument("--stdin", action="store_true", help="read rows from stdin as TSV or JSON")
    parser.add_argument("--slug", help="only decrypt this tenant")
    parser.add_argument("--format", choices=["json", "env", "merge"], default="merge",
                        help="merge: one JSON object per tenant (default); json: a JSON array; "
                             "env: KEY=value blocks")
    parser.add_argument("--self-test", action="store_true", help="verify against a known vector")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    try:
        key = load_master_key()
        if args.stdin or (not args.database_url and not os.environ.get("DATABASE_URL")):
            if sys.stdin.isatty():
                raise DecryptError(
                    "nothing to read: pass --database-url, set DATABASE_URL, or pipe rows to --stdin"
                )
            text = sys.stdin.read()
            if not text.strip():
                raise DecryptError("empty input: expected TSV rows or JSON")
            rows = parse_json_rows(text) if text.lstrip().startswith(("[", "{")) else parse_tsv(text.splitlines())
        else:
            rows = fetch_rows(args.database_url or os.environ["DATABASE_URL"], args.slug)

        results = []
        for slug, nonce, ciphertext, expected_hash in rows:
            if args.slug and slug != args.slug:
                continue
            config = decrypt_row(key, slug, nonce, ciphertext)
            if expected_hash:
                verify_api_key(slug, config, expected_hash)
            results.append({"slug": slug, "schema_name": "public" if slug == "default" else f"tenant_{slug}",
                            "credentials": config})
    except DecryptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not results:
        print("error: no matching rows", file=sys.stderr)
        return 1

    if args.format == "json":
        print(json.dumps(results, indent=2, ensure_ascii=False))
    elif args.format == "env":
        for item in results:
            print(f"# {item['slug']}")
            print(emit_env(item["credentials"]))
            print()
    else:
        for item in results:
            print(json.dumps(item, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
