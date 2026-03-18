#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_BASE_URL = "https://team.654301.xyz"


@dataclass(frozen=True)
class EndpointConfig:
    path: str
    field_name: str
    description: str


ENDPOINTS = {
    "status": EndpointConfig(
        path="/api/status/",
        field_name="code",
        description="Check activation status for a single code.",
    ),
    "warranty": EndpointConfig(
        path="/api/warranty/activate/",
        field_name="codes",
        description="Check warranty activation flow for a single code.",
    ),
}

TSV_FIELDS = [
    "input_code",
    "http_status",
    "api_code",
    "reason",
    "level",
    "message",
    "status",
    "status_label",
    "last_used_email",
    "used_by_email",
    "used_at",
    "warranty_duration",
    "warranty_expires_at",
    "first_used_at",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Batch-check codes against the public endpoints used by team.654301.xyz. "
            "This wraps the site's single-code APIs; it does not send multi-code payloads."
        )
    )
    parser.add_argument(
        "mode",
        choices=sorted(ENDPOINTS.keys()),
        help="Query mode: status or warranty.",
    )
    parser.add_argument(
        "--code",
        action="append",
        dest="codes",
        default=[],
        help="A single code to query. Repeat to add more codes.",
    )
    parser.add_argument(
        "--file",
        type=Path,
        help="Read one code per line from a file.",
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"Base URL of the site. Default: {DEFAULT_BASE_URL}",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=0.3,
        help="Delay in seconds between requests. Default: 0.3",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=15.0,
        help="HTTP timeout in seconds. Default: 15",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "json"),
        default="tsv",
        help="Output format. Default: tsv",
    )
    parser.add_argument(
        "--include-raw",
        action="store_true",
        help="Include the full JSON payload in TSV output.",
    )
    return parser.parse_args()


def read_codes(args: argparse.Namespace) -> list[str]:
    candidates: list[str] = []
    candidates.extend(args.codes)

    if args.file:
        candidates.extend(args.file.read_text(encoding="utf-8").splitlines())

    if not candidates and not sys.stdin.isatty():
        candidates.extend(sys.stdin.read().splitlines())

    seen: set[str] = set()
    codes: list[str] = []
    for raw in candidates:
        code = raw.strip()
        if not code or code.startswith("#") or code in seen:
            continue
        seen.add(code)
        codes.append(code)
    return codes


def perform_request(
    *,
    base_url: str,
    endpoint: EndpointConfig,
    code: str,
    timeout: float,
) -> dict[str, Any]:
    payload = urllib.parse.urlencode({endpoint.field_name: code}).encode("utf-8")
    url = urllib.parse.urljoin(ensure_trailing_slash(base_url), endpoint.path.lstrip("/"))
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Requested-With": "XMLHttpRequest",
            "User-Agent": "Copool batch checker/1.0",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
            return {
                "input_code": code,
                "http_status": response.status,
                "payload": json.loads(body),
            }
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        try:
            payload_json = json.loads(body)
        except json.JSONDecodeError:
            payload_json = {"message": body or str(error.reason)}
        return {
            "input_code": code,
            "http_status": error.code,
            "payload": payload_json,
        }
    except urllib.error.URLError as error:
        return {
            "input_code": code,
            "http_status": 0,
            "payload": {
                "reason": "network_error",
                "message": str(error.reason),
            },
        }


def ensure_trailing_slash(url: str) -> str:
    return url if url.endswith("/") else f"{url}/"


def build_rows(results: Iterable[dict[str, Any]], include_raw: bool) -> tuple[list[str], list[dict[str, Any]]]:
    fieldnames = list(TSV_FIELDS)
    if include_raw:
        fieldnames.append("raw_json")

    rows: list[dict[str, Any]] = []
    for result in results:
        payload = result["payload"]
        row = {
            "input_code": result["input_code"],
            "http_status": result["http_status"],
            "api_code": payload.get("code", ""),
            "reason": payload.get("reason", ""),
            "level": payload.get("level", payload.get("status_level", "")),
            "message": payload.get("message", ""),
            "status": payload.get("status", ""),
            "status_label": payload.get("status_label", ""),
            "last_used_email": payload.get("last_used_email", ""),
            "used_by_email": payload.get("used_by_email", ""),
            "used_at": payload.get("used_at", ""),
            "warranty_duration": payload.get("warranty_duration", ""),
            "warranty_expires_at": payload.get("warranty_expires_at", ""),
            "first_used_at": payload.get("first_used_at", ""),
        }
        if include_raw:
            row["raw_json"] = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        rows.append(row)
    return fieldnames, rows


def write_tsv(results: list[dict[str, Any]], include_raw: bool) -> None:
    fieldnames, rows = build_rows(results, include_raw)
    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)


def write_json(results: list[dict[str, Any]]) -> None:
    json.dump(results, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


def main() -> int:
    args = parse_args()
    codes = read_codes(args)
    if not codes:
        print("No codes provided. Use --code, --file, or stdin.", file=sys.stderr)
        return 2

    endpoint = ENDPOINTS[args.mode]
    results: list[dict[str, Any]] = []
    for index, code in enumerate(codes):
        if index:
            time.sleep(max(args.delay, 0.0))
        results.append(
            perform_request(
                base_url=args.base_url,
                endpoint=endpoint,
                code=code,
                timeout=args.timeout,
            )
        )

    if args.format == "json":
        write_json(results)
    else:
        write_tsv(results, include_raw=args.include_raw)

    has_network_error = any(result["http_status"] == 0 for result in results)
    return 1 if has_network_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
