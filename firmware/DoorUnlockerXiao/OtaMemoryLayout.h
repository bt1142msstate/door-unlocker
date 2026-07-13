#pragma once

#include <stdint.h>

// This layout must remain byte-for-byte aligned with build_secure_bootloader.sh.
constexpr uint32_t OTA_APPLICATION_START = 0x27000;
constexpr uint32_t OTA_DUAL_BANK_APPLICATION_BYTES = 397312;
constexpr uint32_t OTA_STAGING_BANK_START =
  OTA_APPLICATION_START + OTA_DUAL_BANK_APPLICATION_BYTES;
constexpr uint32_t OTA_ACTIVATION_JOURNAL_ADDRESS =
  OTA_STAGING_BANK_START + OTA_DUAL_BANK_APPLICATION_BYTES;
