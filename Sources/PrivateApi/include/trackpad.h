#ifndef WINMUX_TRACKPAD_H
#define WINMUX_TRACKPAD_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int32_t identifier;
    double x, y;
} WMTrackpadContact;

// Contacts are borrowed for the duration of the callback only. Delivery is on
// framework threads; callers must copy before returning and never block on UI.
typedef void (*WMTrackpadCallback)(uintptr_t device, double timestamp,
    const WMTrackpadContact *contacts, int count, bool valid, void *context);

// One process-wide subscription. Start/stop must be serialized by the caller.
// Returns a device count, or -1 when the private API is unavailable.
int WMTrackpadStart(WMTrackpadCallback callback, void *context);
void WMTrackpadStop(void);

#endif
