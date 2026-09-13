// Diagnostic only: observes trackpad input and never sends or suppresses events.
// Private ABI reference: https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <math.h>

typedef struct { float x, y; } WMPoint;
typedef struct { WMPoint position, velocity; } WMVector;
typedef struct {
    int frame; double timestamp; int identifier, state, finger, hand;
    WMVector normalized; float size; int unknown; float angle, major, minor;
    WMVector absolute; int reserved[2]; float density;
} WMContact;
typedef void *WMDevice;
typedef int (*WMCallback)(WMDevice, WMContact *, int, double, int);

@interface WMProbe : NSObject
@property int count;
@property BOOL tracking, rejected;
@property double startTime, lastTime, startX, startY, x, y;
@property NSNumber *display;
@property NSString *app;
@end
@implementation WMProbe
@end
static NSMutableDictionary<NSValue *, WMProbe *> *streams;

static int contactFrame(WMDevice device, WMContact *contacts, int count, double timestamp, int frame) {
    // Copy and validate before leaving the callback; framework-owned pointers expire on return.
    if (count < 0 || count > 16 || (count && !contacts)) return 0;
    int active = 0; double x = 0, y = 0; BOOL valid = YES;
    for (int i = 0; i < count; i++) {
        WMContact c = contacts[i];
        if (c.state < 0 || c.state > 7 || !isfinite(c.normalized.position.x) ||
            !isfinite(c.normalized.position.y) || c.normalized.position.x < 0 ||
            c.normalized.position.x > 1 || c.normalized.position.y < 0 || c.normalized.position.y > 1) {
            valid = NO; break;
        }
        if (c.state == 3 || c.state == 4) {
            active++; x += c.normalized.position.x; y += c.normalized.position.y;
        }
    }
    if (active) { x /= active; y /= active; }
    int fingers = active; double cx = x, cy = y;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSValue *key = [NSValue valueWithPointer:device];
        WMProbe *s = streams[key];
        if (!s) { s = [WMProbe new]; streams[key] = s; }
        if (!valid) { s.rejected = YES; printf("private invalid-ABI-frame\n"); return; }
        if (timestamp - s.lastTime > 0.25 && s.tracking) {
            printf("private cancelled=lost-stream\n"); s.tracking = NO; s.rejected = YES;
        }
        s.lastTime = timestamp;
        if (fingers != s.count) {
            printf("private device=%p frame=%d contacts=%d active=%d\n", device, frame, count, fingers);
            s.count = fingers;
        }
        if ([NSEvent pressedMouseButtons] != 0 || fingers > 3) s.rejected = YES;
        if (fingers == 3 && !s.tracking && !s.rejected) {
            s.tracking = YES; s.startTime = timestamp;
            s.startX = cx; s.startY = cy;
            s.app = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"unknown";
            for (NSScreen *screen in NSScreen.screens) {
                if (NSPointInRect(NSEvent.mouseLocation, screen.frame)) s.display = screen.deviceDescription[@"NSScreenNumber"];
            }
            printf("private began fingers=3 app=%s display=%s\n", s.app.UTF8String, s.display.description.UTF8String);
        }
        if (fingers == 3 && s.tracking) { s.x = cx; s.y = cy; }
        if (fingers == 0) {
            if (s.tracking) {
                double dx = s.x - s.startX, dy = s.y - s.startY;
                BOOL accepted = !s.rejected && fabs(dx) >= 0.15 && fabs(dx) > fabs(dy) * 1.8 && timestamp - s.startTime < 1.5;
                printf("private ended result=%s dx=%.3f dy=%.3f display=%s app=%s\n",
                       accepted ? (dx < 0 ? "left" : "right") : "cancelled", dx, dy,
                       s.display.description.UTF8String, s.app.UTF8String);
            }
            s.tracking = NO; s.rejected = NO;
        }
    });
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        streams = [NSMutableDictionary new];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [NSApp finishLaunching];
        printf("public accessibility=%d input-monitoring=%d\n", AXIsProcessTrusted(), CGPreflightListenEventAccess());
        NSEventMask mask = NSEventMaskScrollWheel | NSEventMaskSwipe | NSEventMaskGesture | NSEventMaskBeginGesture | NSEventMaskEndGesture;
        id monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
            if (event.type == NSEventTypeScrollWheel && event.phase == NSEventPhaseChanged) return;
            NSUInteger touchCount = 0;
            if (event.type != NSEventTypeScrollWheel) touchCount = [event touchesMatchingPhase:NSTouchPhaseTouching inView:nil].count;
            printf("public type=%lu phase=%lu momentum=%lu touches=%lu\n", event.type, event.phase, event.momentumPhase, touchCount);
        }];
        void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
        CFArrayRef (*createList)(void) = dlsym(handle, "MTDeviceCreateList");
        void (*registerCallback)(WMDevice, WMCallback) = dlsym(handle, "MTRegisterContactFrameCallback");
        void (*start)(WMDevice, int) = dlsym(handle, "MTDeviceStart");
        void (*stop)(WMDevice) = dlsym(handle, "MTDeviceStop");
        int (*dimensions)(WMDevice, int *, int *) = dlsym(handle, "MTDeviceGetSensorDimensions");
        if (!handle || !createList || !registerCallback || !start || !stop || !dimensions) {
            fprintf(stderr, "Private backend unavailable: missing framework or symbols\n"); return 1;
        }
        CFArrayRef devices = createList();
        NSMutableArray<NSValue *> *started = [NSMutableArray new];
        if (devices) for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
            WMDevice device = (WMDevice)CFArrayGetValueAtIndex(devices, i);
            int rows = 0, columns = 0; dimensions(device, &rows, &columns);
            printf("private device=%p sensor=%dx%d contact-size=%zu\n", device, rows, columns, sizeof(WMContact));
            if (rows < 10) continue;
            registerCallback(device, contactFrame); start(device, 0);
            [started addObject:[NSValue valueWithPointer:device]];
        }
        printf("ready trackpads=%lu duration=%s seconds; observe only\n", started.count, argc > 1 ? argv[1] : "180");
        double duration = argc > 1 ? atof(argv[1]) : 180;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MAX(1, MIN(duration, 1800))]];
        for (NSValue *device in started) stop(device.pointerValue);
        if (monitor) [NSEvent removeMonitor:monitor];
        // Keep the private library and callback device ownership until process exit: teardown ABI is undocumented.
        return started.count ? 0 : 2;
    }
}
