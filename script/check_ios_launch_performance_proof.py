#!/usr/bin/env python3
"""Validate checked-in physical iPhone cold/warm launch evidence."""

from __future__ import annotations

import json

from ios_launch_performance_contract import PROOF_PATH, validate_proof


def main() -> int:
    try:
        proof = json.loads(PROOF_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"iOS launch performance proof: FAIL ({error})")
        return 1
    failures = validate_proof(proof)
    if failures:
        print("iOS launch performance proof: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    cold = proof["cold"]["metrics"]
    warm = proof["warm"]["metrics"]
    print(
        "iOS launch performance proof: PASS "
        f"(cold median/p95 {cold['median']}/{cold['p95']}ms; "
        f"warm median/p95 {warm['median']}/{warm['p95']}ms)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
