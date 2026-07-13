#!/usr/bin/env python3
"""Apply audited reliability and transport tuning to the upstream bootloader."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit(f"Could not uniquely apply {description} to {path}")
    path.write_text(source.replace(old, new), encoding="utf-8")


def patch(
    source: Path,
    build_id: str,
    flash_local_latency: int,
    phy_mode: str,
    hci_rx_queue_size: int,
    pstorage_queue_size: int,
    minimum_connection_interval_ms: int,
    maximum_connection_interval_ms: int,
) -> None:
    bootloader_util = (
        source / "lib/sdk11/components/libraries/bootloader_dfu/bootloader_util.c"
    )
    replace_once(
        bootloader_util,
        '#include "nrf_peripherals.h"\n',
        '#include "nrf_peripherals.h"\n\n'
        '#if !defined(ACL_PRESENT)\n'
        '#error "Door Unlocker requires nRF52840 ACL flash protection"\n'
        '#endif\n',
        "mandatory nRF52840 application flash protection",
    )

    ghostfat = source / "src/usb/uf2/ghostfat.c"
    replace_once(
        ghostfat,
        '    "Board-ID: " UF2_BOARD_ID "\\r\\n"\n'
        '    "Date: " __DATE__ "\\r\\n";',
        '    "Board-ID: " UF2_BOARD_ID "\\r\\n"\n'
        f'    "Door-Bootloader-ID: {build_id}\\r\\n"\n'
        '    "Date: " __DATE__ "\\r\\n";',
        "USB recovery build identity",
    )

    msc = source / "src/usb/msc_uf2.c"
    replace_once(
        msc,
        "// Callback invoked when received WRITE10 command.\n"
        "// Process data in buffer to disk's storage and return number of written bytes\n",
        "// Door Unlocker exposes the UF2 volume for deterministic USB recovery\n"
        "// discovery, but signed builds recover through CDC serial DFU. Keeping the\n"
        "// volume read-only prevents physical drag-and-drop from bypassing signatures.\n"
        "bool tud_msc_is_writable_cb(uint8_t lun)\n"
        "{\n"
        "  (void) lun;\n"
        "  return false;\n"
        "}\n\n"
        "// Callback invoked when received WRITE10 command.\n"
        "// TinyUSB rejects writes before this callback when the volume is read-only.\n",
        "read-only signed USB recovery volume",
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

    phy_constant = {
        "auto": "BLE_GAP_PHY_AUTO",
        "2m": "BLE_GAP_PHY_2MBPS",
    }[phy_mode]
    replace_once(
        source / "src/main.c",
        "          .rx_phys = BLE_GAP_PHY_AUTO,\n"
        "          .tx_phys = BLE_GAP_PHY_AUTO,\n",
        f"          .rx_phys = {phy_constant},\n"
        f"          .tx_phys = {phy_constant},\n",
        "initial PHY preference",
    )

    transport = source / "lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c"
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
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--flash-local-latency", type=int, required=True)
    parser.add_argument("--phy-mode", choices=("auto", "2m"), required=True)
    parser.add_argument("--hci-rx-queue-size", type=int, required=True)
    parser.add_argument("--pstorage-queue-size", type=int, required=True)
    parser.add_argument("--minimum-connection-interval-ms", type=int, required=True)
    parser.add_argument("--maximum-connection-interval-ms", type=int, required=True)
    args = parser.parse_args()
    if args.flash_local_latency not in range(0, 51):
        parser.error("--flash-local-latency must be between 0 and 50")
    if args.hci_rx_queue_size < 8 or args.hci_rx_queue_size & (args.hci_rx_queue_size - 1):
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
        args.build_id,
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
