#include "chrome/browser/winmux/sidebar_favicon.h"

#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/resource/resource_scale_factor.h"
#include "ui/gfx/image/image_png_rep.h"

namespace winmux {
namespace {

class SidebarFaviconTest : public testing::Test {
 private:
  ui::test::ScopedSetSupportedResourceScaleFactors scales_{
      {ui::k100Percent, ui::k200Percent}};
};

gfx::ImageSkiaRep IconRep(int pixels, float scale, SkColor color) {
  SkBitmap bitmap;
  bitmap.allocN32Pixels(pixels, pixels);
  bitmap.eraseColor(color);
  return gfx::ImageSkiaRep(bitmap, scale);
}

SkBitmap DecodeIcon(const gfx::Image& image) {
  std::string bytes;
  EXPECT_TRUE(base::Base64Decode(EncodeSidebarFavicon(image), &bytes));
  return gfx::PNGCodec::Decode(base::as_byte_span(bytes));
}

TEST_F(SidebarFaviconTest, PreservesRetinaArtworkInsteadOfUpscaling1x) {
  gfx::ImageSkia image(IconRep(16, 1.0f, SK_ColorRED));
  image.AddRepresentation(IconRep(32, 2.0f, SK_ColorBLUE));
  const auto decoded = DecodeIcon(gfx::Image(image));
  ASSERT_EQ(decoded.width(), 32);
  ASSERT_EQ(decoded.height(), 32);
  EXPECT_EQ(decoded.getColor(0, 0), SK_ColorBLUE);
}

TEST_F(SidebarFaviconTest, SelectsLargestPixelsRegardlessOfInsertionOrder) {
  gfx::ImageSkia image(IconRep(64, 4.0f, SK_ColorGREEN));
  image.AddRepresentation(IconRep(16, 1.0f, SK_ColorRED));
  image.AddRepresentation(IconRep(32, 2.0f, SK_ColorBLUE));
  const auto decoded = DecodeIcon(gfx::Image(image));
  ASSERT_EQ(decoded.width(), 64);
  EXPECT_EQ(decoded.getColor(0, 0), SK_ColorGREEN);
}

TEST_F(SidebarFaviconTest, KeepsLowResolutionFallbackAtItsNativeSize) {
  const auto decoded = DecodeIcon(gfx::Image(gfx::ImageSkia(IconRep(16, 1.0f, SK_ColorRED))));
  ASSERT_EQ(decoded.width(), 16);
  EXPECT_EQ(decoded.getColor(0, 0), SK_ColorRED);
}

TEST_F(SidebarFaviconTest, PreservesTransparencyWithoutA1xRepresentation) {
  const auto decoded = DecodeIcon(gfx::Image(gfx::ImageSkia(
      IconRep(32, 2.0f, SkColorSetARGB(128, 0, 0, 255)))));
  ASSERT_EQ(decoded.width(), 32);
  EXPECT_EQ(SkColorGetA(decoded.getColor(0, 0)), 128u);
}

TEST_F(SidebarFaviconTest, MaterializesRetinaArtworkFromCachedPNGImages) {
  const auto small = gfx::PNGCodec::EncodeBGRASkBitmap(
      IconRep(16, 1.0f, SK_ColorRED).GetBitmap(), false);
  const auto retina = gfx::PNGCodec::EncodeBGRASkBitmap(
      IconRep(32, 2.0f, SK_ColorBLUE).GetBitmap(), false);
  ASSERT_TRUE(small);
  ASSERT_TRUE(retina);
  const gfx::Image image(std::vector<gfx::ImagePNGRep>{
      {base::MakeRefCounted<base::RefCountedBytes>(*small), 1.0f},
      {base::MakeRefCounted<base::RefCountedBytes>(*retina), 2.0f}});
  const auto decoded = DecodeIcon(image);
  ASSERT_EQ(decoded.width(), 32);
  ASSERT_EQ(decoded.height(), 32);
  EXPECT_EQ(decoded.getColor(0, 0), SK_ColorBLUE);
}

TEST_F(SidebarFaviconTest, EmptyImageClearsTheIcon) {
  EXPECT_TRUE(EncodeSidebarFavicon(gfx::Image()).empty());
}

}  // namespace
}  // namespace winmux
