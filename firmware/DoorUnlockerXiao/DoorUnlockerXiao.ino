#include <bluefruit.h>
#include <Servo.h>
#include "Adafruit_nRFCrypto.h"
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

// Door Unlocker BLE UUIDs.
static const char DOOR_SERVICE_UUID[] = "4F6B8D90-7E44-4D5D-9C4E-51F0C78B6A01";
static const char COMMAND_CHAR_UUID[] = "4F6B8D91-7E44-4D5D-9C4E-51F0C78B6A01";
static const char STATE_CHAR_UUID[]   = "4F6B8D92-7E44-4D5D-9C4E-51F0C78B6A01";
static const char PAIRING_CHAR_UUID[] = "4F6B8D93-7E44-4D5D-9C4E-51F0C78B6A01";
static const char COUNTER_FILENAME[] = "/door-counter.txt";
static const char PUBLIC_KEY_FILENAME[] = "/door-public-key.bin";
static const uint16_t SECURE_COMMAND_MAX_LEN = 220;
static const uint16_t PAIRING_MAX_LEN = 80;
static const size_t P256_PUBLIC_KEY_LEN = 65;   // X9.63 uncompressed: 0x04 || X || Y
static const size_t P256_SIGNATURE_LEN = 64;    // Raw ECDSA: R || S

BLEService doorService = BLEService(DOOR_SERVICE_UUID);
BLECharacteristic commandCharacteristic = BLECharacteristic(COMMAND_CHAR_UUID);
BLECharacteristic stateCharacteristic = BLECharacteristic(STATE_CHAR_UUID);
BLECharacteristic pairingCharacteristic = BLECharacteristic(PAIRING_CHAR_UUID);
BLEDis deviceInformation;

Servo handleServo;
int currentAngle = LOCK_ANGLE;
bool unlocked = false;
bool servoMoving = false;
uint64_t lastAcceptedCounter = 0;
bool internalFsReady = false;
bool hasPairedPublicKey = false;
uint8_t pairedPublicKey[P256_PUBLIC_KEY_LEN] = {0};

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

void loadPairedPublicKey() {
  if (!ensureInternalFS()) {
    return;
  }

  File file(InternalFS);
  if (!file.open(PUBLIC_KEY_FILENAME, FILE_O_READ)) {
    Serial.println("No paired phone public key yet");
    return;
  }

  uint32_t readLen = file.read(pairedPublicKey, sizeof(pairedPublicKey));
  file.close();

  if (readLen == sizeof(pairedPublicKey) && isValidPublicKey(pairedPublicKey)) {
    hasPairedPublicKey = true;
    Serial.println("Loaded paired phone public key");
  } else {
    memset(pairedPublicKey, 0, sizeof(pairedPublicKey));
    hasPairedPublicKey = false;
    InternalFS.remove(PUBLIC_KEY_FILENAME);
    Serial.println("Removed invalid paired phone public key");
  }
}

bool savePairedPublicKey(const uint8_t* rawKey) {
  if (!ensureInternalFS() || !isValidPublicKey(rawKey)) {
    return false;
  }

  if (InternalFS.exists(PUBLIC_KEY_FILENAME)) {
    InternalFS.remove(PUBLIC_KEY_FILENAME);
  }

  File file(InternalFS);
  if (!file.open(PUBLIC_KEY_FILENAME, FILE_O_WRITE)) {
    return false;
  }

  file.write(rawKey, P256_PUBLIC_KEY_LEN);
  file.close();
  memcpy(pairedPublicKey, rawKey, P256_PUBLIC_KEY_LEN);
  hasPairedPublicKey = true;
  return true;
}

void loadLastAcceptedCounter() {
  if (!ensureInternalFS()) {
    return;
  }

  File file(InternalFS);
  if (!file.open(COUNTER_FILENAME, FILE_O_READ)) {
    Serial.println("No saved command counter yet");
    return;
  }

  char buffer[32] = {0};
  uint32_t readLen = file.read(buffer, sizeof(buffer) - 1);
  file.close();
  buffer[min<uint32_t>(readLen, sizeof(buffer) - 1)] = 0;

  uint64_t storedCounter = 0;
  if (parseUnsigned64Text(buffer, &storedCounter)) {
    lastAcceptedCounter = storedCounter;
  }

  Serial.print("Last secure command counter: ");
  printUnsigned64(lastAcceptedCounter);
  Serial.println();
}

bool saveLastAcceptedCounter(uint64_t counter) {
  if (!ensureInternalFS()) {
    return false;
  }

  if (InternalFS.exists(COUNTER_FILENAME)) {
    InternalFS.remove(COUNTER_FILENAME);
  }

  File file(InternalFS);
  if (!file.open(COUNTER_FILENAME, FILE_O_WRITE)) {
    return false;
  }

  char buffer[24] = {0};
  snprintf(buffer, sizeof(buffer), "%llu", (unsigned long long) counter);
  file.write(buffer, strlen(buffer));
  file.close();
  return true;
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

bool verifySignedPayload(const char* payload, const uint8_t* signature) {
  if (!hasPairedPublicKey) {
    return false;
  }

  CRYS_ECPKI_UserPublKey_t publicKey;
  memset(&publicKey, 0, sizeof(publicKey));
  if (!buildPublicKeyFromRaw(pairedPublicKey, &publicKey)) {
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
    (uint8_t*) payload,
    strlen(payload)
  );

  return err == CRYS_OK;
}

bool isKnownCommand(const char* command) {
  return strcmp(command, "UNLOCK") == 0 || strcmp(command, "LOCK") == 0;
}

const char* currentStateText() {
  if (!hasPairedPublicKey) {
    return "unpaired";
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
  } else if (!hasPairedPublicKey) {
    setRgbLed(true, false, false);  // Red means no phone is paired yet.
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
  unlocked = true;
  servoMoving = false;
  publishState("unlocked");
  updateStatusLed();
}

bool authenticateCommand(char* payload, uint64_t* acceptedCounter, const char** acceptedCommand) {
  if (!hasPairedPublicKey) {
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

  if (counter <= lastAcceptedCounter) {
    rejectCommand("replayed counter");
    return false;
  }

  uint8_t signature[P256_SIGNATURE_LEN] = {0};
  if (!hexToBytes(signatureText, signature, sizeof(signature))) {
    rejectCommand("bad signature encoding");
    return false;
  }

  if (!verifySignedPayload(payload, signature)) {
    rejectCommand("signature mismatch");
    return false;
  }

  *acceptedCounter = counter;
  *acceptedCommand = command;
  return true;
}

void handleCommand(char* payload) {
  uint64_t commandCounter = 0;
  const char* command = nullptr;
  if (!authenticateCommand(payload, &commandCounter, &command)) {
    return;
  }

  if (!saveLastAcceptedCounter(commandCounter)) {
    rejectCommand("counter save failed");
    return;
  }

  lastAcceptedCounter = commandCounter;
  Serial.print("Accepted secure command #");
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

  if (hasPairedPublicKey) {
    rejectCommand("already paired");
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

  if (!savePairedPublicKey(data)) {
    rejectCommand("pairing save failed");
    return;
  }

  lastAcceptedCounter = 0;
  saveLastAcceptedCounter(lastAcceptedCounter);

  Serial.println("Paired phone public key");
  publishState("paired");
  delay(250);
  publishState(currentStateText());
  updateStatusLed();
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
  loadPairedPublicKey();
  loadLastAcceptedCounter();
  updateStatusLed();

  attachServoIfNeeded();
  handleServo.write(LOCK_ANGLE);
  currentAngle = LOCK_ANGLE;
  releaseServoPower();

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName("DoorUnlocker-XIAO");
  Bluefruit.Security.setIOCaps(false, false, false);
  Bluefruit.Security.setMITM(false);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);

  deviceInformation.setManufacturer("Door Unlocker Desk Test");
  deviceInformation.setModel("Seeed XIAO nRF52840 Sense");
  deviceInformation.begin();

  setupDoorService();
  startAdvertising();

  Serial.println("DoorUnlocker-XIAO ready");
  Serial.print("Service UUID: ");
  Serial.println(DOOR_SERVICE_UUID);
}

void loop() {
  updateStatusLed();
  delay(250);
}
