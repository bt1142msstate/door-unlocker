#include <bluefruit.h>
#include <Servo.h>
#include "Adafruit_nRFCrypto.h"
#include "nRFCrypto_Hash.h"
#include "nrf_cc310/include/crys_ecpki_build.h"
#include "nrf_cc310/include/crys_ecpki_domain.h"
#include "nrf_cc310/include/crys_ecpki_ecdsa.h"
#include "nrf_soc.h"
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include "StagingBankMaintenance.h"

using namespace Adafruit_LittleFS_Namespace;

// Desk-test wiring:
// - Servo signal wire: XIAO D2, third pin down on the left with USB-C at the top
// - Servo red/black power wires: battery/Wago power split, not breadboard power rails
// - XIAO GND is second pin down on the right with USB-C at the top
// - XIAO GND, buck converter GND, and servo GND must be common
static const int SERVO_SIGNAL_PIN = D2;

// Tune these on the desk before putting the mechanism near the door.
static const uint8_t DEFAULT_LOCK_ANGLE = 95;    // Rest/release position
static const uint8_t DEFAULT_UNLOCK_ANGLE = 20;  // Handle-push position; lower angle turns the current arm setup right
static const uint8_t MIN_SAFE_SERVO_ANGLE = 10;
static const uint8_t MAX_SAFE_SERVO_ANGLE = 170;
static const uint8_t MIN_SERVO_ANGLE_GAP = 0;
static const int SERVO_ATTACH_SETTLE_MS = 0;
static const int SERVO_MOVE_SETTLE_MS = 180;
static const int SERVO_DETACH_DELAY_MS = 40;
static const int MAIN_LOOP_IDLE_DELAY_MS = 2;
static const int LAST_UNLOCK_NOTIFY_GAP_MS = 40;
// Four simultaneous high-MTU links need scheduling headroom. Apple's ordinary
// BLE accessory profile accepts a 30-45 ms preferred range and a 6 s
// supervision timeout; the shorter 15 ms event schedule could starve a peer.
static const uint16_t MULTI_LINK_CONN_INTERVAL_MIN = 24;  // 30 ms
static const uint16_t MULTI_LINK_CONN_INTERVAL_MAX = 36;  // 45 ms
static const uint16_t MULTI_LINK_SUPERVISION_TIMEOUT_MS = 6000;
static const uint16_t MULTI_LINK_EVENT_LENGTH = 3;  // 3.75 ms
static const uint16_t DEFAULT_UNLOCK_HOLD_TIMEOUT_SECONDS = 30;
static const uint16_t MIN_UNLOCK_HOLD_TIMEOUT_SECONDS = 5;
static const uint16_t MAX_UNLOCK_HOLD_TIMEOUT_SECONDS = 120;
static const char DEFAULT_LOCK_NAME[] = "My Lock";
static const char CONTROLLER_MODEL_NAME[] = "DoorUnlocker-XIAO-v4";
static const char CONTROLLER_FIRMWARE_VERSION[] = "0.1.30";
// Fresh random-static BLE identity for the app-layer-security firmware. This
// avoids stale iOS/macOS OS-level bond records from the earlier encrypted-GATT
// builds while preserving trusted app keys in LittleFS.
static const uint8_t CONTROLLER_BLE_STATIC_ADDRESS[6] = {
  0x26, 0x20, 0x10, 0x5A, 0x17, 0xD8
};
static const uint32_t SETTING_APPLY_STATUS_MS = 3000;

// Door Unlocker BLE v2 UUIDs. The v2 service avoids stale iOS GATT caches
// from earlier firmware that did not include the pairing characteristic.
static const char DOOR_SERVICE_UUID[] = "7A5A2000-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char COMMAND_CHAR_UUID[] = "7A5A2001-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char STATE_CHAR_UUID[]   = "7A5A2002-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char PAIRING_CHAR_UUID[] = "7A5A2003-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char CONTROL_CHAR_UUID[]     = "7A5A2004-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char PAIRINGS_FILENAME[] = "/door-pairings.bin";
static const char PAIRINGS_SLOT_A_FILENAME[] = "/door-pairings-a.bin";
static const char PAIRINGS_SLOT_B_FILENAME[] = "/door-pairings-b.bin";
static const char PAIRINGS_TEMP_FILENAME[] = "/door-pairings-tmp.bin";
static const uint8_t PAIRINGS_FILE_MAGIC[4] = {'D', 'U', 'P', '2'};
static const uint8_t PAIRINGS_FILE_VERSION = 1;
static const size_t PAIRINGS_FILE_HEADER_LEN = 20;
static const char UNLOCK_TIMEOUT_FILENAME[] = "/unlock-timeout.txt";
static const char UNLOCK_TIMEOUT_BACKUP_FILENAME[] = "/unlock-timeout.bak";
static const char UNLOCK_TIMEOUT_TEMP_FILENAME[] = "/unlock-timeout.tmp";
static const char LOCK_NAME_FILENAME[] = "/lock-name.txt";
static const char LOCK_NAME_BACKUP_FILENAME[] = "/lock-name.bak";
static const char LOCK_NAME_TEMP_FILENAME[] = "/lock-name.tmp";
static const char SERVO_ANGLES_FILENAME[] = "/servo-angles.txt";
static const char SERVO_ANGLES_BACKUP_FILENAME[] = "/servo-angles.bak";
static const char SERVO_ANGLES_TEMP_FILENAME[] = "/servo-angles.tmp";
static const char LAST_UNLOCK_FILENAME[] = "/last-unlock.txt";
static const char LAST_UNLOCK_BACKUP_FILENAME[] = "/last-unlock.bak";
static const char LAST_UNLOCK_TEMP_FILENAME[] = "/last-unlock.tmp";
static const uint16_t SECURE_COMMAND_MAX_LEN = 220;
static const uint16_t PAIRING_MAX_LEN = 100;
static const uint16_t SERIAL_COMMAND_MAX_LEN = 260;
static const uint8_t BLE_COMMAND_QUEUE_CAPACITY = 8;
static const uint8_t BLE_COMMAND_QUEUE_PER_CONNECTION_LIMIT = 2;
static const uint8_t STATE_NOTIFICATION_QUEUE_CAPACITY = 12;
static const uint8_t AUTHORITATIVE_STATE_REPEAT_COUNT = 2;
static const size_t BLE_REJECT_REASON_LEN = 40;
static const size_t STATE_PAYLOAD_MAX_LEN = 124;
static const size_t V3_KEY_FINGERPRINT_LEN = 8;
static const size_t V3_NONCE_LEN = 16;
static const uint8_t V3_COMMAND_VERSION = 0x03;
static const uint8_t V3_OP_UNLOCK = 0x01;
static const uint8_t V3_OP_LOCK = 0x02;
static const uint8_t V3_OP_GET_LOCK_NAME = 0x10;
static const uint8_t V3_OP_GET_SERVO_ANGLES = 0x11;
static const uint8_t V3_OP_GET_LAST_UNLOCK = 0x12;
static const uint8_t V3_OP_SET_LOCK_NAME = 0x20;
static const uint8_t V3_OP_SET_SERVO_ANGLES = 0x21;
static const uint8_t V3_OP_SET_TIMEOUT = 0x22;
static const uint8_t V3_OP_SET_DEVICE_NAME = 0x23;
static const uint8_t V3_OP_PAIRING_ENABLE = 0x24;
static const uint8_t V3_OP_PAIRING_DISABLE = 0x25;
static const uint8_t V3_OP_PAIRING_APPROVE = 0x26;
static const uint8_t V3_OP_PAIRING_REJECT = 0x27;
static const uint8_t V3_OP_ENTER_OTA_DFU = 0x30;
static const char V3_COMMAND_SIGNATURE_DOMAIN[] = "DoorUnlocker:v3:command";
static const size_t P256_PUBLIC_KEY_LEN = 65;   // X9.63 uncompressed: 0x04 || X || Y
static const size_t P256_SIGNATURE_LEN = 64;    // Raw ECDSA: R || S
static const size_t V3_COMMAND_HEADER_LEN = 1 + 1 + V3_KEY_FINGERPRINT_LEN + V3_NONCE_LEN + 1;
static const size_t V3_COMMAND_MIN_PACKET_LEN = V3_COMMAND_HEADER_LEN + P256_SIGNATURE_LEN;
static const size_t V3_COMMAND_MAX_PAYLOAD_LEN = SECURE_COMMAND_MAX_LEN - V3_COMMAND_MIN_PACKET_LEN;
static const uint8_t MAX_BLE_CONNECTIONS = 4;
static const uint8_t MAX_PAIRED_PHONES = 4;
static const uint8_t PAIRING_PAYLOAD_WITH_NAME_VERSION = 0x01;
static const size_t PAIRED_DEVICE_NAME_LEN = 24;
static const size_t PAIRED_DEVICE_NAME_STORAGE_LEN = PAIRED_DEVICE_NAME_LEN + 1;
static const size_t LOCK_NAME_LEN = 24;
static const size_t LOCK_NAME_STORAGE_LEN = LOCK_NAME_LEN + 1;
static const size_t PAIRING_RECORD_LEN = P256_PUBLIC_KEY_LEN + sizeof(uint64_t) + PAIRED_DEVICE_NAME_STORAGE_LEN;
static const size_t PAIRING_APPROVAL_CODE_LEN = 4;
static const size_t PAIRING_FINGERPRINT_LEN = 19; // 8-byte SHA-256 prefix as XXXX-XXXX-XXXX-XXXX
static const uint32_t V3_NONCE_RETRY_INTERVAL_MS = 500;
static const uint32_t UNTRUSTED_REJECT_DISCONNECT_DELAY_MS = 400;
static const uint32_t UNTRUSTED_IDLE_DISCONNECT_MS = 8000;
static const uint32_t UNTRUSTED_CLEANUP_INTERVAL_MS = 500;
static const uint32_t STATE_SUBSCRIPTION_SETTLE_MS = 250;

BLEService doorService = BLEService(DOOR_SERVICE_UUID);
BLECharacteristic commandCharacteristic = BLECharacteristic(COMMAND_CHAR_UUID);
BLECharacteristic stateCharacteristic = BLECharacteristic(STATE_CHAR_UUID);
BLECharacteristic pairingCharacteristic = BLECharacteristic(PAIRING_CHAR_UUID);
BLECharacteristic controlCharacteristic = BLECharacteristic(CONTROL_CHAR_UUID);
BLEDis deviceInformation;

Servo handleServo;
uint8_t lockAngle = DEFAULT_LOCK_ANGLE;
uint8_t unlockAngle = DEFAULT_UNLOCK_ANGLE;
int currentAngle = DEFAULT_LOCK_ANGLE;
bool unlocked = false;
bool servoMoving = false;
bool internalFsReady = false;
bool pairingModeEnabled = false;
bool pendingPairingExists = false;
bool unlockAutoLockActive = false;
uint32_t unlockAutoLockStartedMs = 0;
uint16_t unlockHoldTimeoutSeconds = DEFAULT_UNLOCK_HOLD_TIMEOUT_SECONDS;
uint16_t lastPublishedUnlockRemainingSeconds = 0xFFFF;
uint64_t lastUnlockEpochSeconds = 0;
char lastUnlockDeviceFingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
char lastUnlockDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
char controllerLockName[LOCK_NAME_STORAGE_LEN] = {0};
char activeSettingApplyKind[24] = {0};
char activeSettingApplyValue[32] = {0};
bool settingApplyStatusActive = false;
uint32_t settingApplyStatusStartedMs = 0;
uint8_t pendingPairingPublicKey[P256_PUBLIC_KEY_LEN] = {0};
char pendingPairingDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
uint16_t pendingPairingConnHandle = BLE_CONN_HANDLE_INVALID;
uint8_t pairedPublicKeyCount = 0;
uint32_t pairingsGeneration = 0;
char activePairingsSlot = 0;
uint8_t pairedPublicKeys[MAX_PAIRED_PHONES][P256_PUBLIC_KEY_LEN] = {{0}};
uint64_t pairedCounters[MAX_PAIRED_PHONES] = {0};
char pairedDeviceNames[MAX_PAIRED_PHONES][PAIRED_DEVICE_NAME_STORAGE_LEN] = {{0}};
bool connectedDeviceSlotsUsed[MAX_BLE_CONNECTIONS] = {false};
bool connectedDeviceTrusted[MAX_BLE_CONNECTIONS] = {false};
uint16_t connectedDeviceHandles[MAX_BLE_CONNECTIONS] = {0};
char connectedDeviceNames[MAX_BLE_CONNECTIONS][PAIRED_DEVICE_NAME_STORAGE_LEN] = {{0}};
bool connectedDeviceNonceValid[MAX_BLE_CONNECTIONS] = {false};
uint8_t connectedDeviceNonces[MAX_BLE_CONNECTIONS][V3_NONCE_LEN] = {{0}};
uint32_t connectedDeviceFirstSeenMs[MAX_BLE_CONNECTIONS] = {0};
bool connectedDeviceRejected[MAX_BLE_CONNECTIONS] = {false};
char stateNotificationQueues[MAX_BLE_CONNECTIONS][STATE_NOTIFICATION_QUEUE_CAPACITY][STATE_PAYLOAD_MAX_LEN] = {{{0}}};
volatile uint8_t stateNotificationQueueHeads[MAX_BLE_CONNECTIONS] = {0};
volatile uint8_t stateNotificationQueueTails[MAX_BLE_CONNECTIONS] = {0};
volatile uint8_t stateNotificationQueueCounts[MAX_BLE_CONNECTIONS] = {0};
volatile bool stateNotificationSending[MAX_BLE_CONNECTIONS] = {false};
volatile bool stateNotificationQueueOverflowed[MAX_BLE_CONNECTIONS] = {false};
volatile uint32_t stateNotificationQueueGenerations[MAX_BLE_CONNECTIONS] = {0};
bool stateStartupSnapshotPending[MAX_BLE_CONNECTIONS] = {false};
bool stateStartupSnapshotDelivered[MAX_BLE_CONNECTIONS] = {false};
uint32_t stateStartupSnapshotDueMs[MAX_BLE_CONNECTIONS] = {0};
uint32_t stateStartupSnapshotGenerations[MAX_BLE_CONNECTIONS] = {0};
char controllerBootSessionId[17] = {0};
uint32_t lastNonceRetryMs = 0;
uint32_t lastUntrustedCleanupMs = 0;

struct BleCommandJob {
  bool isReject;
  uint16_t connHandle;
  uint16_t payloadLen;
  uint8_t payload[SECURE_COMMAND_MAX_LEN];
  char rejectReason[BLE_REJECT_REASON_LEN];
};

struct PairingsSnapshot {
  uint8_t count;
  uint32_t generation;
  uint8_t keys[MAX_PAIRED_PHONES][P256_PUBLIC_KEY_LEN];
  uint64_t counters[MAX_PAIRED_PHONES];
  char names[MAX_PAIRED_PHONES][PAIRED_DEVICE_NAME_STORAGE_LEN];
};

BleCommandJob bleCommandQueue[BLE_COMMAND_QUEUE_CAPACITY];
volatile uint8_t bleCommandQueueHead = 0;
volatile uint8_t bleCommandQueueTail = 0;
volatile uint8_t bleCommandQueueCount = 0;
uint16_t bleCommandQueueOverflowHandles[MAX_BLE_CONNECTIONS] = {0};
volatile uint8_t bleCommandQueueOverflowCount = 0;
bool bleCommandQueueServeOverflowNext = false;

bool parseUnsigned64Range(const char* start, const char* end, uint64_t* value) {
  if (start == nullptr || end == nullptr || start >= end) {
    return false;
  }

  uint64_t result = 0;
  for (const char* cursor = start; cursor < end; cursor++) {
    if (*cursor < '0' || *cursor > '9') {
      return false;
    }

    uint8_t digit = *cursor - '0';
    if (result > (UINT64_MAX - digit) / 10) {
      return false;
    }

    result = (result * 10) + digit;
  }

  *value = result;
  return true;
}

bool parseUnsigned64Text(const char* text, uint64_t* value) {
  if (text == nullptr) {
    return false;
  }

  return parseUnsigned64Range(text, text + strlen(text), value);
}

bool decodeHexBytes(const char* hex, uint8_t* output, size_t outputCapacity, size_t* outputLen) {
  if (hex == nullptr || output == nullptr || outputLen == nullptr) {
    return false;
  }

  size_t hexLen = strlen(hex);
  if (hexLen == 0 || (hexLen % 2) != 0 || hexLen / 2 > outputCapacity) {
    return false;
  }

  size_t writeIndex = 0;
  for (size_t readIndex = 0; readIndex < hexLen; readIndex += 2) {
    int8_t high = hexNibble(hex[readIndex]);
    int8_t low = hexNibble(hex[readIndex + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    output[writeIndex++] = (uint8_t) ((high << 4) | low);
  }

  *outputLen = writeIndex;
  return true;
}

void printUnsigned64(uint64_t value) {
  char buffer[21] = {0};
  uint8_t position = sizeof(buffer) - 1;

  if (value == 0) {
    Serial.print("0");
    return;
  }

  while (value > 0 && position > 0) {
    buffer[--position] = '0' + (value % 10);
    value /= 10;
  }

  Serial.print(buffer + position);
}

bool ensureInternalFS() {
  if (internalFsReady) {
    return true;
  }

  internalFsReady = InternalFS.begin();
  if (!internalFsReady) {
    Serial.println("InternalFS failed; pairing and replay protection unavailable");
  }

  return internalFsReady;
}

bool readFileBytes(const char* filename, uint8_t* output, size_t capacity, size_t* outputLen) {
  if (output == nullptr || outputLen == nullptr || capacity == 0 || !InternalFS.exists(filename)) {
    return false;
  }
  File file(InternalFS);
  if (!file.open(filename, FILE_O_READ) || file.size() > capacity) {
    file.close();
    return false;
  }
  size_t fileSize = file.size();
  size_t readLen = file.read(output, fileSize);
  file.close();
  if (readLen != fileSize) {
    return false;
  }
  *outputLen = readLen;
  return true;
}

bool writeProtectedBytes(
  const char* primary,
  const char* backup,
  const char* temporary,
  const uint8_t* data,
  size_t len
) {
  if (!ensureInternalFS() || data == nullptr || len == 0) {
    return false;
  }
  InternalFS.remove(temporary);
  File file(InternalFS);
  if (!file.open(temporary, FILE_O_WRITE) || file.write(data, len) != len) {
    file.close();
    InternalFS.remove(temporary);
    return false;
  }
  file.close();

  uint8_t verification[128] = {0};
  size_t verificationLen = 0;
  if (len > sizeof(verification)
      || !readFileBytes(temporary, verification, sizeof(verification), &verificationLen)
      || verificationLen != len
      || memcmp(verification, data, len) != 0) {
    InternalFS.remove(temporary);
    return false;
  }

  if (InternalFS.exists(primary)) {
    InternalFS.remove(backup);
    if (!InternalFS.rename(primary, backup)) {
      InternalFS.remove(temporary);
      return false;
    }
  }
  if (!InternalFS.rename(temporary, primary)) {
    return false;
  }
  return true;
}

void restoreProtectedBackup(const char* primary, const char* backup) {
  if (!InternalFS.exists(backup)) {
    return;
  }
  InternalFS.remove(primary);
  InternalFS.rename(backup, primary);
}

bool buildPublicKeyFromRaw(const uint8_t* rawKey, CRYS_ECPKI_UserPublKey_t* publicKey) {
  const CRYS_ECPKI_Domain_t* domain = CRYS_ECPKI_GetEcDomain(CRYS_ECPKI_DomainID_secp256r1);
  if (domain == nullptr || rawKey == nullptr || publicKey == nullptr || rawKey[0] != 0x04) {
    return false;
  }

  static CRYS_ECPKI_BUILD_TempData_t buildTemp;
  memset(&buildTemp, 0, sizeof(buildTemp));

  uint32_t err = CRYS_ECPKI_BuildPublKeyPartlyCheck(
    domain,
    (uint8_t*) rawKey,
    P256_PUBLIC_KEY_LEN,
    publicKey,
    &buildTemp
  );

  return err == CRYS_OK;
}

bool isValidPublicKey(const uint8_t* rawKey) {
  CRYS_ECPKI_UserPublKey_t publicKey;
  memset(&publicKey, 0, sizeof(publicKey));
  return buildPublicKeyFromRaw(rawKey, &publicKey);
}

bool keyFingerprint(const uint8_t* rawKey, char* output, size_t outputLen) {
  if (rawKey == nullptr || output == nullptr || outputLen < PAIRING_FINGERPRINT_LEN + 1) {
    return false;
  }

  nRFCrypto_Hash hash;
  uint32_t digest[16] = {0};
  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }
  if (!hash.update((uint8_t*) rawKey, P256_PUBLIC_KEY_LEN)) {
    return false;
  }

  uint8_t digestLen = hash.end(digest);
  if (digestLen < 8) {
    return false;
  }

  const uint8_t* bytes = (const uint8_t*) digest;
  snprintf(
    output,
    outputLen,
    "%02X%02X-%02X%02X-%02X%02X-%02X%02X",
    bytes[0], bytes[1], bytes[2], bytes[3],
    bytes[4], bytes[5], bytes[6], bytes[7]
  );
  return true;
}

bool keyFingerprintBytes(const uint8_t* rawKey, uint8_t* output, size_t outputLen) {
  if (rawKey == nullptr || output == nullptr || outputLen < V3_KEY_FINGERPRINT_LEN) {
    return false;
  }

  nRFCrypto_Hash hash;
  uint32_t digest[16] = {0};
  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }
  if (!hash.update((uint8_t*) rawKey, P256_PUBLIC_KEY_LEN)) {
    return false;
  }

  uint8_t digestLen = hash.end(digest);
  if (digestLen < V3_KEY_FINGERPRINT_LEN) {
    return false;
  }

  memcpy(output, (const uint8_t*) digest, V3_KEY_FINGERPRINT_LEN);
  return true;
}

bool keyApprovalCode(const uint8_t* rawKey, char* output, size_t outputLen) {
  if (rawKey == nullptr || output == nullptr || outputLen < PAIRING_APPROVAL_CODE_LEN + 1) {
    return false;
  }

  nRFCrypto_Hash hash;
  uint32_t digest[16] = {0};
  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }
  if (!hash.update((uint8_t*) rawKey, P256_PUBLIC_KEY_LEN)) {
    return false;
  }

  uint8_t digestLen = hash.end(digest);
  if (digestLen < 2) {
    return false;
  }

  const uint8_t* bytes = (const uint8_t*) digest;
  uint16_t code = ((((uint16_t) bytes[0]) << 8) | bytes[1]) % 10000;
  snprintf(output, outputLen, "%04u", code);
  return true;
}

bool isFingerprintText(const char* text) {
  if (text == nullptr || strlen(text) != PAIRING_FINGERPRINT_LEN) {
    return false;
  }

  for (size_t index = 0; index < PAIRING_FINGERPRINT_LEN; index++) {
    char value = text[index];
    if (index == 4 || index == 9 || index == 14) {
      if (value != '-') {
        return false;
      }
      continue;
    }

    bool isHex = (value >= '0' && value <= '9')
      || (value >= 'A' && value <= 'F')
      || (value >= 'a' && value <= 'f');
    if (!isHex) {
      return false;
    }
  }

  return true;
}

bool fingerprintForPairedDevice(uint8_t index, char* output, size_t outputLen) {
  if (index >= pairedPublicKeyCount) {
    return false;
  }

  return keyFingerprint(pairedPublicKeys[index], output, outputLen);
}

void copyResolvedLastUnlockDeviceName(char* output, size_t outputLen) {
  if (output == nullptr || outputLen == 0) {
    return;
  }

  memset(output, 0, outputLen);
  if (lastUnlockDeviceFingerprint[0] != 0) {
    for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
      char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
      if (fingerprintForPairedDevice(index, fingerprint, sizeof(fingerprint))
          && strcmp(fingerprint, lastUnlockDeviceFingerprint) == 0) {
        copyDeviceName(pairedDeviceNames[index], output, outputLen);
        if (output[0] != 0) {
          return;
        }
      }
    }
  }

  copyDeviceName(lastUnlockDeviceName, output, outputLen);
}

bool pairingCodeMatches(const char* expected, const char* provided) {
  if (expected == nullptr || provided == nullptr) {
    return false;
  }

  while (*expected != 0 && *provided != 0) {
    if (*provided == ' ' || *provided == '\t' || *provided == '-') {
      provided++;
      continue;
    }

    char expectedChar = (*expected >= 'A' && *expected <= 'Z') ? *expected + 32 : *expected;
    char providedChar = (*provided >= 'A' && *provided <= 'Z') ? *provided + 32 : *provided;
    if (expectedChar != providedChar) {
      return false;
    }

    expected++;
    provided++;
  }

  while (*provided == ' ' || *provided == '\t' || *provided == '-') {
    provided++;
  }

  return *expected == 0 && *provided == 0;
}

void appendSanitizedDeviceNameChar(char character, char* output, size_t outputLen, size_t& writeIndex, bool& previousWasSpace) {
  if (writeIndex >= outputLen - 1) {
    return;
  }

  if (character == '\t' || character == '\r' || character == '\n') {
    character = ' ';
  }

  bool isPrintable = character >= 32 && character <= 126;
  if (!isPrintable) {
    return;
  }

  if (character == ' ') {
    if (writeIndex == 0 || previousWasSpace) {
      return;
    }
    previousWasSpace = true;
  } else {
    previousWasSpace = false;
  }

  output[writeIndex++] = character;
}

void appendSanitizedDeviceNameText(const char* text, char* output, size_t outputLen, size_t& writeIndex, bool& previousWasSpace) {
  if (text == nullptr) {
    return;
  }

  for (size_t index = 0; text[index] != 0 && writeIndex < outputLen - 1; index++) {
    appendSanitizedDeviceNameChar(text[index], output, outputLen, writeIndex, previousWasSpace);
  }
}

bool normalizedDeviceNameUtf8Replacement(const uint8_t* rawName, size_t rawLen, size_t readIndex, const char** replacement, size_t* consumed) {
  if (replacement == nullptr || consumed == nullptr) {
    return false;
  }

  *replacement = nullptr;
  *consumed = 0;

  if (rawName == nullptr || readIndex + 2 >= rawLen || rawName[readIndex] != 0xE2 || rawName[readIndex + 1] != 0x80) {
    return false;
  }

  switch (rawName[readIndex + 2]) {
    case 0x90: // U+2010 hyphen
    case 0x91: // U+2011 non-breaking hyphen
    case 0x92: // U+2012 figure dash
    case 0x93: // U+2013 en dash
    case 0x94: // U+2014 em dash
      *replacement = "-";
      *consumed = 3;
      return true;
    case 0x98: // U+2018 left single quotation mark
    case 0x99: // U+2019 right single quotation mark
    case 0x9B: // U+201B single high-reversed-9 quotation mark
    case 0xB2: // U+2032 prime
      *replacement = "'";
      *consumed = 3;
      return true;
    case 0x9C: // U+201C left double quotation mark
    case 0x9D: // U+201D right double quotation mark
    case 0x9E: // U+201E double low-9 quotation mark
    case 0xB3: // U+2033 double prime
      *replacement = "\"";
      *consumed = 3;
      return true;
    case 0xA6: // U+2026 ellipsis
      *replacement = "...";
      *consumed = 3;
      return true;
    default:
      return false;
  }
}

void sanitizeDeviceName(const uint8_t* rawName, size_t rawLen, char* output, size_t outputLen) {
  if (output == nullptr || outputLen == 0) {
    return;
  }

  memset(output, 0, outputLen);
  if (rawName == nullptr || rawLen == 0) {
    return;
  }

  size_t writeIndex = 0;
  bool previousWasSpace = false;
  for (size_t readIndex = 0; readIndex < rawLen && writeIndex < outputLen - 1; readIndex++) {
    uint8_t value = rawName[readIndex];
    if (value == 0) {
      break;
    }

    const char* replacement = nullptr;
    size_t consumed = 0;
    if (normalizedDeviceNameUtf8Replacement(rawName, rawLen, readIndex, &replacement, &consumed)) {
      appendSanitizedDeviceNameText(replacement, output, outputLen, writeIndex, previousWasSpace);
      readIndex += consumed - 1;
      continue;
    }

    appendSanitizedDeviceNameChar((char) value, output, outputLen, writeIndex, previousWasSpace);
  }

  while (writeIndex > 0 && output[writeIndex - 1] == ' ') {
    output[--writeIndex] = 0;
  }
}

void copyDeviceName(const char* name, char* output, size_t outputLen) {
  sanitizeDeviceName((const uint8_t*) name, name == nullptr ? 0 : strlen(name), output, outputLen);
}

void copyLockName(const char* name, char* output, size_t outputLen) {
  sanitizeDeviceName((const uint8_t*) name, name == nullptr ? 0 : strlen(name), output, outputLen);
}

bool saveLockName() {
  return writeProtectedBytes(
    LOCK_NAME_FILENAME,
    LOCK_NAME_BACKUP_FILENAME,
    LOCK_NAME_TEMP_FILENAME,
    (uint8_t*) controllerLockName,
    strlen(controllerLockName)
  );
}

void loadLockName() {
  copyLockName(DEFAULT_LOCK_NAME, controllerLockName, sizeof(controllerLockName));

  if (!ensureInternalFS()) {
    return;
  }

  const char* candidates[] = {LOCK_NAME_FILENAME, LOCK_NAME_BACKUP_FILENAME};
  for (uint8_t candidate = 0; candidate < 2; candidate++) {
    char buffer[LOCK_NAME_STORAGE_LEN] = {0};
    size_t readLen = 0;
    if (!readFileBytes(candidates[candidate], (uint8_t*) buffer, sizeof(buffer) - 1, &readLen)) {
      continue;
    }
    buffer[readLen] = 0;
    char sanitizedName[LOCK_NAME_STORAGE_LEN] = {0};
    copyLockName(buffer, sanitizedName, sizeof(sanitizedName));
    if (sanitizedName[0] != 0) {
      copyLockName(sanitizedName, controllerLockName, sizeof(controllerLockName));
      if (candidate == 1) {
        restoreProtectedBackup(LOCK_NAME_FILENAME, LOCK_NAME_BACKUP_FILENAME);
      }
      return;
    }
  }
}

bool setControllerLockName(const char* name) {
  char sanitizedName[LOCK_NAME_STORAGE_LEN] = {0};
  copyLockName(name, sanitizedName, sizeof(sanitizedName));
  if (sanitizedName[0] == 0) {
    return false;
  }

  char previousName[LOCK_NAME_STORAGE_LEN] = {0};
  copyLockName(controllerLockName, previousName, sizeof(previousName));
  copyLockName(sanitizedName, controllerLockName, sizeof(controllerLockName));
  if (!saveLockName()) {
    copyLockName(previousName, controllerLockName, sizeof(controllerLockName));
    return false;
  }

  Serial.print("Lock name set to ");
  Serial.println(controllerLockName);
  return true;
}

bool isValidServoAngle(uint64_t angle) {
  return angle >= MIN_SAFE_SERVO_ANGLE && angle <= MAX_SAFE_SERVO_ANGLE;
}

bool areValidServoAngles(uint64_t requestedLockAngle, uint64_t requestedUnlockAngle) {
  if (!isValidServoAngle(requestedLockAngle) || !isValidServoAngle(requestedUnlockAngle)) {
    return false;
  }

  uint64_t gap = requestedLockAngle > requestedUnlockAngle
    ? requestedLockAngle - requestedUnlockAngle
    : requestedUnlockAngle - requestedLockAngle;
  return gap >= MIN_SERVO_ANGLE_GAP;
}

bool parseServoAnglesText(const char* text, uint16_t* requestedLockAngle, uint16_t* requestedUnlockAngle) {
  if (text == nullptr || requestedLockAngle == nullptr || requestedUnlockAngle == nullptr) {
    return false;
  }

  const char* cursor = text;
  while (*cursor == ' ' || *cursor == '\t') {
    cursor++;
  }

  const char* lockStart = cursor;
  while (*cursor >= '0' && *cursor <= '9') {
    cursor++;
  }
  if (lockStart == cursor) {
    return false;
  }

  uint64_t parsedLockAngle = 0;
  if (!parseUnsigned64Range(lockStart, cursor, &parsedLockAngle)) {
    return false;
  }

  const char* separatorStart = cursor;
  while (*cursor == ' ' || *cursor == '\t') {
    cursor++;
  }

  if (*cursor == ',') {
    cursor++;
  } else if (separatorStart == cursor) {
    return false;
  }

  while (*cursor == ' ' || *cursor == '\t') {
    cursor++;
  }

  const char* unlockStart = cursor;
  while (*cursor >= '0' && *cursor <= '9') {
    cursor++;
  }
  if (unlockStart == cursor) {
    return false;
  }

  uint64_t parsedUnlockAngle = 0;
  if (!parseUnsigned64Range(unlockStart, cursor, &parsedUnlockAngle)) {
    return false;
  }

  while (*cursor == ' ' || *cursor == '\t') {
    cursor++;
  }
  if (*cursor != 0 || !areValidServoAngles(parsedLockAngle, parsedUnlockAngle)) {
    return false;
  }

  *requestedLockAngle = (uint16_t) parsedLockAngle;
  *requestedUnlockAngle = (uint16_t) parsedUnlockAngle;
  return true;
}

bool saveServoAngles() {
  char buffer[12] = {0};
  snprintf(buffer, sizeof(buffer), "%u,%u", lockAngle, unlockAngle);
  return writeProtectedBytes(
    SERVO_ANGLES_FILENAME,
    SERVO_ANGLES_BACKUP_FILENAME,
    SERVO_ANGLES_TEMP_FILENAME,
    (uint8_t*) buffer,
    strlen(buffer)
  );
}

void loadServoAngles() {
  lockAngle = DEFAULT_LOCK_ANGLE;
  unlockAngle = DEFAULT_UNLOCK_ANGLE;

  if (!ensureInternalFS()) {
    return;
  }

  const char* candidates[] = {SERVO_ANGLES_FILENAME, SERVO_ANGLES_BACKUP_FILENAME};
  for (uint8_t candidate = 0; candidate < 2; candidate++) {
    char buffer[16] = {0};
    size_t readLen = 0;
    if (!readFileBytes(candidates[candidate], (uint8_t*) buffer, sizeof(buffer) - 1, &readLen)) {
      continue;
    }
    buffer[readLen] = 0;
    uint16_t storedLockAngle = 0;
    uint16_t storedUnlockAngle = 0;
    if (parseServoAnglesText(buffer, &storedLockAngle, &storedUnlockAngle)) {
      lockAngle = (uint8_t) storedLockAngle;
      unlockAngle = (uint8_t) storedUnlockAngle;
      if (candidate == 1) {
        restoreProtectedBackup(SERVO_ANGLES_FILENAME, SERVO_ANGLES_BACKUP_FILENAME);
      }
      return;
    }
  }
}

bool setServoAngles(uint16_t requestedLockAngle, uint16_t requestedUnlockAngle) {
  if (!areValidServoAngles(requestedLockAngle, requestedUnlockAngle)) {
    return false;
  }

  uint8_t previousLockAngle = lockAngle;
  uint8_t previousUnlockAngle = unlockAngle;
  lockAngle = (uint8_t) requestedLockAngle;
  unlockAngle = (uint8_t) requestedUnlockAngle;
  if (!saveServoAngles()) {
    lockAngle = previousLockAngle;
    unlockAngle = previousUnlockAngle;
    return false;
  }

  Serial.print("Servo angles set to rest=");
  Serial.print(lockAngle);
  Serial.print(" push=");
  Serial.println(unlockAngle);
  return true;
}

bool saveLastUnlockRecord() {
  char buffer[96] = {0};
  if (lastUnlockDeviceFingerprint[0] != 0) {
    snprintf(
      buffer,
      sizeof(buffer),
      "%llu\n%s\n%s",
      (unsigned long long) lastUnlockEpochSeconds,
      lastUnlockDeviceFingerprint,
      lastUnlockDeviceName
    );
  } else if (lastUnlockDeviceName[0] != 0) {
    snprintf(
      buffer,
      sizeof(buffer),
      "%llu\n%s",
      (unsigned long long) lastUnlockEpochSeconds,
      lastUnlockDeviceName
    );
  } else {
    snprintf(buffer, sizeof(buffer), "%llu", (unsigned long long) lastUnlockEpochSeconds);
  }
  return writeProtectedBytes(
    LAST_UNLOCK_FILENAME,
    LAST_UNLOCK_BACKUP_FILENAME,
    LAST_UNLOCK_TEMP_FILENAME,
    (uint8_t*) buffer,
    strlen(buffer)
  );
}

void loadLastUnlockRecord() {
  lastUnlockEpochSeconds = 0;
  memset(lastUnlockDeviceFingerprint, 0, sizeof(lastUnlockDeviceFingerprint));
  memset(lastUnlockDeviceName, 0, sizeof(lastUnlockDeviceName));

  if (!ensureInternalFS()) {
    return;
  }

  char buffer[96] = {0};
  size_t readLen = 0;
  bool loadedBackup = false;
  if (!readFileBytes(LAST_UNLOCK_FILENAME, (uint8_t*) buffer, sizeof(buffer) - 1, &readLen)) {
    loadedBackup = readFileBytes(LAST_UNLOCK_BACKUP_FILENAME, (uint8_t*) buffer, sizeof(buffer) - 1, &readLen);
  }
  if (readLen == 0) {
    return;
  }
  buffer[readLen] = 0;

  char* secondLine = strchr(buffer, '\n');
  if (secondLine != nullptr) {
    *secondLine = 0;
    secondLine++;
  }

  char* carriageReturn = strchr(buffer, '\r');
  if (carriageReturn != nullptr) {
    *carriageReturn = 0;
  }

  uint64_t storedEpochSeconds = 0;
  if (parseUnsigned64Text(buffer, &storedEpochSeconds)) {
    lastUnlockEpochSeconds = storedEpochSeconds;
    if (secondLine != nullptr) {
      char* thirdLine = strchr(secondLine, '\n');
      if (thirdLine != nullptr) {
        *thirdLine = 0;
        thirdLine++;
      }

      char* secondLineCarriageReturn = strchr(secondLine, '\r');
      if (secondLineCarriageReturn != nullptr) {
        *secondLineCarriageReturn = 0;
      }

      if (isFingerprintText(secondLine)) {
        strncpy(lastUnlockDeviceFingerprint, secondLine, sizeof(lastUnlockDeviceFingerprint) - 1);
        lastUnlockDeviceFingerprint[sizeof(lastUnlockDeviceFingerprint) - 1] = 0;
        if (thirdLine != nullptr) {
          copyDeviceName(thirdLine, lastUnlockDeviceName, sizeof(lastUnlockDeviceName));
        }
      } else {
        copyDeviceName(secondLine, lastUnlockDeviceName, sizeof(lastUnlockDeviceName));
      }
    }
    if (loadedBackup) {
      restoreProtectedBackup(LAST_UNLOCK_FILENAME, LAST_UNLOCK_BACKUP_FILENAME);
    }
  } else {
    memset(buffer, 0, sizeof(buffer));
    readLen = 0;
    if (!loadedBackup
        && readFileBytes(LAST_UNLOCK_BACKUP_FILENAME, (uint8_t*) buffer, sizeof(buffer) - 1, &readLen)) {
      restoreProtectedBackup(LAST_UNLOCK_FILENAME, LAST_UNLOCK_BACKUP_FILENAME);
      loadLastUnlockRecord();
    }
  }
}

bool setLastUnlockRecord(uint64_t epochSeconds, const char* deviceFingerprint, const char* deviceName) {
  if (epochSeconds == 0) {
    return true;
  }

  uint64_t previousEpochSeconds = lastUnlockEpochSeconds;
  char previousDeviceFingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  char previousDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  strncpy(previousDeviceFingerprint, lastUnlockDeviceFingerprint, sizeof(previousDeviceFingerprint) - 1);
  copyDeviceName(lastUnlockDeviceName, previousDeviceName, sizeof(previousDeviceName));

  lastUnlockEpochSeconds = epochSeconds;
  memset(lastUnlockDeviceFingerprint, 0, sizeof(lastUnlockDeviceFingerprint));
  if (isFingerprintText(deviceFingerprint)) {
    strncpy(lastUnlockDeviceFingerprint, deviceFingerprint, sizeof(lastUnlockDeviceFingerprint) - 1);
    lastUnlockDeviceFingerprint[sizeof(lastUnlockDeviceFingerprint) - 1] = 0;
  }
  copyDeviceName(deviceName, lastUnlockDeviceName, sizeof(lastUnlockDeviceName));
  if (!saveLastUnlockRecord()) {
    lastUnlockEpochSeconds = previousEpochSeconds;
    strncpy(lastUnlockDeviceFingerprint, previousDeviceFingerprint, sizeof(lastUnlockDeviceFingerprint) - 1);
    lastUnlockDeviceFingerprint[sizeof(lastUnlockDeviceFingerprint) - 1] = 0;
    copyDeviceName(previousDeviceName, lastUnlockDeviceName, sizeof(lastUnlockDeviceName));
    return false;
  }

  Serial.print("Last unlock epoch set to ");
  printUnsigned64(lastUnlockEpochSeconds);
  char resolvedDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  copyResolvedLastUnlockDeviceName(resolvedDeviceName, sizeof(resolvedDeviceName));
  if (resolvedDeviceName[0] != 0) {
    Serial.print(" by ");
    Serial.print(resolvedDeviceName);
  }
  Serial.println();
  return true;
}

void clearPendingPairing() {
  pendingPairingExists = false;
  pendingPairingConnHandle = BLE_CONN_HANDLE_INVALID;
  memset(pendingPairingPublicKey, 0, sizeof(pendingPairingPublicKey));
  memset(pendingPairingDeviceName, 0, sizeof(pendingPairingDeviceName));
}

void printPendingPairingRequest() {
  if (!pendingPairingExists) {
    Serial.println("No pending device pairing request.");
    return;
  }

  char approvalCode[PAIRING_APPROVAL_CODE_LEN + 1] = {0};
  char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  Serial.println("Pending device pairing request.");
  if (keyApprovalCode(pendingPairingPublicKey, approvalCode, sizeof(approvalCode))) {
    Serial.print("Code: ");
    Serial.println(approvalCode);
  } else {
    Serial.println("Code unavailable.");
  }
  if (keyFingerprint(pendingPairingPublicKey, fingerprint, sizeof(fingerprint))) {
    Serial.print("Fingerprint: ");
    Serial.println(fingerprint);
  } else {
    Serial.println("Fingerprint unavailable.");
  }
  if (pendingPairingDeviceName[0] != 0) {
    Serial.print("Device name: ");
    Serial.println(pendingPairingDeviceName);
  }
  Serial.println("Compare the 4-digit code with the app, then type 'pair approve CODE' or 'pair reject'.");
}

void encodeUnsigned64(uint64_t value, uint8_t* bytes) {
  for (int index = 7; index >= 0; index--) {
    bytes[index] = value & 0xff;
    value >>= 8;
  }
}

uint64_t decodeUnsigned64(const uint8_t* bytes) {
  uint64_t value = 0;
  for (uint8_t index = 0; index < 8; index++) {
    value = (value << 8) | bytes[index];
  }
  return value;
}

uint32_t unlockHoldTimeoutMs() {
  return (uint32_t) unlockHoldTimeoutSeconds * 1000UL;
}

uint16_t unlockHoldRemainingSeconds() {
  if (!unlocked || !unlockAutoLockActive) {
    return 0;
  }

  uint32_t elapsedMs = millis() - unlockAutoLockStartedMs;
  uint32_t timeoutMs = unlockHoldTimeoutMs();
  if (elapsedMs >= timeoutMs) {
    return 0;
  }

  uint32_t remainingMs = timeoutMs - elapsedMs;
  return (uint16_t) ((remainingMs + 999UL) / 1000UL);
}

bool isValidUnlockHoldTimeout(uint64_t seconds) {
  return seconds >= MIN_UNLOCK_HOLD_TIMEOUT_SECONDS && seconds <= MAX_UNLOCK_HOLD_TIMEOUT_SECONDS;
}

bool saveUnlockHoldTimeout() {
  char buffer[8] = {0};
  snprintf(buffer, sizeof(buffer), "%u", unlockHoldTimeoutSeconds);
  return writeProtectedBytes(
    UNLOCK_TIMEOUT_FILENAME,
    UNLOCK_TIMEOUT_BACKUP_FILENAME,
    UNLOCK_TIMEOUT_TEMP_FILENAME,
    (uint8_t*) buffer,
    strlen(buffer)
  );
}

void loadUnlockHoldTimeout() {
  unlockHoldTimeoutSeconds = DEFAULT_UNLOCK_HOLD_TIMEOUT_SECONDS;

  if (!ensureInternalFS()) {
    return;
  }

  const char* candidates[] = {UNLOCK_TIMEOUT_FILENAME, UNLOCK_TIMEOUT_BACKUP_FILENAME};
  for (uint8_t candidate = 0; candidate < 2; candidate++) {
    char buffer[8] = {0};
    size_t readLen = 0;
    if (!readFileBytes(candidates[candidate], (uint8_t*) buffer, sizeof(buffer) - 1, &readLen)) {
      continue;
    }
    buffer[readLen] = 0;
    uint64_t seconds = 0;
    if (parseUnsigned64Text(buffer, &seconds) && isValidUnlockHoldTimeout(seconds)) {
      unlockHoldTimeoutSeconds = seconds;
      if (candidate == 1) {
        restoreProtectedBackup(UNLOCK_TIMEOUT_FILENAME, UNLOCK_TIMEOUT_BACKUP_FILENAME);
      }
      return;
    }
  }
}

int8_t pairedPublicKeyIndex(const uint8_t* rawKey) {
  if (rawKey == nullptr) {
    return -1;
  }

  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    if (memcmp(pairedPublicKeys[index], rawKey, P256_PUBLIC_KEY_LEN) == 0) {
      return index;
    }
  }
  return -1;
}

bool pairedPublicKeyExists(const uint8_t* rawKey) {
  return pairedPublicKeyIndex(rawKey) >= 0;
}

int8_t pairedPublicKeyIndexForFingerprint(const char* fingerprint) {
  if (fingerprint == nullptr || *fingerprint == 0) {
    return -1;
  }

  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    char pairedFingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
    if (keyFingerprint(pairedPublicKeys[index], pairedFingerprint, sizeof(pairedFingerprint))
        && pairingCodeMatches(pairedFingerprint, fingerprint)) {
      return index;
    }
  }

  return -1;
}

int8_t pairedPublicKeyIndexForToken(const char* token) {
  if (token == nullptr || *token == 0) {
    return -1;
  }

  uint64_t requestedIndex = 0;
  if (parseUnsigned64Text(token, &requestedIndex)) {
    if (requestedIndex >= 1 && requestedIndex <= pairedPublicKeyCount) {
      return (int8_t)(requestedIndex - 1);
    }
    return -1;
  }

  return pairedPublicKeyIndexForFingerprint(token);
}

uint32_t pairingsCrc32Update(uint32_t crc, const uint8_t* data, size_t len) {
  for (size_t index = 0; index < len; index++) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xEDB88320UL & (uint32_t)(-(int32_t)(crc & 1)));
    }
  }
  return crc;
}

void encodeUnsigned32(uint32_t value, uint8_t* output) {
  for (uint8_t index = 0; index < 4; index++) {
    output[index] = (uint8_t)(value >> (index * 8));
  }
}

uint32_t decodeUnsigned32(const uint8_t* input) {
  uint32_t value = 0;
  for (uint8_t index = 0; index < 4; index++) {
    value |= ((uint32_t) input[index]) << (index * 8);
  }
  return value;
}

bool readPairingsSnapshot(const char* filename, PairingsSnapshot* snapshot) {
  if (snapshot == nullptr || !InternalFS.exists(filename)) {
    return false;
  }

  File file(InternalFS);
  if (!file.open(filename, FILE_O_READ)) {
    return false;
  }

  uint8_t header[PAIRINGS_FILE_HEADER_LEN] = {0};
  if (file.read(header, sizeof(header)) != sizeof(header)
      || memcmp(header, PAIRINGS_FILE_MAGIC, sizeof(PAIRINGS_FILE_MAGIC)) != 0
      || header[4] != PAIRINGS_FILE_VERSION
      || header[5] > MAX_PAIRED_PHONES) {
    file.close();
    return false;
  }

  uint8_t count = header[5];
  uint16_t payloadLen = (uint16_t) header[12] | ((uint16_t) header[13] << 8);
  uint32_t expectedCrc = decodeUnsigned32(header + 16);
  if (payloadLen != count * PAIRING_RECORD_LEN
      || file.size() != PAIRINGS_FILE_HEADER_LEN + payloadLen) {
    file.close();
    return false;
  }

  PairingsSnapshot candidate = {};
  candidate.count = count;
  candidate.generation = decodeUnsigned32(header + 8);
  uint32_t crc = pairingsCrc32Update(0xFFFFFFFFUL, header, 16);

  for (uint8_t index = 0; index < count; index++) {
    uint8_t counterBytes[8] = {0};
    if (file.read(candidate.keys[index], P256_PUBLIC_KEY_LEN) != P256_PUBLIC_KEY_LEN
        || file.read(counterBytes, sizeof(counterBytes)) != sizeof(counterBytes)
        || file.read((uint8_t*) candidate.names[index], PAIRED_DEVICE_NAME_STORAGE_LEN) != PAIRED_DEVICE_NAME_STORAGE_LEN) {
      file.close();
      return false;
    }
    candidate.names[index][PAIRED_DEVICE_NAME_LEN] = 0;
    candidate.counters[index] = decodeUnsigned64(counterBytes);
    crc = pairingsCrc32Update(crc, candidate.keys[index], P256_PUBLIC_KEY_LEN);
    crc = pairingsCrc32Update(crc, counterBytes, sizeof(counterBytes));
    crc = pairingsCrc32Update(crc, (uint8_t*) candidate.names[index], PAIRED_DEVICE_NAME_STORAGE_LEN);
    if (!isValidPublicKey(candidate.keys[index])) {
      file.close();
      return false;
    }
    for (uint8_t previous = 0; previous < index; previous++) {
      if (memcmp(candidate.keys[previous], candidate.keys[index], P256_PUBLIC_KEY_LEN) == 0) {
        file.close();
        return false;
      }
    }
  }

  file.close();
  if ((crc ^ 0xFFFFFFFFUL) != expectedCrc) {
    return false;
  }
  *snapshot = candidate;
  return true;
}

bool writePairingsSnapshot(const char* filename, uint32_t generation) {
  if (InternalFS.exists(filename)) {
    InternalFS.remove(filename);
  }

  File file(InternalFS);
  if (!file.open(filename, FILE_O_WRITE)) {
    return false;
  }

  uint8_t header[PAIRINGS_FILE_HEADER_LEN] = {0};
  memcpy(header, PAIRINGS_FILE_MAGIC, sizeof(PAIRINGS_FILE_MAGIC));
  header[4] = PAIRINGS_FILE_VERSION;
  header[5] = pairedPublicKeyCount;
  encodeUnsigned32(generation, header + 8);
  uint16_t payloadLen = pairedPublicKeyCount * PAIRING_RECORD_LEN;
  header[12] = (uint8_t) payloadLen;
  header[13] = (uint8_t)(payloadLen >> 8);
  uint32_t crc = pairingsCrc32Update(0xFFFFFFFFUL, header, 16);
  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    uint8_t counterBytes[8] = {0};
    encodeUnsigned64(pairedCounters[index], counterBytes);
    crc = pairingsCrc32Update(crc, pairedPublicKeys[index], P256_PUBLIC_KEY_LEN);
    crc = pairingsCrc32Update(crc, counterBytes, sizeof(counterBytes));
    crc = pairingsCrc32Update(crc, (uint8_t*) pairedDeviceNames[index], PAIRED_DEVICE_NAME_STORAGE_LEN);
  }
  encodeUnsigned32(crc ^ 0xFFFFFFFFUL, header + 16);
  if (file.write(header, sizeof(header)) != sizeof(header)) {
    file.close();
    return false;
  }
  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    uint8_t counterBytes[8] = {0};
    encodeUnsigned64(pairedCounters[index], counterBytes);
    if (file.write(pairedPublicKeys[index], P256_PUBLIC_KEY_LEN) != P256_PUBLIC_KEY_LEN
        || file.write(counterBytes, sizeof(counterBytes)) != sizeof(counterBytes)
        || file.write((uint8_t*) pairedDeviceNames[index], PAIRED_DEVICE_NAME_STORAGE_LEN) != PAIRED_DEVICE_NAME_STORAGE_LEN) {
      file.close();
      return false;
    }
  }
  file.close();
  return true;
}

void applyPairingsSnapshot(const PairingsSnapshot& snapshot) {
  pairedPublicKeyCount = snapshot.count;
  pairingsGeneration = snapshot.generation;
  memcpy(pairedPublicKeys, snapshot.keys, sizeof(pairedPublicKeys));
  memcpy(pairedCounters, snapshot.counters, sizeof(pairedCounters));
  memcpy(pairedDeviceNames, snapshot.names, sizeof(pairedDeviceNames));
}

bool savePairings() {
  if (!ensureInternalFS()) {
    return false;
  }

  uint32_t nextGeneration = pairingsGeneration + 1;
  if (nextGeneration == 0) {
    nextGeneration = 1;
  }
  const char* target = activePairingsSlot == 'A' ? PAIRINGS_SLOT_B_FILENAME : PAIRINGS_SLOT_A_FILENAME;
  char targetSlot = activePairingsSlot == 'A' ? 'B' : 'A';

  if (!writePairingsSnapshot(PAIRINGS_TEMP_FILENAME, nextGeneration)) {
    InternalFS.remove(PAIRINGS_TEMP_FILENAME);
    return false;
  }
  PairingsSnapshot verified = {};
  if (!readPairingsSnapshot(PAIRINGS_TEMP_FILENAME, &verified)
      || verified.generation != nextGeneration
      || verified.count != pairedPublicKeyCount) {
    InternalFS.remove(PAIRINGS_TEMP_FILENAME);
    return false;
  }

  if (InternalFS.exists(target)) {
    InternalFS.remove(target);
  }
  if (!InternalFS.rename(PAIRINGS_TEMP_FILENAME, target)) {
    InternalFS.remove(PAIRINGS_TEMP_FILENAME);
    return false;
  }

  pairingsGeneration = nextGeneration;
  activePairingsSlot = targetSlot;
  return true;
}

bool loadLegacyPairings() {
  File file(InternalFS);
  if (!file.open(PAIRINGS_FILENAME, FILE_O_READ)) {
    return false;
  }
  uint32_t fileSize = file.size();
  if (fileSize == 0 || fileSize % PAIRING_RECORD_LEN != 0
      || fileSize / PAIRING_RECORD_LEN > MAX_PAIRED_PHONES) {
    file.close();
    return false;
  }

  while (pairedPublicKeyCount < fileSize / PAIRING_RECORD_LEN) {
    uint8_t counterBytes[8] = {0};
    uint8_t index = pairedPublicKeyCount;
    if (file.read(pairedPublicKeys[index], P256_PUBLIC_KEY_LEN) != P256_PUBLIC_KEY_LEN
        || file.read(counterBytes, sizeof(counterBytes)) != sizeof(counterBytes)
        || file.read((uint8_t*) pairedDeviceNames[index], PAIRED_DEVICE_NAME_STORAGE_LEN) != PAIRED_DEVICE_NAME_STORAGE_LEN
        || !isValidPublicKey(pairedPublicKeys[index])) {
      file.close();
      return false;
    }
    pairedDeviceNames[index][PAIRED_DEVICE_NAME_LEN] = 0;
    pairedCounters[index] = decodeUnsigned64(counterBytes);
    pairedPublicKeyCount++;
  }
  file.close();
  return pairedPublicKeyCount > 0;
}

void loadPairings() {
  if (!ensureInternalFS()) {
    return;
  }

  pairedPublicKeyCount = 0;
  pairingsGeneration = 0;
  activePairingsSlot = 0;
  memset(pairedPublicKeys, 0, sizeof(pairedPublicKeys));
  memset(pairedCounters, 0, sizeof(pairedCounters));
  memset(pairedDeviceNames, 0, sizeof(pairedDeviceNames));

  PairingsSnapshot slotA = {};
  PairingsSnapshot slotB = {};
  bool validA = readPairingsSnapshot(PAIRINGS_SLOT_A_FILENAME, &slotA);
  bool validB = readPairingsSnapshot(PAIRINGS_SLOT_B_FILENAME, &slotB);
  if (validA || validB) {
    bool useA = validA && (!validB || (int32_t)(slotA.generation - slotB.generation) > 0);
    applyPairingsSnapshot(useA ? slotA : slotB);
    activePairingsSlot = useA ? 'A' : 'B';
    Serial.print("Loaded protected paired devices from slot ");
    Serial.println(activePairingsSlot);
  } else if (loadLegacyPairings()) {
    Serial.println("Migrating legacy paired device table to protected storage");
    if (savePairings()) {
      InternalFS.remove(PAIRINGS_FILENAME);
    }
  } else {
    Serial.println("No valid paired device keys yet");
  }

  InternalFS.remove(PAIRINGS_TEMP_FILENAME);
  Serial.print("Loaded paired devices: ");
  Serial.print(pairedPublicKeyCount);
  Serial.print("/");
  Serial.println(MAX_PAIRED_PHONES);
}

bool appendPairedPublicKey(const uint8_t* rawKey, const char* deviceName) {
  if (!ensureInternalFS() || !isValidPublicKey(rawKey)) {
    return false;
  }

  int8_t existingIndex = pairedPublicKeyIndex(rawKey);
  if (existingIndex >= 0) {
    if (deviceName != nullptr && deviceName[0] != 0) {
      char previousName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
      copyDeviceName(pairedDeviceNames[existingIndex], previousName, sizeof(previousName));
      copyDeviceName(deviceName, pairedDeviceNames[existingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
      if (!savePairings()) {
        copyDeviceName(previousName, pairedDeviceNames[existingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
        return false;
      }
    }
    return true;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    return false;
  }

  uint8_t addedIndex = pairedPublicKeyCount;
  memcpy(pairedPublicKeys[addedIndex], rawKey, P256_PUBLIC_KEY_LEN);
  copyDeviceName(deviceName, pairedDeviceNames[addedIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
  pairedCounters[addedIndex] = 0;
  pairedPublicKeyCount++;
  if (!savePairings()) {
    pairedPublicKeyCount--;
    memset(pairedPublicKeys[addedIndex], 0, P256_PUBLIC_KEY_LEN);
    pairedCounters[addedIndex] = 0;
    memset(pairedDeviceNames[addedIndex], 0, PAIRED_DEVICE_NAME_STORAGE_LEN);
    return false;
  }
  return true;
}

bool removePairedPublicKeyAt(uint8_t removeIndex) {
  if (removeIndex >= pairedPublicKeyCount) {
    return false;
  }

  uint8_t originalCount = pairedPublicKeyCount;
  uint8_t originalKeys[MAX_PAIRED_PHONES][P256_PUBLIC_KEY_LEN] = {{0}};
  uint64_t originalCounters[MAX_PAIRED_PHONES] = {0};
  char originalNames[MAX_PAIRED_PHONES][PAIRED_DEVICE_NAME_STORAGE_LEN] = {{0}};
  memcpy(originalKeys, pairedPublicKeys, sizeof(pairedPublicKeys));
  memcpy(originalCounters, pairedCounters, sizeof(pairedCounters));
  memcpy(originalNames, pairedDeviceNames, sizeof(pairedDeviceNames));

  for (uint8_t index = removeIndex; index + 1 < pairedPublicKeyCount; index++) {
    memcpy(pairedPublicKeys[index], pairedPublicKeys[index + 1], P256_PUBLIC_KEY_LEN);
    pairedCounters[index] = pairedCounters[index + 1];
    memcpy(pairedDeviceNames[index], pairedDeviceNames[index + 1], PAIRED_DEVICE_NAME_STORAGE_LEN);
  }

  pairedPublicKeyCount--;
  memset(pairedPublicKeys[pairedPublicKeyCount], 0, P256_PUBLIC_KEY_LEN);
  pairedCounters[pairedPublicKeyCount] = 0;
  memset(pairedDeviceNames[pairedPublicKeyCount], 0, PAIRED_DEVICE_NAME_STORAGE_LEN);

  if (!savePairings()) {
    pairedPublicKeyCount = originalCount;
    memcpy(pairedPublicKeys, originalKeys, sizeof(pairedPublicKeys));
    memcpy(pairedCounters, originalCounters, sizeof(pairedCounters));
    memcpy(pairedDeviceNames, originalNames, sizeof(pairedDeviceNames));
    return false;
  }

  if (pairedPublicKeyCount == 0) {
    pairingModeEnabled = false;
    clearPendingPairing();
  }

  return true;
}

bool clearPairings() {
  uint8_t originalCount = pairedPublicKeyCount;
  uint32_t originalGeneration = pairingsGeneration;
  char originalActiveSlot = activePairingsSlot;
  uint8_t originalKeys[MAX_PAIRED_PHONES][P256_PUBLIC_KEY_LEN] = {{0}};
  uint64_t originalCounters[MAX_PAIRED_PHONES] = {0};
  char originalNames[MAX_PAIRED_PHONES][PAIRED_DEVICE_NAME_STORAGE_LEN] = {{0}};
  memcpy(originalKeys, pairedPublicKeys, sizeof(pairedPublicKeys));
  memcpy(originalCounters, pairedCounters, sizeof(pairedCounters));
  memcpy(originalNames, pairedDeviceNames, sizeof(pairedDeviceNames));

  pairingModeEnabled = false;
  clearPendingPairing();
  pairedPublicKeyCount = 0;
  memset(pairedPublicKeys, 0, sizeof(pairedPublicKeys));
  memset(pairedCounters, 0, sizeof(pairedCounters));
  memset(pairedDeviceNames, 0, sizeof(pairedDeviceNames));

  // Commit an empty snapshot at a newer generation. If power fails before the
  // atomic rename, the old trust table remains valid; after it, the empty table
  // wins over every older slot and revoked keys cannot be resurrected.
  if (!savePairings()) {
    pairedPublicKeyCount = originalCount;
    pairingsGeneration = originalGeneration;
    activePairingsSlot = originalActiveSlot;
    memcpy(pairedPublicKeys, originalKeys, sizeof(pairedPublicKeys));
    memcpy(pairedCounters, originalCounters, sizeof(pairedCounters));
    memcpy(pairedDeviceNames, originalNames, sizeof(pairedDeviceNames));
    return false;
  }

  InternalFS.remove(PAIRINGS_FILENAME);
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    connectedDeviceTrusted[index] = false;
    connectedDeviceRejected[index] = false;
  }
  return true;
}

bool repairInternalStorage() {
  clearPendingPairing();
  pairingModeEnabled = false;
  pairedPublicKeyCount = 0;
  memset(pairedPublicKeys, 0, sizeof(pairedPublicKeys));
  memset(pairedCounters, 0, sizeof(pairedCounters));
  memset(pairedDeviceNames, 0, sizeof(pairedDeviceNames));
  pairingsGeneration = 0;
  activePairingsSlot = 0;

  if (!ensureInternalFS() || !InternalFS.format()) {
    internalFsReady = false;
    return false;
  }
  internalFsReady = true;

  bool restored = saveLockName()
    && saveServoAngles()
    && saveUnlockHoldTimeout()
    && savePairings();
  if (restored && lastUnlockEpochSeconds > 0) {
    restored = saveLastUnlockRecord();
  }
  return restored;
}

int8_t hexNibble(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

char hexDigit(uint8_t value) {
  value &= 0x0f;
  return value < 10 ? (char) ('0' + value) : (char) ('a' + value - 10);
}

bool bytesToHex(const uint8_t* bytes, size_t byteLen, char* output, size_t outputLen) {
  if (bytes == nullptr || output == nullptr || outputLen < (byteLen * 2) + 1) {
    return false;
  }

  for (size_t index = 0; index < byteLen; index++) {
    output[index * 2] = hexDigit(bytes[index] >> 4);
    output[index * 2 + 1] = hexDigit(bytes[index]);
  }
  output[byteLen * 2] = 0;
  return true;
}

bool hexToBytes(const char* hex, uint8_t* bytes, size_t byteLen) {
  if (strlen(hex) != byteLen * 2) {
    return false;
  }

  for (size_t index = 0; index < byteLen; index++) {
    int8_t high = hexNibble(hex[index * 2]);
    int8_t low = hexNibble(hex[index * 2 + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    bytes[index] = (high << 4) | low;
  }

  return true;
}

int8_t pairedPublicKeyIndexForFingerprintBytes(const uint8_t* fingerprint) {
  if (fingerprint == nullptr) {
    return -1;
  }

  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    uint8_t pairedFingerprint[V3_KEY_FINGERPRINT_LEN] = {0};
    if (keyFingerprintBytes(pairedPublicKeys[index], pairedFingerprint, sizeof(pairedFingerprint))
        && memcmp(pairedFingerprint, fingerprint, V3_KEY_FINGERPRINT_LEN) == 0) {
      return index;
    }
  }

  return -1;
}

bool verifySignatureForPairedDevice(uint8_t pairingIndex, const uint8_t* message, size_t messageLen, const uint8_t* signature) {
  if (pairingIndex >= pairedPublicKeyCount || message == nullptr || messageLen == 0 || signature == nullptr) {
    return false;
  }

  CRYS_ECPKI_UserPublKey_t publicKey;
  memset(&publicKey, 0, sizeof(publicKey));
  if (!buildPublicKeyFromRaw(pairedPublicKeys[pairingIndex], &publicKey)) {
    return false;
  }

  static CRYS_ECDSA_VerifyUserContext_t verifyContext;
  memset(&verifyContext, 0, sizeof(verifyContext));

  uint32_t err = CRYS_ECDSA_Verify(
    &verifyContext,
    &publicKey,
    CRYS_ECPKI_HASH_SHA256_mode,
    (uint8_t*) signature,
    P256_SIGNATURE_LEN,
    (uint8_t*) message,
    messageLen
  );

  return err == CRYS_OK;
}

bool buildV3CommandSignatureMessage(const uint8_t* packet, uint16_t packetLen, uint8_t* output, size_t outputLen, size_t* messageLen) {
  if (packet == nullptr || output == nullptr || messageLen == nullptr) {
    return false;
  }

  if (packetLen < V3_COMMAND_MIN_PACKET_LEN || packet[0] != V3_COMMAND_VERSION) {
    return false;
  }

  uint8_t payloadLen = packet[V3_COMMAND_HEADER_LEN - 1];
  if (payloadLen > V3_COMMAND_MAX_PAYLOAD_LEN) {
    return false;
  }

  const size_t unsignedLen = V3_COMMAND_HEADER_LEN + payloadLen;
  if (packetLen != unsignedLen + P256_SIGNATURE_LEN) {
    return false;
  }

  const size_t domainLen = strlen(V3_COMMAND_SIGNATURE_DOMAIN);
  const size_t requiredLen = domainLen + unsignedLen;
  if (outputLen < requiredLen) {
    return false;
  }

  memcpy(output, V3_COMMAND_SIGNATURE_DOMAIN, domainLen);
  memcpy(output + domainLen, packet, unsignedLen);
  *messageLen = requiredLen;
  return true;
}

bool setUnlockHoldTimeoutSeconds(uint16_t seconds) {
  if (!isValidUnlockHoldTimeout(seconds)) {
    return false;
  }

  uint16_t previousSeconds = unlockHoldTimeoutSeconds;
  unlockHoldTimeoutSeconds = seconds;
  if (!saveUnlockHoldTimeout()) {
    unlockHoldTimeoutSeconds = previousSeconds;
    return false;
  }

  if (unlocked) {
    unlockAutoLockStartedMs = millis();
    unlockAutoLockActive = true;
  }

  Serial.print("Auto-lock timeout set to ");
  Serial.print(unlockHoldTimeoutSeconds);
  Serial.println(" seconds.");
  return true;
}

const char* currentStateText() {
  if (pendingPairingExists) {
    return "pairing_pending";
  }

  if (pairingModeEnabled) {
    return "pairing_enabled";
  }

  if (pairedPublicKeyCount == 0) {
    return "pairing_locked";
  }

  return unlocked ? "unlocked" : "locked";
}

void setRgbLed(bool red, bool green, bool blue) {
  // XIAO nRF52840 RGB channels are active-low: LOW is on, HIGH is off.
  digitalWrite(LED_RED, red ? LOW : HIGH);
  digitalWrite(LED_GREEN, green ? LOW : HIGH);
  digitalWrite(LED_BLUE, blue ? LOW : HIGH);
}

void updateStatusLed() {
  if (servoMoving) {
    setRgbLed(true, true, false);   // Yellow while the servo is moving.
  } else if (pendingPairingExists) {
    setRgbLed(false, true, true);    // Cyan means a device is waiting for USB approval.
  } else if (pairingModeEnabled) {
    setRgbLed(true, false, true);   // Purple means USB-enabled pairing mode.
  } else if (pairedPublicKeyCount == 0) {
    setRgbLed(true, false, false);  // Red means no device can command it yet.
  } else if (unlocked) {
    setRgbLed(false, true, false);  // Green means unlocked.
  } else {
    setRgbLed(false, false, true);  // Blue means locked.
  }
}

void setupStatusLed() {
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  updateStatusLed();
}

int8_t connectedDeviceSlotForHandle(uint16_t connHandle) {
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (connectedDeviceSlotsUsed[index] && connectedDeviceHandles[index] == connHandle) {
      return index;
    }
  }
  return -1;
}

int8_t firstAvailableConnectedDeviceSlot() {
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (!connectedDeviceSlotsUsed[index]) {
      return index;
    }
  }
  return -1;
}

void sanitizeConnectionPayloadName(const char* name, char* output, size_t outputLen) {
  if (output == nullptr || outputLen == 0) {
    return;
  }

  memset(output, 0, outputLen);
  if (name == nullptr) {
    return;
  }

  size_t writeIndex = 0;
  bool previousWasSpace = false;
  for (size_t readIndex = 0; name[readIndex] != 0 && writeIndex < outputLen - 1; readIndex++) {
    char value = name[readIndex];
    if (value == ':' || value == '|' || value == ',') {
      value = ' ';
    }
    appendSanitizedDeviceNameChar(value, output, outputLen, writeIndex, previousWasSpace);
  }

  while (writeIndex > 0 && output[writeIndex - 1] == ' ') {
    output[--writeIndex] = 0;
  }
}

bool setConnectedDeviceName(uint16_t connHandle, const char* name, bool trustedName) {
  if (connHandle == BLE_CONN_HANDLE_INVALID || name == nullptr || name[0] == 0) {
    return false;
  }

  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    slot = firstAvailableConnectedDeviceSlot();
  }
  if (slot < 0) {
    return false;
  }

  if (connectedDeviceSlotsUsed[slot] && connectedDeviceTrusted[slot] && !trustedName) {
    return false;
  }

  bool didChange = !connectedDeviceSlotsUsed[slot]
    || connectedDeviceTrusted[slot] != trustedName
    || connectedDeviceHandles[slot] != connHandle
    || strcmp(connectedDeviceNames[slot], name) != 0;

  connectedDeviceSlotsUsed[slot] = true;
  connectedDeviceTrusted[slot] = trustedName;
  connectedDeviceHandles[slot] = connHandle;
  if (connectedDeviceFirstSeenMs[slot] == 0) {
    connectedDeviceFirstSeenMs[slot] = millis();
  }
  if (trustedName) {
    connectedDeviceRejected[slot] = false;
  }
  copyDeviceName(name, connectedDeviceNames[slot], sizeof(connectedDeviceNames[slot]));
  return didChange;
}

void trackConnectedDevice(uint16_t connHandle, const char* centralName) {
  if (connHandle == BLE_CONN_HANDLE_INVALID) {
    return;
  }

  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    slot = firstAvailableConnectedDeviceSlot();
  }
  if (slot < 0) {
    return;
  }

  connectedDeviceSlotsUsed[slot] = true;
  connectedDeviceTrusted[slot] = false;
  connectedDeviceHandles[slot] = connHandle;
  connectedDeviceFirstSeenMs[slot] = millis();
  connectedDeviceRejected[slot] = false;
  copyDeviceName(centralName, connectedDeviceNames[slot], sizeof(connectedDeviceNames[slot]));
}

void markConnectedDeviceUntrusted(uint16_t connHandle, bool rejected = false) {
  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    return;
  }

  connectedDeviceTrusted[slot] = false;
  if (rejected) {
    connectedDeviceRejected[slot] = true;
  }
}

void clearConnectedDeviceSlot(uint8_t slot) {
  if (slot >= MAX_BLE_CONNECTIONS) {
    return;
  }

  connectedDeviceSlotsUsed[slot] = false;
  connectedDeviceTrusted[slot] = false;
  connectedDeviceHandles[slot] = BLE_CONN_HANDLE_INVALID;
  memset(connectedDeviceNames[slot], 0, sizeof(connectedDeviceNames[slot]));
  connectedDeviceNonceValid[slot] = false;
  memset(connectedDeviceNonces[slot], 0, sizeof(connectedDeviceNonces[slot]));
  connectedDeviceFirstSeenMs[slot] = 0;
  connectedDeviceRejected[slot] = false;
  stateStartupSnapshotPending[slot] = false;
  stateStartupSnapshotDelivered[slot] = false;
  stateStartupSnapshotDueMs[slot] = 0;
  stateStartupSnapshotGenerations[slot] = 0;
  taskENTER_CRITICAL();
  stateNotificationQueueHeads[slot] = 0;
  stateNotificationQueueTails[slot] = 0;
  stateNotificationQueueCounts[slot] = 0;
  stateNotificationSending[slot] = false;
  stateNotificationQueueOverflowed[slot] = false;
  stateNotificationQueueGenerations[slot]++;
  memset(stateNotificationQueues[slot], 0, sizeof(stateNotificationQueues[slot]));
  taskEXIT_CRITICAL();
}

void resetStateNotificationSubscription(uint8_t slot) {
  if (slot >= MAX_BLE_CONNECTIONS) {
    return;
  }

  stateStartupSnapshotPending[slot] = false;
  stateStartupSnapshotDelivered[slot] = false;
  stateStartupSnapshotDueMs[slot] = 0;
  stateStartupSnapshotGenerations[slot] = 0;
  taskENTER_CRITICAL();
  stateNotificationQueueHeads[slot] = 0;
  stateNotificationQueueTails[slot] = 0;
  stateNotificationQueueCounts[slot] = 0;
  stateNotificationSending[slot] = false;
  stateNotificationQueueOverflowed[slot] = false;
  stateNotificationQueueGenerations[slot]++;
  memset(stateNotificationQueues[slot], 0, sizeof(stateNotificationQueues[slot]));
  taskEXIT_CRITICAL();
}

void initializeConnectedDeviceSlots() {
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    clearConnectedDeviceSlot(index);
  }
}

void clearConnectedDevice(uint16_t connHandle) {
  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    return;
  }

  clearConnectedDeviceSlot((uint8_t) slot);
}

uint8_t disconnectUntrustedLockedConnections(bool force = false) {
  if (!force && (pairingModeEnabled || pendingPairingExists)) {
    return 0;
  }

  uint32_t now = millis();
  if (!force && (uint32_t)(now - lastUntrustedCleanupMs) < UNTRUSTED_CLEANUP_INTERVAL_MS) {
    return 0;
  }
  lastUntrustedCleanupMs = now;

  uint8_t disconnectedCount = 0;
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (!connectedDeviceSlotsUsed[index] || connectedDeviceTrusted[index]) {
      continue;
    }

    uint16_t connHandle = connectedDeviceHandles[index];
    if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
      clearConnectedDeviceSlot(index);
      continue;
    }

    uint32_t connectedForMs = connectedDeviceFirstSeenMs[index] == 0 ? 0 : (uint32_t)(now - connectedDeviceFirstSeenMs[index]);
    bool shouldDisconnect = connectedDeviceRejected[index] && connectedForMs >= UNTRUSTED_REJECT_DISCONNECT_DELAY_MS;
    shouldDisconnect = shouldDisconnect || force || connectedForMs >= UNTRUSTED_IDLE_DISCONNECT_MS;
    if (!shouldDisconnect) {
      continue;
    }

    Serial.print("Disconnecting untrusted BLE device: ");
    Serial.println(connectedDeviceNames[index][0] == 0 ? "central" : connectedDeviceNames[index]);
    if (Bluefruit.disconnect(connHandle)) {
      disconnectedCount++;
    }
  }

  return disconnectedCount;
}

bool fillSecureRandomBytes(uint8_t* output, size_t outputLen) {
  if (output == nullptr || outputLen == 0) {
    return false;
  }

  size_t offset = 0;
  uint8_t attempts = 0;
  while (offset < outputLen && attempts < 100) {
    uint8_t chunkLen = (uint8_t) min<size_t>(outputLen - offset, 8);
    uint32_t err = sd_rand_application_vector_get(output + offset, chunkLen);
    if (err == NRF_SUCCESS) {
      offset += chunkLen;
      attempts = 0;
      continue;
    }

    attempts++;
    delay(1);
  }

  return offset == outputLen;
}

void initializeControllerBootSession() {
  uint8_t randomBytes[8] = {0};
  if (fillSecureRandomBytes(randomBytes, sizeof(randomBytes))
      && bytesToHex(randomBytes, sizeof(randomBytes), controllerBootSessionId, sizeof(controllerBootSessionId))) {
    return;
  }

  snprintf(
    controllerBootSessionId,
    sizeof(controllerBootSessionId),
    "%08lx%08lx",
    (unsigned long) NRF_FICR->DEVICEID[0],
    (unsigned long) micros()
  );
}

bool publishControlTo(uint16_t connHandle, const char* payload) {
  if (connHandle == BLE_CONN_HANDLE_INVALID || payload == nullptr || !Bluefruit.connected(connHandle)) {
    return false;
  }

  if (controlCharacteristic.notifyEnabled(connHandle)) {
    return controlCharacteristic.notify(connHandle, payload);
  } else if (controlCharacteristic.indicateEnabled(connHandle)) {
    return controlCharacteristic.indicate(connHandle, payload);
  }

  return false;
}

void publishControlRejectTo(uint16_t connHandle, const char* reason) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "reject:v3:%s", reason == nullptr ? "rejected" : reason);
  publishControlTo(connHandle, payload);
  Serial.print("Control: ");
  Serial.println(payload);
}

bool issueV3NonceTo(uint16_t connHandle) {
  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0 || !Bluefruit.connected(connHandle)) {
    return false;
  }

  if (!connectedDeviceNonceValid[slot]) {
    if (!fillSecureRandomBytes(connectedDeviceNonces[slot], V3_NONCE_LEN)) {
      connectedDeviceNonceValid[slot] = false;
      publishControlRejectTo(connHandle, "nonce_unavailable");
      return false;
    }
  }

  char nonceHex[V3_NONCE_LEN * 2 + 1] = {0};
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (!bytesToHex(connectedDeviceNonces[slot], V3_NONCE_LEN, nonceHex, sizeof(nonceHex))) {
    return false;
  }
  snprintf(payload, sizeof(payload), "nonce:v3:%s", nonceHex);
  bool pushedNonce = publishControlTo(connHandle, payload);
  if (!pushedNonce) {
    memset(connectedDeviceNonces[slot], 0, sizeof(connectedDeviceNonces[slot]));
    connectedDeviceNonceValid[slot] = false;
    return false;
  }

  connectedDeviceNonceValid[slot] = true;
  Serial.print("Control: ");
  Serial.println(payload);

  return true;
}

void rotateV3NonceFor(uint16_t connHandle) {
  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    return;
  }

  connectedDeviceNonceValid[slot] = false;
  memset(connectedDeviceNonces[slot], 0, sizeof(connectedDeviceNonces[slot]));
  issueV3NonceTo(connHandle);
}

void retryMissingV3Nonces() {
  uint32_t now = millis();
  if ((uint32_t)(now - lastNonceRetryMs) < V3_NONCE_RETRY_INTERVAL_MS) {
    return;
  }
  lastNonceRetryMs = now;

  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (!connectedDeviceSlotsUsed[index] || connectedDeviceNonceValid[index]) {
      continue;
    }

    uint16_t connHandle = connectedDeviceHandles[index];
    if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
      continue;
    }

    if (controlCharacteristic.notifyEnabled(connHandle) || controlCharacteristic.indicateEnabled(connHandle)) {
      issueV3NonceTo(connHandle);
      delay(2);
    }
  }
}

bool enqueueStateNotification(uint8_t slot, const char* payload) {
  if (slot >= MAX_BLE_CONNECTIONS || payload == nullptr || payload[0] == 0) {
    return false;
  }

  taskENTER_CRITICAL();
  if (stateNotificationQueueCounts[slot] >= STATE_NOTIFICATION_QUEUE_CAPACITY) {
    stateNotificationQueueOverflowed[slot] = true;
    taskEXIT_CRITICAL();
    return false;
  }

  uint8_t index = stateNotificationQueueHeads[slot];
  strncpy(stateNotificationQueues[slot][index], payload, STATE_PAYLOAD_MAX_LEN - 1);
  stateNotificationQueues[slot][index][STATE_PAYLOAD_MAX_LEN - 1] = 0;
  stateNotificationQueueHeads[slot] = (index + 1) % STATE_NOTIFICATION_QUEUE_CAPACITY;
  stateNotificationQueueCounts[slot]++;
  taskEXIT_CRITICAL();
  return true;
}

void processStateNotificationForSlot(uint8_t slot) {
  if (slot >= MAX_BLE_CONNECTIONS) {
    return;
  }

  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  uint16_t connHandle = BLE_CONN_HANDLE_INVALID;
  uint8_t queueIndex = 0;
  uint32_t generation = 0;

  taskENTER_CRITICAL();
  if (!connectedDeviceSlotsUsed[slot]
      || stateNotificationQueueCounts[slot] == 0
      || stateNotificationSending[slot]) {
    taskEXIT_CRITICAL();
    return;
  }
  connHandle = connectedDeviceHandles[slot];
  queueIndex = stateNotificationQueueTails[slot];
  generation = stateNotificationQueueGenerations[slot];
  strncpy(payload, stateNotificationQueues[slot][queueIndex], sizeof(payload) - 1);
  stateNotificationSending[slot] = true;
  taskEXIT_CRITICAL();

  bool sent = connHandle != BLE_CONN_HANDLE_INVALID
    && Bluefruit.connected(connHandle)
    && stateCharacteristic.notifyEnabled(connHandle)
    && stateCharacteristic.notify(connHandle, payload);

  taskENTER_CRITICAL();
  if (stateNotificationQueueGenerations[slot] == generation) {
    stateNotificationSending[slot] = false;
    if (sent
        && stateNotificationQueueCounts[slot] > 0
        && stateNotificationQueueTails[slot] == queueIndex) {
      memset(stateNotificationQueues[slot][queueIndex], 0, STATE_PAYLOAD_MAX_LEN);
      stateNotificationQueueTails[slot] = (queueIndex + 1) % STATE_NOTIFICATION_QUEUE_CAPACITY;
      stateNotificationQueueCounts[slot]--;
    }
  }
  taskEXIT_CRITICAL();
}

void queueStateNotificationForHandle(uint16_t connHandle, const char* payload) {
  if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
    return;
  }
  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0 || !stateCharacteristic.notifyEnabled(connHandle)) {
    return;
  }
  if (enqueueStateNotification((uint8_t) slot, payload)) {
    processStateNotificationForSlot((uint8_t) slot);
  }
}

void processPendingStateNotifications() {
  for (uint8_t slot = 0; slot < MAX_BLE_CONNECTIONS; slot++) {
    if (stateNotificationQueueOverflowed[slot]) {
      uint16_t connHandle = connectedDeviceHandles[slot];
      Serial.println("State notification queue overflow; reconnecting subscriber for a fresh snapshot");
      if (connHandle != BLE_CONN_HANDLE_INVALID && Bluefruit.connected(connHandle)) {
        Bluefruit.disconnect(connHandle);
      } else {
        clearConnectedDeviceSlot(slot);
      }
      continue;
    }
    processStateNotificationForSlot(slot);
  }
}

bool hasPendingStateNotifications() {
  for (uint8_t slot = 0; slot < MAX_BLE_CONNECTIONS; slot++) {
    if (stateNotificationQueueCounts[slot] > 0 || stateNotificationSending[slot]) {
      return true;
    }
  }
  return false;
}

void drainStateNotificationsBeforeRestart(uint32_t timeoutMs = 320) {
  uint32_t startedAt = millis();
  while (hasPendingStateNotifications()
         && (uint32_t)(millis() - startedAt) < timeoutMs) {
    processPendingStateNotifications();
    delay(2);
  }
}

void notifyStateSubscribers(const char* payload) {
  if (payload == nullptr || !Bluefruit.connected()) {
    return;
  }

  uint16_t handles[MAX_BLE_CONNECTIONS] = {0};
  uint8_t connectedCount = Bluefruit.getConnectedHandles(handles, MAX_BLE_CONNECTIONS);
  for (uint8_t index = 0; index < connectedCount; index++) {
    queueStateNotificationForHandle(handles[index], payload);
  }
}

void notifyAuthoritativeStateSubscribers(const char* payload) {
  for (uint8_t repeat = 0; repeat < AUTHORITATIVE_STATE_REPEAT_COUNT; repeat++) {
    notifyStateSubscribers(payload);
  }
}

void notifyStateSubscriber(uint16_t connHandle, const char* payload) {
  if (payload == nullptr || !Bluefruit.connected()) {
    return;
  }

  if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
    notifyStateSubscribers(payload);
    return;
  }

  queueStateNotificationForHandle(connHandle, payload);
}

void writeAndNotifyStatePayload(const char* payload) {
  stateCharacteristic.write(payload);
  notifyStateSubscribers(payload);
}

void writeAndNotifyAuthoritativeStatePayload(const char* payload) {
  stateCharacteristic.write(payload);
  notifyAuthoritativeStateSubscribers(payload);
}

bool isTrackedConnectionSlotActive(uint8_t slot) {
  if (slot >= MAX_BLE_CONNECTIONS || !connectedDeviceSlotsUsed[slot]) {
    return false;
  }

  uint16_t connHandle = connectedDeviceHandles[slot];
  return connHandle != BLE_CONN_HANDLE_INVALID && Bluefruit.connected(connHandle);
}

bool pruneDisconnectedTrackedConnections() {
  bool didPrune = false;
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (!connectedDeviceSlotsUsed[index]) {
      continue;
    }

    uint16_t connHandle = connectedDeviceHandles[index];
    if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
      clearConnectedDeviceSlot(index);
      didPrune = true;
    }
  }
  return didPrune;
}

uint8_t trackedConnectionCount() {
  uint8_t count = 0;
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (isTrackedConnectionSlotActive(index)) {
      count++;
    }
  }
  return count;
}

bool buildConnectionsStatePayload(char* payload, size_t payloadLen) {
  if (payload == nullptr || payloadLen == 0) {
    return false;
  }

  pruneDisconnectedTrackedConnections();
  uint8_t connectedCount = trackedConnectionCount();
  int written = snprintf(payload, payloadLen, "connections:%u/%u:", connectedCount, MAX_BLE_CONNECTIONS);
  if (written < 0) {
    return false;
  }

  size_t offset = min<size_t>((size_t) written, payloadLen - 1);
  bool hasName = false;
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS && offset < payloadLen - 1; index++) {
    if (!isTrackedConnectionSlotActive(index)) {
      continue;
    }

    char name[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
    sanitizeConnectionPayloadName(connectedDeviceNames[index], name, sizeof(name));
    if (name[0] == 0) {
      snprintf(name, sizeof(name), "Device %u", index + 1);
    }

    int nextWritten = snprintf(
      payload + offset,
      payloadLen - offset,
      "%s%s",
      hasName ? "|" : "",
      name
    );
    if (nextWritten < 0) {
      break;
    }
    offset += min<size_t>((size_t) nextWritten, payloadLen - 1 - offset);
    hasName = true;
  }

  return true;
}

void publishConnectionsStateTo(uint16_t connHandle) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (!buildConnectionsStatePayload(payload, sizeof(payload))) {
    return;
  }

  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishConnectionsState() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (!buildConnectionsStatePayload(payload, sizeof(payload))) {
    return;
  }

  notifyAuthoritativeStateSubscribers(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishState(const char* state) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (strcmp(state, "unlocked") == 0) {
    uint16_t remainingSeconds = unlockHoldRemainingSeconds();
    snprintf(payload, sizeof(payload), "unlocked:%u", remainingSeconds);
    lastPublishedUnlockRemainingSeconds = remainingSeconds;
  } else {
    snprintf(payload, sizeof(payload), "%s", state);
    lastPublishedUnlockRemainingSeconds = 0xFFFF;
  }

  writeAndNotifyStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishStateTo(uint16_t connHandle, const char* state) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (strcmp(state, "unlocked") == 0) {
    uint16_t remainingSeconds = unlockHoldRemainingSeconds();
    snprintf(payload, sizeof(payload), "unlocked:%u", remainingSeconds);
  } else {
    snprintf(payload, sizeof(payload), "%s", state);
  }

  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishStartupSnapshotTo(uint16_t connHandle) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "session:%s", controllerBootSessionId);
  notifyStateSubscriber(connHandle, payload);
  snprintf(payload, sizeof(payload), "health:%s", internalFsReady ? "ok" : "storage_fault");
  notifyStateSubscriber(connHandle, payload);
  publishConnectionsStateTo(connHandle);
  publishStateTo(connHandle, currentStateText());

  snprintf(payload, sizeof(payload), "firmware_version:%s", CONTROLLER_FIRMWARE_VERSION);
  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);

  snprintf(payload, sizeof(payload), "lock_name:%s", controllerLockName);
  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);

  snprintf(payload, sizeof(payload), "servo_angles:%u,%u", lockAngle, unlockAngle);
  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);

  snprintf(payload, sizeof(payload), "timeout_set:%u", unlockHoldTimeoutSeconds);
  notifyStateSubscriber(connHandle, payload);
}

void publishCriticalStartupSnapshotTo(uint16_t connHandle) {
  char statePayload[24] = {0};
  if (strcmp(currentStateText(), "unlocked") == 0) {
    snprintf(statePayload, sizeof(statePayload), "unlocked:%u", unlockHoldRemainingSeconds());
  } else {
    snprintf(statePayload, sizeof(statePayload), "%s", currentStateText());
  }

  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(
    payload,
    sizeof(payload),
    "critical:%s|%s|%s",
    controllerBootSessionId,
    internalFsReady ? "ok" : "storage_fault",
    statePayload
  );
  notifyStateSubscriber(connHandle, payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void processPendingStateStartupSnapshots() {
  uint32_t now = millis();
  for (uint8_t slot = 0; slot < MAX_BLE_CONNECTIONS; slot++) {
    if (!stateStartupSnapshotPending[slot]
        || (int32_t)(now - stateStartupSnapshotDueMs[slot]) < 0) {
      continue;
    }

    uint16_t connHandle = connectedDeviceHandles[slot];
    uint32_t generation = stateStartupSnapshotGenerations[slot];
    stateStartupSnapshotPending[slot] = false;
    if (!connectedDeviceSlotsUsed[slot]
        || stateNotificationQueueGenerations[slot] != generation
        || connHandle == BLE_CONN_HANDLE_INVALID
        || !Bluefruit.connected(connHandle)
        || !stateCharacteristic.notifyEnabled(connHandle)) {
      continue;
    }

    stateStartupSnapshotDelivered[slot] = true;
    char payload[STATE_PAYLOAD_MAX_LEN] = {0};
    snprintf(payload, sizeof(payload), "session:%s", controllerBootSessionId);
    notifyStateSubscriber(connHandle, payload);
    // The first notification after CCCD enable can be accepted by the stack
    // before CoreBluetooth has completed local subscription setup. Repeat the
    // small boot-session payload so freshness never depends on that boundary.
    notifyStateSubscriber(connHandle, payload);
    snprintf(payload, sizeof(payload), "health:%s", internalFsReady ? "ok" : "storage_fault");
    notifyStateSubscriber(connHandle, payload);
    publishStateTo(connHandle, currentStateText());
    if (stagingBankMaintenanceComplete()) {
      notifyStateSubscriber(connHandle, "ota_staging_ready");
    }
  }
}

void publishFirmwareUpdateState(const char* state, const char* updaterName = nullptr) {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (updaterName != nullptr && updaterName[0] != 0) {
    snprintf(payload, sizeof(payload), "firmware_update:%s:%s", state, updaterName);
  } else {
    snprintf(payload, sizeof(payload), "firmware_update:%s", state);
  }
  writeAndNotifyAuthoritativeStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishTimeoutSetState() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "timeout_set:%u", unlockHoldTimeoutSeconds);
  writeAndNotifyAuthoritativeStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

bool currentSettingApplyingPayload(char* output, size_t outputLen) {
  if (output == nullptr || outputLen == 0 || !settingApplyStatusActive) {
    return false;
  }

  uint32_t elapsedMs = millis() - settingApplyStatusStartedMs;
  if (elapsedMs > SETTING_APPLY_STATUS_MS) {
    settingApplyStatusActive = false;
    activeSettingApplyKind[0] = 0;
    activeSettingApplyValue[0] = 0;
    return false;
  }

  if (activeSettingApplyValue[0] != 0) {
    snprintf(output, outputLen, "%s:%s", activeSettingApplyKind, activeSettingApplyValue);
  } else {
    strncpy(output, activeSettingApplyKind, outputLen - 1);
  }
  output[outputLen - 1] = 0;
  return output[0] != 0;
}

void publishSettingApplyingState(const char* kind, const char* value) {
  strncpy(activeSettingApplyKind, kind, sizeof(activeSettingApplyKind) - 1);
  activeSettingApplyKind[sizeof(activeSettingApplyKind) - 1] = 0;
  if (value == nullptr) {
    activeSettingApplyValue[0] = 0;
  } else {
    strncpy(activeSettingApplyValue, value, sizeof(activeSettingApplyValue) - 1);
    activeSettingApplyValue[sizeof(activeSettingApplyValue) - 1] = 0;
  }
  settingApplyStatusStartedMs = millis();
  settingApplyStatusActive = activeSettingApplyKind[0] != 0;

  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (activeSettingApplyValue[0] != 0) {
    snprintf(payload, sizeof(payload), "setting_applying:%s:%s", activeSettingApplyKind, activeSettingApplyValue);
  } else {
    snprintf(payload, sizeof(payload), "setting_applying:%s", activeSettingApplyKind);
  }
  writeAndNotifyStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishSettingApplyingState(const char* kind) {
  publishSettingApplyingState(kind, nullptr);
}

void publishLockNameState() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "lock_name:%s", controllerLockName);
  writeAndNotifyAuthoritativeStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishServoAnglesState() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "servo_angles:%u,%u", lockAngle, unlockAngle);
  writeAndNotifyAuthoritativeStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void publishLastUnlockState() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  char resolvedDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  copyResolvedLastUnlockDeviceName(resolvedDeviceName, sizeof(resolvedDeviceName));

  if (lastUnlockDeviceFingerprint[0] != 0 && resolvedDeviceName[0] != 0) {
    snprintf(
      payload,
      sizeof(payload),
      "last_unlock:%llu:%s:%s",
      (unsigned long long) lastUnlockEpochSeconds,
      lastUnlockDeviceFingerprint,
      resolvedDeviceName
    );
  } else if (lastUnlockDeviceFingerprint[0] != 0) {
    snprintf(
      payload,
      sizeof(payload),
      "last_unlock:%llu:%s",
      (unsigned long long) lastUnlockEpochSeconds,
      lastUnlockDeviceFingerprint
    );
  } else if (resolvedDeviceName[0] != 0) {
    snprintf(
      payload,
      sizeof(payload),
      "last_unlock:%llu:%s",
      (unsigned long long) lastUnlockEpochSeconds,
      resolvedDeviceName
    );
  } else {
    snprintf(payload, sizeof(payload), "last_unlock:%llu", (unsigned long long) lastUnlockEpochSeconds);
  }
  writeAndNotifyStatePayload(payload);
  Serial.print("State: ");
  Serial.println(payload);
}

void writeCurrentStateCharacteristic() {
  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  const char* state = currentStateText();
  if (strcmp(state, "unlocked") == 0) {
    uint16_t remainingSeconds = unlockHoldRemainingSeconds();
    snprintf(payload, sizeof(payload), "unlocked:%u", remainingSeconds);
    lastPublishedUnlockRemainingSeconds = remainingSeconds;
  } else {
    snprintf(payload, sizeof(payload), "%s", state);
    lastPublishedUnlockRemainingSeconds = 0xFFFF;
  }

  stateCharacteristic.write(payload);
}

void refreshUnlockCountdownValueIfChanged() {
  if (!unlocked || !unlockAutoLockActive) {
    lastPublishedUnlockRemainingSeconds = 0xFFFF;
    return;
  }

  uint16_t remainingSeconds = unlockHoldRemainingSeconds();
  if (remainingSeconds == lastPublishedUnlockRemainingSeconds) {
    return;
  }

  char payload[STATE_PAYLOAD_MAX_LEN] = {0};
  snprintf(payload, sizeof(payload), "unlocked:%u", remainingSeconds);
  lastPublishedUnlockRemainingSeconds = remainingSeconds;
  writeAndNotifyStatePayload(payload);
}

void rejectCommandFor(uint16_t connHandle, const char* reason) {
  Serial.print("Rejected command: ");
  Serial.println(reason);
  publishStateTo(connHandle, "rejected");
  delay(250);
  publishStateTo(connHandle, currentStateText());
}

void rejectCommand(const char* reason) {
  rejectCommandFor(BLE_CONN_HANDLE_INVALID, reason);
}

void attachServoIfNeeded() {
  if (!handleServo.attached()) {
    handleServo.attach(SERVO_SIGNAL_PIN);
    delay(SERVO_ATTACH_SETTLE_MS);
  }
}

void moveServoTo(int targetAngle, const char* transitionState) {
  targetAngle = constrain(targetAngle, MIN_SAFE_SERVO_ANGLE, MAX_SAFE_SERVO_ANGLE);
  attachServoIfNeeded();
  handleServo.write(targetAngle);
  // Begin physical movement before BLE notification backpressure. The state
  // characteristic still reports the transition before the settle delay.
  publishState(transitionState);
  if (currentAngle != targetAngle) {
    delay(SERVO_MOVE_SETTLE_MS);
  }
  currentAngle = targetAngle;
}

void releaseServoPower() {
  delay(SERVO_DETACH_DELAY_MS);
  handleServo.detach();
}

void lockRest() {
  unlockAutoLockActive = false;
  servoMoving = true;
  updateStatusLed();
  moveServoTo(lockAngle, "locking");
  unlocked = false;
  servoMoving = false;
  publishState("locked");
  updateStatusLed();
  releaseServoPower();
}

void unlockHold(uint64_t epochSeconds = 0, const char* deviceFingerprint = nullptr, const char* deviceName = nullptr) {
  servoMoving = true;
  updateStatusLed();
  moveServoTo(unlockAngle, "unlocking");
  unlockAutoLockStartedMs = millis();
  unlockAutoLockActive = true;
  unlocked = true;
  servoMoving = false;
  publishState("unlocked");
  updateStatusLed();

  bool didStoreLastUnlock = false;
  if (epochSeconds > 0) {
    didStoreLastUnlock = setLastUnlockRecord(epochSeconds, deviceFingerprint, deviceName);
    if (!didStoreLastUnlock) {
      Serial.println("Last unlock timestamp save failed; continuing unlock.");
    }
  }

  if (didStoreLastUnlock) {
    delay(LAST_UNLOCK_NOTIFY_GAP_MS);
    publishLastUnlockState();
    delay(LAST_UNLOCK_NOTIFY_GAP_MS);
    publishState(currentStateText());
  }
  Serial.print("Auto-lock scheduled in ");
  Serial.print(unlockHoldTimeoutSeconds);
  Serial.println(" seconds.");
}

void handleUnlockTimeout() {
  if (!unlocked || !unlockAutoLockActive) {
    return;
  }

  if ((uint32_t)(millis() - unlockAutoLockStartedMs) < unlockHoldTimeoutMs()) {
    return;
  }

  Serial.println("Unlock timeout reached; locking.");
  lockRest();
}

void finishV3Command(uint16_t connHandle) {
  issueV3NonceTo(connHandle);
}

void rejectV3CommandFor(uint16_t connHandle, const char* reason, bool issueFreshNonce = true) {
  publishControlRejectTo(connHandle, reason);
  if (issueFreshNonce) {
    issueV3NonceTo(connHandle);
  }
}

void handleV3Command(const uint8_t* packet, uint16_t packetLen, uint16_t connHandle) {
  if (packet == nullptr || packetLen < V3_COMMAND_MIN_PACKET_LEN || packet[0] != V3_COMMAND_VERSION) {
    publishControlRejectTo(connHandle, "bad_packet");
    return;
  }

  uint8_t op = packet[1];
  uint8_t payloadLen = packet[V3_COMMAND_HEADER_LEN - 1];
  if (payloadLen > V3_COMMAND_MAX_PAYLOAD_LEN || packetLen != V3_COMMAND_HEADER_LEN + payloadLen + P256_SIGNATURE_LEN) {
    publishControlRejectTo(connHandle, "bad_packet");
    return;
  }

  int8_t pairingIndex = pairedPublicKeyIndexForFingerprintBytes(packet + 2);
  if (pairingIndex < 0) {
    markConnectedDeviceUntrusted(connHandle, true);
    publishControlRejectTo(connHandle, "unpaired");
    publishConnectionsState();
    return;
  }

  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0 || !connectedDeviceNonceValid[slot]) {
    publishControlRejectTo(connHandle, "missing_nonce");
    issueV3NonceTo(connHandle);
    return;
  }

  const uint8_t* nonce = packet + 2 + V3_KEY_FINGERPRINT_LEN;
  if (memcmp(connectedDeviceNonces[slot], nonce, V3_NONCE_LEN) != 0) {
    publishControlRejectTo(connHandle, "bad_nonce");
    issueV3NonceTo(connHandle);
    return;
  }

  uint8_t signatureMessage[sizeof(V3_COMMAND_SIGNATURE_DOMAIN) - 1 + V3_COMMAND_HEADER_LEN + V3_COMMAND_MAX_PAYLOAD_LEN] = {0};
  size_t signatureMessageLen = 0;
  if (!buildV3CommandSignatureMessage(packet, packetLen, signatureMessage, sizeof(signatureMessage), &signatureMessageLen)) {
    publishControlRejectTo(connHandle, "bad_packet");
    return;
  }

  const uint8_t* signature = packet + V3_COMMAND_HEADER_LEN + payloadLen;
  if (!verifySignatureForPairedDevice((uint8_t) pairingIndex, signatureMessage, signatureMessageLen, signature)) {
    connectedDeviceNonceValid[slot] = false;
    memset(connectedDeviceNonces[slot], 0, sizeof(connectedDeviceNonces[slot]));
    markConnectedDeviceUntrusted(connHandle, true);
    publishControlRejectTo(connHandle, "bad_signature");
    publishConnectionsState();
    issueV3NonceTo(connHandle);
    return;
  }

  connectedDeviceNonceValid[slot] = false;
  memset(connectedDeviceNonces[slot], 0, sizeof(connectedDeviceNonces[slot]));

  const char* trustedDeviceName = pairedDeviceNames[pairingIndex][0] != 0 ? pairedDeviceNames[pairingIndex] : nullptr;
  if (trustedDeviceName != nullptr && setConnectedDeviceName(connHandle, trustedDeviceName, true)) {
    publishConnectionsState();
  }

  Serial.print("Accepted v3 secure command from device ");
  Serial.print(pairingIndex + 1);
  Serial.print(": ");
  Serial.println(op);

  const uint8_t* payload = packet + V3_COMMAND_HEADER_LEN;

  if (op == V3_OP_UNLOCK) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    unlockHold();
    finishV3Command(connHandle);
  } else if (op == V3_OP_LOCK) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    lockRest();
    finishV3Command(connHandle);
  } else if (op == V3_OP_GET_LOCK_NAME) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    publishLockNameState();
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_GET_SERVO_ANGLES) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    publishServoAnglesState();
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_GET_LAST_UNLOCK) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    publishLastUnlockState();
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_SET_LOCK_NAME) {
    char lockName[LOCK_NAME_STORAGE_LEN] = {0};
    sanitizeDeviceName(payload, payloadLen, lockName, sizeof(lockName));
    if (lockName[0] == 0) {
      rejectV3CommandFor(connHandle, "bad lock name");
      return;
    }

    publishSettingApplyingState("lock_name", lockName);
    if (!setControllerLockName(lockName)) {
      rejectV3CommandFor(connHandle, "lock name save failed");
      return;
    }

    publishLockNameState();
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_SET_SERVO_ANGLES) {
    if (payloadLen != 2) {
      rejectV3CommandFor(connHandle, "bad servo angles");
      return;
    }

    uint16_t requestedLockAngle = payload[0];
    uint16_t requestedUnlockAngle = payload[1];
    char angleText[16] = {0};
    snprintf(angleText, sizeof(angleText), "%u,%u", requestedLockAngle, requestedUnlockAngle);
    publishSettingApplyingState("servo_angles", angleText);
    if (!setServoAngles(requestedLockAngle, requestedUnlockAngle)) {
      rejectV3CommandFor(connHandle, "servo angle save failed");
      return;
    }

    publishServoAnglesState();
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_SET_TIMEOUT) {
    if (payloadLen != 2) {
      rejectV3CommandFor(connHandle, "bad timeout");
      return;
    }

    uint16_t requestedSeconds = (((uint16_t) payload[0]) << 8) | payload[1];
    char timeoutText[8] = {0};
    snprintf(timeoutText, sizeof(timeoutText), "%u", requestedSeconds);
    publishSettingApplyingState("timeout", timeoutText);
    if (!setUnlockHoldTimeoutSeconds(requestedSeconds)) {
      rejectV3CommandFor(connHandle, "timeout save failed");
      return;
    }

    publishTimeoutSetState();
    delay(40);
    publishState(currentStateText());
    updateStatusLed();
    finishV3Command(connHandle);
  } else if (op == V3_OP_SET_DEVICE_NAME) {
    char deviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
    char previousName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
    sanitizeDeviceName(payload, payloadLen, deviceName, sizeof(deviceName));
    if (deviceName[0] == 0) {
      rejectV3CommandFor(connHandle, "bad device name");
      return;
    }

    publishSettingApplyingState("device_name", deviceName);
    copyDeviceName(pairedDeviceNames[pairingIndex], previousName, sizeof(previousName));
    copyDeviceName(deviceName, pairedDeviceNames[pairingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
    if (!savePairings()) {
      copyDeviceName(previousName, pairedDeviceNames[pairingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
      rejectV3CommandFor(connHandle, "device name save failed");
      return;
    }

    Serial.print("Device ");
    Serial.print(pairingIndex + 1);
    Serial.print(" name set to ");
    Serial.println(pairedDeviceNames[pairingIndex]);
    setConnectedDeviceName(connHandle, pairedDeviceNames[pairingIndex], true);
    publishConnectionsState();
    publishState("paired");
    delay(40);
    publishState(currentStateText());
    finishV3Command(connHandle);
  } else if (op == V3_OP_PAIRING_ENABLE) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }
    if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
      rejectV3CommandFor(connHandle, "paired_table_full");
      return;
    }

    pairingModeEnabled = true;
    clearPendingPairing();
    publishState(currentStateText());
    updateStatusLed();
    finishV3Command(connHandle);
  } else if (op == V3_OP_PAIRING_DISABLE) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }

    pairingModeEnabled = false;
    clearPendingPairing();
    publishState(currentStateText());
    updateStatusLed();
    finishV3Command(connHandle);
  } else if (op == V3_OP_PAIRING_APPROVE) {
    if (payloadLen == 0 || payloadLen > PAIRING_FINGERPRINT_LEN) {
      rejectV3CommandFor(connHandle, "bad_approval_code");
      return;
    }

    char approvalCode[PAIRING_FINGERPRINT_LEN + 1] = {0};
    memcpy(approvalCode, payload, payloadLen);
    approvalCode[payloadLen] = 0;
    if (!approvePendingPairing(approvalCode)) {
      rejectV3CommandFor(connHandle, "approval_failed");
      return;
    }

    finishV3Command(connHandle);
  } else if (op == V3_OP_PAIRING_REJECT) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }

    rejectPendingPairing();
    finishV3Command(connHandle);
  } else if (op == V3_OP_ENTER_OTA_DFU) {
    if (payloadLen != 0) {
      rejectV3CommandFor(connHandle, "bad_payload");
      return;
    }

    publishFirmwareUpdateState("ota_dfu", pairedDeviceNames[pairingIndex]);
    finishV3Command(connHandle);
    drainStateNotificationsBeforeRestart();
    Serial.flush();
    enterOTADfu();
  } else {
    rejectV3CommandFor(connHandle, "bad_op");
  }
}

uint8_t queuedBleCommandCountForHandleLocked(uint16_t connHandle) {
  uint8_t count = 0;
  for (uint8_t offset = 0; offset < bleCommandQueueCount; offset++) {
    uint8_t index = (bleCommandQueueTail + offset) % BLE_COMMAND_QUEUE_CAPACITY;
    if (bleCommandQueue[index].connHandle == connHandle) {
      count++;
    }
  }
  return count;
}

void markBleCommandQueueOverflowLocked(uint16_t connHandle) {
  for (uint8_t index = 0; index < bleCommandQueueOverflowCount; index++) {
    if (bleCommandQueueOverflowHandles[index] == connHandle) {
      return;
    }
  }

  if (bleCommandQueueOverflowCount < MAX_BLE_CONNECTIONS) {
    bleCommandQueueOverflowHandles[bleCommandQueueOverflowCount++] = connHandle;
  }
}

bool enqueueBleCommandJob(uint16_t connHandle, const uint8_t* data, uint16_t len, bool isReject, const char* rejectReason = nullptr) {
  taskENTER_CRITICAL();
  if (bleCommandQueueCount >= BLE_COMMAND_QUEUE_CAPACITY
      || queuedBleCommandCountForHandleLocked(connHandle) >= BLE_COMMAND_QUEUE_PER_CONNECTION_LIMIT) {
    markBleCommandQueueOverflowLocked(connHandle);
    taskEXIT_CRITICAL();
    return false;
  }

  uint8_t index = bleCommandQueueHead;
  BleCommandJob& job = bleCommandQueue[index];
  job.isReject = isReject;
  job.connHandle = connHandle;
  job.payloadLen = 0;
  memset(job.payload, 0, sizeof(job.payload));
  memset(job.rejectReason, 0, sizeof(job.rejectReason));

  if (isReject) {
    strncpy(job.rejectReason, rejectReason == nullptr ? "controller busy" : rejectReason, sizeof(job.rejectReason) - 1);
  } else {
    uint16_t copyLen = min<uint16_t>(len, SECURE_COMMAND_MAX_LEN);
    if (data != nullptr && copyLen > 0) {
      memcpy(job.payload, data, copyLen);
    }
    job.payloadLen = copyLen;
  }

  bleCommandQueueHead = (bleCommandQueueHead + 1) % BLE_COMMAND_QUEUE_CAPACITY;
  bleCommandQueueCount++;
  taskEXIT_CRITICAL();
  return true;
}

bool enqueueBleReject(uint16_t connHandle, const char* reason) {
  return enqueueBleCommandJob(connHandle, nullptr, 0, true, reason);
}

bool enqueueBleSecureCommand(uint16_t connHandle, const uint8_t* data, uint16_t len) {
  return enqueueBleCommandJob(connHandle, data, len, false);
}

bool popBleCommandJob(BleCommandJob* output) {
  if (output == nullptr) {
    return false;
  }

  taskENTER_CRITICAL();
  if (bleCommandQueueCount == 0) {
    taskEXIT_CRITICAL();
    return false;
  }

  uint8_t index = bleCommandQueueTail;
  *output = bleCommandQueue[index];
  bleCommandQueueTail = (bleCommandQueueTail + 1) % BLE_COMMAND_QUEUE_CAPACITY;
  bleCommandQueueCount--;
  taskEXIT_CRITICAL();
  return true;
}

bool popBleCommandQueueOverflow(uint16_t* connHandle) {
  if (connHandle == nullptr) {
    return false;
  }

  taskENTER_CRITICAL();
  if (bleCommandQueueOverflowCount == 0) {
    taskEXIT_CRITICAL();
    return false;
  }

  *connHandle = bleCommandQueueOverflowHandles[0];
  for (uint8_t index = 1; index < bleCommandQueueOverflowCount; index++) {
    bleCommandQueueOverflowHandles[index - 1] = bleCommandQueueOverflowHandles[index];
  }
  bleCommandQueueOverflowCount--;
  bleCommandQueueOverflowHandles[bleCommandQueueOverflowCount] = BLE_CONN_HANDLE_INVALID;
  taskEXIT_CRITICAL();
  return true;
}

void discardBleCommandsForHandle(uint16_t connHandle) {
  taskENTER_CRITICAL();

  uint8_t originalCount = bleCommandQueueCount;
  uint8_t keptCount = 0;
  for (uint8_t offset = 0; offset < originalCount; offset++) {
    uint8_t readIndex = (bleCommandQueueTail + offset) % BLE_COMMAND_QUEUE_CAPACITY;
    if (bleCommandQueue[readIndex].connHandle == connHandle) {
      continue;
    }

    uint8_t writeIndex = (bleCommandQueueTail + keptCount) % BLE_COMMAND_QUEUE_CAPACITY;
    if (writeIndex != readIndex) {
      bleCommandQueue[writeIndex] = bleCommandQueue[readIndex];
    }
    keptCount++;
  }
  bleCommandQueueCount = keptCount;
  bleCommandQueueHead = (bleCommandQueueTail + keptCount) % BLE_COMMAND_QUEUE_CAPACITY;

  uint8_t overflowWriteIndex = 0;
  for (uint8_t index = 0; index < bleCommandQueueOverflowCount; index++) {
    if (bleCommandQueueOverflowHandles[index] != connHandle) {
      bleCommandQueueOverflowHandles[overflowWriteIndex++] = bleCommandQueueOverflowHandles[index];
    }
  }
  bleCommandQueueOverflowCount = overflowWriteIndex;
  for (uint8_t index = overflowWriteIndex; index < MAX_BLE_CONNECTIONS; index++) {
    bleCommandQueueOverflowHandles[index] = BLE_CONN_HANDLE_INVALID;
  }

  taskEXIT_CRITICAL();
}

void commandWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void) chr;

  if (len > SECURE_COMMAND_MAX_LEN) {
    enqueueBleReject(connHandle, "payload too long");
    return;
  }

  enqueueBleSecureCommand(connHandle, data, len);
}

void stateCccdWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint16_t value) {
  (void) chr;

  if (connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
    return;
  }

  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot < 0) {
    return;
  }
  if (value == 0) {
    resetStateNotificationSubscription((uint8_t) slot);
    return;
  }
  if (stateStartupSnapshotPending[slot]
      || stateStartupSnapshotDelivered[slot]) {
    return;
  }

  // CoreBluetooth can report subscription success just after the controller's
  // CCCD callback. Defer the first authoritative payload so the subscriber does
  // not lose the boot-session identifier while its local notification state is
  // still settling. Slot generation prevents delivery to a recycled handle.
  stateStartupSnapshotPending[slot] = true;
  stateStartupSnapshotDueMs[slot] = millis() + STATE_SUBSCRIPTION_SETTLE_MS;
  stateStartupSnapshotGenerations[slot] = stateNotificationQueueGenerations[slot];
  // A newly ready subscriber changes the authoritative roster. Rebroadcast it
  // after CCCD enable so already-connected devices do not depend solely on the
  // earlier GAP connect callback, which can race notification delivery.
  publishConnectionsState();
}

void controlCccdWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint16_t value) {
  (void) chr;

  if (value == 0 || connHandle == BLE_CONN_HANDLE_INVALID || !Bluefruit.connected(connHandle)) {
    return;
  }

  int8_t slot = connectedDeviceSlotForHandle(connHandle);
  if (slot >= 0 && !connectedDeviceNonceValid[slot]) {
    issueV3NonceTo(connHandle);
  }
}

void processPendingBleCommand() {
  uint16_t connHandle = BLE_CONN_HANDLE_INVALID;
  if (bleCommandQueueServeOverflowNext && popBleCommandQueueOverflow(&connHandle)) {
    bleCommandQueueServeOverflowNext = false;
    publishControlRejectTo(connHandle, "controller_busy");
    rotateV3NonceFor(connHandle);
    return;
  }

  BleCommandJob job;
  if (!popBleCommandJob(&job)) {
    if (popBleCommandQueueOverflow(&connHandle)) {
      bleCommandQueueServeOverflowNext = false;
      publishControlRejectTo(connHandle, "controller_busy");
      rotateV3NonceFor(connHandle);
    }
    return;
  }
  bleCommandQueueServeOverflowNext = true;

  if (job.isReject) {
    rejectCommandFor(job.connHandle, job.rejectReason);
    return;
  }

  if (job.payloadLen > 0 && job.payload[0] == V3_COMMAND_VERSION) {
    handleV3Command(job.payload, job.payloadLen, job.connHandle);
    return;
  }

  if (job.payloadLen == 5 && memcmp(job.payload, "nonce", 5) == 0) {
    issueV3NonceTo(job.connHandle);
    return;
  }

  if (job.payloadLen == 8 && memcmp(job.payload, "snapshot", 8) == 0) {
    publishStartupSnapshotTo(job.connHandle);
    return;
  }

  static const char criticalSnapshotCommand[] = "critical_snapshot";
  if (job.payloadLen == sizeof(criticalSnapshotCommand) - 1
      && memcmp(job.payload, criticalSnapshotCommand, sizeof(criticalSnapshotCommand) - 1) == 0) {
    publishCriticalStartupSnapshotTo(job.connHandle);
    return;
  }

  publishControlRejectTo(job.connHandle, "bad_protocol");
}

void pairingWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void) chr;

  if (!pairingModeEnabled) {
    rejectCommandFor(connHandle, "pairing mode locked");
    return;
  }

  const uint8_t* rawKey = data;
  char deviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  bool hasNamedPayload = len > P256_PUBLIC_KEY_LEN
    && data[0] == PAIRING_PAYLOAD_WITH_NAME_VERSION
    && len >= P256_PUBLIC_KEY_LEN + 1;

  if (hasNamedPayload) {
    rawKey = data + 1;
    size_t nameLen = len - 1 - P256_PUBLIC_KEY_LEN;
    sanitizeDeviceName(data + 1 + P256_PUBLIC_KEY_LEN, nameLen, deviceName, sizeof(deviceName));
  } else if (len != P256_PUBLIC_KEY_LEN) {
    rejectCommandFor(connHandle, "bad pairing key length");
    return;
  }

  if (!isValidPublicKey(rawKey)) {
    rejectCommandFor(connHandle, "invalid pairing key");
    return;
  }

  int8_t existingIndex = pairedPublicKeyIndex(rawKey);
  if (existingIndex >= 0) {
    if (deviceName[0] != 0) {
      char previousName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
      copyDeviceName(pairedDeviceNames[existingIndex], previousName, sizeof(previousName));
      copyDeviceName(deviceName, pairedDeviceNames[existingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
      if (!savePairings()) {
        copyDeviceName(previousName, pairedDeviceNames[existingIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
        rejectCommandFor(connHandle, "pairing save failed");
        return;
      }
    }
    setConnectedDeviceName(connHandle, pairedDeviceNames[existingIndex], true);
    pairingModeEnabled = false;
    clearPendingPairing();
    Serial.println("Device key was already paired; pairing mode disabled");
    publishConnectionsState();
    publishState("paired");
    delay(250);
    publishState(currentStateText());
    updateStatusLed();
    return;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    pairingModeEnabled = false;
    clearPendingPairing();
    rejectCommandFor(connHandle, "paired device table full");
    updateStatusLed();
    return;
  }

  if (pendingPairingExists) {
    if (memcmp(pendingPairingPublicKey, rawKey, P256_PUBLIC_KEY_LEN) == 0) {
      printPendingPairingRequest();
      publishState(currentStateText());
      updateStatusLed();
      return;
    }

    rejectCommandFor(connHandle, "pairing request already pending");
    updateStatusLed();
    return;
  }

  memcpy(pendingPairingPublicKey, rawKey, P256_PUBLIC_KEY_LEN);
  copyDeviceName(deviceName, pendingPairingDeviceName, sizeof(pendingPairingDeviceName));
  pendingPairingConnHandle = connHandle;
  setConnectedDeviceName(connHandle, pendingPairingDeviceName, false);
  pendingPairingExists = true;
  Serial.println("Device pairing request received over BLE.");
  printPendingPairingRequest();
  publishConnectionsState();
  publishState(currentStateText());
  updateStatusLed();
}

bool approvePendingPairing(const char* approvalCode) {
  if (!pendingPairingExists) {
    Serial.println("No pending device pairing request to approve.");
    printPairingStatus();
    return false;
  }

  char approvalCodeExpected[PAIRING_APPROVAL_CODE_LEN + 1] = {0};
  char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  if (!keyApprovalCode(pendingPairingPublicKey, approvalCodeExpected, sizeof(approvalCodeExpected))) {
    Serial.println("Could not calculate pending pairing approval code.");
    return false;
  }

  if (!keyFingerprint(pendingPairingPublicKey, fingerprint, sizeof(fingerprint))) {
    Serial.println("Could not calculate pending pairing fingerprint.");
    return false;
  }

  if (!pairingCodeMatches(approvalCodeExpected, approvalCode) && !pairingCodeMatches(fingerprint, approvalCode)) {
    Serial.println("Approval code did not match the pending device.");
    Serial.println("Type the 4-digit code shown in the app, for example: pair approve 1234");
    publishState(currentStateText());
    updateStatusLed();
    return false;
  }

  if (pairedPublicKeyExists(pendingPairingPublicKey)) {
    int8_t existingIndex = pairedPublicKeyIndex(pendingPairingPublicKey);
    if (existingIndex >= 0) {
      setConnectedDeviceName(pendingPairingConnHandle, pairedDeviceNames[existingIndex], true);
    }
    pairingModeEnabled = false;
    clearPendingPairing();
    Serial.println("Device key was already paired; pairing mode disabled.");
    publishConnectionsState();
    publishState("paired");
    delay(250);
    publishState(currentStateText());
    updateStatusLed();
    return true;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    uint16_t connHandle = pendingPairingConnHandle;
    pairingModeEnabled = false;
    clearPendingPairing();
    rejectCommandFor(connHandle, "paired device table full");
    updateStatusLed();
    return false;
  }

  if (!appendPairedPublicKey(pendingPairingPublicKey, pendingPairingDeviceName)) {
    rejectCommandFor(pendingPairingConnHandle, "pairing save failed");
    updateStatusLed();
    return false;
  }

  pairingModeEnabled = false;
  uint16_t approvedConnHandle = pendingPairingConnHandle;
  setConnectedDeviceName(approvedConnHandle, pendingPairingDeviceName, true);
  clearPendingPairing();
  Serial.print("Approved and stored device public key: ");
  Serial.println(fingerprint);
  publishConnectionsState();
  publishState("paired");
  issueV3NonceTo(approvedConnHandle);
  delay(250);
  publishState(currentStateText());
  updateStatusLed();
  return true;
}

bool pairDeviceFromUSBPayload(const char* payloadHex) {
  uint8_t payload[PAIRING_MAX_LEN] = {0};
  size_t payloadLen = 0;
  if (!decodeHexBytes(payloadHex, payload, sizeof(payload), &payloadLen)) {
    printAppError("reason=bad_pairing_payload");
    return false;
  }

  const uint8_t* rawKey = payload;
  char deviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  bool hasNamedPayload = payloadLen > P256_PUBLIC_KEY_LEN
    && payload[0] == PAIRING_PAYLOAD_WITH_NAME_VERSION
    && payloadLen >= P256_PUBLIC_KEY_LEN + 1;

  if (hasNamedPayload) {
    rawKey = payload + 1;
    size_t nameLen = payloadLen - 1 - P256_PUBLIC_KEY_LEN;
    sanitizeDeviceName(payload + 1 + P256_PUBLIC_KEY_LEN, nameLen, deviceName, sizeof(deviceName));
  } else if (payloadLen != P256_PUBLIC_KEY_LEN) {
    printAppError("reason=bad_pairing_key_length");
    return false;
  }

  if (!isValidPublicKey(rawKey)) {
    printAppError("reason=invalid_pairing_key");
    return false;
  }

  if (!pairedPublicKeyExists(rawKey) && pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    printAppError("reason=paired_table_full");
    return false;
  }

  if (!appendPairedPublicKey(rawKey, deviceName)) {
    printAppError("reason=pairing_save_failed");
    return false;
  }

  char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  pairingModeEnabled = false;
  clearPendingPairing();
  Serial.print("APP_OK paired=yes");
  if (keyFingerprint(rawKey, fingerprint, sizeof(fingerprint))) {
    Serial.print(" fingerprint=");
    Serial.print(fingerprint);
  }
  if (deviceName[0] != 0) {
    Serial.print(" name=");
    Serial.print(deviceName);
  }
  Serial.println();
  publishState("paired");
  delay(250);
  publishState(currentStateText());
  updateStatusLed();
  return true;
}

bool renamePairedDeviceFromUSB(const char* tokenAndName) {
  if (tokenAndName == nullptr) {
    printAppError("reason=missing_rename_target");
    return false;
  }

  char buffer[SERIAL_COMMAND_MAX_LEN + 1] = {0};
  strncpy(buffer, tokenAndName, sizeof(buffer) - 1);
  char* token = trimSerialCommand(buffer);
  char* name = token;
  while (*name != 0 && *name != ' ' && *name != '\t') {
    name++;
  }

  if (*name != 0) {
    *name = 0;
    name++;
  }
  name = trimSerialCommand(name);

  if (*token == 0) {
    printAppError("reason=missing_rename_target");
    return false;
  }

  int8_t renameIndex = pairedPublicKeyIndexForToken(token);
  if (renameIndex < 0) {
    printAppError("reason=rename_target_not_found");
    return false;
  }

  char deviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  char previousName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  sanitizeDeviceName((const uint8_t*) name, strlen(name), deviceName, sizeof(deviceName));
  if (deviceName[0] == 0) {
    printAppError("reason=bad_device_name");
    return false;
  }

  copyDeviceName(pairedDeviceNames[renameIndex], previousName, sizeof(previousName));
  copyDeviceName(deviceName, pairedDeviceNames[renameIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
  if (!savePairings()) {
    copyDeviceName(previousName, pairedDeviceNames[renameIndex], PAIRED_DEVICE_NAME_STORAGE_LEN);
    printAppError("reason=device_name_save_failed");
    return false;
  }

  Serial.print("APP_OK renamed=");
  Serial.print(renameIndex + 1);
  Serial.print(" name=");
  Serial.println(pairedDeviceNames[renameIndex]);
  publishState("paired");
  delay(250);
  publishState(currentStateText());
  updateStatusLed();
  return true;
}

void rejectPendingPairing() {
  if (!pendingPairingExists) {
    Serial.println("No pending device pairing request to reject.");
    printPairingStatus();
    return;
  }

  clearPendingPairing();
  Serial.println("Rejected pending device pairing request. Pairing mode is still enabled.");
  publishState(currentStateText());
  updateStatusLed();
}

char lowercaseChar(char value) {
  if (value >= 'A' && value <= 'Z') {
    return value + 32;
  }
  return value;
}

bool serialCommandEquals(const char* command, const char* expected) {
  while (*command != 0 && *expected != 0) {
    if (lowercaseChar(*command) != lowercaseChar(*expected)) {
      return false;
    }
    command++;
    expected++;
  }
  return *command == 0 && *expected == 0;
}

bool serialCommandStartsWith(const char* command, const char* prefix) {
  while (*prefix != 0) {
    if (*command == 0 || lowercaseChar(*command) != lowercaseChar(*prefix)) {
      return false;
    }
    command++;
    prefix++;
  }
  return *command == 0 || *command == ' ' || *command == '\t';
}

char* trimSerialCommand(char* line) {
  while (*line == ' ' || *line == '\t') {
    line++;
  }

  size_t len = strlen(line);
  while (len > 0 && (line[len - 1] == ' ' || line[len - 1] == '\t')) {
    line[len - 1] = 0;
    len--;
  }

  return line;
}

void printAppOk(const char* detail) {
  Serial.print("APP_OK");
  if (detail != nullptr && *detail != 0) {
    Serial.print(" ");
    Serial.print(detail);
  }
  Serial.println();
}

void printAppError(const char* detail) {
  Serial.print("APP_ERROR");
  if (detail != nullptr && *detail != 0) {
    Serial.print(" ");
    Serial.print(detail);
  }
  Serial.println();
}

void printAppStatus() {
  Serial.println("APP_STATUS_BEGIN");
  Serial.println("protocol=1");
  Serial.print("boot_session=");
  Serial.println(controllerBootSessionId);
  Serial.print("storage_health=");
  Serial.println(internalFsReady ? "ok" : "fault");
  Serial.print("model=");
  Serial.println(CONTROLLER_MODEL_NAME);
  Serial.print("firmware_version=");
  Serial.println(CONTROLLER_FIRMWARE_VERSION);
  Serial.print("lock_name=");
  Serial.println(controllerLockName);
  Serial.print("pairing_mode=");
  Serial.println(pairingModeEnabled ? "enabled" : "locked");
  Serial.print("paired_count=");
  Serial.println(pairedPublicKeyCount);
  Serial.print("max_pairs=");
  Serial.println(MAX_PAIRED_PHONES);
  Serial.print("pending=");
  Serial.println(pendingPairingExists ? "yes" : "no");
  if (pendingPairingExists) {
    char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
    Serial.print("pending_fingerprint=");
    if (keyFingerprint(pendingPairingPublicKey, fingerprint, sizeof(fingerprint))) {
      Serial.println(fingerprint);
    } else {
      Serial.println("unknown");
    }
    Serial.print("pending_name=");
    Serial.println(pendingPairingDeviceName);
  }
  Serial.print("ble_state=");
  Serial.println(currentStateText());
  char settingPayload[STATE_PAYLOAD_MAX_LEN] = {0};
  if (currentSettingApplyingPayload(settingPayload, sizeof(settingPayload))) {
    Serial.print("setting_applying=");
    Serial.println(settingPayload);
  }
  Serial.print("ble_connected_count=");
  Serial.println(trackedConnectionCount());
  Serial.print("ble_max_connections=");
  Serial.println(MAX_BLE_CONNECTIONS);
  for (uint8_t index = 0; index < MAX_BLE_CONNECTIONS; index++) {
    if (!isTrackedConnectionSlotActive(index)) {
      continue;
    }

    char name[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
    sanitizeConnectionPayloadName(connectedDeviceNames[index], name, sizeof(name));
    Serial.print("connected_device=index=");
    Serial.print(index + 1);
    Serial.print(" handle=");
    Serial.print(connectedDeviceHandles[index]);
    Serial.print(" trusted=");
    Serial.print(connectedDeviceTrusted[index] ? "yes" : "no");
    Serial.print(" rejected=");
    Serial.print(connectedDeviceRejected[index] ? "yes" : "no");
    Serial.print(" age_ms=");
    Serial.print(connectedDeviceFirstSeenMs[index] == 0 ? 0 : (uint32_t)(millis() - connectedDeviceFirstSeenMs[index]));
    Serial.print(" name=");
    Serial.println(name);
  }
  Serial.print("unlocked=");
  Serial.println(unlocked ? "yes" : "no");
  Serial.print("auto_lock_seconds=");
  Serial.println(unlockHoldTimeoutSeconds);
  Serial.print("auto_lock_remaining_seconds=");
  Serial.println(unlockHoldRemainingSeconds());
  Serial.print("lock_angle=");
  Serial.println(lockAngle);
  Serial.print("unlock_angle=");
  Serial.println(unlockAngle);
  Serial.print("last_unlock_epoch=");
  printUnsigned64(lastUnlockEpochSeconds);
  Serial.println();
  Serial.print("last_unlock_device_id=");
  Serial.println(lastUnlockDeviceFingerprint);
  char resolvedLastUnlockDeviceName[PAIRED_DEVICE_NAME_STORAGE_LEN] = {0};
  copyResolvedLastUnlockDeviceName(resolvedLastUnlockDeviceName, sizeof(resolvedLastUnlockDeviceName));
  Serial.print("last_unlock_device=");
  Serial.println(resolvedLastUnlockDeviceName);
  Serial.print("servo_min_angle=");
  Serial.println(MIN_SAFE_SERVO_ANGLE);
  Serial.print("servo_max_angle=");
  Serial.println(MAX_SAFE_SERVO_ANGLE);
  Serial.print("servo_min_angle_gap=");
  Serial.println(MIN_SERVO_ANGLE_GAP);
  Serial.println("APP_STATUS_END");
}

void printAppPairs() {
  Serial.println("APP_PAIRS_BEGIN");
  Serial.print("count=");
  Serial.println(pairedPublicKeyCount);
  Serial.print("max=");
  Serial.println(MAX_PAIRED_PHONES);
  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
    Serial.print("pair index=");
    Serial.print(index + 1);
    Serial.print(" fingerprint=");
    if (keyFingerprint(pairedPublicKeys[index], fingerprint, sizeof(fingerprint))) {
      Serial.print(fingerprint);
    } else {
      Serial.print("unknown");
    }
    Serial.print(" counter=");
    printUnsigned64(pairedCounters[index]);
    Serial.print(" name=");
    Serial.print(pairedDeviceNames[index]);
    Serial.println();
  }
  Serial.println("APP_PAIRS_END");
}

bool handleAppCommand(char* command) {
  if (!serialCommandStartsWith(command, "app")) {
    return false;
  }

  char* subcommand = trimSerialCommand(command + strlen("app"));
  if (*subcommand == 0 || serialCommandEquals(subcommand, "status")) {
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "pairs")) {
    printAppPairs();
  } else if (serialCommandEquals(subcommand, "pair on") || serialCommandEquals(subcommand, "pairing on")) {
    if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
      printAppError("reason=paired_table_full");
    } else {
      pairingModeEnabled = true;
      clearPendingPairing();
      publishState(currentStateText());
      updateStatusLed();
      printAppOk("pairing_mode=enabled");
    }
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "pair off") || serialCommandEquals(subcommand, "pairing off")) {
    pairingModeEnabled = false;
    clearPendingPairing();
    publishState(currentStateText());
    updateStatusLed();
    printAppOk("pairing_mode=locked");
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "approve") || serialCommandStartsWith(subcommand, "pair approve")) {
    char* approvalCode = subcommand + (serialCommandStartsWith(subcommand, "pair approve") ? strlen("pair approve") : strlen("approve"));
    approvalCode = trimSerialCommand(approvalCode);
    if (*approvalCode == 0) {
      printAppError("reason=missing_approval_code");
    } else if (approvePendingPairing(approvalCode)) {
      printAppOk("approved=yes");
    } else {
      printAppError("reason=approval_failed");
    }
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "pair usb") || serialCommandStartsWith(subcommand, "pair direct")) {
    char* payloadHex = subcommand + (serialCommandStartsWith(subcommand, "pair direct") ? strlen("pair direct") : strlen("pair usb"));
    payloadHex = trimSerialCommand(payloadHex);
    if (*payloadHex == 0) {
      printAppError("reason=missing_pairing_payload");
    } else {
      pairDeviceFromUSBPayload(payloadHex);
    }
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "reject") || serialCommandEquals(subcommand, "pair reject")) {
    bool hadPendingRequest = pendingPairingExists;
    rejectPendingPairing();
    printAppOk(hadPendingRequest ? "rejected=yes" : "rejected=no");
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "remove")) {
    char* token = trimSerialCommand(subcommand + strlen("remove"));
    int8_t removeIndex = pairedPublicKeyIndexForToken(token);
    if (*token == 0) {
      printAppError("reason=missing_remove_target");
    } else if (removeIndex < 0) {
      printAppError("reason=remove_target_not_found");
    } else {
      char removedFingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
      keyFingerprint(pairedPublicKeys[removeIndex], removedFingerprint, sizeof(removedFingerprint));
      if (removePairedPublicKeyAt((uint8_t) removeIndex)) {
        Serial.print("APP_OK removed=");
        Serial.println(removedFingerprint);
        publishState(currentStateText());
        updateStatusLed();
      } else {
        printAppError("reason=remove_failed");
      }
    }
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "rename")) {
    char* tokenAndName = trimSerialCommand(subcommand + strlen("rename"));
    renamePairedDeviceFromUSB(tokenAndName);
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "name") || serialCommandStartsWith(subcommand, "lock name")) {
    bool lockNameCommand = serialCommandStartsWith(subcommand, "lock name");
    char* rawName = subcommand + (lockNameCommand ? strlen("lock name") : strlen("name"));
    rawName = trimSerialCommand(rawName);
    if (*rawName == 0) {
      printAppError("reason=missing_lock_name");
    } else {
      char lockName[LOCK_NAME_STORAGE_LEN] = {0};
      copyLockName(rawName, lockName, sizeof(lockName));
      publishSettingApplyingState("lock_name", lockName);
      if (setControllerLockName(rawName)) {
        publishLockNameState();
        delay(250);
        publishState(currentStateText());
        printAppOk("lock_name_set=yes");
      } else {
        printAppError("reason=lock_name_save_failed");
      }
    }
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "angles") || serialCommandStartsWith(subcommand, "servo angles")) {
    char* rawAngles = subcommand + (serialCommandStartsWith(subcommand, "servo angles") ? strlen("servo angles") : strlen("angles"));
    rawAngles = trimSerialCommand(rawAngles);
    uint16_t requestedLockAngle = 0;
    uint16_t requestedUnlockAngle = 0;
    if (*rawAngles == 0 || !parseServoAnglesText(rawAngles, &requestedLockAngle, &requestedUnlockAngle)) {
      printAppError("reason=bad_servo_angles");
    } else {
      char angleText[16] = {0};
      snprintf(angleText, sizeof(angleText), "%u,%u", requestedLockAngle, requestedUnlockAngle);
      publishSettingApplyingState("servo_angles", angleText);
      if (setServoAngles(requestedLockAngle, requestedUnlockAngle)) {
        publishServoAnglesState();
        delay(250);
        publishState(currentStateText());
        printAppOk("angles_set=yes");
      } else {
        printAppError("reason=servo_angle_save_failed");
      }
    }
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "clear pairs") || serialCommandEquals(subcommand, "pairs clear")) {
    if (clearPairings()) {
      publishConnectionsState();
      publishState(currentStateText());
      updateStatusLed();
      printAppOk("cleared=yes");
    } else {
      printAppError("reason=pairing_clear_save_failed");
    }
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "storage repair")) {
    if (repairInternalStorage()) {
      publishState(currentStateText());
      updateStatusLed();
      printAppOk("storage_repaired=yes");
    } else {
      printAppError("reason=storage_repair_failed");
    }
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "cleanup untrusted") || serialCommandEquals(subcommand, "disconnect untrusted")) {
    uint8_t disconnectedCount = disconnectUntrustedLockedConnections(true);
    Serial.print("APP_OK untrusted_disconnected=");
    Serial.println(disconnectedCount);
    publishConnectionsState();
    printAppStatus();
  } else if (serialCommandEquals(subcommand, "bootloader") || serialCommandEquals(subcommand, "uf2")) {
    printAppOk("bootloader=uf2");
    Serial.flush();
    delay(100);
    enterUf2Dfu();
  } else if (serialCommandEquals(subcommand, "ota") || serialCommandEquals(subcommand, "ota-dfu")) {
    printAppOk("firmware_update=ota_dfu");
    publishFirmwareUpdateState("ota_dfu", "This Mac over USB-C");
    drainStateNotificationsBeforeRestart();
    Serial.flush();
    enterOTADfu();
  } else if (serialCommandStartsWith(subcommand, "lock")) {
    char* epochText = trimSerialCommand(subcommand + strlen("lock"));
    uint64_t lockEpochSeconds = 0;
    if (*epochText != 0 && !parseUnsigned64Text(epochText, &lockEpochSeconds)) {
      printAppError("reason=bad_lock_time");
    } else {
      lockRest();
      printAppOk("command=lock");
    }
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "unlock")) {
    char* epochText = trimSerialCommand(subcommand + strlen("unlock"));
    char* deviceNameText = epochText;
    while (*deviceNameText != 0 && *deviceNameText != ' ' && *deviceNameText != '\t') {
      deviceNameText++;
    }
    if (*deviceNameText != 0) {
      *deviceNameText = 0;
      deviceNameText++;
    }
    deviceNameText = trimSerialCommand(deviceNameText);

    uint64_t unlockEpochSeconds = 0;
    if (*epochText != 0 && !parseUnsigned64Text(epochText, &unlockEpochSeconds)) {
      printAppError("reason=bad_last_unlock_time");
    } else {
      unlockHold(unlockEpochSeconds, nullptr, *deviceNameText == 0 ? nullptr : deviceNameText);
      printAppOk("command=unlock");
    }
    printAppStatus();
  } else if (serialCommandStartsWith(subcommand, "timeout")) {
    char* secondsText = trimSerialCommand(subcommand + strlen("timeout"));
    uint64_t parsedSeconds = 0;
    if (*secondsText == 0 || !parseUnsigned64Text(secondsText, &parsedSeconds) || !isValidUnlockHoldTimeout(parsedSeconds)) {
      printAppError("reason=bad_timeout");
    } else {
      char timeoutText[8] = {0};
      snprintf(timeoutText, sizeof(timeoutText), "%u", (uint16_t) parsedSeconds);
      publishSettingApplyingState("timeout", timeoutText);
      if (setUnlockHoldTimeoutSeconds((uint16_t) parsedSeconds)) {
        publishTimeoutSetState();
        delay(250);
        publishState(currentStateText());
        updateStatusLed();
        printAppOk("timeout_set=yes");
      } else {
        printAppError("reason=timeout_save_failed");
      }
    }
    printAppStatus();
  } else {
    printAppError("reason=unknown_command");
    printAppStatus();
  }

  return true;
}

void printPairingHelp() {
  Serial.println("USB commands:");
  Serial.println("  pair on        Enable BLE pairing requests");
  Serial.println("  pair approve CODE");
  Serial.println("                 Approve the pending device if CODE matches the app");
  Serial.println("  pair reject    Reject the pending device shown in USB serial");
  Serial.println("  pair off       Disable BLE pairing mode and clear pending request");
  Serial.println("  pair status    Print pairing mode, pending request, and paired device count");
  Serial.println("  pairs list     Print paired device slots and fingerprints");
  Serial.println("  pairs remove N Remove paired device by slot number");
  Serial.println("  app rename N NAME");
  Serial.println("                 Rename a trusted device by slot or fingerprint");
  Serial.println("  pairs clear    Remove all paired devices");
  Serial.println("  app status     Print machine-readable controller status for the Mac app");
  Serial.println("  app lock [EPOCH_SECONDS]");
  Serial.println("                 Lock with an optional command timestamp");
  Serial.println("  app unlock [EPOCH_SECONDS]");
  Serial.println("                 Unlock and optionally store the last-unlock timestamp");
  Serial.println("  app angles REST PUSH");
  Serial.println("                 Set safe persisted servo angles, e.g. app angles 95 20");
  Serial.println("  app bootloader");
  Serial.println("                 Reboot into UF2 bootloader mode for firmware updates");
  Serial.println("  app ota");
  Serial.println("                 Reboot into BLE OTA DFU mode for app-driven firmware updates");
  Serial.println("  app pair usb HEX");
  Serial.println("                 Trust a Mac app key sent over USB-C");
  Serial.println("  app cleanup untrusted");
  Serial.println("                 Disconnect currently untrusted BLE links");
}

void printPairingStatus() {
  Serial.print("Pairing mode: ");
  Serial.println(pairingModeEnabled ? "enabled" : "locked");
  Serial.print("Paired devices: ");
  Serial.print(pairedPublicKeyCount);
  Serial.print("/");
  Serial.println(MAX_PAIRED_PHONES);
  Serial.print("Pending request: ");
  Serial.println(pendingPairingExists ? "yes" : "no");
  if (pendingPairingExists) {
    printPendingPairingRequest();
  }
  Serial.print("BLE state: ");
  Serial.println(currentStateText());
}

void handleSerialCommand(char* rawLine) {
  char* command = trimSerialCommand(rawLine);
  if (*command == 0) {
    return;
  }

  if (handleAppCommand(command)) {
    return;
  }

  if (serialCommandEquals(command, "pair on") || serialCommandEquals(command, "pairing on")) {
    if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
      Serial.println("Pairing mode not enabled: paired device table is full.");
      printPairingStatus();
      return;
    }

    pairingModeEnabled = true;
    clearPendingPairing();
  Serial.println("Pairing mode enabled. Open the app and tap Pair This iPhone, then approve the 4-digit code here.");
    publishState(currentStateText());
    updateStatusLed();
  } else if (serialCommandStartsWith(command, "pair approve")) {
    char* approvalCode = command + strlen("pair approve");
    approvalCode = trimSerialCommand(approvalCode);
    if (*approvalCode == 0) {
      Serial.println("Missing approval code. Use: pair approve 1234");
      printPendingPairingRequest();
      return;
    }
    approvePendingPairing(approvalCode);
  } else if (serialCommandEquals(command, "pair reject") || serialCommandEquals(command, "reject pair")) {
    rejectPendingPairing();
  } else if (serialCommandEquals(command, "pair off") || serialCommandEquals(command, "pairing off")) {
    pairingModeEnabled = false;
    clearPendingPairing();
    Serial.println("Pairing mode disabled and pending request cleared.");
    publishState(currentStateText());
    updateStatusLed();
  } else if (serialCommandEquals(command, "pair status") || serialCommandEquals(command, "status")) {
    printPairingStatus();
  } else if (serialCommandEquals(command, "pairs clear") || serialCommandEquals(command, "clear pairs")) {
    clearPairings();
    Serial.println("All paired devices cleared. Run 'pair on' before pairing a device.");
    publishState(currentStateText());
    updateStatusLed();
  } else if (serialCommandEquals(command, "pairs list") || serialCommandEquals(command, "list pairs")) {
    printAppPairs();
  } else if (serialCommandStartsWith(command, "pairs remove") || serialCommandStartsWith(command, "remove pair")) {
    char* token = command + (serialCommandStartsWith(command, "pairs remove") ? strlen("pairs remove") : strlen("remove pair"));
    token = trimSerialCommand(token);
    int8_t removeIndex = pairedPublicKeyIndexForToken(token);
    if (*token == 0) {
      Serial.println("Missing pair slot or fingerprint. Use: pairs remove 1");
      return;
    }
    if (removeIndex < 0) {
      Serial.println("No paired device matched that slot or fingerprint.");
      return;
    }

    char removedFingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
    keyFingerprint(pairedPublicKeys[removeIndex], removedFingerprint, sizeof(removedFingerprint));
    if (removePairedPublicKeyAt((uint8_t) removeIndex)) {
      Serial.print("Removed paired device: ");
      Serial.println(removedFingerprint);
      publishState(currentStateText());
      updateStatusLed();
    } else {
      Serial.println("Could not remove paired device.");
    }
  } else if (serialCommandEquals(command, "help") || serialCommandEquals(command, "?")) {
    printPairingHelp();
  } else {
    Serial.print("Unknown USB command: ");
    Serial.println(command);
    printPairingHelp();
  }
}

void processSerialCommands() {
  static char buffer[SERIAL_COMMAND_MAX_LEN + 1] = {0};
  static uint16_t length = 0;

  while (Serial.available() > 0) {
    char value = Serial.read();
    if (value == '\r') {
      continue;
    }
    if (value == '\n') {
      buffer[length] = 0;
      handleSerialCommand(buffer);
      length = 0;
      buffer[0] = 0;
      continue;
    }

    if (length < sizeof(buffer) - 1) {
      buffer[length++] = value;
    }
  }
}

void restartAdvertisingIfConnectionSlotAvailable() {
  if (Bluefruit.connected() < MAX_BLE_CONNECTIONS) {
    Bluefruit.Advertising.start(0);
  }
}

void applyBleIdentity() {
  ble_gap_addr_t address = {};
  address.addr_type = BLE_GAP_ADDR_TYPE_RANDOM_STATIC;
  memcpy(address.addr, CONTROLLER_BLE_STATIC_ADDRESS, sizeof(address.addr));
  address.addr[5] |= 0xC0;
  Bluefruit.setAddr(&address);
}

void connectCallback(uint16_t connHandle) {
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  char centralName[32] = {0};
  if (connection != nullptr) {
    connection->getPeerName(centralName, sizeof(centralName));
    connection->requestDataLengthUpdate();
    connection->requestMtuExchange(128);
  }

  Serial.print("Connected to ");
  Serial.print(centralName[0] == 0 ? "central" : centralName);
  Serial.print(" (");
  Serial.print(Bluefruit.connected());
  Serial.print("/");
  Serial.print(MAX_BLE_CONNECTIONS);
  Serial.println(")");
  trackConnectedDevice(connHandle, centralName);
  publishConnectionsState();
  publishState(currentStateText());
  if (controlCharacteristic.notifyEnabled(connHandle) || controlCharacteristic.indicateEnabled(connHandle)) {
    issueV3NonceTo(connHandle);
  }
  restartAdvertisingIfConnectionSlotAvailable();
  updateStatusLed();
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void) reason;
  Serial.println("Disconnected; advertising");
  if (pendingPairingExists && pendingPairingConnHandle == connHandle) {
    clearPendingPairing();
    Serial.println("Cancelled pairing request because its device disconnected");
  }
  discardBleCommandsForHandle(connHandle);
  clearConnectedDevice(connHandle);
  publishConnectionsState();
  restartAdvertisingIfConnectionSlotAvailable();
  updateStatusLed();
}

void setupDoorService() {
  doorService.begin();

  // Door commands are authenticated at the app layer with a trusted P-256 key,
  // a signature, and a controller-issued one-time nonce. Keeping GATT writes open avoids
  // macOS/iOS BLE bond churn while preserving command authorization.
  commandCharacteristic.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  commandCharacteristic.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  commandCharacteristic.setMaxLen(SECURE_COMMAND_MAX_LEN);
  commandCharacteristic.setWriteCallback(commandWrittenCallback);
  commandCharacteristic.begin();

  // Pairing still requires USB-C approval of the app-displayed code, so the BLE
  // pairing request itself does not need fragile OS-level link encryption.
  pairingCharacteristic.setProperties(CHR_PROPS_WRITE);
  pairingCharacteristic.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  pairingCharacteristic.setMaxLen(PAIRING_MAX_LEN);
  pairingCharacteristic.setWriteCallback(pairingWrittenCallback);
  pairingCharacteristic.begin();

  stateCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  stateCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  stateCharacteristic.setMaxLen(STATE_PAYLOAD_MAX_LEN);
  stateCharacteristic.setCccdWriteCallback(stateCccdWrittenCallback);
  stateCharacteristic.begin();
  writeCurrentStateCharacteristic();

  // This characteristic carries connection-private nonce/reject traffic only.
  // It has no Read property, so its value cannot be fetched. Bluefruit reuses
  // the read permission for CCCD writes, so OPEN is required for subscribing.
  controlCharacteristic.setProperties(CHR_PROPS_NOTIFY | CHR_PROPS_INDICATE);
  controlCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  controlCharacteristic.setMaxLen(STATE_PAYLOAD_MAX_LEN);
  controlCharacteristic.setCccdWriteCallback(controlCccdWrittenCallback);
  controlCharacteristic.begin();
}

void startAdvertising() {
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(doorService);
  Bluefruit.ScanResponse.addName();

  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void setup() {
  Serial.begin(115200);
  delay(300);

  initializeConnectedDeviceSlots();
  setupStatusLed();
  nRFCrypto.begin();
  loadPairings();
  loadUnlockHoldTimeout();
  loadLockName();
  loadServoAngles();
  loadLastUnlockRecord();
  updateStatusLed();

  attachServoIfNeeded();
  handleServo.write(lockAngle);
  currentAngle = lockAngle;
  releaseServoPower();

  // Keep the 128-byte MTU needed by one-packet signed commands, but reserve a
  // normal 3.75 ms event rather than BANDWIDTH_HIGH's 7.5 ms on every link.
  Bluefruit.configPrphConn(128, MULTI_LINK_EVENT_LENGTH, 2, 1);
  Bluefruit.begin(MAX_BLE_CONNECTIONS, 0);
  initializeControllerBootSession();
  applyBleIdentity();
  // App-approved P-256 keys are our trust source. Clear OS BLE bonds so stale
  // macOS/iOS link-encryption keys cannot destabilize multi-device control.
  Bluefruit.Periph.clearBonds();
  Bluefruit.Periph.setConnInterval(MULTI_LINK_CONN_INTERVAL_MIN, MULTI_LINK_CONN_INTERVAL_MAX);
  Bluefruit.Periph.setConnSupervisionTimeoutMS(MULTI_LINK_SUPERVISION_TIMEOUT_MS);
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName(CONTROLLER_MODEL_NAME);
  Bluefruit.Security.setIOCaps(false, false, false);
  Bluefruit.Security.setMITM(false);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);

  deviceInformation.setManufacturer("Door Unlocker Desk Test");
  deviceInformation.setModel("Seeed XIAO nRF52840 Sense");
  deviceInformation.begin();

  setupDoorService();
  startAdvertising();
  beginStagingBankMaintenance(millis());

  Serial.print(CONTROLLER_MODEL_NAME);
  Serial.println(" ready");
  Serial.print("Service UUID: ");
  Serial.println(DOOR_SERVICE_UUID);
  Serial.print("Auto-lock timeout: ");
  Serial.print(unlockHoldTimeoutSeconds);
  Serial.println(" seconds");
  Serial.print("BLE connections: 0/");
  Serial.println(MAX_BLE_CONNECTIONS);
  Serial.print("Servo angles: rest=");
  Serial.print(lockAngle);
  Serial.print(" push=");
  Serial.println(unlockAngle);
  printPairingHelp();
}

void loop() {
  processSerialCommands();
  processPendingBleCommand();
  processPendingStateStartupSnapshots();
  processPendingStateNotifications();
  retryMissingV3Nonces();
  disconnectUntrustedLockedConnections();
  handleUnlockTimeout();
  refreshUnlockCountdownValueIfChanged();
  updateStatusLed();
  if (serviceStagingBankMaintenance(
        millis(),
        servoMoving || unlocked || bleCommandQueueCount > 0 || settingApplyStatusActive
      )) {
    notifyStateSubscribers("ota_staging_ready");
  }
  delay(MAIN_LOOP_IDLE_DELAY_MS);
}
