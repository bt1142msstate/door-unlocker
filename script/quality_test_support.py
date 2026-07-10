#!/usr/bin/env python3
"""Shared helpers for inspecting Swift test declarations.

These helpers only establish that a test is registered in source. Runtime
success is separate evidence and must come from `swift test` or `xcodebuild
test` in the quality suite.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable


XCTEST_DECLARATION = re.compile(r"^\s*func\s+test[A-Za-z0-9_]*\s*\(", re.M)
SWIFT_TESTING_DECLARATION = re.compile(r"^\s*@Test(?:\s*\([^\n]*\))?\s*$", re.M)


def without_swift_comments(text: str) -> str:
    """Remove Swift comments while preserving strings and line structure."""
    output: list[str] = []
    index = 0
    block_depth = 0
    in_string = False
    escaped = False

    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""

        if block_depth:
            if current == "/" and following == "*":
                block_depth += 1
                output.extend("  ")
                index += 2
                continue
            if current == "*" and following == "/":
                block_depth -= 1
                output.extend("  ")
                index += 2
                continue
            output.append("\n" if current == "\n" else " ")
            index += 1
            continue

        if in_string:
            output.append(current)
            if escaped:
                escaped = False
            elif current == "\\":
                escaped = True
            elif current == '"':
                in_string = False
            index += 1
            continue

        if current == '"':
            in_string = True
            output.append(current)
            index += 1
            continue
        if current == "/" and following == "/":
            while index < len(text) and text[index] != "\n":
                output.append(" ")
                index += 1
            continue
        if current == "/" and following == "*":
            block_depth = 1
            output.extend("  ")
            index += 2
            continue

        output.append(current)
        index += 1

    return "".join(output)


def swift_structure_text(text: str) -> str:
    """Mask comments and string contents so declarations/braces can be counted."""
    source = without_swift_comments(text)
    output: list[str] = []
    index = 0
    delimiter: str | None = None
    escaped = False

    while index < len(source):
        if delimiter is None:
            if source.startswith('"""', index):
                delimiter = '"""'
                output.extend("   ")
                index += 3
                continue
            if source[index] == '"':
                delimiter = '"'
                output.append(" ")
                index += 1
                continue
            output.append(source[index])
            index += 1
            continue

        if delimiter == '"""' and source.startswith('"""', index):
            delimiter = None
            output.extend("   ")
            index += 3
            continue
        if delimiter == '"':
            if escaped:
                escaped = False
            elif source[index] == "\\":
                escaped = True
            elif source[index] == '"':
                delimiter = None

        output.append("\n" if source[index] == "\n" else " ")
        index += 1

    return "".join(output)


def count_swift_test_declarations(text: str) -> int:
    source = swift_structure_text(text)
    return len(XCTEST_DECLARATION.findall(source)) + len(SWIFT_TESTING_DECLARATION.findall(source))


def count_swift_tests(paths: Iterable[Path]) -> int:
    return sum(
        count_swift_test_declarations(path.read_text(encoding="utf-8"))
        for path in paths
        if path.exists()
    )


def count_swift_tests_under(path: Path) -> int:
    if not path.exists():
        return 0
    return count_swift_tests(path.rglob("*.swift"))
