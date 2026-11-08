/* SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * ELAN USB commands and frame ordering are based on libfprint's elan driver:
 * Copyright (C) 2017 Igor Filatov; Copyright (C) 2018 Sébastien Béchet.
 * https://gitlab.freedesktop.org/libfprint/libfprint
 *
 * This experimental capture core is not an authentication implementation.
 */
#include "elan0c4f.h"

#include <string.h>

#define ELAN_REPLY_ENDPOINT 0x83
#define ELAN_IMAGE_ENDPOINT 0x82
#define ELAN_COMMAND_TIMEOUT 10000U

static int command(struct elan_device *device, uint8_t first, uint8_t second,
                   uint8_t endpoint, uint8_t *reply, size_t length, unsigned timeout_ms)
{
    const uint8_t request[] = { first, second };
    int status = device->io.write(device->io.context, request, sizeof(request), ELAN_COMMAND_TIMEOUT);
    if (status != ELAN_OK || length == 0)
        return status;
    return device->io.read(device->io.context, endpoint, reply, length, timeout_ms);
}

int elan_initialize(struct elan_device *device, struct elan_transport transport)
{
    uint8_t firmware[2], dimensions[4];
    unsigned width, height;
    int result;
    if (!device || !transport.write || !transport.read || !transport.sleep_ms)
        return ELAN_ERR_ARGUMENT;
    memset(device, 0, sizeof(*device));
    device->io = transport;
    result = command(device, 0x40, 0x19, ELAN_REPLY_ENDPOINT, firmware, sizeof(firmware), ELAN_COMMAND_TIMEOUT);
    if (result != ELAN_OK) return result;
    result = command(device, 0x00, 0x0c, ELAN_REPLY_ENDPOINT, dimensions, sizeof(dimensions), ELAN_COMMAND_TIMEOUT);
    if (result != ELAN_OK) return result;
    width = dimensions[2]; height = dimensions[0];
    if (width % 2 && height % 2) { width++; height++; }
    if (width != ELAN_FRAME_WIDTH || height != ELAN_FRAME_HEIGHT)
        return ELAN_ERR_DEVICE;
    device->firmware = (uint16_t)((unsigned)firmware[0] * 256U + firmware[1]);
    device->ready = true;
    return ELAN_OK;
}

int elan_read_frame(struct elan_device *device, struct elan_frame *frame, unsigned timeout_ms)
{
    uint8_t raw[ELAN_FRAME_PIXELS * 2];
    int status;
    if (!device || !device->ready || !frame || !timeout_ms || timeout_ms > ELAN_COMMAND_TIMEOUT)
        return ELAN_ERR_ARGUMENT;
    /* A failed read must not leave an earlier biometric frame as apparent output. */
    elan_clear_frame(frame);
    status = command(device, 0x00, 0x09, ELAN_IMAGE_ENDPOINT, raw, sizeof(raw), timeout_ms);
    if (status == ELAN_OK) {
        for (size_t y = 0; y < ELAN_FRAME_HEIGHT; y++) {
            for (size_t x = 0; x < ELAN_FRAME_WIDTH; x++) {
                size_t input = (x * ELAN_FRAME_HEIGHT + y) * 2;
                frame->pixels[y * ELAN_FRAME_WIDTH + x] = (uint16_t)(raw[input] | ((unsigned)raw[input + 1] << 8));
            }
        }
    }
    /* Never leave a second raw copy on the stack. */
    volatile uint8_t *clear = raw;
    for (size_t i = 0; i < sizeof(raw); i++) clear[i] = 0;
    return status;
}

int elan_calibrate(struct elan_device *device, struct elan_frame *background, unsigned max_polls)
{
    uint8_t mean[2], state;
    int status;
    if (!device || !device->ready || !background || max_polls < 1 || max_polls > 100)
        return ELAN_ERR_ARGUMENT;
    status = elan_read_frame(device, background, ELAN_COMMAND_TIMEOUT);
    if (status != ELAN_OK) return status;
    for (unsigned attempt = 0; attempt < max_polls; attempt++) {
        uint64_t sum = 0;
        status = command(device, 0x40, 0x24, ELAN_REPLY_ENDPOINT, mean, sizeof(mean), ELAN_COMMAND_TIMEOUT);
        if (status != ELAN_OK) return status;
        for (size_t i = 0; i < ELAN_FRAME_PIXELS; i++) sum += background->pixels[i];
        /* Preserve the upstream driver's calibration convention. */
        int difference = (int)(sum / ELAN_FRAME_PIXELS) - (int)(mean[0] * 255U + mean[1]);
        if (difference >= -500 && difference <= 500) return ELAN_OK;
        bool retry_seen = false, ready_seen = false;
        for (unsigned poll = 0; poll < max_polls; poll++) {
            status = command(device, 0x40, 0x23, ELAN_REPLY_ENDPOINT, &state, 1, ELAN_COMMAND_TIMEOUT);
            if (status != ELAN_OK) return status;
            if (state == 0x01) retry_seen = true;
            else if (state == 0x03 && retry_seen) { ready_seen = true; break; }
            device->io.sleep_ms(device->io.context, 50);
        }
        if (!ready_seen) return ELAN_ERR_CALIBRATION;
        status = elan_read_frame(device, background, ELAN_COMMAND_TIMEOUT);
        if (status != ELAN_OK) return status;
    }
    return ELAN_ERR_CALIBRATION;
}

int elan_wait_finger(struct elan_device *device, unsigned timeout_ms)
{
    uint8_t state;
    int status;
    if (!device || !device->ready || !timeout_ms || timeout_ms > 90000)
        return ELAN_ERR_ARGUMENT;
    status = command(device, 0x40, 0x31, 0, NULL, 0, ELAN_COMMAND_TIMEOUT);
    if (status != ELAN_OK) return status;
    device->waiting = true;
    status = command(device, 0x40, 0x3f, ELAN_REPLY_ENDPOINT, &state, 1, timeout_ms);
    if (status == ELAN_ERR_TIMEOUT) return ELAN_NO_FINGER;
    if (status != ELAN_OK) return status;
    if (state == 0x55) return ELAN_OK;
    if (state == 0x00 || state == 0xaf) return ELAN_NO_FINGER;
    if (state == 0xff) return ELAN_ERR_CALIBRATION;
    return ELAN_ERR_PROTOCOL;
}

int elan_stop(struct elan_device *device)
{
    int result;
    if (!device || !device->ready) return ELAN_ERR_ARGUMENT;
    if (!device->waiting) return ELAN_OK;
    result = command(device, 0x00, 0x0b, 0, NULL, 0, ELAN_COMMAND_TIMEOUT);
    if (result == ELAN_OK) device->waiting = false;
    return result;
}

void elan_clear_frame(struct elan_frame *frame)
{
    if (!frame) return;
    volatile uint8_t *bytes = (volatile uint8_t *)frame;
    for (size_t i = 0; i < sizeof(*frame); i++) bytes[i] = 0;
}
