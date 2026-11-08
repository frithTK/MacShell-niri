/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "elan0c4f_usb.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

static volatile sig_atomic_t cancelled;
static void on_interrupt(int signal_number) { (void)signal_number; cancelled = 1; }

int main(int argc, char **argv)
{
    bool capture = false;
    int status, exit_code = 1;
    struct elan_usb *usb = NULL;
    struct elan_device device = {0};
    struct elan_frame background = {0}, sample = {0};
    struct rlimit no_core = {0, 0};
    if (argc == 2 && strcmp(argv[1], "--capture") == 0) capture = true;
    else if (argc != 1) { fprintf(stderr, "Usage: %s [--capture]\n", argv[0]); return 2; }
    if (setrlimit(RLIMIT_CORE, &no_core) != 0) { fprintf(stderr, "Cannot disable core dumps\n"); return 1; }
    struct sigaction action = {0};
    action.sa_handler = on_interrupt;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) return 1;

    status = elan_usb_open(&usb);
    if (status != ELAN_OK) { fprintf(stderr, "Reader unavailable (code %d)\n", status); goto done; }
    status = elan_initialize(&device, elan_usb_transport(usb));
    if (status != ELAN_OK) { fprintf(stderr, "Reader initialization failed (code %d)\n", status); goto done; }
    printf("READER_READY 04f3:0c4f firmware=%04x size=%dx%d\n", device.firmware, ELAN_FRAME_WIDTH, ELAN_FRAME_HEIGHT);
    fflush(stdout);
    if (!capture) { exit_code = 0; goto done; }
    puts("CALIBRATING: keep the sensor clear"); fflush(stdout);
    status = elan_calibrate(&device, &background, 50);
    if (status != ELAN_OK || cancelled) { fprintf(stderr, "Calibration stopped (code %d)\n", status); goto done; }
    puts("WAITING_FOR_FINGER"); fflush(stdout);
    status = elan_wait_finger(&device, 60000);
    if (status != ELAN_OK || cancelled) { fprintf(stderr, "Finger not captured (code %d)\n", status); goto done; }
    status = elan_read_frame(&device, &sample, 2000);
    if (status != ELAN_OK || cancelled) { fprintf(stderr, "Capture stopped (code %d)\n", status); goto done; }
    puts("CAPTURE_OK: frame processed in memory only");
    exit_code = 0;
done:
    if (device.ready && elan_stop(&device) != ELAN_OK) {
        fprintf(stderr, "Reader did not confirm stop\n");
        exit_code = 1;
    }
    elan_clear_frame(&background);
    elan_clear_frame(&sample);
    elan_usb_close(usb);
    return exit_code;
}
