#pragma once
#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <vector>
namespace portlight {
struct Rect {
  double x = 0, y = 0, w = 0, h = 0;
};
struct Monitor {
  std::string id;
  Rect frame;
};
// Match macOS Arrange Displays in logical points; compact only empty bands.
inline std::map<std::string, Rect>
displayLayout(const std::vector<Monitor> &monitors, bool compact) {
  std::map<std::string, Rect> result;
  if (monitors.empty())
    return result;
  auto gaps = [&](bool horizontal) {
    std::vector<std::pair<double, double>> intervals, empty;
    for (auto &m : monitors) {
      auto r = m.frame;
      double start = horizontal ? r.x : r.y;
      intervals.push_back({start, start + (horizontal ? r.w : r.h)});
    }
    std::sort(intervals.begin(), intervals.end());
    double end = intervals.front().second;
    for (auto i : intervals) {
      if (i.first > end)
        empty.push_back({end, i.first});
      end = std::max(end, i.second);
    }
    return empty;
  };
  auto horizontal = gaps(true), vertical = gaps(false);
  double minX = 1e30, minY = 1e30;
  for (auto m : monitors) {
    auto r = m.frame;
    if (compact) {
      for (auto g : horizontal)
        if (g.second <= m.frame.x)
          r.x -= g.second - g.first;
      for (auto g : vertical)
        if (g.second <= m.frame.y)
          r.y -= g.second - g.first;
    }
    minX = std::min(minX, r.x);
    minY = std::min(minY, r.y);
    result[m.id] = r;
  }
  for (auto &pair : result) {
    pair.second.x -= minX;
    pair.second.y -= minY;
  }
  return result;
}
inline Rect bounds(const std::map<std::string, Rect> &layout) {
  Rect r;
  for (auto &p : layout) {
    r.w = std::max(r.w, p.second.x + p.second.w);
    r.h = std::max(r.h, p.second.y + p.second.h);
  }
  return r;
}
} // namespace portlight
