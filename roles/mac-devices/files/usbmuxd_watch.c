// usbmuxd_watch.c
//
// The usbmuxd_watch binary is universal (arm64 + x86_64), runs on macOS 13.0+ and is
// statically linked with libplist 2.7.0, libimobiledevice-glue 1.3.2 and libusbmuxd 2.1.1.
// scripts/build_usbmuxd_watch.sh builds it from this file and the pinned release tarballs
// of the libraries; CI builds it the same way and tests it with tests/usbmuxd_watch_test.sh.
#include <stdio.h>
#include <unistd.h>
#include <usbmuxd.h>

static void on_event(const usbmuxd_event_t *event, void *user_data) {
    // usbmuxd also reports devices reachable over Wi-Fi, with the same udid as over USB:
    // a Wi-Fi drop of a device still connected by cable must not detach it
    if (event->device.conn_type != CONNECTION_TYPE_USB) {
        return;
    }
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

