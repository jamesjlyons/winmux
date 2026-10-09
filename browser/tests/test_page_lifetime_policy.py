"""Exercise the exact scheduling policy used by the Chromium integration."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PageLifetimePolicyTests(unittest.TestCase):
    def test_deadlines_recency_and_pressure(self):
        compiler = shutil.which("clang++") or shutil.which("c++")
        if not compiler:
            self.skipTest("A C++20 compiler is required")
        with tempfile.TemporaryDirectory(prefix="winmux-page-policy-") as directory:
            source = Path(directory) / "policy.cc"
            executable = Path(directory) / "policy"
            source.write_text(r'''
#include "chrome/browser/winmux/page_lifetime_policy.h"
#include <algorithm>
#include <cassert>
using A = winmux::BackgroundPageAction;
int main() {
  constexpr uint64_t budget = uint64_t{8} * 1024 * 1024 * 1024;
  assert(!winmux::HasBackgroundPageMemoryPressure(100, budget));
  assert(!winmux::HasBackgroundPageMemoryPressure(150, budget));
  assert(winmux::HasBackgroundPageMemoryPressure(100, budget + 1));
  assert(winmux::HasBackgroundPageMemoryPressure(50, 0));
  assert(winmux::HasBackgroundPageMemoryPressure(0, 0));
  // Clearing pressure can issue another release callback at the default
  // limit. That callback must not keep discarding the recent warm pages.
  std::vector<int64_t> recent(2, 1000);
  auto capped = winmux::PlanBackgroundPages(recent,
      winmux::HasBackgroundPageMemoryPressure(50, 0));
  assert(capped.back() == A::kDiscard);
  auto recovered = winmux::PlanBackgroundPages(recent,
      winmux::HasBackgroundPageMemoryPressure(100, 0));
  assert(std::count(recovered.begin(), recovered.end(), A::kWarm) == 2);
  assert(winmux::PlanBackgroundPages({}, false).empty());
  std::vector<int64_t> ages(12, 3600000);
  auto warm = winmux::PlanBackgroundPages(ages, false);
  assert(std::count(warm.begin(), warm.end(), A::kWarm) == 12);
  ages.push_back(119999);
  assert(winmux::PlanBackgroundPages(ages, false).back() == A::kWarm);
  ages.back() = 120000;
  assert(winmux::PlanBackgroundPages(ages, false).back() == A::kFreeze);
  ages.back() = 899999;
  assert(winmux::PlanBackgroundPages(ages, false).back() == A::kFreeze);
  ages.back() = 900000;
  assert(winmux::PlanBackgroundPages(ages, false).back() == A::kDiscard);
  ages.push_back(3600000);
  auto pressure = winmux::PlanBackgroundPages(ages, true);
  assert(std::count(pressure.begin(), pressure.end(), A::kDiscard) == 1);
  assert(pressure[12] == A::kFreeze); // Do not thaw every cold page under pressure.
  assert(pressure.back() == A::kDiscard);
  ages = {1000, 1000};
  pressure = winmux::PlanBackgroundPages(ages, true);
  assert(pressure.front() == A::kWarm);
  assert(pressure.back() == A::kDiscard); // Pressure may evict from the warm set.
}
''')
            subprocess.run([compiler, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "browser/chromium/overlay"),
                            str(source), "-o", str(executable)], check=True,
                           capture_output=True, text=True)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
