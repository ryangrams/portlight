#pragma once
#include "../third_party/nlohmann/json.hpp"
#include <cstdint>
#include <stdexcept>
#include <vector>
namespace su_remote {
struct Envelope {
  nlohmann::json header;
  size_t payloadOffset;
};
inline Envelope parseEnvelope(const std::vector<uint8_t> &data) {
  if (data.size() < 5 || data.size() > 32 * 1024 * 1024)
    throw std::runtime_error("Invalid binary message length");
  uint32_t n = (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) |
               (uint32_t(data[2]) << 8) | data[3];
  if (n == 0 || n > 65536 || n > data.size() - 4)
    throw std::runtime_error("Invalid binary header length");
  auto header = nlohmann::json::parse(
      data.begin() + 4, data.begin() + 4 + n,
      [](int depth, nlohmann::json::parse_event_t, nlohmann::json &) {
        if (depth > 8)
          throw std::runtime_error("Binary header nesting too deep");
        return true;
      });
  if (!header.is_object())
    throw std::runtime_error("Binary header must be an object");
  return {std::move(header), 4 + n};
}
inline bool validImageRect(int x, int y, int width, int height, int canvasWidth,
                           int canvasHeight) {
  return width > 0 && height > 0 && canvasWidth > 0 && canvasHeight > 0 &&
         canvasWidth <= 3840 && canvasHeight <= 3840 &&
         uint64_t(canvasWidth) * canvasHeight <= 3840u * 2160u && x >= 0 &&
         y >= 0 && width <= canvasWidth && height <= canvasHeight &&
         x <= canvasWidth - width && y <= canvasHeight - height;
}
} // namespace su_remote
namespace su_remote {
inline void validateCanvasList(const nlohmann::json &canvases,
                               const std::vector<std::string> &selected) {
  if (!canvases.is_array() || canvases.size() > selected.size())
    throw std::runtime_error("Unexpected canvas list");
  std::vector<std::string> seen;
  uint64_t total = 0;
  for (const auto &c : canvases) {
    const auto id = c.at("id").get<std::string>();
    if (std::find(selected.begin(), selected.end(), id) == selected.end() ||
        std::find(seen.begin(), seen.end(), id) != seen.end())
      throw std::runtime_error("Unknown or duplicate canvas ID");
    const auto w = c.at("width").get<int64_t>(),
               h = c.at("height").get<int64_t>();
    if (w < 1 || h < 1 || w > 3840 || h > 3840 ||
        !validImageRect(0, 0, (int)w, (int)h, (int)w, (int)h))
      throw std::runtime_error("Invalid canvas dimensions");
    total += (uint64_t)w * h * 4;
    if (total > 256 * 1024 * 1024)
      throw std::runtime_error(
          "Selected displays exceed the 256 MB image budget");
    seen.push_back(id);
  }
}
} // namespace su_remote
