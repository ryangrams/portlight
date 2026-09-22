#pragma once
#include "../third_party/nlohmann/json.hpp"
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace su_remote {
struct PopupText {
  std::string utf8;
  std::vector<size_t> boundaries{0};
  bool nonblank = false;
};
inline bool popupWhitespace(uint32_t c) {
  return c == 9 || c == 10 || c == 32 || c == 0x85 || c == 0xa0 ||
         c == 0x1680 || (c >= 0x2000 && c <= 0x200b) || c == 0x2028 ||
         c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}
inline PopupText popupText(const std::u16string &text) {
  PopupText result;
  for (size_t i = 0; i < text.size();) {
    uint32_t c = text[i++];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i == text.size() || text[i] < 0xdc00 || text[i] > 0xdfff)
        throw std::runtime_error(
            "Finish entering the character before sending.");
      c = 0x10000 + ((c - 0xd800) << 10) + text[i++] - 0xdc00;
    } else if (c >= 0xdc00 && c <= 0xdfff)
      throw std::runtime_error("The message contains an incomplete character.");
    if ((c < 32 && c != 9 && c != 10) || c == 127 || c == 0x061c ||
        c == 0x200e || c == 0x200f || (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2066 && c <= 0x2069))
      throw std::runtime_error(
          "Remove hidden control characters before sending.");
    result.nonblank |= !popupWhitespace(c);
    result.boundaries.push_back(i);
    if (c < 0x80)
      result.utf8 += char(c);
    else if (c < 0x800) {
      result.utf8 += char(0xc0 | (c >> 6));
      result.utf8 += char(0x80 | (c & 0x3f));
    } else if (c < 0x10000) {
      result.utf8 += char(0xe0 | (c >> 12));
      result.utf8 += char(0x80 | ((c >> 6) & 0x3f));
      result.utf8 += char(0x80 | (c & 0x3f));
    } else {
      result.utf8 += char(0xf0 | (c >> 18));
      result.utf8 += char(0x80 | ((c >> 12) & 0x3f));
      result.utf8 += char(0x80 | ((c >> 6) & 0x3f));
      result.utf8 += char(0x80 | (c & 0x3f));
    }
  }
  return result;
}
inline nlohmann::json popupCommand(const std::u16string &text, int duration,
                                   const nlohmann::json &runs) {
  auto parsed = popupText(text);
  if (!parsed.nonblank)
    throw std::runtime_error("Write a message before sending.");
  if (parsed.boundaries.size() > 251 || parsed.utf8.size() > 4000)
    throw std::runtime_error("Keep the message to 250 characters.");
  if (duration < 0 || duration > 10800)
    throw std::runtime_error("Choose a duration up to 3 hours.");
  if (!runs.is_array() || runs.size() > 250)
    throw std::runtime_error("Invalid message formatting.");
  size_t previousEnd = 0;
  for (const auto &run : runs) {
    if (!run.is_object() || !run.at("start").is_number_integer() ||
        !run.at("length").is_number_integer())
      throw std::runtime_error("Invalid message formatting range.");
    auto start = run.at("start").get<int64_t>();
    auto length = run.at("length").get<int64_t>();
    if (start < 0 || length <= 0 || start > int64_t(text.size()) ||
        length > int64_t(text.size()) - start || size_t(start) < previousEnd)
      throw std::runtime_error("Invalid message formatting range.");
    auto boundary = [&](size_t p) {
      return std::find(parsed.boundaries.begin(), parsed.boundaries.end(), p) !=
             parsed.boundaries.end();
    };
    if (!boundary(size_t(start)) || !boundary(size_t(start + length)))
      throw std::runtime_error("Message formatting splits a character.");
    previousEnd = size_t(start + length);
    if (run.contains("color")) {
      auto color = run.at("color").get<std::string>();
      if (color.size() != 7 || color[0] != '#' ||
          color.find_first_not_of("0123456789abcdefABCDEF", 1) !=
              std::string::npos)
        throw std::runtime_error("Invalid message color.");
    }
    if (run.contains("underline") && !run["underline"].is_boolean())
      throw std::runtime_error("Invalid message underline.");
  }
  return {{"type", "popupMessage"},
          {"text", parsed.utf8},
          {"durationSeconds", duration},
          {"runs", runs}};
}
} // namespace su_remote
