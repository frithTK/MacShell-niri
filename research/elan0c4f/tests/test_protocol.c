/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "elan0c4f.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

struct fixture {
    uint8_t command[2];
    uint8_t finger_state;
    bool timeout;
    bool wrong_dimensions;
    bool calibration_stuck;
    bool fail_frame;
    unsigned write_count;
    unsigned stop_count;
};

static int fake_write(void *context, const uint8_t *data, size_t length, unsigned timeout)
{
    struct fixture *f = context;
    assert(length == 2 && timeout > 0);
    memcpy(f->command, data, 2);
    f->write_count++;
    if (data[0] == 0x00 && data[1] == 0x0b) f->stop_count++;
    return ELAN_OK;
}

static int fake_read(void *context, uint8_t endpoint, uint8_t *data, size_t length, unsigned timeout)
{
    struct fixture *f = context;
    assert(timeout > 0);
    if (f->command[0] == 0x40 && f->command[1] == 0x19) {
        assert(endpoint == 0x83 && length == 2);
        data[0] = 1; data[1] = 0x65;
    } else if (f->command[0] == 0x00 && f->command[1] == 0x0c) {
        assert(endpoint == 0x83 && length == 4);
        data[0] = f->wrong_dimensions ? 0x20 : 0x4f; data[1] = 0;
        data[2] = f->wrong_dimensions ? 0x20 : 0x4f; data[3] = 0;
    } else if (f->command[0] == 0x00 && f->command[1] == 0x09) {
        assert(endpoint == 0x82 && length == ELAN_FRAME_PIXELS * 2);
        if (f->fail_frame) return ELAN_ERR_TIMEOUT;
        for (size_t i = 0; i < ELAN_FRAME_PIXELS; i++) {
            data[2 * i] = (uint8_t)(i & 255);
            data[2 * i + 1] = (uint8_t)(i >> 8);
        }
    } else if (f->command[0] == 0x40 && f->command[1] == 0x3f) {
        assert(endpoint == 0x83 && length == 1);
        if (f->timeout) return ELAN_ERR_TIMEOUT;
        data[0] = f->finger_state;
    } else if (f->command[0] == 0x40 && f->command[1] == 0x24) {
        assert(endpoint == 0x83 && length == 2);
        /* Background mean is 3199, within 500 of 12 * 255 + 100. */
        data[0] = f->calibration_stuck ? 0 : 12; data[1] = f->calibration_stuck ? 0 : 100;
    } else if (f->command[0] == 0x40 && f->command[1] == 0x23) {
        assert(endpoint == 0x83 && length == 1);
        data[0] = 0;
    } else {
        return ELAN_ERR_PROTOCOL;
    }
    return ELAN_OK;
}

static void fake_sleep(void *context, unsigned ms) { (void)context; (void)ms; }

static struct elan_transport transport(struct fixture *f)
{
    return (struct elan_transport){ .context = f, .write = fake_write, .read = fake_read, .sleep_ms = fake_sleep };
}

int main(void)
{
    struct fixture f = {0};
    struct elan_device dev;
    struct elan_frame frame;
    assert(elan_initialize(&dev, transport(&f)) == ELAN_OK);
    assert(dev.ready && dev.firmware == 0x0165);
    assert(elan_read_frame(&dev, &frame, 1000) == ELAN_OK);
    assert(frame.pixels[4 * 80 + 7] == 7 * 80 + 4);
    f.fail_frame = true;
    assert(elan_read_frame(&dev, &frame, 1000) == ELAN_ERR_TIMEOUT);
    for (size_t i = 0; i < ELAN_FRAME_PIXELS; i++) assert(frame.pixels[i] == 0);
    f.fail_frame = false;
    assert(elan_calibrate(&dev, &frame, 2) == ELAN_OK);
    f.calibration_stuck = true;
    assert(elan_calibrate(&dev, &frame, 2) == ELAN_ERR_CALIBRATION);
    f.calibration_stuck = false;
    f.finger_state = 0x55;
    assert(elan_wait_finger(&dev, 1000) == ELAN_OK);
    assert(elan_stop(&dev) == ELAN_OK && f.stop_count == 1);
    assert(elan_stop(&dev) == ELAN_OK && f.stop_count == 1);
    f.finger_state = 0x17;
    assert(elan_wait_finger(&dev, 1000) == ELAN_ERR_PROTOCOL);
    assert(elan_stop(&dev) == ELAN_OK);
    f.timeout = true;
    assert(elan_wait_finger(&dev, 1000) == ELAN_NO_FINGER);
    assert(elan_stop(&dev) == ELAN_OK);
    elan_clear_frame(&frame);
    for (size_t i = 0; i < ELAN_FRAME_PIXELS; i++) assert(frame.pixels[i] == 0);
    assert(elan_wait_finger(&dev, 0) == ELAN_ERR_ARGUMENT);
    f.wrong_dimensions = true;
    assert(elan_initialize(&dev, transport(&f)) == ELAN_ERR_DEVICE && !dev.ready);
    puts("ELAN_PROTOCOL_PASS: dimensions, rotation, calibration, status and cleanup");
    return 0;
}
