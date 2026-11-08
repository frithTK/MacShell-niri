/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef ELAN0C4F_USB_H
#define ELAN0C4F_USB_H
#include "elan0c4f.h"

struct elan_usb;
int elan_usb_open(struct elan_usb **result);
struct elan_transport elan_usb_transport(struct elan_usb *usb);
void elan_usb_close(struct elan_usb *usb);

#endif
