/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "elan0c4f_usb.h"

#include <limits.h>
#include <stdlib.h>
#include <time.h>
#include <libusb.h>

struct elan_usb {
    libusb_context *context;
    libusb_device_handle *handle;
    bool claimed;
};

static int usb_result(int error)
{
    if (error == LIBUSB_ERROR_TIMEOUT) return ELAN_ERR_TIMEOUT;
    if (error == LIBUSB_ERROR_BUSY) return ELAN_ERR_BUSY;
    return ELAN_ERR_IO;
}

void elan_usb_close(struct elan_usb *usb)
{
    if (!usb) return;
    if (usb->claimed) libusb_release_interface(usb->handle, 0);
    if (usb->handle) libusb_close(usb->handle);
    if (usb->context) libusb_exit(usb->context);
    free(usb);
}

int elan_usb_open(struct elan_usb **result)
{
    struct elan_usb *usb;
    libusb_device **list = NULL, *target = NULL;
    ssize_t count;
    int status = ELAN_ERR_DEVICE, matches = 0, config = 0;
    if (!result) return ELAN_ERR_ARGUMENT;
    *result = NULL;
    usb = calloc(1, sizeof(*usb));
    if (!usb) return ELAN_ERR_IO;
    if (libusb_init(&usb->context) != LIBUSB_SUCCESS) goto done;
    count = libusb_get_device_list(usb->context, &list);
    if (count < 0) { status = ELAN_ERR_IO; goto done; }
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(list[i], &descriptor) != LIBUSB_SUCCESS) continue;
        if (descriptor.idVendor == ELAN_VENDOR_ID && descriptor.idProduct == ELAN_PRODUCT_ID) {
            target = list[i];
            matches++;
        }
    }
    if (matches != 1) goto done;
    int error = libusb_open(target, &usb->handle);
    if (error != LIBUSB_SUCCESS) { status = usb_result(error); goto done; }
    error = libusb_get_configuration(usb->handle, &config);
    if (error != LIBUSB_SUCCESS || config == 0) { status = ELAN_ERR_DEVICE; goto done; }
    error = libusb_kernel_driver_active(usb->handle, 0);
    if (error == 1) { status = ELAN_ERR_BUSY; goto done; }
    if (error < 0 && error != LIBUSB_ERROR_NOT_SUPPORTED) { status = usb_result(error); goto done; }
    error = libusb_claim_interface(usb->handle, 0);
    if (error != LIBUSB_SUCCESS) { status = usb_result(error); goto done; }
    usb->claimed = true;
    status = ELAN_OK;
done:
    if (list) libusb_free_device_list(list, 1);
    if (status == ELAN_OK) *result = usb;
    else elan_usb_close(usb);
    return status;
}

static int transfer(struct elan_usb *usb, uint8_t endpoint, uint8_t *data, size_t length, unsigned timeout_ms)
{
    int actual = 0;
    if (!usb || !usb->claimed || !data || length > INT_MAX || !timeout_ms)
        return ELAN_ERR_ARGUMENT;
    int result = libusb_bulk_transfer(usb->handle, endpoint, data, (int)length, &actual, timeout_ms);
    if (result != LIBUSB_SUCCESS) return usb_result(result);
    return actual == (int)length ? ELAN_OK : ELAN_ERR_PROTOCOL;
}

static int usb_write(void *context, const uint8_t *data, size_t length, unsigned timeout_ms)
{
    return transfer(context, 0x01, (uint8_t *)data, length, timeout_ms);
}

static int usb_read(void *context, uint8_t endpoint, uint8_t *data, size_t length, unsigned timeout_ms)
{
    if (endpoint != 0x82 && endpoint != 0x83) return ELAN_ERR_ARGUMENT;
    return transfer(context, endpoint, data, length, timeout_ms);
}

static void usb_sleep(void *context, unsigned milliseconds)
{
    (void)context;
    struct timespec delay = { .tv_sec = milliseconds / 1000, .tv_nsec = (long)(milliseconds % 1000) * 1000000L };
    nanosleep(&delay, NULL);
}

struct elan_transport elan_usb_transport(struct elan_usb *usb)
{
    return (struct elan_transport){ .context = usb, .write = usb_write, .read = usb_read, .sleep_ms = usb_sleep };
}
