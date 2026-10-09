#include "chrome/browser/winmux/one_password_native_messaging.h"

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace winmux {
namespace {
class DesktopAppNativeMessagingTest : public testing::TestWithParam<const char*> {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    support_ = directory_.GetPath().AppendASCII("Application Support");
  }

  base::FilePath Register(const char* product, const std::string& host) {
    auto path = support_.AppendASCII(product)
                    .AppendASCII("NativeMessagingHosts")
                    .AppendASCII(host + ".json");
    EXPECT_TRUE(base::CreateDirectory(path.DirName()));
    EXPECT_TRUE(base::WriteFile(path, "{}"));
    return path;
  }

  base::FilePath Register(const char* product) {
    return Register(product, GetParam());
  }

  base::FilePath Find(bool allowed = true) {
    return WithDesktopAppManifestFallback({}, GetParam(), allowed, support_);
  }

  base::ScopedTempDir directory_;
  base::FilePath support_;
};

TEST_P(DesktopAppNativeMessagingTest, FindsInstalledChromeRegistration) {
  auto path = Register("Google/Chrome");
  EXPECT_EQ(Find(), path);
}

TEST_P(DesktopAppNativeMessagingTest, FallsBackToChromiumRegistration) {
  auto chromium = Register("Chromium");
  EXPECT_EQ(Find(), chromium);
  auto chrome = Register("Google/Chrome");
  EXPECT_EQ(Find(), chrome);
}

TEST_P(DesktopAppNativeMessagingTest, PreservesExplicitUserOrSystemManifest) {
  Register("Google/Chrome");
  for (const char* name : {"WinMux Workspace", "System"}) {
    auto explicit_manifest = Register(name);
    EXPECT_EQ(WithDesktopAppManifestFallback(explicit_manifest, GetParam(), true,
                                            support_),
              explicit_manifest);
    EXPECT_EQ(WithDesktopAppManifestFallback(explicit_manifest, GetParam(), false,
                                            support_),
              explicit_manifest);
  }
}

TEST_P(DesktopAppNativeMessagingTest, RespectsUserLevelHostPolicy) {
  Register("Google/Chrome");
  Register("Chromium");
  EXPECT_TRUE(Find(false).empty());
}

TEST_P(DesktopAppNativeMessagingTest, DoesNotDiscoverOtherNativeHosts) {
  for (const char* host : {"com.other.host", "com.1password.other", "",
                          "com.openai.other", "com.openai.codexextension.beta",
                          "../com.openai.codexextension"}) {
    Register("Google/Chrome", host);
    EXPECT_TRUE(WithDesktopAppManifestFallback({}, host, true, support_).empty());
  }
}

TEST_P(DesktopAppNativeMessagingTest, DoesNotCreateOrCacheRegistrations) {
  EXPECT_TRUE(Find().empty());
  EXPECT_FALSE(base::PathExists(support_));
  auto path = Register("Google/Chrome");
  EXPECT_EQ(Find(), path);
  EXPECT_TRUE(base::DeleteFile(path));
  EXPECT_TRUE(Find().empty());
}

TEST_P(DesktopAppNativeMessagingTest, RejectsDirectoriesAndMissingBasePath) {
  auto path = Register("Google/Chrome");
  EXPECT_TRUE(base::DeleteFile(path));
  EXPECT_TRUE(base::CreateDirectory(path));
  EXPECT_TRUE(Find().empty());
  EXPECT_TRUE(WithDesktopAppManifestFallback({}, GetParam(), true, {}).empty());
  EXPECT_TRUE(WithDesktopAppManifestFallback(
      {}, GetParam(), true, base::FilePath("relative")).empty());
}

TEST_P(DesktopAppNativeMessagingTest, DoesNotReturnAnotherAppsRegistration) {
  Register("Google/Chrome", std::string(GetParam()) == "com.openai.codexextension"
                                ? "com.1password.1password"
                                : "com.openai.codexextension");
  EXPECT_TRUE(Find().empty());
}

INSTANTIATE_TEST_SUITE_P(
    DesktopApps,
    DesktopAppNativeMessagingTest,
    testing::Values("com.1password.1password", "com.openai.codexextension"));
}  // namespace
}  // namespace winmux
