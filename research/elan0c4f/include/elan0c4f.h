/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef ELAN0C4F_H
#define ELAN0C4F_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ELAN_VENDOR_ID 0x04f3
#define ELAN_PRODUCT_ID 0x0c4f
#define ELAN_FRAME_WIDTH 80
#define ELAN_FRAME_HEIGHT 80
#define ELAN_FRAME_PIXELS (ELAN_FRAME_WIDTH * ELAN_FRAME_HEIGHT)

enum elan_result {
    ELAN_OK = 0,
    ELAN_NO_FINGER = 1,
    ELAN_ERR_IO = -1,
    ELAN_ERR_TIMEOUT = -2,
    ELAN_ERR_PROTOCOL = -3,
    ELAN_ERR_ARGUMENT = -4,
    ELAN_ERR_BUSY = -5,
    ELAN_ERR_DEVICE = -6,
    ELAN_ERR_CALIBRATION = -7
};

/* Implementations must return only elan_result values and never log frame data. */
struct elan_transport {
    void *context;
    int (*write)(void *context, const uint8_t *data, size_t length, unsigned timeout_ms);
    int (*read)(void *context, uint8_t endpoint, uint8_t *data, size_t length, unsigned timeout_ms);
    void (*sleep_ms)(void *context, unsigned milliseconds);
};

struct elan_frame { uint16_t pixels[ELAN_FRAME_PIXELS]; };
struct elan_device {
    struct elan_transport io;
    uint16_t firmware;
    bool ready;
    bool waiting;
};

int elan_initialize(struct elan_device *device, struct elan_transport transport);
int elan_read_frame(struct elan_device *device, struct elan_frame *frame, unsigned timeout_ms);
int elan_calibrate(struct elan_device *device, struct elan_frame *background, unsigned max_polls);
int elan_wait_finger(struct elan_device *device, unsigned timeout_ms);
int elan_stop(struct elan_device *device);
void elan_clear_frame(struct elan_frame *frame);

#endif
