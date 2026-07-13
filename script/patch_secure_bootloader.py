#!/usr/bin/env python3
"""Apply Door Unlocker's small, audited changes to the upstream bootloader."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"Could not uniquely apply {description} to {path}")
    path.write_text(source.replace(old, new), encoding="utf-8")


def patch(
    source: Path,
    module: Path,
    flash_local_latency: int,
    phy_mode: str,
    hci_rx_queue_size: int,
    pstorage_queue_size: int,
    minimum_connection_interval_ms: int,
    maximum_connection_interval_ms: int,
) -> None:
    destination = source / "src"
    shutil.copy2(module / "door_activation_journal.c", destination)
    shutil.copy2(module / "door_activation_journal.h", destination)

    replace_once(
        source / "CMakeLists.txt",
        "  src/flash_nrf5x.c\n",
        "  src/flash_nrf5x.c\n  src/door_activation_journal.c\n",
        "transactional activation source registration",
    )

    replace_once(
        source / "src/sdk_config.h",
        "#define HCI_RX_BUF_QUEUE_SIZE              16  // must be power of 2\n",
        f"#define HCI_RX_BUF_QUEUE_SIZE              {hci_rx_queue_size}  // must be power of 2\n",
        "BLE receive queue size",
    )
    replace_once(
        source / "src/pstorage_platform.h",
        "#define PSTORAGE_CMD_QUEUE_SIZE     18",
        f"#define PSTORAGE_CMD_QUEUE_SIZE     {pstorage_queue_size}",
        "flash command queue size",
    )

    replace_once(
        source / "lib/sdk11/components/libraries/bootloader_dfu/dfu_types.h",
        "#define DFU_BANK_1_REGION_START         "
        "(DFU_BANK_0_REGION_START + DFU_IMAGE_MAX_SIZE_BANKED)           "
        "/**< Bank 1 region start. */\n",
        "#define DFU_BANK_1_REGION_START         "
        "(DFU_BANK_0_REGION_START + DFU_IMAGE_MAX_SIZE_BANKED)           "
        "/**< Bank 1 region start. */\n"
        "#define DFU_ACTIVATION_JOURNAL_ADDRESS  "
        "(DFU_BANK_1_REGION_START + DFU_IMAGE_MAX_SIZE_BANKED)           "
        "/**< Dedicated page recording a verified app activation until bank 0 is durable. */\n",
        "activation journal address",
    )

    dual_bank = source / "lib/sdk11/components/libraries/bootloader_dfu/dfu_dual_bank.c"
    replace_once(
        dual_bank,
        "static void dfu_prepare_func_swap_erase(uint32_t image_size)\n{\n",
        "static bool dfu_region_is_erased(uint32_t address, uint32_t image_size)\n"
        "{\n"
        "    uint32_t const end = address + ALIGN_NUM(image_size, CODE_PAGE_SIZE);\n"
        "    for (uint32_t cursor = address; cursor < end; cursor += sizeof(uint32_t))\n"
        "    {\n"
        "        if (*(uint32_t const *)cursor != EMPTY_FLASH_MASK)\n"
        "        {\n"
        "            return false;\n"
        "        }\n"
        "    }\n"
        "    return true;\n"
        "}\n\n"
        "static void dfu_prepare_func_swap_erase(uint32_t image_size)\n{\n",
        "blank staging-bank detection",
    )
    replace_once(
        dual_bank,
        "    if ( is_ota() )\n"
        "    {\n"
        "        uint32_t err_code;\n"
        "        while(1) {\n"
        "            err_code = pstorage_clear(&m_storage_handle_swap, image_size);\n",
        "    if ( is_ota() )\n"
        "    {\n"
        "        if (dfu_region_is_erased(DFU_BANK_1_REGION_START, image_size))\n"
        "        {\n"
        "            pstorage_callback_handler(\n"
        "                &m_storage_handle_swap, PSTORAGE_CLEAR_OP_CODE, NRF_SUCCESS, NULL, 0);\n"
        "            return;\n"
        "        }\n\n"
        "        uint32_t err_code;\n"
        "        while(1) {\n"
        "            err_code = pstorage_clear(&m_storage_handle_swap, image_size);\n",
        "verified staging-bank erase bypass",
    )
    dual_source = dual_bank.read_text(encoding="utf-8")
    function_start = dual_source.index("static uint32_t dfu_activate_app(void)")
    function_end = dual_source.index(
        "/**@brief Function for activating received Bootloader image.",
        function_start,
    )
    replacement = """static uint32_t dfu_activate_app(void)
{
    return door_activation_stage(m_start_packet.app_image_size, m_image_crc);
}


"""
    dual_source = dual_source[:function_start] + replacement + dual_source[function_end:]
    include_marker = '#include "bootloader.h"\n'
    if dual_source.count(include_marker) != 1:
        raise SystemExit(f"Could not uniquely add activation include to {dual_bank}")
    dual_bank.write_text(
        dual_source.replace(
            include_marker,
            include_marker + '#include "door_activation_journal.h"\n',
        ),
        encoding="utf-8",
    )

    main = source / "src/main.c"
    replace_once(
        main,
        '#include "bootloader.h"\n',
        '#include "bootloader.h"\n#include "door_activation_journal.h"\n',
        "activation journal include",
    )
    replace_once(
        main,
        "  bootloader_init();\n  PRINTF(\"Bootloader Start\\r\\n\");\n"
        "  led_state(STATE_BOOTLOADER_STARTED);\n",
        "  bootloader_init();\n"
        "  APP_ERROR_CHECK(door_activation_journal_init());\n"
        "  PRINTF(\"Bootloader Start\\r\\n\");\n"
        "  led_state(STATE_BOOTLOADER_STARTED);\n\n"
        "  // A verified bank-1 image is activated before BLE or USB starts.\n"
        "  // The journal remains until bank 0 and settings are durable, so\n"
        "  // power loss simply repeats this idempotent operation.\n"
        "  if (door_activation_in_progress()) {\n"
        "    led_state(STATE_WRITING_STARTED);\n"
        "    uint32_t const activation_result = door_activation_continue();\n"
        "    if (activation_result != NRF_SUCCESS && door_activation_in_progress()) {\n"
        "      NVIC_SystemReset();\n"
        "    }\n"
        "    led_state(STATE_WRITING_FINISHED);\n"
        "  }\n",
        "boot-time transactional activation",
    )

    phy_constant = {
        "auto": "BLE_GAP_PHY_AUTO",
        "2m": "BLE_GAP_PHY_2MBPS",
    }[phy_mode]
    replace_once(
        main,
        "          .rx_phys = BLE_GAP_PHY_AUTO,\n"
        "          .tx_phys = BLE_GAP_PHY_AUTO,\n",
        f"          .rx_phys = {phy_constant},\n"
        f"          .tx_phys = {phy_constant},\n",
        "initial PHY preference",
    )

    transport = (
        source
        / "lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c"
    )
    replace_once(
        transport,
        "#define MIN_CONN_INTERVAL                    "
        "(uint16_t)(MSEC_TO_UNITS(15, UNIT_1_25_MS))",
        "#define MIN_CONN_INTERVAL                    "
        f"(uint16_t)(MSEC_TO_UNITS({minimum_connection_interval_ms}, UNIT_1_25_MS))",
        "configured minimum connection interval",
    )
    replace_once(
        transport,
        "#define MAX_CONN_INTERVAL                    "
        "(uint16_t)(MSEC_TO_UNITS(30, UNIT_1_25_MS))",
        "#define MAX_CONN_INTERVAL                    "
        f"(uint16_t)(MSEC_TO_UNITS({maximum_connection_interval_ms}, UNIT_1_25_MS))",
        "configured maximum connection interval",
    )
    replace_once(
        transport,
        "  opt.gap_opt.local_conn_latency.requested_latency = 50;",
        "  opt.gap_opt.local_conn_latency.requested_latency = "
        f"{flash_local_latency};",
        "flash-write connection latency",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--module", type=Path, required=True)
    parser.add_argument("--flash-local-latency", type=int, required=True)
    parser.add_argument("--phy-mode", choices=("auto", "2m"), required=True)
    parser.add_argument("--hci-rx-queue-size", type=int, required=True)
    parser.add_argument("--pstorage-queue-size", type=int, required=True)
    parser.add_argument("--minimum-connection-interval-ms", type=int, required=True)
    parser.add_argument("--maximum-connection-interval-ms", type=int, required=True)
    args = parser.parse_args()
    if args.flash_local_latency not in range(0, 51):
        parser.error("--flash-local-latency must be between 0 and 50")
    if args.hci_rx_queue_size < 8 or args.hci_rx_queue_size & (
        args.hci_rx_queue_size - 1
    ):
        parser.error("--hci-rx-queue-size must be a power of two of at least 8")
    if args.pstorage_queue_size < args.hci_rx_queue_size + 2:
        parser.error("--pstorage-queue-size must exceed the BLE queue by at least two")
    if args.minimum_connection_interval_ms not in (15, 30):
        parser.error("--minimum-connection-interval-ms must be 15 or 30")
    if args.maximum_connection_interval_ms not in (15, 30):
        parser.error("--maximum-connection-interval-ms must be 15 or 30")
    if args.minimum_connection_interval_ms > args.maximum_connection_interval_ms:
        parser.error("minimum connection interval cannot exceed maximum")
    patch(
        args.source.resolve(),
        args.module.resolve(),
        args.flash_local_latency,
        args.phy_mode,
        args.hci_rx_queue_size,
        args.pstorage_queue_size,
        args.minimum_connection_interval_ms,
        args.maximum_connection_interval_ms,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
