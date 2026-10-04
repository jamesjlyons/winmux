#include "chrome/browser/winmux/profile_identity_lookup.h"

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "chrome/common/chrome_constants.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace winmux {
namespace {
constexpr char kProfileUUID[] = "7ea6d1b1-b9dc-401c-a6ec-7d75cfbf67ea";
constexpr char kOtherUUID[] = "f6b96f9b-f3f6-438c-bf9a-b59c5f97b096";

class ProfileIdentityLookupTest : public testing::Test {
 protected:
  void SetUp() override { ASSERT_TRUE(directory_.CreateUniqueTempDir()); }

  base::FilePath MakeProfile(const std::string& name, const std::string& uuid) {
    auto path = directory_.GetPath().AppendASCII(name);
    EXPECT_TRUE(base::CreateDirectory(path));
    EXPECT_TRUE(
        base::WriteFile(path.Append(chrome::kPreferencesFilename),
                        "{\"winmux\":{\"profile_uuid\":\"" + uuid + "\"}}"));
    return path;
  }

  base::ScopedTempDir directory_;
};

TEST_F(ProfileIdentityLookupTest, FindsOnlyRequestedRegisteredIdentity) {
  auto primary = MakeProfile("Default", kOtherUUID);
  auto secondary = MakeProfile("Profile 1", kProfileUUID);
  EXPECT_EQ(FindRegisteredProfileIdentity({primary, secondary}, kProfileUUID),
            secondary);
  EXPECT_TRUE(FindRegisteredProfileIdentity({primary}, kProfileUUID).empty());
  EXPECT_EQ(FindRegisteredProfileIdentity(
                {secondary}, "7EA6D1B1-B9DC-401C-A6EC-7D75CFBF67EA"),
            secondary);
}

TEST_F(ProfileIdentityLookupTest, RejectsAmbiguousCopiedIdentity) {
  auto first = MakeProfile("Default", kProfileUUID);
  auto second = MakeProfile("Profile 1", kProfileUUID);
  EXPECT_TRUE(
      FindRegisteredProfileIdentity({first, second}, kProfileUUID).empty());
}

TEST_F(ProfileIdentityLookupTest, RejectsUnloadedDuplicateOfLoadedMatch) {
  auto loaded = MakeProfile("Default", kProfileUUID);
  auto unloaded = MakeProfile("Profile 1", kProfileUUID);
  EXPECT_TRUE(
      FindRegisteredProfileIdentity({unloaded}, kProfileUUID, loaded).empty());
}

TEST_F(ProfileIdentityLookupTest, PreservesLoadedMatchWhenOthersDiffer) {
  auto loaded = MakeProfile("Default", kProfileUUID);
  auto unloaded = MakeProfile("Profile 1", kOtherUUID);
  EXPECT_EQ(FindRegisteredProfileIdentity({unloaded}, kProfileUUID, loaded),
            loaded);
  EXPECT_EQ(FindRegisteredProfileIdentity({}, kProfileUUID, loaded), loaded);
}

TEST_F(ProfileIdentityLookupTest, RejectsMalformedAndDeletedPreferences) {
  auto path = MakeProfile("Profile 1", kProfileUUID);
  EXPECT_TRUE(
      base::WriteFile(path.Append(chrome::kPreferencesFilename), "{broken"));
  EXPECT_TRUE(FindRegisteredProfileIdentity({path}, kProfileUUID).empty());
  EXPECT_TRUE(base::WriteFile(path.Append(chrome::kPreferencesFilename),
                              "{\"winmux\":{\"profile_uuid\":\"invalid\"}}"));
  EXPECT_TRUE(FindRegisteredProfileIdentity({path}, kProfileUUID).empty());
  EXPECT_TRUE(base::DeleteFile(path.Append(chrome::kPreferencesFilename)));
  EXPECT_TRUE(FindRegisteredProfileIdentity({path}, kProfileUUID).empty());
}

TEST_F(ProfileIdentityLookupTest, BoundsFileSizeAndCandidateCount) {
  auto path = MakeProfile("Profile 1", kProfileUUID);
  std::string oversized(kMaximumProfileIdentityPreferencesBytes + 1, ' ');
  EXPECT_TRUE(
      base::WriteFile(path.Append(chrome::kPreferencesFilename), oversized));
  EXPECT_TRUE(FindRegisteredProfileIdentity({path}, kProfileUUID).empty());
  path = MakeProfile("Profile 1", kProfileUUID);
  std::vector<base::FilePath> excessive(kMaximumProfileIdentityCandidates + 1,
                                        path);
  EXPECT_TRUE(FindRegisteredProfileIdentity(excessive, kProfileUUID).empty());
  EXPECT_TRUE(FindRegisteredProfileIdentity({path}, "invalid").empty());
}
}  // namespace
}  // namespace winmux
