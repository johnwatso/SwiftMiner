#!/usr/bin/env python3
"""Extract Twitch persisted-query hashes from a local request capture.

The input may be a browser-exported HAR file or a copied Twitch GraphQL JSON
request body. The tool reads local data only and deliberately ignores request
headers, cookies, access tokens, variables, and response bodies.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse


DEFAULT_OPERATION = "ViewerDropsDashboard"
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class DiscoveryError(RuntimeError):
    """The capture could not be read or did not contain the requested query."""


@dataclass(frozen=True)
class QueryHash:
    operation_name: str
    sha256_hash: str


def _is_twitch_gql_request(request: dict[str, Any]) -> bool:
    if request.get("method") != "POST":
        return False
    url = request.get("url")
    if not isinstance(url, str):
        return False
    parsed = urlparse(url)
    return parsed.hostname == "gql.twitch.tv" and parsed.path.rstrip("/") == "/gql"


def _decode_post_data(post_data: dict[str, Any]) -> str | None:
    text = post_data.get("text")
    if not isinstance(text, str):
        return None
    if post_data.get("encoding") != "base64":
        return text
    try:
        return base64.b64decode(text, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return None


def _payload_documents(document: Any) -> Iterable[Any]:
    """Yield GraphQL request bodies without traversing headers or responses."""
    if isinstance(document, dict) and isinstance(document.get("log"), dict):
        entries = document["log"].get("entries", [])
        if not isinstance(entries, list):
            return
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            request = entry.get("request")
            if not isinstance(request, dict) or not _is_twitch_gql_request(request):
                continue
            post_data = request.get("postData")
            if not isinstance(post_data, dict):
                continue
            text = _decode_post_data(post_data)
            if text is None:
                continue
            try:
                yield json.loads(text)
            except json.JSONDecodeError:
                continue
        return

    # A direct payload copied from the browser's request inspector.
    yield document


def _requests(payload: Any) -> Iterable[dict[str, Any]]:
    if isinstance(payload, dict):
        yield payload
    elif isinstance(payload, list):
        for item in payload:
            if isinstance(item, dict):
                yield item


def discover(document: Any) -> list[QueryHash]:
    """Return valid persisted-query observations in capture order."""
    discoveries: list[QueryHash] = []
    for payload in _payload_documents(document):
        for request in _requests(payload):
            operation = request.get("operationName")
            extensions = request.get("extensions")
            if not isinstance(operation, str) or not isinstance(extensions, dict):
                continue
            persisted = extensions.get("persistedQuery")
            if not isinstance(persisted, dict):
                continue
            query_hash = persisted.get("sha256Hash")
            if not isinstance(query_hash, str) or not HASH_PATTERN.fullmatch(query_hash):
                continue
            discoveries.append(QueryHash(operation, query_hash))
    return discoveries


def latest_by_operation(discoveries: Iterable[QueryHash]) -> dict[str, str]:
    """Return the final observed hash for every operation."""
    latest: dict[str, str] = {}
    for discovery in discoveries:
        latest[discovery.operation_name] = discovery.sha256_hash
    return latest


def _read_document(path: Path) -> Any:
    try:
        raw = sys.stdin.read() if str(path) == "-" else path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise DiscoveryError(
            "capture file not found. In Safari Web Inspector's Network tab, "
            "reload the Twitch Drops page, press Command-S to export a HAR, "
            "then pass that saved file's actual path"
        ) from error
    except OSError as error:
        raise DiscoveryError(f"could not read capture: {error}") from error
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise DiscoveryError(
            f"capture is not valid JSON (line {error.lineno}, column {error.colno})"
        ) from error


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "capture",
        type=Path,
        help="HAR or JSON request-body file; use - to read JSON from standard input",
    )
    parser.add_argument(
        "--operation",
        default=DEFAULT_OPERATION,
        help=f"operation to report (default: {DEFAULT_OPERATION})",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="report every persisted-query operation in the capture",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit a JSON object instead of human-readable lines",
    )
    parser.add_argument(
        "--hash-only",
        action="store_true",
        help="emit only the requested hash (not valid together with --all or --json)",
    )
    arguments = parser.parse_args(argv)
    if arguments.hash_only and (arguments.all or arguments.json):
        parser.error("--hash-only cannot be combined with --all or --json")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        document = _read_document(arguments.capture)
        discoveries = discover(document)
        latest = latest_by_operation(discoveries)
        if arguments.all:
            selected = dict(sorted(latest.items()))
            if not selected:
                raise DiscoveryError("no persisted-query hashes were found")
        else:
            query_hash = latest.get(arguments.operation)
            if query_hash is None:
                raise DiscoveryError(
                    f"operation {arguments.operation!r} was not found in the capture"
                )
            selected = {arguments.operation: query_hash}

        if arguments.hash_only:
            print(next(iter(selected.values())))
        elif arguments.json:
            print(json.dumps(selected, indent=2, sort_keys=True))
        else:
            for operation, query_hash in selected.items():
                print(f"{operation}: {query_hash}")
        return 0
    except DiscoveryError as error:
        print(f"Twitch query hash discovery failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
