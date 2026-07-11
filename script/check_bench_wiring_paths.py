#!/usr/bin/env python3
"""Check the visible bench-map wire lanes for crossings and visual overlap."""

from __future__ import annotations

import re
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path

from html_runtime import render_html


ROOT = Path(__file__).resolve().parents[1]
HTML_PATH = ROOT / "phase-1-desk-test-wiring.html"
MIN_PARALLEL_CENTER_SPACING = 12.0  # 8px wire plus a 4px visible gap.


@dataclass(frozen=True)
class WirePath:
    label: str
    classes: frozenset[str]
    d: str


@dataclass(frozen=True)
class Segment:
    wire: WirePath
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def horizontal(self) -> bool:
        return self.y1 == self.y2

    @property
    def min_x(self) -> float:
        return min(self.x1, self.x2)

    @property
    def max_x(self) -> float:
        return max(self.x1, self.x2)

    @property
    def min_y(self) -> float:
        return min(self.y1, self.y2)

    @property
    def max_y(self) -> float:
        return max(self.y1, self.y2)


class WireParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.paths: list[WirePath] = []
        self.bridges: list[WirePath] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "path":
            return
        values = {name: value or "" for name, value in attrs}
        classes = frozenset(values.get("class", "").split())
        if "wire" not in classes or "bread-jumper" in classes or "card-bridge" in classes:
            return
        if not values.get("d"):
            raise AssertionError(f"Runtime wire path {values.get('id', 'unlabeled')} has no geometry")
        path = WirePath(values.get("data-parts", "unlabeled"), classes, values["d"])
        if "wire-bridge" in classes:
            self.bridges.append(path)
        else:
            self.paths.append(path)


def segments_for(path: WirePath) -> list[Segment]:
    tokens = re.findall(r"[MHVL]|-?\d+(?:\.\d+)?", path.d)
    index = 0
    x = 0.0
    y = 0.0
    segments: list[Segment] = []
    while index < len(tokens):
        command = tokens[index]
        index += 1
        if command == "M":
            x = float(tokens[index])
            y = float(tokens[index + 1])
            index += 2
        elif command == "H":
            next_x = float(tokens[index])
            index += 1
            segments.append(Segment(path, x, y, next_x, y))
            x = next_x
        elif command == "V":
            next_y = float(tokens[index])
            index += 1
            segments.append(Segment(path, x, y, x, next_y))
            y = next_y
        elif command == "L":
            next_x = float(tokens[index])
            next_y = float(tokens[index + 1])
            index += 2
            segments.append(Segment(path, x, y, next_x, next_y))
            x, y = next_x, next_y
        else:
            raise ValueError(f"Unsupported SVG command {command!r} in {path.d!r}")
    return [segment for segment in segments if segment.x1 != segment.x2 or segment.y1 != segment.y2]


def visible(path: WirePath, mode: str) -> bool:
    if mode == "buck":
        return "usb-wire" not in path.classes and "usb-ground-wire" not in path.classes
    return "buck-wire" not in path.classes


def overlap_length(first_min: float, first_max: float, second_min: float, second_max: float) -> float:
    return min(first_max, second_max) - max(first_min, second_min)


def intersection_point(first: Segment, second: Segment) -> tuple[float, float] | None:
    """Return the intersection of two finite straight segments, including diagonals."""

    denominator = (first.x1 - first.x2) * (second.y1 - second.y2) - (
        first.y1 - first.y2
    ) * (second.x1 - second.x2)
    if abs(denominator) < 1e-9:
        return None
    first_cross = first.x1 * first.y2 - first.y1 * first.x2
    second_cross = second.x1 * second.y2 - second.y1 * second.x2
    x = (
        first_cross * (second.x1 - second.x2)
        - (first.x1 - first.x2) * second_cross
    ) / denominator
    y = (
        first_cross * (second.y1 - second.y2)
        - (first.y1 - first.y2) * second_cross
    ) / denominator
    epsilon = 1e-6
    if not (
        first.min_x - epsilon <= x <= first.max_x + epsilon
        and first.min_y - epsilon <= y <= first.max_y + epsilon
        and second.min_x - epsilon <= x <= second.max_x + epsilon
        and second.min_y - epsilon <= y <= second.max_y + epsilon
    ):
        return None
    return x, y


def bridge_covers(bridges: list[WirePath], wire: WirePath, x: float, y: float) -> bool:
    for bridge in bridges:
        if bridge.label != wire.label:
            continue
        for segment in segments_for(bridge):
            if (
                segment.min_x - 0.1 <= x <= segment.max_x + 0.1
                and segment.min_y - 0.1 <= y <= segment.max_y + 0.1
            ):
                return True
    return False


def issues_for_mode(paths: list[WirePath], bridges: list[WirePath], mode: str) -> list[str]:
    segments = [segment for path in paths if visible(path, mode) for segment in segments_for(path)]
    issues: list[str] = []
    for index, first in enumerate(segments):
        for second in segments[index + 1 :]:
            if first.wire is second.wire:
                continue

            pair = f"{first.wire.label!r} / {second.wire.label!r}"
            if first.horizontal and second.horizontal:
                shared = overlap_length(first.min_x, first.max_x, second.min_x, second.max_x)
                if shared > 0 and first.y1 == second.y1:
                    issues.append(f"collinear overlap: {pair}")
                elif shared > 0 and abs(first.y1 - second.y1) < MIN_PARALLEL_CENTER_SPACING:
                    issues.append(f"horizontal clearance below {MIN_PARALLEL_CENTER_SPACING:g}px: {pair}")
                continue

            if not first.horizontal and not second.horizontal:
                shared = overlap_length(first.min_y, first.max_y, second.min_y, second.max_y)
                if shared > 0 and first.x1 == second.x1:
                    issues.append(f"collinear overlap: {pair}")
                elif shared > 0 and abs(first.x1 - second.x1) < MIN_PARALLEL_CENTER_SPACING:
                    issues.append(f"vertical clearance below {MIN_PARALLEL_CENTER_SPACING:g}px: {pair}")
                continue

            intersection = intersection_point(first, second)
            if intersection:
                x, y = intersection
                if not (
                    bridge_covers(bridges, first.wire, x, y)
                    or bridge_covers(bridges, second.wire, x, y)
                ):
                    issues.append(f"wire crossing: {pair} at ({x:g}, {y:g})")
    return sorted(set(issues))


def main() -> int:
    parser = WireParser()
    parser.feed(render_html(HTML_PATH))
    if not parser.paths:
        raise AssertionError("No bench wiring paths found")

    failures: list[str] = []
    for mode in ("buck", "usb"):
        issues = issues_for_mode(parser.paths, parser.bridges, mode)
        print(f"{mode} mode: {len(parser.paths) - sum(not visible(path, mode) for path in parser.paths)} visible paths")
        if issues:
            failures.extend(f"{mode}: {issue}" for issue in issues)
        else:
            print(f"- no crossings, collinear overlaps, or parallel lanes below {MIN_PARALLEL_CENTER_SPACING:g}px")

    if failures:
        raise AssertionError("\n".join(failures))
    if not parser.bridges:
        raise AssertionError("Intentional wire crossing has no rendered bridge marker")
    print(f"- {len(parser.bridges)} intentional crossing bridge rendered")
    print("Bench wiring path validation: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
