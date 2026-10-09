#include "chrome/browser/winmux/one_password_native_messaging.h"

#include "base/files/file_util.h"

namespace winmux {

base::FilePath WithDesktopAppManifestFallback(
    const base::FilePath& standard_manifest,
    const std::string& host_name,
    bool allow_user_level_hosts,
    const base::FilePath& application_support) {
  if (!standard_manifest.empty() || !allow_user_level_hosts ||
      (host_name != "com.1password.1password" &&
       host_name != "com.openai.codexextension") ||
      !application_support.IsAbsolute()) {
    return standard_manifest;
  }

  // Desktop apps install Chrome registrations even when WinMux has a custom
  // --user-data-dir. Read that registration in place so app updates or removal
  // take effect on the next connection, without copying stale paths or changing
  // extension origins. Chromium still validates the manifest and enterprise
  // policy; native hosts still apply their own browser authentication.
  for (const char* product : {"Google/Chrome", "Chromium"}) {
    auto path = application_support.AppendASCII(product)
                    .AppendASCII("NativeMessagingHosts")
                    .AppendASCII(host_name + ".json");
    if (base::PathExists(path) && !base::DirectoryExists(path)) {
      return path;
    }
  }
  return {};
}

}  // namespace winmux
