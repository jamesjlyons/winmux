#ifndef CHROME_BROWSER_WINMUX_PROFILE_IDENTITY_LOOKUP_H_
#define CHROME_BROWSER_WINMUX_PROFILE_IDENTITY_LOOKUP_H_

#include <cstddef>
#include <string>
#include <vector>

#include "base/files/file_path.h"

namespace winmux {
inline constexpr size_t kMaximumProfileIdentityCandidates = 64;
inline constexpr size_t kMaximumProfileIdentityPreferencesBytes =
    16 * 1024 * 1024;

// Runs on a blocking worker. Callers supply only registered profile paths and
// must recheck registration and the loaded profile's UUID before using a match.
// initial_match is a registered loaded profile whose in-memory UUID matched.
// Missing or ambiguous identities return an empty path.
base::FilePath FindRegisteredProfileIdentity(
    const std::vector<base::FilePath>& registered_paths,
    const std::string& profile_uuid,
    const base::FilePath& initial_match = {});
}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_PROFILE_IDENTITY_LOOKUP_H_
