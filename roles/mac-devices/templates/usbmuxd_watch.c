// usbmuxd_watch.c
#include <stdio.h>
#include <unistd.h>
#include <usbmuxd.h>

static void on_event(const usbmuxd_event_t *event, void *user_data) {
    switch (event->event) {
        case UE_DEVICE_ADD:
            printf("ATTACH udid=%s handle=%u\n", event->device.udid, event->device.handle);
            break;
        case UE_DEVICE_REMOVE:
            printf("DETACH udid=%s handle=%u\n", event->device.udid, event->device.handle);
            break;
        case UE_DEVICE_PAIRED:
            printf("PAIRED udid=%s\n", event->device.udid);
            break;
    }
    fflush(stdout);
}

int main(void) {
    usbmuxd_subscription_context_t ctx;
    int rc = usbmuxd_events_subscribe(&ctx, on_event, NULL);
    if (rc != 0) {
        fprintf(stderr, "usbmuxd_events_subscribe failed: %d\n", rc);
        return 1;
    }
    for (;;) sleep(3600);
}

