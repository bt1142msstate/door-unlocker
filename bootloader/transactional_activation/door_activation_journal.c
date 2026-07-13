#include "door_activation_journal.h"

#include "app_error.h"
#include "bootloader.h"
#include "crc16.h"
#include "dfu.h"
#include "dfu_types.h"
#include "flash_nrf5x.h"
#include "nrf.h"
#include "nrfx_nvmc.h"
#include "pstorage.h"
#include "sdk_common.h"
#include "sdk_errors.h"

#define ACTIVATION_JOURNAL_MAGIC  0x44554A31UL
#define ACTIVATION_JOURNAL_COMMIT 0xA37C59E1UL

typedef struct
{
    uint32_t magic;
    uint32_t image_size;
    uint32_t image_size_inverse;
    uint32_t image_crc;
    uint32_t image_crc_inverse;
    uint32_t bank_1_address;
    uint32_t bank_1_address_inverse;
    uint32_t commit;
    uint32_t commit_inverse;
} activation_journal_t;

static pstorage_handle_t journal_handle;
static volatile bool operation_complete;
static volatile uint32_t operation_result;

extern bool is_ota(void);

static void journal_callback(pstorage_handle_t * handle,
                             uint8_t op_code,
                             uint32_t result,
                             uint8_t * data,
                             uint32_t data_len)
{
    (void)handle;
    (void)op_code;
    (void)data;
    (void)data_len;
    operation_result = result;
    operation_complete = true;
    APP_ERROR_CHECK(result);
}

static bool journal_valid(activation_journal_t const * journal)
{
    return journal->magic == ACTIVATION_JOURNAL_MAGIC &&
           journal->commit == ACTIVATION_JOURNAL_COMMIT &&
           journal->commit_inverse == ~ACTIVATION_JOURNAL_COMMIT &&
           journal->image_size > 0 &&
           journal->image_size <= DFU_IMAGE_MAX_SIZE_BANKED &&
           journal->image_size_inverse == ~journal->image_size &&
           journal->image_crc <= UINT16_MAX &&
           journal->image_crc_inverse == ~journal->image_crc &&
           journal->bank_1_address == DFU_BANK_1_REGION_START &&
           journal->bank_1_address_inverse == ~DFU_BANK_1_REGION_START;
}

static uint32_t wait_for_operation(void)
{
    while (!operation_complete)
    {
        (void)proc_soc();
    }
    return operation_result;
}

static uint32_t clear_journal(void)
{
    if (is_ota())
    {
        operation_complete = false;
        operation_result = NRF_ERROR_INTERNAL;
        uint32_t const result = pstorage_clear(&journal_handle, CODE_PAGE_SIZE);
        VERIFY_SUCCESS(result);
        return wait_for_operation();
    }

    nrfx_nvmc_page_erase(DFU_ACTIVATION_JOURNAL_ADDRESS);
    return NRF_SUCCESS;
}

static uint32_t store_journal(activation_journal_t const * journal)
{
    if (is_ota())
    {
        operation_complete = false;
        operation_result = NRF_ERROR_INTERNAL;
        uint32_t const result = pstorage_store(
            &journal_handle,
            (uint8_t *)journal,
            sizeof(*journal),
            0);
        VERIFY_SUCCESS(result);
        return wait_for_operation();
    }

    nrfx_nvmc_words_write(
        DFU_ACTIVATION_JOURNAL_ADDRESS,
        (uint32_t *)journal,
        sizeof(*journal) / sizeof(uint32_t));
    return NRF_SUCCESS;
}

uint32_t door_activation_journal_init(void)
{
    if ((DFU_ACTIVATION_JOURNAL_ADDRESS + CODE_PAGE_SIZE) >
        (BOOTLOADER_REGION_START - DFU_APP_DATA_RESERVED))
    {
        return NRF_ERROR_INVALID_ADDR;
    }

    pstorage_module_param_t parameters = {.cb = journal_callback};
    journal_handle.block_id = DFU_ACTIVATION_JOURNAL_ADDRESS;
    return pstorage_register(&parameters, &journal_handle);
}

uint32_t door_activation_stage(uint32_t image_size, uint16_t image_crc)
{
    __attribute__((aligned(4))) activation_journal_t journal =
    {
        .magic = ACTIVATION_JOURNAL_MAGIC,
        .image_size = image_size,
        .image_size_inverse = ~image_size,
        .image_crc = image_crc,
        .image_crc_inverse = ~((uint32_t)image_crc),
        .bank_1_address = DFU_BANK_1_REGION_START,
        .bank_1_address_inverse = ~DFU_BANK_1_REGION_START,
        .commit = ACTIVATION_JOURNAL_COMMIT,
        .commit_inverse = ~ACTIVATION_JOURNAL_COMMIT,
    };

    if (!journal_valid(&journal))
    {
        return NRF_ERROR_INVALID_PARAM;
    }

    uint16_t const staged_crc = crc16_compute(
        (uint8_t *)DFU_BANK_1_REGION_START,
        image_size,
        NULL);
    if (staged_crc != image_crc)
    {
        return NRF_ERROR_INVALID_DATA;
    }

    uint32_t result = clear_journal();
    VERIFY_SUCCESS(result);
    result = store_journal(&journal);
    VERIFY_SUCCESS(result);

    if (!journal_valid(
            (activation_journal_t const *)DFU_ACTIVATION_JOURNAL_ADDRESS))
    {
        return NRF_ERROR_INVALID_DATA;
    }

    // At WAIT_4_ACTIVATE, dfu_reset requests a normal bootloader reset. The
    // journal is then activated before BLE or USB transports are initialized.
    dfu_reset();
    return NRF_SUCCESS;
}

bool door_activation_in_progress(void)
{
    return journal_valid(
        (activation_journal_t const *)DFU_ACTIVATION_JOURNAL_ADDRESS);
}

uint32_t door_activation_continue(void)
{
    activation_journal_t const * journal =
        (activation_journal_t const *)DFU_ACTIVATION_JOURNAL_ADDRESS;
    if (!journal_valid(journal))
    {
        return NRF_ERROR_INVALID_STATE;
    }

    uint32_t const image_size = journal->image_size;
    uint16_t const image_crc = (uint16_t)journal->image_crc;
    uint16_t const staged_crc = crc16_compute(
        (uint8_t *)DFU_BANK_1_REGION_START,
        image_size,
        NULL);
    if (staged_crc != image_crc)
    {
        // Bank 0 is untouched in this boot, so a valid previous app can remain.
        return clear_journal();
    }

    // This sequence is intentionally idempotent. Bank 1 and the journal are
    // never modified, so any reset restarts from the verified source image.
    flash_nrf5x_erase(DFU_BANK_0_REGION_START, image_size);
    flash_nrf5x_write(
        DFU_BANK_0_REGION_START,
        (uint8_t *)DFU_BANK_1_REGION_START,
        image_size,
        false);
    flash_nrf5x_flush(false);

    uint16_t const installed_crc = crc16_compute(
        (uint8_t *)DFU_BANK_0_REGION_START,
        image_size,
        NULL);
    if (installed_crc != image_crc)
    {
        return NRF_ERROR_INVALID_DATA;
    }

    dfu_update_status_t update_status = {0};
    update_status.status_code = DFU_UPDATE_APP_COMPLETE;
    update_status.app_crc = image_crc;
    update_status.app_size = image_size;
    bootloader_dfu_update_process(update_status);

    if (!bootloader_app_is_valid())
    {
        return NRF_ERROR_INVALID_DATA;
    }

    // Bank 0 and settings are durable. Interruption before or during this
    // final erase either retries activation or boots the verified bank 0.
    uint32_t const result = clear_journal();
    if (result == NRF_SUCCESS)
    {
        NRF_POWER->GPREGRET = 0;
    }
    return result;
}
