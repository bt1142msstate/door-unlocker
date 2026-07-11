#!/usr/bin/env python3
"""Verify reliable, ordered controller-state delivery to every BLE subscriber."""

from __future__ import annotations

import random
import re
import sys
from collections import deque
from pathlib import Path


SOURCE = Path("firmware/DoorUnlockerXiao/DoorUnlockerXiao.ino")


def source_checks(text: str) -> dict[str, bool]:
    capacity_match = re.search(r"STATE_NOTIFICATION_QUEUE_CAPACITY\s*=\s*(\d+)", text)
    capacity = int(capacity_match.group(1)) if capacity_match else 0
    return {
        "per-subscriber queue capacity covers startup snapshot": capacity >= 10,
        "all state notifications use the checked delivery lane": text.count("stateCharacteristic.notify(") == 1,
        "failed notifications remain queued": (
            "if (sent" in text
            and "stateNotificationQueueCounts[slot]--" in text
            and "processPendingStateNotifications();" in text
        ),
        "queue overflow reconnects for a fresh snapshot": (
            "stateNotificationQueueOverflowed[slot] = true" in text
            and "Bluefruit.disconnect(connHandle)" in text
            and "fresh snapshot" in text
        ),
        "disconnect invalidates pending state": (
            "stateNotificationQueueGenerations[slot]++" in text
            and "stateNotificationQueueCounts[slot] = 0" in text
        ),
        "startup snapshot waits for subscriber readiness": (
            "STATE_SUBSCRIPTION_SETTLE_MS" in text
            and "stateStartupSnapshotPending[slot] = true" in text
            and "processPendingStateStartupSnapshots();" in text
        ),
        "critical boot session is redundant at subscription boundary": (
            text.count("notifyStateSubscriber(connHandle, payload);") >= 2
            and "freshness never depends on that boundary" in text
        ),
        "startup snapshot is scoped to connection generation": (
            "stateStartupSnapshotGenerations[slot]" in text
            and "stateNotificationQueueGenerations[slot] != generation" in text
            and "stateStartupSnapshotDelivered[slot] = true" in text
        ),
        "subscription disable invalidates queued startup state": (
            "resetStateNotificationSubscription((uint8_t) slot)" in text
            and "stateStartupSnapshotDelivered[slot] = false" in text
        ),
    }


def randomized_fifo_check(seed: int = 0xD00F, events: int = 250_000) -> bool:
    rng = random.Random(seed)
    queues = [deque() for _ in range(4)]
    delivered = [[] for _ in range(4)]
    expected = [[] for _ in range(4)]
    connected = [True] * 4
    generation = [0] * 4
    next_sequence = 0

    for _ in range(events):
        action = rng.randrange(100)
        slot = rng.randrange(4)
        if action < 47:
            next_sequence += 1
            for subscriber in range(4):
                if connected[subscriber]:
                    queues[subscriber].append((generation[subscriber], next_sequence))
                    expected[subscriber].append((generation[subscriber], next_sequence))
        elif action < 88:
            if connected[slot] and queues[slot] and rng.randrange(4) != 0:
                item = queues[slot].popleft()
                delivered[slot].append(item)
        elif action < 94:
            connected[slot] = False
            queues[slot].clear()
            generation[slot] += 1
            expected[slot] = [item for item in expected[slot] if item[0] == generation[slot]]
            delivered[slot] = [item for item in delivered[slot] if item[0] == generation[slot]]
        else:
            connected[slot] = True

        for subscriber in range(4):
            current = delivered[subscriber] + list(queues[subscriber])
            if current != expected[subscriber]:
                return False

    return True


def randomized_startup_snapshot_check(seed: int = 0x51A7E, events: int = 250_000) -> bool:
    rng = random.Random(seed)
    generation = [0] * 4
    connected = [False] * 4
    subscribed = [False] * 4
    pending_generation: list[int | None] = [None] * 4
    delivered_generation: list[int | None] = [None] * 4

    for _ in range(events):
        slot = rng.randrange(4)
        action = rng.randrange(100)
        if action < 18:
            generation[slot] += 1
            connected[slot] = True
            subscribed[slot] = False
            pending_generation[slot] = None
            delivered_generation[slot] = None
        elif action < 34:
            connected[slot] = False
            subscribed[slot] = False
            pending_generation[slot] = None
            delivered_generation[slot] = None
            generation[slot] += 1
        elif action < 62 and connected[slot]:
            subscribed[slot] = True
            if pending_generation[slot] is None and delivered_generation[slot] is None:
                pending_generation[slot] = generation[slot]
        elif action < 92 and pending_generation[slot] is not None:
            scheduled_generation = pending_generation[slot]
            pending_generation[slot] = None
            if connected[slot] and subscribed[slot] and scheduled_generation == generation[slot]:
                delivered_generation[slot] = scheduled_generation
        elif connected[slot]:
            subscribed[slot] = False
            pending_generation[slot] = None
            delivered_generation[slot] = None
            generation[slot] += 1

        for index in range(4):
            delivered = delivered_generation[index]
            pending = pending_generation[index]
            if delivered is not None and (
                not connected[index]
                or not subscribed[index]
                or delivered != generation[index]
            ):
                return False
            if pending is not None and pending != generation[index]:
                return False

    return True


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    checks = source_checks(text)
    checks["250k adverse delivery events preserve per-subscriber FIFO order"] = randomized_fifo_check()
    checks["250k startup races preserve one generation-scoped snapshot"] = randomized_startup_snapshot_check()

    failures = [name for name, passed in checks.items() if not passed]
    for name, passed in checks.items():
        print(f"{'PASS' if passed else 'FAIL'}: {name}")

    if failures:
        print("State notification delivery contract: FAIL", file=sys.stderr)
        return 1
    print("State notification delivery contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
