#ifndef CHROME_BROWSER_WINMUX_SIDEBAR_FAVICON_H_
#define CHROME_BROWSER_WINMUX_SIDEBAR_FAVICON_H_

#include <string>

#include "base/base64.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"

namespace winmux {

// Inventory transports one PNG, so keep the largest available representation
// of Chromium's 16-DIP favicon. As1xPNGBytes() drops its Retina artwork.
inline std::string EncodeSidebarFavicon(const gfx::Image& image) {
  if (image.IsEmpty()) return {};
  const auto& skia = image.AsImageSkia();
  // Database-backed PNG images materialize their representations lazily.
  skia.EnsureRepsForSupportedScales();
  gfx::ImageSkiaRep best;
  for (const auto& rep : skia.image_reps()) {
    if (!rep.is_null() && (best.is_null() ||
        rep.pixel_width() * rep.pixel_height() >
            best.pixel_width() * best.pixel_height())) {
      best = rep;
    }
  }
  if (best.is_null()) return {};
  auto png = gfx::PNGCodec::EncodeBGRASkBitmap(
      best.GetBitmap(), /*discard_transparency=*/false);
  if (!png || png->empty() || png->size() > 98304) return {};
  return base::Base64Encode(*png);
}

}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_SIDEBAR_FAVICON_H_
