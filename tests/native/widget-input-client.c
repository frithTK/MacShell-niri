// Minimal client bindings for the public wlr-virtual-pointer-v1/v2 protocol.
// Protocol: https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-virtual-pointer-unstable-v1.xml
// The client sends input only to the probe's guarded test area.
#include <wayland-client.h>
#include <linux/input-event-codes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const struct wl_interface pointer_interface;
static const struct wl_interface *create_types[] = {&wl_seat_interface, &pointer_interface};
static const struct wl_interface *create_output_types[] = {&wl_seat_interface, &wl_output_interface, &pointer_interface};
static const struct wl_message manager_requests[] = {
    {"create_virtual_pointer", "?on", create_types}, {"destroy", "", NULL},
    {"create_virtual_pointer_with_output", "2?o?on", create_output_types},
};
static const struct wl_interface manager_interface = {"zwlr_virtual_pointer_manager_v1", 2, 3, manager_requests, 0, NULL};
static const struct wl_message pointer_requests[] = {
    {"motion", "uff", NULL}, {"motion_absolute", "uuuuu", NULL}, {"button", "uuu", NULL},
    {"axis", "uuf", NULL}, {"frame", "", NULL}, {"axis_source", "u", NULL},
    {"axis_stop", "uu", NULL}, {"axis_discrete", "uufi", NULL}, {"destroy", "", NULL},
};
static const struct wl_interface pointer_interface = {"zwlr_virtual_pointer_v1", 2, 9, pointer_requests, 0, NULL};

struct output { struct wl_output *proxy; char name[256]; };
static struct output outputs[32];
static size_t output_count;
static struct wl_proxy *manager;
static uint32_t manager_version;
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sub, const char *make, const char *model, int32_t transform) {}
static void mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {}
static void done(void *d, struct wl_output *o) {}
static void scale(void *d, struct wl_output *o, int32_t factor) {}
static void name(void *d, struct wl_output *o, const char *value) { snprintf(((struct output *)d)->name, 256, "%s", value); }
static void description(void *d, struct wl_output *o, const char *value) {}
static const struct wl_output_listener output_listener = {geometry, mode, done, scale, name, description};
static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    if (strcmp(interface, manager_interface.name) == 0) {
        manager_version = version < 2 ? version : 2;
        manager = wl_registry_bind(registry, id, &manager_interface, manager_version);
    } else if (strcmp(interface, "wl_output") == 0 && version >= 4 && output_count < 32) {
        struct output *output = &outputs[output_count++];
        output->proxy = wl_registry_bind(registry, id, &wl_output_interface, 4);
        wl_output_add_listener(output->proxy, &output_listener, output);
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {}
static const struct wl_registry_listener registry_listener = {global, removed};
static uint32_t now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint32_t)((uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000);
}
static void frame(struct wl_proxy *pointer) { wl_proxy_marshal_flags(pointer, 4, NULL, 2, 0); }
static void motion(struct wl_proxy *pointer, uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    wl_proxy_marshal_flags(pointer, 1, NULL, 2, 0, now(), x, y, width, height); frame(pointer);
}
static void button(struct wl_proxy *pointer, uint32_t code, uint32_t state) {
    wl_proxy_marshal_flags(pointer, 2, NULL, 2, 0, now(), code, state); frame(pointer);
}
static unsigned number(const char *text, unsigned limit) {
    char *end;
    unsigned long value = strtoul(text, &end, 10);
    if (*text == '-' || *end || !*text || value > limit) { fprintf(stderr, "Invalid coordinate\n"); exit(2); }
    return (unsigned)value;
}
int main(int argc, char **argv) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "Wayland display unavailable\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0) return 1;
    if (argc == 2 && strcmp(argv[1], "--list") == 0) {
        printf("virtual-pointer-v%u\n", manager_version);
        wl_display_disconnect(display);
        return manager_version >= 2 ? 0 : 77;
    }
    if (argc != 9 && argc != 11) { fprintf(stderr, "Expected click/drag, output and bounded coordinates\n"); return 2; }
    if (manager_version < 2) { fprintf(stderr, "Virtual pointer v2 unavailable\n"); return 77; }
    struct wl_output *output = NULL;
    for (size_t i = 0; i < output_count; i++) if (strcmp(outputs[i].name, argv[2]) == 0) output = outputs[i].proxy;
    if (!output) { fprintf(stderr, "Probe output unavailable\n"); return 1; }
    unsigned x = number(argv[3], 100000), y = number(argv[4], 100000);
    unsigned width = number(argv[5], 100000), height = number(argv[6], 100000);
    if (!width || !height || x >= width || y >= height) return 2;
    unsigned code = strcmp(argv[7], "right") == 0 ? BTN_RIGHT : BTN_LEFT;
    // Last argument is an explicit guard word supplied by the Python probe.
    if (strcmp(argv[argc - 1], "owned-probe") != 0) return 2;
    int dragging = strcmp(argv[1], "drag") == 0 && argc == 11;
    if (!dragging && (strcmp(argv[1], "click") != 0 || argc != 9)) return 2;
    unsigned target_x = dragging ? number(argv[8], width - 1) : x;
    unsigned target_y = dragging ? number(argv[9], height - 1) : y;
    struct wl_proxy *pointer = wl_proxy_marshal_flags(manager, 2, &pointer_interface, 2, 0, NULL, output, NULL);
    // Send the bounded sequence in one batch so another pointing device cannot
    // move a button press away from its guarded target between client waits.
    motion(pointer, x, y, width, height);
    button(pointer, code, WL_POINTER_BUTTON_STATE_PRESSED);
    if (dragging) {
        motion(pointer, (x + target_x) / 2, (y + target_y) / 2, width, height);
        motion(pointer, target_x, target_y, width, height);
    }
    button(pointer, code, WL_POINTER_BUTTON_STATE_RELEASED); wl_display_roundtrip(display);
    wl_proxy_marshal_flags(pointer, 8, NULL, 2, WL_MARSHAL_FLAG_DESTROY);
    wl_proxy_marshal_flags(manager, 1, NULL, 2, WL_MARSHAL_FLAG_DESTROY);
    wl_display_roundtrip(display); wl_display_disconnect(display);
    return 0;
}
