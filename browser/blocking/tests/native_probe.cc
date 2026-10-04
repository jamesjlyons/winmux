#include "winmux_blocking.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
using Blocker = std::unique_ptr<WMBlocker, decltype(&wm_blocker_free)>;
WMStringView View(const std::string& value) {
  return {reinterpret_cast<const uint8_t*>(value.data()), value.size()};
}
void Require(bool value, const char* message) {
  if (!value) { fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
void FreeDecision(WMDecision result) {
  wm_string_free(result.redirect);
  wm_string_free(result.rewritten_url);
}
double Percentile(std::vector<double> values, double percentile) {
  std::sort(values.begin(), values.end());
  return values.at(static_cast<size_t>(std::ceil(values.size() * percentile)) - 1);
}

int main(int argc, const char* argv[]) {
  Require(argc == 2, "provide an uncompressed filter-list file");
  std::ifstream input(argv[1]);
  Require(input.good(), "open rules");
  std::string rules{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
  Require(rules.size() > 1000000, "benchmark must include full bundled lists");
  rules += "\n||ads.winmux.test^\n@@||ads.winmux.test/allowed.js$script\n"
           "winmux.test##.sponsored\n##.winmux-advert\n"
           "winmux.test#@#.winmux-advert\n";
  auto compile_start = Clock::now();
  Blocker engine(wm_blocker_create(View(rules)), wm_blocker_free);
  Require(engine != nullptr, "compile full bundled rules");
  double compile_ms = std::chrono::duration<double, std::milli>(Clock::now() - compile_start).count();
  const std::string source = "https://winmux.test/article";
  const std::string blocked = "https://ads.winmux.test/banner.js";
  const std::string allowed = "https://ads.winmux.test/allowed.js";
  const std::string type = "script", method = "GET";
  auto Check = [&](const std::string& url, bool enabled) {
    return wm_blocker_check(engine.get(), View(url), View(source), View(type), View(method), enabled);
  };
  auto result = Check(blocked, true);
  Require(result.status == WM_OK && result.blocked, "network blocking via C ABI");
  FreeDecision(result);
  result = Check(allowed, true);
  Require(result.status == WM_OK && !result.blocked && result.excepted, "exception via C ABI");
  FreeDecision(result);
  result = Check(blocked, false);
  Require(result.status == WM_OK && !result.blocked, "site disabled via C ABI");
  FreeDecision(result);
  char* cosmetics = wm_blocker_cosmetics(engine.get(), View(source), true);
  Require(cosmetics && std::string(cosmetics).find(".sponsored") != std::string::npos, "cosmetic selector via C ABI");
  wm_string_free(cosmetics);
  std::string tokens = R"({"classes":["winmux-advert"],"ids":[]})";
  char* delta = wm_blocker_dynamic_cosmetics(engine.get(), View(source), View(tokens), true);
  Require(delta && std::string(delta) == "[]", "cosmetic exception via C ABI");
  wm_string_free(delta);
  // A rejected replacement leaves the caller's current immutable engine intact.
  Blocker bad(wm_blocker_create(View("<html>download failed</html>")), wm_blocker_free);
  Require(!bad, "invalid replacement rejected");
  result = Check(blocked, true);
  Require(result.blocked, "last valid engine still usable");
  FreeDecision(result);

  constexpr int kRuns = 3, kThreads = 4, kPerThread = 10000;
  printf("{\"scope\":\"native_blocker_microbenchmark\",\"browser_integrated\":false,"
         "\"compile_ms\":%.3f,\"threads\":%d,\"runs\":[", compile_ms, kThreads);
  for (int run = 0; run < kRuns; ++run) {
    std::vector<std::vector<double>> samples(kThreads);
    std::vector<std::thread> threads;
    for (int worker = 0; worker < kThreads; ++worker) {
      threads.emplace_back([&, worker] {
        auto& times = samples[worker];
        times.reserve(kPerThread);
        for (int i = 0; i < kPerThread; ++i) {
          // Mix match, exception, and non-match. Different paths exercise actual
          // tokenization rather than one repeated URL/result cache.
          std::string url = i % 3 == 0 ? allowed : (i % 3 == 1 ? blocked :
              "https://content.winmux.test/article/" + std::to_string(worker * kPerThread + i));
          auto start = Clock::now();
          auto result = Check(url, true);
          auto end = Clock::now();
          Require(result.status == WM_OK && result.blocked == (i % 3 == 1), "concurrent decision");
          FreeDecision(result);
          times.push_back(std::chrono::duration<double, std::milli>(end - start).count());
        }
      });
    }
    for (auto& thread : threads) thread.join();
    std::vector<double> combined;
    for (auto& values : samples) combined.insert(combined.end(), values.begin(), values.end());
    printf("%s{\"run\":%d,\"requests\":%zu,\"p95_ms\":%.6f,\"p99_ms\":%.6f}",
           run ? "," : "", run + 1, combined.size(), Percentile(combined, .95), Percentile(combined, .99));
  }
  puts("]}");
}
