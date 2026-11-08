/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Experimental USB-only bridge; stdout is a private binary pipe, not a log. */
#include "elan0c4f_usb.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

static volatile sig_atomic_t cancelled;
static void interrupt(int number) { (void)number; cancelled = 1; }

static bool send_result(int result, const struct elan_frame *frame)
{
    if (result != ELAN_OK) return printf("ERR %d\n", result) > 0 && fflush(stdout) == 0;
    if (!frame) return puts("OK") >= 0 && fflush(stdout) == 0;
    if (printf("FRAME %zu\n", sizeof(*frame)) < 0 ||
        fwrite(frame, 1, sizeof(*frame), stdout) != sizeof(*frame)) return false;
    return fflush(stdout) == 0;
}

int main(int argc, char **argv)
{
    struct elan_usb *usb = NULL;
    struct elan_device device = {0};
    struct elan_frame frame = {0};
    struct rlimit no_core = {0, 0};
    char line[64];
    int status, result = 1;
    (void)argv;
    if (argc != 1 || setrlimit(RLIMIT_CORE, &no_core) != 0) return 1;
    struct sigaction action = {0};
    action.sa_handler = interrupt;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) return 1;
    signal(SIGPIPE, SIG_IGN);
    status = elan_usb_open(&usb);
    if (status == ELAN_OK) status = elan_initialize(&device, elan_usb_transport(usb));
    if (status != ELAN_OK) { send_result(status, NULL); goto done; }
    if (printf("READY %04x\n", device.firmware) < 0 || fflush(stdout) != 0) goto done;
    while (!cancelled && fgets(line, sizeof(line), stdin)) {
        unsigned timeout = 0;
        char extra;
        if (strcmp(line, "Q\n") == 0) { result = 0; break; }
        if (strcmp(line, "C\n") == 0) {
            status = elan_calibrate(&device, &frame, 50);
            if (!send_result(status, status == ELAN_OK ? &frame : NULL)) break;
            elan_clear_frame(&frame);
        } else if (strcmp(line, "R\n") == 0) {
            status = elan_read_frame(&device, &frame, 2000);
            if (!send_result(status, status == ELAN_OK ? &frame : NULL)) break;
            elan_clear_frame(&frame);
        } else if (sscanf(line, "W %u %c", &timeout, &extra) == 1 && timeout >= 100 && timeout <= 90000) {
            status = elan_wait_finger(&device, timeout);
            if (!send_result(status, NULL)) break;
        } else {
            if (!send_result(ELAN_ERR_ARGUMENT, NULL)) break;
        }
    }
done:
    elan_clear_frame(&frame);
    if (device.ready && elan_stop(&device) != ELAN_OK) result = 1;
    elan_usb_close(usb);
    return result;
}
