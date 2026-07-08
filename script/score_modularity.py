#!/usr/bin/env python3
"""Score SwiftUI coupling/modularity for the Door Unlocker apps.

The score is intentionally simple and repeatable. It favors modern SwiftUI
structure: small files, tiny composition roots, dedicated subviews instead of
computed-view fragments, explicit feature folders, narrow data flow, and primary
types that match file names.

Apple does not publish a numeric Swift coupling/modularity score. This gate
therefore scores the app/UI boundary and reports large hardware state owners as
tracked risk instead of letting one BLE controller class swamp every SwiftUI
composition metric.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class AppConfig:
    name: str
    root: Path
    root_view: Path
    wide_dependency_names: tuple[str, ...]
    adapter_boundary_patterns: tuple[str, ...]
    expected_feature_dirs: tuple[str, ...]
    state_owner_names: tuple[str, ...]


APPS = (
    AppConfig(
        name="iOS",
        root=ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker",
        root_view=ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "ContentView.swift",
        wide_dependency_names=("DoorUnlockerController",),
        adapter_boundary_patterns=(
            "Views/Screen/",
            "Views/Components/ControllerStateCard.swift",
            "Views/Components/ControllerStatusPresentation.swift",
            "Views/Components/LockControlButton.swift",
            "Views/Components/PairingGuidanceView.swift",
            "Views/LockZone/",
            "Views/Settings/",
        ),
        expected_feature_dirs=("Styling", "Views/Components", "Views/LockZone"),
        state_owner_names=("DoorUnlockerController",),
    ),
    AppConfig(
        name="Mac",
        root=ROOT / "mac" / "DoorUnlockerAdmin" / "Sources" / "DoorUnlockerAdmin",
        root_view=ROOT / "mac" / "DoorUnlockerAdmin" / "Sources" / "DoorUnlockerAdmin" / "Views" / "ContentView.swift",
        wide_dependency_names=("DoorAdminStore",),
        adapter_boundary_patterns=(
            "Views/ContentView.swift",
            "Views/Navigation/",
            "Views/Detail/",
            "Views/Panels/",
            "Views/Settings/",
            "Views/Components/ControllerStatusStrip.swift",
        ),
        expected_feature_dirs=("Views/Components", "Views/Detail", "Views/Navigation", "Views/Panels", "Views/Settings"),
        state_owner_names=("DoorAdminStore",),
    ),
)


@dataclass
class SwiftFile:
    path: Path
    text: str
    lines: int

    @property
    def rel(self) -> str:
        return str(self.path.relative_to(ROOT))


def swift_files(root: Path) -> list[SwiftFile]:
    files: list[SwiftFile] = []
    for path in sorted(root.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        files.append(SwiftFile(path=path, text=text, lines=len(text.splitlines())))
    return files


def is_state_owner(config: AppConfig, file: SwiftFile) -> bool:
    return file.path.stem in config.state_owner_names


def is_ui_boundary_file(file: SwiftFile) -> bool:
    return (
        "/Views/" in file.rel
        or "/Styling/" in file.rel
        or "/App/" in file.rel
        or file.path.name == "ContentView.swift"
        or re.search(r":\s*View\b", file.text) is not None
    )


def is_adapter_boundary(config: AppConfig, file: SwiftFile) -> bool:
    rel = str(file.path.relative_to(config.root))
    return any(pattern in rel for pattern in config.adapter_boundary_patterns)


def clamp(value: float, lower: float = 0, upper: float = 100) -> float:
    return max(lower, min(upper, value))


def primary_type_name(text: str) -> str | None:
    match = re.search(r"^\s*(?:@MainActor\s+)?(?:public\s+|internal\s+|private\s+)?(?:struct|final class|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M)
    return match.group(1) if match else None


def top_level_type_names(text: str) -> list[str]:
    return re.findall(
        r"^\s*(?:@MainActor\s+)?(?:public\s+|internal\s+|private\s+)?(?:struct|final class|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)",
        text,
        re.M,
    )


def is_grouped_source_file(file: SwiftFile) -> bool:
    grouped_suffixes = (
        "Controls",
        "Effects",
        "Intents",
        "Store",
        "Views",
    )
    return any(file.path.stem.endswith(suffix) for suffix in grouped_suffixes)


def score_file_size(config: AppConfig, files: list[SwiftFile]) -> tuple[float, str]:
    scored_files = [file for file in files if is_ui_boundary_file(file) and not is_state_owner(config, file)]
    oversized = [file for file in scored_files if file.lines > 300]
    huge = [file for file in scored_files if file.lines > 600]
    max_lines = max((file.lines for file in files), default=0)
    max_scored_lines = max((file.lines for file in scored_files), default=0)
    avg_lines = sum(file.lines for file in scored_files) / max(len(scored_files), 1)
    penalty = sum(min((file.lines - 300) / 18, 18) for file in oversized)
    penalty += sum(min((file.lines - 600) / 20, 18) for file in huge)
    penalty += max(0, avg_lines - 180) / 12
    score = clamp(100 - penalty)
    return score, f"uiMax={max_scored_lines}, repoMax={max_lines}, uiAvg={avg_lines:.0f}, uiOversized={len(oversized)}"


def score_root(root_view: SwiftFile | None) -> tuple[float, str]:
    if root_view is None:
        return 0, "missing root view"

    computed_views = len(re.findall(r"private\s+(?:var|func)\s+[A-Za-z0-9_]+[^\n]*(?:some\s+View|ViewBuilder)", root_view.text))
    line_penalty = max(0, root_view.lines - 260) / 8
    helper_penalty = max(0, computed_views - 3) * 5
    score = clamp(100 - line_penalty - helper_penalty)
    return score, f"lines={root_view.lines}, computedViewHelpers={computed_views}"


def score_feature_dirs(config: AppConfig) -> tuple[float, str]:
    present = [feature for feature in config.expected_feature_dirs if (config.root / feature).is_dir()]
    score = 100 * len(present) / max(len(config.expected_feature_dirs), 1)
    return score, f"{len(present)}/{len(config.expected_feature_dirs)} expected feature dirs"


def score_type_file_names(files: list[SwiftFile]) -> tuple[float, str]:
    typed_files = 0
    matching = 0
    grouped = 0
    for file in files:
        types = top_level_type_names(file.text)
        if not types:
            continue
        typed_files += 1
        if file.path.stem in types:
            matching += 1
        elif is_grouped_source_file(file):
            matching += 1
            grouped += 1

    score = 100 * matching / max(typed_files, 1)
    return score, f"{matching}/{typed_files} files have matching or explicit grouped type names, grouped={grouped}"


def score_computed_view_sprawl(files: list[SwiftFile]) -> tuple[float, str]:
    total = 0
    heavy_files = 0
    for file in files:
        count = len(re.findall(r"private\s+(?:var|func)\s+[A-Za-z0-9_]+[^\n]*(?:some\s+View|ViewBuilder)", file.text))
        total += count
        if count > 4:
            heavy_files += 1
    view_file_count = sum(1 for file in files if re.search(r":\s*View\b", file.text))
    expected_small_helpers = view_file_count * 0.35
    score = clamp(100 - max(0, total - expected_small_helpers) * 1.6 - heavy_files * 8)
    return score, f"computedViewHelpers={total}, viewFiles={view_file_count}, heavyFiles={heavy_files}"


def wide_dependency_files(config: AppConfig, files: list[SwiftFile]) -> tuple[list[SwiftFile], list[SwiftFile]]:
    leaf_offenders: list[SwiftFile] = []
    adapter_boundaries: list[SwiftFile] = []
    for file in files:
        if file.path == config.root_view:
            continue
        if file.path.name in config.wide_dependency_names:
            continue
        if file.path.stem in config.wide_dependency_names:
            continue
        if not ("/Views/" in file.rel or "/Styling/" in file.rel or "/Support/" in file.rel):
            continue
        if any(re.search(rf"\b{name}\b", file.text) for name in config.wide_dependency_names):
            if is_adapter_boundary(config, file):
                adapter_boundaries.append(file)
            else:
                leaf_offenders.append(file)

    return leaf_offenders, adapter_boundaries


def score_wide_dependencies(config: AppConfig, files: list[SwiftFile]) -> tuple[float, str]:
    leaf_offenders, adapter_boundaries = wide_dependency_files(config, files)

    total_view_files = sum(1 for file in files if re.search(r":\s*View\b", file.text))
    leaf_ratio = len(leaf_offenders) / max(total_view_files, 1)
    adapter_ratio = len(adapter_boundaries) / max(total_view_files, 1)
    score = clamp(100 - len(leaf_offenders) * 18 - leaf_ratio * 45 - adapter_ratio * 10)
    return score, (
        f"leafWideDependencyFiles={len(leaf_offenders)}/{total_view_files}, "
        f"adapterBoundaryFiles={len(adapter_boundaries)}"
    )


def score_module_boundaries(config: AppConfig) -> tuple[float, str]:
    if config.name == "iOS":
        project = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker.xcodeproj" / "project.pbxproj"
        project_text = project.read_text(encoding="utf-8") if project.exists() else ""
        shared_package = ROOT / "shared" / "DoorUnlockerShared" / "Package.swift"
        shared_tests = ROOT / "shared" / "DoorUnlockerShared" / "Tests"
        checks = {
            "appTarget": "DoorUnlocker" in project_text,
            "widgetTarget": "DoorUnlockerWidget" in project_text,
            "sharedPackage": shared_package.exists(),
            "sharedTests": shared_tests.exists(),
        }
    else:
        package = ROOT / "mac" / "DoorUnlockerAdmin" / "Package.swift"
        package_text = package.read_text(encoding="utf-8") if package.exists() else ""
        checks = {
            "coreLibrary": ".library(name: \"DoorUnlockerCore\"" in package_text,
            "adminExecutable": ".executable(name: \"DoorUnlockerAdmin\"" in package_text,
            "cliExecutable": ".executable(name: \"door-unlocker\"" in package_text,
            "coreTests": "\"DoorUnlockerCoreTests\"" in package_text,
            "sharedDependency": "DoorUnlockerShared" in package_text,
        }

    passed = sum(1 for value in checks.values() if value)
    score = 100 * passed / max(len(checks), 1)
    return score, f"{passed}/{len(checks)} module boundary checks"


def score_layering(files: list[SwiftFile]) -> tuple[float, str]:
    view_logic_patterns = (
        r"CBPeripheral",
        r"CBCentralManager",
        r"URLSession",
        r"FileManager\.",
        r"Process\(",
        r"DispatchQueue\(",
        r"CryptoKit",
    )
    view_files = [file for file in files if "/Views/" in file.rel or file.path.name == "ContentView.swift"]
    hits = []
    for file in view_files:
        if any(re.search(pattern, file.text) for pattern in view_logic_patterns):
            hits.append(file)
    score = clamp(100 - len(hits) * 18)
    return score, f"viewLogicBoundaryHits={len(hits)}"


def score_state_owner_pressure(config: AppConfig, files: list[SwiftFile]) -> tuple[float, str]:
    owners = [file for file in files if is_state_owner(config, file)]
    if not owners:
        return 100, "no state owner files"

    max_owner_lines = max(file.lines for file in owners)
    private_function_count = sum(len(re.findall(r"^\s+private\s+func\s+", file.text, re.M)) for file in owners)
    extension_count = sum(len(re.findall(r"^extension\s+", file.text, re.M)) for file in owners)
    score = clamp(
        100
        - max(0, max_owner_lines - 2200) / 95
        - max(0, private_function_count - 70) * 0.18
        + min(extension_count * 1.5, 6)
    )
    return score, f"maxOwnerLines={max_owner_lines}, privateFunctions={private_function_count}, extensions={extension_count}"


def source_contains(path: Path, needle: str) -> bool:
    return path.exists() and needle in path.read_text(encoding="utf-8")


def score_shared_protocol_codec(config: AppConfig) -> tuple[float, str]:
    shared_codec = ROOT / "shared" / "DoorUnlockerShared" / "Sources" / "DoorUnlockerShared" / "DoorSecureCommandCodec.swift"
    shared_tests = ROOT / "shared" / "DoorUnlockerShared" / "Tests" / "DoorUnlockerSharedTests" / "DoorSecureCommandCodecTests.swift"
    if config.name == "iOS":
        auth_file = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "DoorCommandAuthenticator.swift"
    else:
        auth_file = ROOT / "mac" / "DoorUnlockerAdmin" / "Sources" / "DoorUnlockerCore" / "DoorCommandAuthenticator.swift"

    checks = {
        "sharedCodec": shared_codec.exists(),
        "sharedCodecTests": shared_tests.exists() and shared_tests.read_text(encoding="utf-8").count("func test") >= 5,
        "appUsesSharedCodec": source_contains(auth_file, "DoorSecureCommandCodec"),
        "appDoesNotOwnOpcodeTable": not source_contains(auth_file, "fastCommandSetServoAnglesOp"),
    }
    passed = sum(1 for value in checks.values() if value)
    return 100 * passed / len(checks), f"{passed}/{len(checks)} shared protocol codec checks"


def score_shared_controller_policy(config: AppConfig) -> tuple[float, str]:
    shared_policy = ROOT / "shared" / "DoorUnlockerShared" / "Sources" / "DoorUnlockerShared" / "DoorControllerPolicy.swift"
    shared_tests = ROOT / "shared" / "DoorUnlockerShared" / "Tests" / "DoorUnlockerSharedTests" / "DoorControllerPolicyTests.swift"
    policy_test_count = shared_tests.read_text(encoding="utf-8").count("func test") if shared_tests.exists() else 0

    if config.name == "iOS":
        controller = ROOT / "ios" / "DoorUnlockerApp" / "DoorUnlocker" / "DoorUnlockerController.swift"
        checks = {
            "sharedPolicy": shared_policy.exists(),
            "sharedPolicyTests": policy_test_count >= 4,
            "controllerUsesPolicy": source_contains(controller, "DoorControllerPolicy"),
            "controllerDoesNotOwnDeviceNameNormalizer": not source_contains(controller, "normalizedDeviceNameSource"),
            "controllerDoesNotOwnServoClamp": not source_contains(controller, "private static func clampedServoAngles"),
        }
    else:
        core_model = ROOT / "mac" / "DoorUnlockerAdmin" / "Sources" / "DoorUnlockerCore" / "ControllerModels.swift"
        store = ROOT / "mac" / "DoorUnlockerAdmin" / "Sources" / "DoorUnlockerAdmin" / "Stores" / "DoorAdminStore.swift"
        checks = {
            "sharedPolicy": shared_policy.exists(),
            "sharedPolicyTests": policy_test_count >= 4,
            "coreModelUsesPolicy": source_contains(core_model, "DoorControllerPolicy"),
            "storeUsesCorePolicy": source_contains(store, "ControllerStatus.clampedAutoLockSeconds"),
            "storeDoesNotOwnServoClamp": not source_contains(store, "private func clampedServoAngles"),
        }

    passed = sum(1 for value in checks.values() if value)
    return 100 * passed / len(checks), f"{passed}/{len(checks)} shared controller policy checks"


def count_tests(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(
        text.count("func test")
        for text in (file.read_text(encoding="utf-8") for file in path.rglob("*.swift"))
    )


def score_independent_testability(config: AppConfig) -> tuple[float, str]:
    shared_package = ROOT / "shared" / "DoorUnlockerShared" / "Package.swift"
    shared_tests = ROOT / "shared" / "DoorUnlockerShared" / "Tests"
    mac_package = ROOT / "mac" / "DoorUnlockerAdmin" / "Package.swift"
    mac_tests = ROOT / "mac" / "DoorUnlockerAdmin" / "Tests"
    shared_test_count = count_tests(shared_tests)
    mac_test_count = count_tests(mac_tests)

    if config.name == "iOS":
        app_parser_adapter = ROOT / "ios" / "DoorUnlockerApp" / "Shared" / "DoorControllerStateParser.swift"
        shared_policy_tests = shared_tests / "DoorUnlockerSharedTests" / "DoorControllerPolicyTests.swift"
        checks = {
            "sharedPackage": shared_package.exists(),
            "sharedTests": shared_test_count >= 14,
            "sharedSecureCodecTests": (shared_tests / "DoorUnlockerSharedTests" / "DoorSecureCommandCodecTests.swift").exists(),
            "sharedPolicyTests": shared_policy_tests.exists() and shared_policy_tests.read_text(encoding="utf-8").count("func test") >= 4,
            "iOSParserUsesShared": source_contains(app_parser_adapter, "DoorControllerStateParsing"),
            "iOSAuthUsesShared": score_shared_protocol_codec(config)[0] == 100,
        }
    else:
        package_text = mac_package.read_text(encoding="utf-8") if mac_package.exists() else ""
        shared_policy_tests = shared_tests / "DoorUnlockerSharedTests" / "DoorControllerPolicyTests.swift"
        checks = {
            "coreLibrary": ".library(name: \"DoorUnlockerCore\"" in package_text,
            "coreTests": mac_test_count >= 6,
            "cliExecutable": ".executable(name: \"door-unlocker\"" in package_text,
            "sharedDependency": "DoorUnlockerShared" in package_text,
            "macAuthUsesShared": score_shared_protocol_codec(config)[0] == 100,
            "sharedPolicyTests": shared_policy_tests.exists() and shared_policy_tests.read_text(encoding="utf-8").count("func test") >= 4,
        }

    passed = sum(1 for value in checks.values() if value)
    return 100 * passed / len(checks), (
        f"{passed}/{len(checks)} independent checks, "
        f"sharedTests={shared_test_count}, macCoreTests={mac_test_count}"
    )


def state_owner_risks(config: AppConfig, files: list[SwiftFile]) -> list[dict[str, object]]:
    risks = []
    for file in files:
        if not is_state_owner(config, file):
            continue
        extension_count = len(re.findall(r"^extension\s+", file.text, re.M))
        private_func_count = len(re.findall(r"^\s+private\s+func\s+", file.text, re.M))
        risks.append(
            {
                "file": file.rel,
                "lines": file.lines,
                "extensions": extension_count,
                "privateFunctions": private_func_count,
                "risk": "high" if file.lines > 1200 else "moderate" if file.lines > 600 else "low",
            }
        )
    return risks


def weighted_score(parts: list[tuple[str, float, float, str]]) -> float:
    return sum(score * weight for _, weight, score, _ in parts) / sum(weight for _, weight, _, _ in parts)


def score_app(config: AppConfig) -> tuple[float, list[tuple[str, float, float, str]]]:
    files = swift_files(config.root)
    root_view = next((file for file in files if file.path == config.root_view), None)
    parts = [
        ("ui-file-size", 0.14, *score_file_size(config, files)),
        ("root-composition", 0.16, *score_root(root_view)),
        ("feature-folders", 0.10, *score_feature_dirs(config)),
        ("type-file-naming", 0.10, *score_type_file_names(files)),
        ("computed-view-sprawl", 0.12, *score_computed_view_sprawl(files)),
        ("wide-dependencies", 0.15, *score_wide_dependencies(config, files)),
        ("module-boundaries", 0.16, *score_module_boundaries(config)),
        ("layering", 0.07, *score_layering(files)),
        ("state-owner-pressure", 0.00, *score_state_owner_pressure(config, files)),
        ("shared-protocol-codec", 0.00, *score_shared_protocol_codec(config)),
        ("shared-controller-policy", 0.00, *score_shared_controller_policy(config)),
        ("independent-testability", 0.00, *score_independent_testability(config)),
    ]
    return weighted_score(parts), parts


def dimension_scores(parts: list[tuple[str, float, float, str]]) -> dict[str, float]:
    by_name = {name: score for name, _, score, _ in parts}
    high_modularity = (
        by_name["ui-file-size"] * 0.18
        + by_name["root-composition"] * 0.18
        + by_name["feature-folders"] * 0.14
        + by_name["type-file-naming"] * 0.14
        + by_name["computed-view-sprawl"] * 0.16
        + by_name["module-boundaries"] * 0.20
    )
    low_coupling = (
        by_name["wide-dependencies"] * 0.32
        + by_name["layering"] * 0.20
        + by_name["shared-protocol-codec"] * 0.22
        + by_name["shared-controller-policy"] * 0.21
        + by_name["state-owner-pressure"] * 0.05
    )
    independent_testability = (
        by_name["module-boundaries"] * 0.24
        + by_name["shared-protocol-codec"] * 0.22
        + by_name["shared-controller-policy"] * 0.22
        + by_name["independent-testability"] * 0.32
    )
    return {
        "highModularity": round(high_modularity, 1),
        "lowCoupling": round(low_coupling, 1),
        "independentTestability": round(independent_testability, 1),
    }


def dependency_graph_mermaid() -> str:
    return """flowchart LR
    subgraph iOS["iOS app"]
        IOSApp["DoorUnlocker app target"]
        Widget["DoorUnlockerWidget extension"]
    end

    subgraph Mac["macOS app"]
        MacAdmin["DoorUnlockerAdmin executable"]
        MacCLI["door-unlocker CLI executable"]
        MacCore["DoorUnlockerCore library"]
        MacTests["DoorUnlockerCoreTests"]
    end

    subgraph Shared["shared package"]
        SharedLib["DoorUnlockerShared library"]
        SharedTests["DoorUnlockerSharedTests"]
    end

    subgraph ThirdParty["third-party packages"]
        Nordic["NordicDFU"]
        ZIP["ZIPFoundation"]
    end

    IOSApp --> Widget
    IOSApp --> SharedLib
    IOSApp --> Nordic
    MacAdmin --> MacCore
    MacAdmin --> Nordic
    MacCLI --> MacCore
    MacTests --> MacCore
    MacCore --> SharedLib
    SharedTests --> SharedLib
    Nordic --> ZIP
"""


def write_dependency_graph(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# Door Unlocker Dependency Graph\n\n"
        "```mermaid\n"
        f"{dependency_graph_mermaid()}"
        "```\n",
        encoding="utf-8",
    )


def result_payload(threshold: float) -> dict[str, object]:
    apps = []
    failed = False
    for config in APPS:
        score, parts = score_app(config)
        files = swift_files(config.root)
        dimensions = dimension_scores(parts)
        app_failed = score < threshold or any(score < threshold for score in dimensions.values())
        leaf_offenders, adapter_boundaries = wide_dependency_files(config, files)
        failed = failed or app_failed
        apps.append(
            {
                "name": config.name,
                "score": round(score, 1),
                "threshold": threshold,
                "passed": not app_failed,
                "dimensions": dimensions,
                "parts": [
                    {
                        "name": name,
                        "weight": weight,
                        "score": round(part_score, 1),
                        "detail": detail,
                    }
                    for name, weight, part_score, detail in parts
                ],
                "stateOwnerRisks": state_owner_risks(config, files),
                "wideDependencyOffenders": [file.rel for file in leaf_offenders],
                "adapterBoundaryFiles": [file.rel for file in adapter_boundaries],
            }
        )
    return {"threshold": threshold, "passed": not failed, "apps": apps}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--threshold", type=float, default=85.0)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable scoring output.")
    parser.add_argument("--write-graph", type=Path, help="Write a Mermaid dependency graph markdown file.")
    args = parser.parse_args()

    payload = result_payload(args.threshold)
    if args.write_graph:
        write_dependency_graph(args.write_graph)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for app in payload["apps"]:
            print(f"{app['name']}: {app['score']:.1f}/100")
            print(
                "  dimensions: "
                f"highModularity={app['dimensions']['highModularity']:.1f}, "
                f"lowCoupling={app['dimensions']['lowCoupling']:.1f}, "
                f"independentTestability={app['dimensions']['independentTestability']:.1f}"
            )
            for part in app["parts"]:
                print(
                    f"  {part['name']:21} {part['score']:5.1f}  "
                    f"weight={part['weight']:.2f}  {part['detail']}"
                )
            if app["passed"]:
                print("  result: pass")
            else:
                print(f"  result: below threshold {args.threshold:.1f}")
            if app["wideDependencyOffenders"]:
                print("  leaf wide-dependency offenders:")
                for offender in app["wideDependencyOffenders"]:
                    print(f"    - {offender}")
            if app["adapterBoundaryFiles"]:
                print(f"  adapter boundary files: {len(app['adapterBoundaryFiles'])}")
            print()

    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
