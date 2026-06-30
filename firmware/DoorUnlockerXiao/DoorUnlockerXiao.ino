#include <bluefruit.h>
#include <Servo.h>
#include "Adafruit_nRFCrypto.h"
#include "nRFCrypto_Hash.h"
#include "nrf_cc310/include/crys_ecpki_build.h"
#include "nrf_cc310/include/crys_ecpki_domain.h"
#include "nrf_cc310/include/crys_ecpki_ecdsa.h"
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>

using namespace Adafruit_LittleFS_Namespace;

// Desk-test wiring:
// - Servo signal wire: XIAO D2
// - Servo red/black power wires: battery/Wago power split, not breadboard power rails
// - XIAO GND, buck converter GND, and servo GND must be common
static const int SERVO_SIGNAL_PIN = D2;

// Tune these on the desk before putting the mechanism near the door.
static const int LOCK_ANGLE = 20;        // Rest/release position
static const int UNLOCK_ANGLE = 95;      // Handle-push position
static const int SERVO_STEP_DELAY_MS = 8;
static const int SERVO_DETACH_DELAY_MS = 250;
static const uint32_t UNLOCK_HOLD_TIMEOUT_MS = 30UL * 1000UL;

// Door Unlocker BLE v2 UUIDs. The v2 service avoids stale iOS GATT caches
// from earlier firmware that did not include the pairing characteristic.
static const char DOOR_SERVICE_UUID[] = "7A5A1000-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char COMMAND_CHAR_UUID[] = "7A5A1001-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char STATE_CHAR_UUID[]   = "7A5A1002-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char PAIRING_CHAR_UUID[] = "7A5A1003-2B8D-4C3E-94E7-0B3C0DDAAF10";
static const char LEGACY_COUNTER_FILENAME[] = "/door-counter.txt";
static const char LEGACY_PUBLIC_KEY_FILENAME[] = "/door-public-key.bin";
static const char PAIRINGS_FILENAME[] = "/door-pairings.bin";
static const uint16_t SECURE_COMMAND_MAX_LEN = 220;
static const uint16_t PAIRING_MAX_LEN = 80;
static const size_t P256_PUBLIC_KEY_LEN = 65;   // X9.63 uncompressed: 0x04 || X || Y
static const size_t P256_SIGNATURE_LEN = 64;    // Raw ECDSA: R || S
static const uint8_t MAX_PAIRED_PHONES = 4;
static const size_t PAIRING_RECORD_LEN = P256_PUBLIC_KEY_LEN + sizeof(uint64_t);
static const size_t PAIRING_FINGERPRINT_LEN = 19; // 8-byte SHA-256 prefix as XXXX-XXXX-XXXX-XXXX

BLEService doorService = BLEService(DOOR_SERVICE_UUID);
BLECharacteristic commandCharacteristic = BLECharacteristic(COMMAND_CHAR_UUID);
BLECharacteristic stateCharacteristic = BLECharacteristic(STATE_CHAR_UUID);
BLECharacteristic pairingCharacteristic = BLECharacteristic(PAIRING_CHAR_UUID);
BLEDis deviceInformation;

Servo handleServo;
int currentAngle = LOCK_ANGLE;
bool unlocked = false;
bool servoMoving = false;
bool internalFsReady = false;
bool pairingModeEnabled = false;
bool pendingPairingExists = false;
bool unlockAutoLockActive = false;
uint32_t unlockAutoLockStartedMs = 0;
uint8_t pendingPairingPublicKey[P256_PUBLIC_KEY_LEN] = {0};
uint8_t pairedPublicKeyCount = 0;
uint8_t pairedPublicKeys[MAX_PAIRED_PHONES][P256_PUBLIC_KEY_LEN] = {{0}};
uint64_t pairedCounters[MAX_PAIRED_PHONES] = {0};

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

void printUnsigned64(uint64_t value) {
  char buffer[24] = {0};
  snprintf(buffer, sizeof(buffer), "%llu", (unsigned long long) value);
  Serial.print(buffer);
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

bool pairingCodeMatches(const char* expected, const char* provided) {
  if (expected == nullptr || provided == nullptr) {
    return false;
  }

  while (*expected != 0 && *provided != 0) {
    if (*provided == ' ' || *provided == '\t') {
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

  while (*provided == ' ' || *provided == '\t') {
    provided++;
  }

  return *expected == 0 && *provided == 0;
}

void clearPendingPairing() {
  pendingPairingExists = false;
  memset(pendingPairingPublicKey, 0, sizeof(pendingPairingPublicKey));
}

void printPendingPairingRequest() {
  if (!pendingPairingExists) {
    Serial.println("No pending phone pairing request.");
    return;
  }

  char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  Serial.println("Pending phone pairing request.");
  if (keyFingerprint(pendingPairingPublicKey, fingerprint, sizeof(fingerprint))) {
    Serial.print("Fingerprint: ");
    Serial.println(fingerprint);
  } else {
    Serial.println("Fingerprint unavailable.");
  }
  Serial.println("Compare it with the iPhone app, then type 'pair approve CODE' or 'pair reject'.");
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

bool readLegacyCounter(uint64_t* counter) {
  if (!ensureInternalFS()) {
    return false;
  }

  File file(InternalFS);
  if (!file.open(LEGACY_COUNTER_FILENAME, FILE_O_READ)) {
    return false;
  }

  char buffer[32] = {0};
  uint32_t readLen = file.read(buffer, sizeof(buffer) - 1);
  file.close();
  buffer[min<uint32_t>(readLen, sizeof(buffer) - 1)] = 0;
  return parseUnsigned64Text(buffer, counter);
}

bool pairedPublicKeyExists(const uint8_t* rawKey) {
  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    if (memcmp(pairedPublicKeys[index], rawKey, P256_PUBLIC_KEY_LEN) == 0) {
      return true;
    }
  }
  return false;
}

bool savePairings() {
  if (!ensureInternalFS()) {
    return false;
  }

  if (InternalFS.exists(PAIRINGS_FILENAME)) {
    InternalFS.remove(PAIRINGS_FILENAME);
  }

  if (pairedPublicKeyCount == 0) {
    return true;
  }

  File file(InternalFS);
  if (!file.open(PAIRINGS_FILENAME, FILE_O_WRITE)) {
    return false;
  }

  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    uint8_t counterBytes[8] = {0};
    encodeUnsigned64(pairedCounters[index], counterBytes);
    file.write(pairedPublicKeys[index], P256_PUBLIC_KEY_LEN);
    file.write(counterBytes, sizeof(counterBytes));
  }

  file.close();
  return true;
}

void loadPairings() {
  if (!ensureInternalFS()) {
    return;
  }

  pairedPublicKeyCount = 0;
  memset(pairedPublicKeys, 0, sizeof(pairedPublicKeys));
  memset(pairedCounters, 0, sizeof(pairedCounters));

  File file(InternalFS);
  if (file.open(PAIRINGS_FILENAME, FILE_O_READ)) {
    bool needsRepair = false;
    while (pairedPublicKeyCount < MAX_PAIRED_PHONES) {
      uint8_t rawKey[P256_PUBLIC_KEY_LEN] = {0};
      uint8_t counterBytes[8] = {0};
      uint32_t keyReadLen = file.read(rawKey, sizeof(rawKey));
      if (keyReadLen == 0) {
        break;
      }
      if (keyReadLen != sizeof(rawKey)) {
        needsRepair = true;
        break;
      }

      uint32_t counterReadLen = file.read(counterBytes, sizeof(counterBytes));
      if (counterReadLen != sizeof(counterBytes)) {
        needsRepair = true;
        break;
      }

      if (isValidPublicKey(rawKey) && !pairedPublicKeyExists(rawKey)) {
        memcpy(pairedPublicKeys[pairedPublicKeyCount], rawKey, P256_PUBLIC_KEY_LEN);
        pairedCounters[pairedPublicKeyCount] = decodeUnsigned64(counterBytes);
        pairedPublicKeyCount++;
      } else {
        needsRepair = true;
      }
    }
    file.close();

    if (needsRepair) {
      savePairings();
      Serial.println("Repaired paired phone table");
    }

    Serial.print("Loaded paired phones: ");
    Serial.print(pairedPublicKeyCount);
    Serial.print("/");
    Serial.println(MAX_PAIRED_PHONES);
    return;
  }

  File legacyFile(InternalFS);
  if (!legacyFile.open(LEGACY_PUBLIC_KEY_FILENAME, FILE_O_READ)) {
    Serial.println("No paired phone keys yet");
    return;
  }

  uint8_t legacyKey[P256_PUBLIC_KEY_LEN] = {0};
  uint32_t readLen = legacyFile.read(legacyKey, sizeof(legacyKey));
  legacyFile.close();

  if (readLen == sizeof(legacyKey) && isValidPublicKey(legacyKey)) {
    memcpy(pairedPublicKeys[0], legacyKey, P256_PUBLIC_KEY_LEN);
    pairedPublicKeyCount = 1;
    readLegacyCounter(&pairedCounters[0]);
    savePairings();
    InternalFS.remove(LEGACY_PUBLIC_KEY_FILENAME);
    InternalFS.remove(LEGACY_COUNTER_FILENAME);
    Serial.println("Migrated legacy paired phone key");
  } else {
    InternalFS.remove(LEGACY_PUBLIC_KEY_FILENAME);
    Serial.println("Removed invalid legacy paired phone key");
  }
}

bool appendPairedPublicKey(const uint8_t* rawKey) {
  if (!ensureInternalFS() || !isValidPublicKey(rawKey)) {
    return false;
  }

  if (pairedPublicKeyExists(rawKey)) {
    return true;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    return false;
  }

  memcpy(pairedPublicKeys[pairedPublicKeyCount], rawKey, P256_PUBLIC_KEY_LEN);
  pairedCounters[pairedPublicKeyCount] = 0;
  pairedPublicKeyCount++;
  return savePairings();
}

void clearPairings() {
  pairingModeEnabled = false;
  clearPendingPairing();
  pairedPublicKeyCount = 0;
  memset(pairedPublicKeys, 0, sizeof(pairedPublicKeys));
  memset(pairedCounters, 0, sizeof(pairedCounters));

  if (ensureInternalFS()) {
    InternalFS.remove(PAIRINGS_FILENAME);
    InternalFS.remove(LEGACY_PUBLIC_KEY_FILENAME);
    InternalFS.remove(LEGACY_COUNTER_FILENAME);
  }
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

int8_t verifySignedPayload(const char* payload, const uint8_t* signature) {
  if (pairedPublicKeyCount == 0) {
    return -1;
  }

  for (uint8_t index = 0; index < pairedPublicKeyCount; index++) {
    CRYS_ECPKI_UserPublKey_t publicKey;
    memset(&publicKey, 0, sizeof(publicKey));
    if (!buildPublicKeyFromRaw(pairedPublicKeys[index], &publicKey)) {
      continue;
    }

    static CRYS_ECDSA_VerifyUserContext_t verifyContext;
    memset(&verifyContext, 0, sizeof(verifyContext));

    uint32_t err = CRYS_ECDSA_Verify(
      &verifyContext,
      &publicKey,
      CRYS_ECPKI_HASH_SHA256_mode,
      (uint8_t*) signature,
      P256_SIGNATURE_LEN,
      (uint8_t*) payload,
      strlen(payload)
    );

    if (err == CRYS_OK) {
      return index;
    }
  }

  return -1;
}

bool isKnownCommand(const char* command) {
  return strcmp(command, "UNLOCK") == 0 || strcmp(command, "LOCK") == 0;
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
    setRgbLed(false, true, true);    // Cyan means a phone is waiting for USB approval.
  } else if (pairingModeEnabled) {
    setRgbLed(true, false, true);   // Purple means USB-enabled pairing mode.
  } else if (pairedPublicKeyCount == 0) {
    setRgbLed(true, false, false);  // Red means no phone can command it yet.
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

void publishState(const char* state) {
  stateCharacteristic.write(state);
  if (Bluefruit.connected()) {
    stateCharacteristic.notify(state);
  }
  Serial.print("State: ");
  Serial.println(state);
}

void rejectCommand(const char* reason) {
  Serial.print("Rejected command: ");
  Serial.println(reason);
  publishState("rejected");
  delay(250);
  publishState(currentStateText());
}

void attachServoIfNeeded() {
  if (!handleServo.attached()) {
    handleServo.attach(SERVO_SIGNAL_PIN);
    delay(40);
  }
}

void moveServoTo(int targetAngle) {
  targetAngle = constrain(targetAngle, 0, 180);
  attachServoIfNeeded();

  int step = targetAngle >= currentAngle ? 1 : -1;
  while (currentAngle != targetAngle) {
    currentAngle += step;
    handleServo.write(currentAngle);
    delay(SERVO_STEP_DELAY_MS);
  }
}

void releaseServoPower() {
  delay(SERVO_DETACH_DELAY_MS);
  handleServo.detach();
}

void lockRest() {
  unlockAutoLockActive = false;
  servoMoving = true;
  updateStatusLed();
  publishState("locking");
  moveServoTo(LOCK_ANGLE);
  releaseServoPower();
  unlocked = false;
  servoMoving = false;
  publishState("locked");
  updateStatusLed();
}

void unlockHold() {
  servoMoving = true;
  updateStatusLed();
  publishState("unlocking");
  moveServoTo(UNLOCK_ANGLE);
  unlockAutoLockStartedMs = millis();
  unlockAutoLockActive = true;
  unlocked = true;
  servoMoving = false;
  publishState("unlocked");
  updateStatusLed();
  Serial.print("Auto-lock scheduled in ");
  Serial.print(UNLOCK_HOLD_TIMEOUT_MS / 1000UL);
  Serial.println(" seconds.");
}

void handleUnlockTimeout() {
  if (!unlocked || !unlockAutoLockActive) {
    return;
  }

  if ((uint32_t)(millis() - unlockAutoLockStartedMs) < UNLOCK_HOLD_TIMEOUT_MS) {
    return;
  }

  Serial.println("Unlock timeout reached; locking.");
  lockRest();
}

bool authenticateCommand(char* payload, uint64_t* acceptedCounter, const char** acceptedCommand, uint8_t* acceptedPairingIndex) {
  if (pairedPublicKeyCount == 0) {
    rejectCommand("phone not paired");
    return false;
  }

  char* signatureSeparator = strrchr(payload, '|');
  if (signatureSeparator == nullptr) {
    rejectCommand("missing signature");
    return false;
  }

  *signatureSeparator = 0;
  const char* signatureText = signatureSeparator + 1;

  if (strncmp(payload, "v2|", 3) != 0) {
    rejectCommand("bad protocol version");
    return false;
  }

  char* firstSeparator = strchr(payload, '|');
  char* secondSeparator = firstSeparator == nullptr ? nullptr : strchr(firstSeparator + 1, '|');
  if (firstSeparator == nullptr || secondSeparator == nullptr) {
    rejectCommand("malformed command");
    return false;
  }

  const char* command = secondSeparator + 1;
  if (!isKnownCommand(command)) {
    rejectCommand("unknown command");
    return false;
  }

  uint64_t counter = 0;
  if (!parseUnsigned64Range(firstSeparator + 1, secondSeparator, &counter)) {
    rejectCommand("bad counter");
    return false;
  }

  uint8_t signature[P256_SIGNATURE_LEN] = {0};
  if (!hexToBytes(signatureText, signature, sizeof(signature))) {
    rejectCommand("bad signature encoding");
    return false;
  }

  int8_t matchedIndex = verifySignedPayload(payload, signature);
  if (matchedIndex < 0) {
    rejectCommand("signature mismatch");
    return false;
  }

  if (counter <= pairedCounters[matchedIndex]) {
    rejectCommand("replayed counter");
    return false;
  }

  *acceptedCounter = counter;
  *acceptedCommand = command;
  *acceptedPairingIndex = matchedIndex;
  return true;
}

void handleCommand(char* payload) {
  uint64_t commandCounter = 0;
  const char* command = nullptr;
  uint8_t pairingIndex = 0;
  if (!authenticateCommand(payload, &commandCounter, &command, &pairingIndex)) {
    return;
  }

  uint64_t previousCounter = pairedCounters[pairingIndex];
  pairedCounters[pairingIndex] = commandCounter;
  if (!savePairings()) {
    pairedCounters[pairingIndex] = previousCounter;
    rejectCommand("counter save failed");
    return;
  }

  Serial.print("Accepted secure command from phone ");
  Serial.print(pairingIndex + 1);
  Serial.print(" #");
  printUnsigned64(commandCounter);
  Serial.print(": ");
  Serial.println(command);

  if (strcmp(command, "UNLOCK") == 0) {
    unlockHold();
  } else if (strcmp(command, "LOCK") == 0) {
    lockRest();
  }
}

void commandWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void) connHandle;
  (void) chr;

  if (len > SECURE_COMMAND_MAX_LEN) {
    rejectCommand("payload too long");
    return;
  }

  char buffer[SECURE_COMMAND_MAX_LEN + 1] = {0};
  uint16_t copyLen = min<uint16_t>(len, SECURE_COMMAND_MAX_LEN);
  memcpy(buffer, data, copyLen);
  handleCommand(buffer);
}

void pairingWrittenCallback(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void) connHandle;
  (void) chr;

  if (!pairingModeEnabled) {
    rejectCommand("pairing mode locked");
    return;
  }

  if (len != P256_PUBLIC_KEY_LEN) {
    rejectCommand("bad pairing key length");
    return;
  }

  if (!isValidPublicKey(data)) {
    rejectCommand("invalid pairing key");
    return;
  }

  if (pairedPublicKeyExists(data)) {
    pairingModeEnabled = false;
    clearPendingPairing();
    Serial.println("Phone key was already paired; pairing mode disabled");
    publishState("paired");
    delay(250);
    publishState(currentStateText());
    updateStatusLed();
    return;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    pairingModeEnabled = false;
    clearPendingPairing();
    rejectCommand("paired phone table full");
    updateStatusLed();
    return;
  }

  if (pendingPairingExists) {
    if (memcmp(pendingPairingPublicKey, data, P256_PUBLIC_KEY_LEN) == 0) {
      printPendingPairingRequest();
      publishState(currentStateText());
      updateStatusLed();
      return;
    }

    rejectCommand("pairing request already pending");
    updateStatusLed();
    return;
  }

  memcpy(pendingPairingPublicKey, data, P256_PUBLIC_KEY_LEN);
  pendingPairingExists = true;
  Serial.println("Phone pairing request received over BLE.");
  printPendingPairingRequest();
  publishState(currentStateText());
  updateStatusLed();
}

void approvePendingPairing(const char* approvalCode) {
  if (!pendingPairingExists) {
    Serial.println("No pending phone pairing request to approve.");
    printPairingStatus();
    return;
  }

  char fingerprint[PAIRING_FINGERPRINT_LEN + 1] = {0};
  if (!keyFingerprint(pendingPairingPublicKey, fingerprint, sizeof(fingerprint))) {
    Serial.println("Could not calculate pending pairing fingerprint.");
    return;
  }

  if (!pairingCodeMatches(fingerprint, approvalCode)) {
    Serial.println("Approval code did not match the pending phone fingerprint.");
    Serial.print("Expected: ");
    Serial.println(fingerprint);
    Serial.println("Type the exact code shown in the iPhone app, for example: pair approve XXXX-XXXX-XXXX-XXXX");
    publishState(currentStateText());
    updateStatusLed();
    return;
  }

  if (pairedPublicKeyExists(pendingPairingPublicKey)) {
    pairingModeEnabled = false;
    clearPendingPairing();
    Serial.println("Phone key was already paired; pairing mode disabled.");
    publishState("paired");
    delay(250);
    publishState(currentStateText());
    updateStatusLed();
    return;
  }

  if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
    pairingModeEnabled = false;
    clearPendingPairing();
    rejectCommand("paired phone table full");
    updateStatusLed();
    return;
  }

  if (!appendPairedPublicKey(pendingPairingPublicKey)) {
    rejectCommand("pairing save failed");
    updateStatusLed();
    return;
  }

  pairingModeEnabled = false;
  clearPendingPairing();
  Serial.print("Approved and stored phone public key: ");
  Serial.println(fingerprint);
  publishState("paired");
  delay(250);
  publishState(currentStateText());
  updateStatusLed();
}

void rejectPendingPairing() {
  if (!pendingPairingExists) {
    Serial.println("No pending phone pairing request to reject.");
    printPairingStatus();
    return;
  }

  clearPendingPairing();
  Serial.println("Rejected pending phone pairing request. Pairing mode is still enabled.");
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

void printPairingHelp() {
  Serial.println("USB commands:");
  Serial.println("  pair on        Enable BLE pairing requests");
  Serial.println("  pair approve CODE");
  Serial.println("                 Approve the pending phone if CODE matches the iPhone app");
  Serial.println("  pair reject    Reject the pending phone shown in USB serial");
  Serial.println("  pair off       Disable BLE pairing mode and clear pending request");
  Serial.println("  pair status    Print pairing mode, pending request, and paired phone count");
  Serial.println("  pairs clear    Remove all paired phones");
}

void printPairingStatus() {
  Serial.print("Pairing mode: ");
  Serial.println(pairingModeEnabled ? "enabled" : "locked");
  Serial.print("Paired phones: ");
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

  if (serialCommandEquals(command, "pair on") || serialCommandEquals(command, "pairing on")) {
    if (pairedPublicKeyCount >= MAX_PAIRED_PHONES) {
      Serial.println("Pairing mode not enabled: paired phone table is full.");
      printPairingStatus();
      return;
    }

    pairingModeEnabled = true;
    clearPendingPairing();
    Serial.println("Pairing mode enabled. Open the app and tap Pair This iPhone, then approve the fingerprint here.");
    publishState(currentStateText());
    updateStatusLed();
  } else if (serialCommandStartsWith(command, "pair approve")) {
    char* approvalCode = command + strlen("pair approve");
    approvalCode = trimSerialCommand(approvalCode);
    if (*approvalCode == 0) {
      Serial.println("Missing approval code. Use: pair approve XXXX-XXXX-XXXX-XXXX");
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
    Serial.println("All paired phones cleared. Run 'pair on' before pairing a phone.");
    publishState(currentStateText());
    updateStatusLed();
  } else if (serialCommandEquals(command, "help") || serialCommandEquals(command, "?")) {
    printPairingHelp();
  } else {
    Serial.print("Unknown USB command: ");
    Serial.println(command);
    printPairingHelp();
  }
}

void processSerialCommands() {
  static char buffer[80] = {0};
  static uint8_t length = 0;

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

void connectCallback(uint16_t connHandle) {
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  char centralName[32] = {0};
  connection->getPeerName(centralName, sizeof(centralName));
  connection->requestDataLengthUpdate();
  connection->requestMtuExchange(247);
  if (!connection->bonded()) {
    connection->requestPairing();
  }

  Serial.print("Connected to ");
  Serial.println(centralName);
  publishState(currentStateText());
  updateStatusLed();
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void) connHandle;
  (void) reason;
  Serial.println("Disconnected; advertising");
  Bluefruit.Advertising.start(0);
  updateStatusLed();
}

void setupDoorService() {
  doorService.begin();

  commandCharacteristic.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  commandCharacteristic.setPermission(SECMODE_NO_ACCESS, SECMODE_ENC_NO_MITM);
  commandCharacteristic.setMaxLen(SECURE_COMMAND_MAX_LEN);
  commandCharacteristic.setWriteCallback(commandWrittenCallback);
  commandCharacteristic.begin();

  pairingCharacteristic.setProperties(CHR_PROPS_WRITE);
  pairingCharacteristic.setPermission(SECMODE_NO_ACCESS, SECMODE_ENC_NO_MITM);
  pairingCharacteristic.setMaxLen(PAIRING_MAX_LEN);
  pairingCharacteristic.setWriteCallback(pairingWrittenCallback);
  pairingCharacteristic.begin();

  stateCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  stateCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  stateCharacteristic.setMaxLen(24);
  stateCharacteristic.begin();
  stateCharacteristic.write(currentStateText());
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

  setupStatusLed();
  nRFCrypto.begin();
  loadPairings();
  updateStatusLed();

  attachServoIfNeeded();
  handleServo.write(LOCK_ANGLE);
  currentAngle = LOCK_ANGLE;
  releaseServoPower();

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName("DoorUnlocker-XIAO-v2");
  Bluefruit.Security.setIOCaps(false, false, false);
  Bluefruit.Security.setMITM(false);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);

  deviceInformation.setManufacturer("Door Unlocker Desk Test");
  deviceInformation.setModel("Seeed XIAO nRF52840 Sense");
  deviceInformation.begin();

  setupDoorService();
  startAdvertising();

  Serial.println("DoorUnlocker-XIAO-v2 ready");
  Serial.print("Service UUID: ");
  Serial.println(DOOR_SERVICE_UUID);
  printPairingHelp();
}

void loop() {
  processSerialCommands();
  handleUnlockTimeout();
  updateStatusLed();
  delay(250);
}
