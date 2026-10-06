#include "chrome/browser/winmux/one_password_native_messaging.h"

#include "base/files/file_util.h"

namespace winmux {

base::FilePath WithOnePasswordManifestFallback(
    const base::FilePath& standard_manifest,
    const std::string& host_name,
    bool allow_user_level_hosts,
    const base::FilePath& application_support) {
  if (!standard_manifest.empty() || !allow_user_level_hosts ||
      host_name != "com.1password.1password" ||
      !application_support.IsAbsolute()) {
    return standard_manifest;
  }

  // 1Password installs its Chrome registration even when WinMux has a custom
  // --user-data-dir. Read that registration in place so app updates or removal
  // take effect on the next connection, without copying stale paths or changing
  // extension origins. Chromium still validates the manifest and enterprise
  // policy; 1Password still verifies this browser's real signature/trusted entry.
  for (const char* product : {"Google/Chrome", "Chromium"}) {
    auto path = application_support.AppendASCII(product)
                    .AppendASCII("NativeMessagingHosts")
                    .AppendASCII("com.1password.1password.json");
    if (base::PathExists(path) && !base::DirectoryExists(path)) {
      return path;
    }
  }
  return {};
}

}  // namespace winmux
