#include <bluefruit.h>
#include <Servo.h>
#include "Adafruit_nRFCrypto.h"
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
static const char COUNTER_FILENAME[] = "/door-counter.txt";
static const uint16_t SECURE_COMMAND_MAX_LEN = 128;

// Public sample key. Replace with a private 32-byte key and paste the same
// bytes into DoorCommandAuthenticator.swift before real hardware use.
static const uint8_t COMMAND_AUTH_KEY[32] = {
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
  0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
};

BLEService doorService = BLEService(DOOR_SERVICE_UUID);
BLECharacteristic commandCharacteristic = BLECharacteristic(COMMAND_CHAR_UUID);
BLECharacteristic stateCharacteristic = BLECharacteristic(STATE_CHAR_UUID);
BLEDis deviceInformation;

Servo handleServo;
int currentAngle = LOCK_ANGLE;
bool unlocked = false;
bool servoMoving = false;
uint64_t lastAcceptedCounter = 0;

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

void loadLastAcceptedCounter() {
  if (!InternalFS.begin()) {
    Serial.println("InternalFS failed; secure command replay protection unavailable");
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

bool sha256Digest(const uint8_t* data, size_t len, uint8_t digest[32]) {
  nRFCrypto_Hash hash;
  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }

  if (len > 0) {
    hash.update((uint8_t*) data, len);
  }

  return hash.end(digest) == 32;
}

bool hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* message, size_t messageLen, uint8_t mac[32]) {
  uint8_t normalizedKey[64] = {0};
  if (keyLen > sizeof(normalizedKey)) {
    if (!sha256Digest(key, keyLen, normalizedKey)) {
      return false;
    }
  } else {
    memcpy(normalizedKey, key, keyLen);
  }

  uint8_t innerPad[64] = {0};
  uint8_t outerPad[64] = {0};
  for (size_t index = 0; index < sizeof(normalizedKey); index++) {
    innerPad[index] = normalizedKey[index] ^ 0x36;
    outerPad[index] = normalizedKey[index] ^ 0x5c;
  }

  uint8_t innerDigest[32] = {0};
  nRFCrypto_Hash hash;
  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }
  hash.update(innerPad, sizeof(innerPad));
  hash.update((uint8_t*) message, messageLen);
  if (hash.end(innerDigest) != 32) {
    return false;
  }

  if (!hash.begin(CRYS_HASH_SHA256_mode)) {
    return false;
  }
  hash.update(outerPad, sizeof(outerPad));
  hash.update(innerDigest, sizeof(innerDigest));
  return hash.end(mac) == 32;
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

bool constantTimeEqual(const uint8_t* left, const uint8_t* right, size_t len) {
  uint8_t diff = 0;
  for (size_t index = 0; index < len; index++) {
    diff |= left[index] ^ right[index];
  }

  return diff == 0;
}

bool isKnownCommand(const char* command) {
  return strcmp(command, "UNLOCK") == 0 || strcmp(command, "LOCK") == 0;
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
  publishState(unlocked ? "unlocked" : "locked");
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
  char* macSeparator = strrchr(payload, '|');
  if (macSeparator == nullptr) {
    rejectCommand("missing MAC");
    return false;
  }

  *macSeparator = 0;
  const char* macText = macSeparator + 1;

  if (strncmp(payload, "v1|", 3) != 0) {
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

  uint8_t providedMac[32] = {0};
  if (!hexToBytes(macText, providedMac, sizeof(providedMac))) {
    rejectCommand("bad MAC encoding");
    return false;
  }

  uint8_t expectedMac[32] = {0};
  if (!hmacSha256(COMMAND_AUTH_KEY, sizeof(COMMAND_AUTH_KEY), (uint8_t*) payload, strlen(payload), expectedMac)) {
    rejectCommand("MAC calculation failed");
    return false;
  }

  if (!constantTimeEqual(providedMac, expectedMac, sizeof(expectedMac))) {
    rejectCommand("MAC mismatch");
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
  publishState(unlocked ? "unlocked" : "locked");
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

  stateCharacteristic.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
  stateCharacteristic.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  stateCharacteristic.setMaxLen(24);
  stateCharacteristic.begin();
  stateCharacteristic.write("locked");
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
  loadLastAcceptedCounter();

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
