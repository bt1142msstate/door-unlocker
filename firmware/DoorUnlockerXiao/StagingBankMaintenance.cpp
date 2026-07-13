#include "StagingBankMaintenance.h"
#include "OtaMemoryLayout.h"

#include <Arduino.h>
#include <flash/flash_nrf5x.h>

namespace {
constexpr uint32_t kPageBytes = 4096;
constexpr uint32_t kInitialDelayMs = 15000;
constexpr uint32_t kEraseCooldownMs = 120;

uint32_t nextPageAddress = OTA_STAGING_BANK_START;
uint32_t maintenanceStartsAtMs = 0;
uint32_t nextEraseAllowedAtMs = 0;
bool maintenanceComplete = false;

bool pageIsErased(uint32_t address) {
  auto words = reinterpret_cast<volatile const uint32_t*>(address);
  for (uint32_t offset = 0; offset < kPageBytes / sizeof(uint32_t); offset++) {
    if (words[offset] != UINT32_MAX) {
      return false;
    }
  }
  return true;
}
}

void beginStagingBankMaintenance(uint32_t nowMs) {
  nextPageAddress = OTA_STAGING_BANK_START;
  maintenanceStartsAtMs = nowMs + kInitialDelayMs;
  nextEraseAllowedAtMs = maintenanceStartsAtMs;
  maintenanceComplete = false;
}

bool serviceStagingBankMaintenance(uint32_t nowMs, bool controllerBusy) {
  if (maintenanceComplete || controllerBusy ||
      static_cast<int32_t>(nowMs - maintenanceStartsAtMs) < 0 ||
      static_cast<int32_t>(nowMs - nextEraseAllowedAtMs) < 0) {
    return false;
  }

  constexpr uint32_t bankEnd =
    OTA_STAGING_BANK_START + OTA_DUAL_BANK_APPLICATION_BYTES;
  while (nextPageAddress < bankEnd && pageIsErased(nextPageAddress)) {
    nextPageAddress += kPageBytes;
  }

  if (nextPageAddress >= bankEnd) {
    maintenanceComplete = true;
    Serial.println("OTA staging bank ready");
    return true;
  }

  uint32_t const pageAddress = nextPageAddress;
  if (flash_nrf5x_erase(pageAddress)) {
    nextPageAddress += kPageBytes;
    nextEraseAllowedAtMs = nowMs + kEraseCooldownMs;
  } else {
    nextEraseAllowedAtMs = nowMs + kEraseCooldownMs;
    Serial.print("OTA staging erase retry at 0x");
    Serial.println(pageAddress, HEX);
  }
  return false;
}

bool stagingBankMaintenanceComplete() {
  return maintenanceComplete;
}
