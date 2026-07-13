#pragma once

#include <stdint.h>

void beginStagingBankMaintenance(uint32_t nowMs);
bool serviceStagingBankMaintenance(
    uint32_t nowMs,
    bool controllerBusy
);
bool stagingBankMaintenanceComplete();
