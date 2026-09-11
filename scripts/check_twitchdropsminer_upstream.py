#!/usr/bin/env python3
"""Detect persisted-query hash drift in DevilXD/TwitchDropsMiner.

The checker downloads source as data through GitHub's API. It never imports or
executes upstream code and it never changes SwiftMiner files.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


UPSTREAM_QUERY_PATTERN = re.compile(
    r'"(?P<key>[A-Za-z0-9_]+)"\s*:\s*GQLPersistedQuery\('
    r'\s*(?:#[^\n]*\n\s*)?'
    r'"(?P<operation>[^"]+)"\s*,\s*'
    r'"(?P<hash>[0-9a-f]{64})"',
    re.MULTILINE,
)
SWIFT_HASH_PATTERN = re.compile(
    r'public\s+static\s+let\s+(?P<name>[A-Za-z0-9_]+)\s*=\s*'
    r'"(?P<hash>[0-9a-f]{64})"'
)


class CheckError(RuntimeError):
    """The monitor could not safely complete its check."""


@dataclass(frozen=True)
class HashMismatch:
    upstream_key: str
    swift_constant: str
    upstream_hash: str | None
    swift_hash: str | None


@dataclass(frozen=True)
class DriftReport:
    head: str
    hash_mismatches: tuple[HashMismatch, ...]

    @property
    def has_drift(self) -> bool:
        return bool(self.hash_mismatches)


def parse_upstream_queries(source: str) -> dict[str, tuple[str, str]]:
    """Return upstream registry key -> (operation name, SHA-256 hash)."""
    return {
        match.group("key"): (match.group("operation"), match.group("hash"))
        for match in UPSTREAM_QUERY_PATTERN.finditer(source)
    }


def parse_swift_hashes(source: str) -> dict[str, str]:
    """Return Swift constant name -> SHA-256 hash."""
    return {
        match.group("name"): match.group("hash")
        for match in SWIFT_HASH_PATTERN.finditer(source)
    }


def analyze(
    config: dict[str, Any],
    *,
    head: str,
    upstream_queries: dict[str, tuple[str, str]],
    swift_hashes: dict[str, str],
) -> DriftReport:
    mismatches: list[HashMismatch] = []
    for mapping in config["hashMappings"]:
        upstream_key = mapping["upstreamKey"]
        swift_constant = mapping["swiftConstant"]
        upstream_entry = upstream_queries.get(upstream_key)
        upstream_hash = upstream_entry[1] if upstream_entry is not None else None
        swift_hash = swift_hashes.get(swift_constant)
        if upstream_hash is None or swift_hash is None or upstream_hash != swift_hash:
            mismatches.append(
                HashMismatch(
                    upstream_key=upstream_key,
                    swift_constant=swift_constant,
                    upstream_hash=upstream_hash,
                    swift_hash=swift_hash,
                )
            )

    return DriftReport(
        head=head,
        hash_mismatches=tuple(mismatches),
    )


class GitHubClient:
    def __init__(self, token: str | None = None) -> None:
        self._token = token

    def get_json(self, url: str) -> dict[str, Any]:
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "SwiftMiner-query-hash-monitor",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (
            urllib.error.URLError,
            TimeoutError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ) as error:
            raise CheckError(f"GitHub API request failed for {url}: {error}") from error


def api_url(repository: str, suffix: str) -> str:
    quoted_repository = "/".join(
        urllib.parse.quote(part, safe="") for part in repository.split("/")
    )
    return f"https://api.github.com/repos/{quoted_repository}/{suffix}"


def fetch_upstream_state(
    client: GitHubClient,
    config: dict[str, Any],
) -> tuple[str, str]:
    repository = config["repository"]
    branch = urllib.parse.quote(config["branch"], safe="")

    commit = client.get_json(api_url(repository, f"commits/{branch}"))
    head = commit.get("sha")
    if not isinstance(head, str) or not head:
        raise CheckError("GitHub commit response did not contain a head SHA")

    contents = client.get_json(
        api_url(repository, f"contents/constants.py?ref={urllib.parse.quote(head, safe='')}")
    )
    encoded = contents.get("content")
    if not isinstance(encoded, str):
        raise CheckError("GitHub contents response did not include constants.py data")
    try:
        source = base64.b64decode(encoded, validate=False).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise CheckError(f"Could not decode upstream constants.py: {error}") from error

    return head, source


def validate_config(config: dict[str, Any]) -> None:
    required = ("repository", "branch", "hashMappings")
    missing = [key for key in required if key not in config]
    if missing:
        raise CheckError(f"Monitor config is missing: {', '.join(missing)}")
    if not isinstance(config["hashMappings"], list) or not config["hashMappings"]:
        raise CheckError("hashMappings must be a non-empty list")
    for mapping in config["hashMappings"]:
        if not isinstance(mapping, dict) or not all(
            isinstance(mapping.get(key), str) and mapping[key]
            for key in ("upstreamKey", "swiftConstant")
        ):
            raise CheckError(
                "every hashMappings entry must define upstreamKey and swiftConstant"
            )


def print_report(report: DriftReport, repository: str) -> None:
    print("TwitchDropsMiner persisted-query hash check")
    print(f"Repository: https://github.com/{repository}")
    print(f"Current:    {report.head}")

    if report.hash_mismatches:
        print("\nPersisted-query differences:")
        for mismatch in report.hash_mismatches:
            upstream = mismatch.upstream_hash or "missing"
            swift = mismatch.swift_hash or "missing"
            print(
                f"  - {mismatch.upstream_key} -> {mismatch.swift_constant}: "
                f"upstream={upstream}, SwiftMiner={swift}"
            )

    if report.has_drift:
        print(f"\nUpdate required: https://github.com/{repository}/commit/{report.head}")
    else:
        print("\nNo persisted-query hash drift detected.")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(".github/upstream/twitchdropsminer.json"),
    )
    parser.add_argument(
        "--swift-hashes",
        type=Path,
        default=Path("Sources/SwiftMinerCore/Utils/GQLHashes.swift"),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        config = json.loads(arguments.config.read_text(encoding="utf-8"))
        validate_config(config)
        swift_source = arguments.swift_hashes.read_text(encoding="utf-8")
        client = GitHubClient(os.environ.get("GITHUB_TOKEN"))
        head, upstream_source = fetch_upstream_state(client, config)
        upstream_queries = parse_upstream_queries(upstream_source)
        swift_hashes = parse_swift_hashes(swift_source)
        report = analyze(
            config,
            head=head,
            upstream_queries=upstream_queries,
            swift_hashes=swift_hashes,
        )
        print_report(report, config["repository"])
        return 1 if report.has_drift else 0
    except (CheckError, OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"Query hash monitor could not complete safely: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
