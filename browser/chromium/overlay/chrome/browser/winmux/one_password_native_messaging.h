#ifndef CHROME_BROWSER_WINMUX_ONE_PASSWORD_NATIVE_MESSAGING_H_
#define CHROME_BROWSER_WINMUX_ONE_PASSWORD_NATIVE_MESSAGING_H_

#include <string>

#include "base/files/file_path.h"

namespace winmux {

// Called on Chromium's native-messaging blocking runner, before its normal
// manifest validation and process launch. Never changes an explicit registration.
base::FilePath WithOnePasswordManifestFallback(
    const base::FilePath& standard_manifest,
    const std::string& host_name,
    bool allow_user_level_hosts,
    const base::FilePath& application_support);

}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_ONE_PASSWORD_NATIVE_MESSAGING_H_
