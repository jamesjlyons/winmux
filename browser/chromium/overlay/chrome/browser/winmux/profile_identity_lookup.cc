#include "chrome/browser/winmux/profile_identity_lookup.h"

#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/common/chrome_constants.h"

namespace winmux {
base::FilePath FindRegisteredProfileIdentity(
    const std::vector<base::FilePath>& registered_paths,
    const std::string& profile_uuid,
    const base::FilePath& initial_match) {
  const auto requested = base::Uuid::ParseCaseInsensitive(profile_uuid);
  if (!requested.is_valid() ||
      registered_paths.size() > kMaximumProfileIdentityCandidates) {
    return {};
  }
  base::FilePath match = initial_match;
  for (const auto& path : registered_paths) {
    std::string preferences;
    if (!base::ReadFileToStringWithMaxSize(
            path.Append(chrome::kPreferencesFilename), &preferences,
            kMaximumProfileIdentityPreferencesBytes)) {
      continue;
    }
    auto value = base::JSONReader::Read(preferences, base::JSON_PARSE_RFC);
    if (!value || !value->is_dict()) {
      continue;
    }
    const auto* stored =
        value->GetDict().FindStringByDottedPath("winmux.profile_uuid");
    if (!stored || base::Uuid::ParseCaseInsensitive(*stored) != requested) {
      continue;
    }
    // Copied profiles can contain the same UUID. Never choose an account based
    // on enumeration order, including when the first match was readable.
    if (!match.empty() && match != path) {
      return {};
    }
    match = path;
  }
  return match;
}
}  // namespace winmux
