// Exercise the production queue with move-only callbacks without linking Blink.
#include <cassert>
#include <deque>
#include <memory>
#include <vector>

#include "third_party/blink/renderer/platform/widget/compositing/bounded_presentation_callbacks.h"

using Callback = std::unique_ptr<int>;
using Queue = std::deque<std::pair<uint32_t, std::vector<Callback>>>;

int main() {
  Queue pending;
  std::vector<int> failed;
  // A missing presentation stream must remain bounded far past the old crash
  // threshold, retaining the newest frames and completing each expired one.
  for (int frame = 1; frame <= 1000; ++frame) {
    auto expired = blink::internal::EnqueueBoundedPresentationCallback(
        frame, std::make_unique<int>(frame), pending, 60, 250);
    for (auto& callback : expired) failed.push_back(*callback);
    assert(pending.size() <= 60);
  }
  assert(failed.size() == 940);
  for (int i = 0; i < 940; ++i) assert(failed[i] == i + 1);
  assert(pending.front().first == 941);
  assert(pending.back().first == 1000);
  // One delayed successful presentation can still complete the retained tail.
  int expected = 941;
  for (auto& [frame, callbacks] : pending) {
    assert(frame == static_cast<uint32_t>(expected));
    assert(callbacks.size() == 1 && *callbacks[0] == expected++);
  }
  pending.clear();
  failed.clear();
  // Many registrations for the same token must also stay bounded and must
  // not expire unrelated tokens or reorder the surviving callbacks.
  for (int i = 0; i < 1000; ++i) {
    auto expired = blink::internal::EnqueueBoundedPresentationCallback(
        1, std::make_unique<int>(i), pending, 60, 250);
    for (auto& callback : expired) failed.push_back(*callback);
    assert(pending.size() == 1 && pending.back().second.size() <= 250);
  }
  assert(failed.size() == 750);
  for (int i = 0; i < 750; ++i) assert(failed[i] == i);
  for (int i = 0; i < 250; ++i) assert(*pending.front().second[i] == i + 750);
  // Normal presentation clears each batch without expiring anything.
  pending.clear();
  for (int frame = 1; frame <= 1000; ++frame) {
    auto expired = blink::internal::EnqueueBoundedPresentationCallback(
        frame, std::make_unique<int>(frame), pending, 60, 250);
    assert(expired.empty() && pending.size() == 1);
    pending.pop_front();
  }
}
