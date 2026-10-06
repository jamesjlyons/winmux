#include "chrome/browser/winmux/one_password_native_messaging.h"

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace winmux {
namespace {
constexpr char kHost[] = "com.1password.1password";

class OnePasswordNativeMessagingTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    support_ = directory_.GetPath().AppendASCII("Application Support");
  }

  base::FilePath Register(const char* product) {
    auto path = support_.AppendASCII(product)
                    .AppendASCII("NativeMessagingHosts")
                    .AppendASCII("com.1password.1password.json");
    EXPECT_TRUE(base::CreateDirectory(path.DirName()));
    EXPECT_TRUE(base::WriteFile(path, "{}"));
    return path;
  }

  base::FilePath Find(const std::string& host = kHost, bool allowed = true) {
    return WithOnePasswordManifestFallback({}, host, allowed, support_);
  }

  base::ScopedTempDir directory_;
  base::FilePath support_;
};

TEST_F(OnePasswordNativeMessagingTest, FindsInstalledChromeRegistration) {
  auto path = Register("Google/Chrome");
  EXPECT_EQ(Find(), path);
}

TEST_F(OnePasswordNativeMessagingTest, FallsBackToChromiumRegistration) {
  auto chromium = Register("Chromium");
  EXPECT_EQ(Find(), chromium);
  auto chrome = Register("Google/Chrome");
  EXPECT_EQ(Find(), chrome);
}

TEST_F(OnePasswordNativeMessagingTest, PreservesExplicitUserOrSystemManifest) {
  Register("Google/Chrome");
  for (const char* name : {"WinMux Workspace", "System"}) {
    auto explicit_manifest = Register(name);
    EXPECT_EQ(WithOnePasswordManifestFallback(explicit_manifest, kHost, true,
                                             support_), explicit_manifest);
    EXPECT_EQ(WithOnePasswordManifestFallback(explicit_manifest, kHost, false,
                                             support_), explicit_manifest);
  }
}

TEST_F(OnePasswordNativeMessagingTest, RespectsUserLevelHostPolicy) {
  Register("Google/Chrome");
  Register("Chromium");
  EXPECT_TRUE(Find(kHost, false).empty());
}

TEST_F(OnePasswordNativeMessagingTest, DoesNotDiscoverOtherNativeHosts) {
  Register("Google/Chrome");
  for (const char* host : {"com.other.host", "com.1password.other", "",
                           "../com.1password.1password"}) {
    EXPECT_TRUE(Find(host).empty());
  }
}

TEST_F(OnePasswordNativeMessagingTest, DoesNotCreateOrCacheRegistrations) {
  EXPECT_TRUE(Find().empty());
  EXPECT_FALSE(base::PathExists(support_));
  auto path = Register("Google/Chrome");
  EXPECT_EQ(Find(), path);
  EXPECT_TRUE(base::DeleteFile(path));
  EXPECT_TRUE(Find().empty());
}

TEST_F(OnePasswordNativeMessagingTest, RejectsDirectoriesAndMissingBasePath) {
  auto path = Register("Google/Chrome");
  EXPECT_TRUE(base::DeleteFile(path));
  EXPECT_TRUE(base::CreateDirectory(path));
  EXPECT_TRUE(Find().empty());
  EXPECT_TRUE(WithOnePasswordManifestFallback({}, kHost, true, {}).empty());
  EXPECT_TRUE(WithOnePasswordManifestFallback(
      {}, kHost, true, base::FilePath("relative")).empty());
}
}  // namespace
}  // namespace winmux
