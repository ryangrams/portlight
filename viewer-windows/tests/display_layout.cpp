#include "../display_layout.hpp"
#include <cassert>
#include <iostream>
#include <random>
using namespace portlight;
int main() {
  std::vector<Monitor> monitors = {{"1", {0, 0, 1920, 1080}},
                                   {"2", {1920, 0, 1920, 1080}},
                                   {"3", {3840, 0, 1920, 1080}}};
  auto all = displayLayout(monitors, true);
  assert(bounds(all).w == 5760);
  auto outer = displayLayout({monitors[0], monitors[2]}, true);
  assert(outer["3"].x == 1920 && bounds(outer).w == 3840);
  auto map = displayLayout({monitors[0], monitors[2]}, false);
  assert(map["3"].x == 3840 && bounds(map).w == 5760);
  auto mixed = displayLayout(
      {{"retina", {-1440, 0, 1440, 900}}, {"portrait", {0, -300, 1080, 1920}}},
      true);
  assert(mixed["retina"].x == 0 && mixed["retina"].y == 300 &&
         mixed["portrait"].x == 1440);
  assert(bounds(mixed).w == 2520 && bounds(mixed).h == 1920);
  auto stacked = displayLayout(
      {{"top", {0, -2160, 1920, 1080}}, {"bottom", {0, 0, 1920, 1080}}}, true);
  assert(stacked["top"].y == 0 && stacked["bottom"].y == 1080);
  auto offset = displayLayout(
      {{"a", {0, 0, 1920, 1080}}, {"b", {1800, 1080, 1920, 1080}}}, true);
  assert(offset["b"].x ==
         1800); // occupied overlapping bands retain the host offset
  assert(displayLayout({}, true).empty());
  std::mt19937 rng(472);
  for (int n = 0; n < 10000; ++n) {
    std::vector<Monitor> sample;
    for (int i = 0; i < 6; ++i)
      sample.push_back(
          {std::to_string(i),
           {double(int(rng() % 12000) - 6000), double(int(rng() % 8000) - 4000),
            double(400 + rng() % 3000), double(300 + rng() % 2000)}});
    auto layout = displayLayout(sample, true);
    auto b = bounds(layout);
    for (auto &m : sample) {
      auto r = layout[m.id];
      assert(r.x >= 0 && r.y >= 0 && r.x + r.w <= b.w && r.y + r.h <= b.h);
      assert(r.w == m.frame.w && r.h == m.frame.h);
    }
  }
  std::cout
      << "{\"ok\":true,\"tests\":[\"logical mixed-DPI geometry\",\"1+3 compact "
         "layout\",\"physical map gaps\",\"stacked screens\",\"negative "
         "origins\",\"10000 random layouts under sanitizers\"]}\n";
}
