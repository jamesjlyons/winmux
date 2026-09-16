// The private ABI is isolated here. No private types escape into Swift.
#import <CoreFoundation/CoreFoundation.h>
#include "include/trackpad.h"
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, finger, hand;
    MTVector normalized;
    float size;
    int32_t unknown;
    float angle, major, minor;
    MTVector absolute;
    int32_t reserved[2];
    float density;
} MTContact;
typedef void *MTDevice;
typedef int (*MTCallback)(MTDevice, MTContact *, int, double, int);

static CFArrayRef (*createList)(void);
static int (*dimensions)(MTDevice, int *, int *);
static void (*registerCallback)(MTDevice, MTCallback);
static void (*unregisterCallback)(MTDevice, MTCallback);
static void (*startDevice)(MTDevice, int);
static void (*stopDevice)(MTDevice);
static void *framework;
static CFArrayRef devices;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static WMTrackpadCallback listener;
static void *listenerContext;

static int contactFrame(MTDevice device, MTContact *contacts, int count, double timestamp, int frame) {
    (void)frame;
    pthread_mutex_lock(&gate);
    if (!listener || !devices || !CFArrayContainsValue(devices, CFRangeMake(0, CFArrayGetCount(devices)), device)) {
        pthread_mutex_unlock(&gate);
        return 0;
    }
    WMTrackpadContact copied[16];
    int active = 0;
    bool valid = count >= 0 && count <= 16 && (!count || contacts) && isfinite(timestamp);
    if (valid) for (int i = 0; i < count; i++) {
        MTContact c = contacts[i];
        if (c.state < 0 || c.state > 7 || !isfinite(c.normalized.position.x) ||
            !isfinite(c.normalized.position.y) || c.normalized.position.x < 0 ||
            c.normalized.position.x > 1 || c.normalized.position.y < 0 || c.normalized.position.y > 1) {
            valid = false;
            break;
        }
        if (c.state == 3 || c.state == 4) {
            copied[active++] = (WMTrackpadContact){c.identifier, c.normalized.position.x, c.normalized.position.y};
        }
    }
    // Holding the gate through the short copy callback makes stop a lifetime
    // barrier for the Swift context, without assuming MTDeviceStop drains work.
    listener((uintptr_t)device, timestamp, copied, active, valid, listenerContext);
    pthread_mutex_unlock(&gate);
    return 0;
}

static bool loadFramework(void) {
    if (!framework) framework = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!framework) return false;
    createList = dlsym(framework, "MTDeviceCreateList");
    dimensions = dlsym(framework, "MTDeviceGetSensorDimensions");
    registerCallback = dlsym(framework, "MTRegisterContactFrameCallback");
    unregisterCallback = dlsym(framework, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(framework, "MTDeviceStart");
    stopDevice = dlsym(framework, "MTDeviceStop");
    return createList && dimensions && registerCallback && unregisterCallback && startDevice && stopDevice;
}

void WMTrackpadStop(void) {
    pthread_mutex_lock(&gate);
    listener = NULL;
    listenerContext = NULL;
    CFArrayRef stoppedDevices = devices;
    devices = NULL;
    pthread_mutex_unlock(&gate);
    if (!stoppedDevices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(stoppedDevices); i++) {
        MTDevice device = (MTDevice)CFArrayGetValueAtIndex(stoppedDevices, i);
        unregisterCallback(device, contactFrame);
        stopDevice(device);
    }
    CFRelease(stoppedDevices);
    // Intentionally do not dlclose: late framework callbacks may still return.
}

int WMTrackpadStart(WMTrackpadCallback callback, void *context) {
    WMTrackpadStop();
    if (!loadFramework()) return -1;
    CFArrayRef all = createList();
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (all) {
        for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
            MTDevice device = (MTDevice)CFArrayGetValueAtIndex(all, i);
            int rows = 0, columns = 0;
            dimensions(device, &rows, &columns);
            // Touch Bars and other thin sensors must never enter the recognizer.
            if (rows >= 10 && columns >= 10) CFArrayAppendValue(selected, device);
        }
        CFRelease(all);
    }
    pthread_mutex_lock(&gate);
    devices = selected;
    listener = callback;
    listenerContext = context;
    pthread_mutex_unlock(&gate);
    int count = (int)CFArrayGetCount(selected);
    for (int i = 0; i < count; i++) {
        MTDevice device = (MTDevice)CFArrayGetValueAtIndex(selected, i);
        registerCallback(device, contactFrame);
        startDevice(device, 0);
    }
    return count;
}
