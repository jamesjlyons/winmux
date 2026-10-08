#ifndef CHROME_BROWSER_WINMUX_TAB_CREATION_TRACE_H_
#define CHROME_BROWSER_WINMUX_TAB_CREATION_TRACE_H_
#include <string>
class BrowserWindowInterface;
namespace winmux {
// Opt-in diagnostics contain only operation/surface IDs and monotonic times.
void TraceTabCreation(const std::string& operation, const char* stage,
                      const std::string& surface = "");
void TraceTabSurface(const std::string& surface, const char* stage);
void TraceTabPresentation(BrowserWindowInterface* browser,
                          const std::string& surface);
}
#endif
