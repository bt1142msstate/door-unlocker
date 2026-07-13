#ifndef DOOR_ACTIVATION_JOURNAL_H
#define DOOR_ACTIVATION_JOURNAL_H

#include <stdbool.h>
#include <stdint.h>

uint32_t door_activation_journal_init(void);
uint32_t door_activation_stage(uint32_t image_size, uint16_t image_crc);
bool door_activation_in_progress(void);
uint32_t door_activation_continue(void);

#endif
