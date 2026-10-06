// usbmuxd_watch.c
//
// The usbmuxd_watch binary is universal (arm64 + x86_64), runs on macOS 13.0+ and is
// statically linked. Each slice is built with libplist 2.7.0, libimobiledevice-glue 1.3.2
// and libusbmuxd 2.1.1, each configured for ARCH (arm64 or x86_64, HOST aarch64 or x86_64) with:
//   CC="clang -arch ARCH -mmacosx-version-min=13.0" ./configure --host=HOST-apple-darwin --disable-shared --enable-static
// then:
//   clang -arch ARCH -mmacosx-version-min=13.0 usbmuxd_watch.c libusbmuxd-2.0.a libimobiledevice-glue-1.0.a libplist-2.0.a -o usbmuxd_watch.ARCH
//   lipo -create usbmuxd_watch.arm64 usbmuxd_watch.x86_64 -output usbmuxd_watch
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

