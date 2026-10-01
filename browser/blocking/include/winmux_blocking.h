#ifndef WINMUX_BLOCKING_H
#define WINMUX_BLOCKING_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct WMBlocker WMBlocker;
// All strings are UTF-8, with explicit lengths (no terminating NUL required).
// Nonempty views must reference live allocations for the duration of the call.
typedef struct { const uint8_t *data; size_t length; } WMStringView;
typedef enum { WM_OK = 0, WM_INVALID_INPUT = 1, WM_ENGINE_FAILURE = 2 } WMStatus;
typedef struct {
  WMStatus status;
  bool blocked;
  bool excepted;
  // Optional owned UTF-8 values; release with wm_string_free, including on error.
  char *redirect;
  char *rewritten_url;
} WMDecision;

// Build on a background sequence, retain the previous instance on failure.
WMBlocker *wm_blocker_create(WMStringView rules);
// Available in the chromium-bundled build; uses the embedded verified snapshot.
WMBlocker *wm_blocker_create_bundled(void);
// Queries may run concurrently; destruction requires all in-flight calls to end.
void wm_blocker_free(WMBlocker *blocker);
// source_url MUST come from trusted browser initiator context, never page input.
// Site/profile exceptions are resolved by the browser and supplied per request.
WMDecision wm_blocker_check(const WMBlocker *, WMStringView url,
                          WMStringView source_url, WMStringView request_type,
                          WMStringView method, bool site_enabled);
// Returned JSON carries declarative CSS, exceptions, and generic-hide state.
// No downloaded JavaScript or workspace-control API is exposed to documents.
char *wm_blocker_cosmetics(const WMBlocker *, WMStringView document_url, bool site_enabled);
// Bounded delta of newly seen DOM tokens: {"classes":[...],"ids":[...]}.
// Document exceptions/generichide are evaluated in the same engine snapshot.
char *wm_blocker_dynamic_cosmetics(const WMBlocker *, WMStringView document_url,
                                  WMStringView tokens_json, bool site_enabled);
void wm_string_free(char *value);

#ifdef __cplusplus
}
#endif
#endif
