#include "../protocol_validation.hpp"
#include <iostream>
#include <limits>
#include <random>
static void require(bool condition, const char *reason) {
  if (!condition)
    throw std::runtime_error(reason);
}
int main() {
  auto wrap = [](const std::string &s) {
    std::vector<uint8_t> b{(uint8_t)(s.size() >> 24), (uint8_t)(s.size() >> 16),
                           (uint8_t)(s.size() >> 8), (uint8_t)s.size()};
    b.insert(b.end(), s.begin(), s.end());
    return b;
  };
  auto rejected = [](const std::vector<uint8_t> &b) {
    try {
      su_remote::parseEnvelope(b);
      return false;
    } catch (...) {
      return true;
    }
  };
  try {
    auto v = wrap(R"({"type":"frame","display":"3","revision":17})");
    v.push_back(255);
    auto e = su_remote::parseEnvelope(v);
    require(e.header.at("display") == "3" && v[e.payloadOffset] == 255,
            "payload boundary");
    require(rejected({0, 0, 0, 255, '{', '}'}), "truncation accepted");
    require(rejected({255, 255, 255, 255, '{'}), "oversized header accepted");
    require(rejected(wrap("[]")), "non-object accepted");
    require(rejected(wrap("{\"n\":" + std::string(100, '[') + "0" +
                          std::string(100, ']') + "}")),
            "deep nesting accepted");
    require(su_remote::validImageRect(3712, 2032, 128, 128, 3840, 2160),
            "edge tile rejected");
    require(!su_remote::validImageRect(3713, 2032, 128, 128, 3840, 2160),
            "overflow tile accepted");
    require(!su_remote::validImageRect(0, 0, 3840, 3840, 3840, 3840),
            "excess canvas allocation accepted");
    require(!su_remote::validImageRect(std::numeric_limits<int>::max(), 0, 1, 1,
                                       1920, 1080),
            "integer overflow accepted");
    auto badCanvases = [](const nlohmann::json &c,
                          const std::vector<std::string> &ids) {
      try {
        su_remote::validateCanvasList(c, ids);
        return false;
      } catch (...) {
        return true;
      }
    };
    require(badCanvases(nlohmann::json::array({{{"id", "unrequested"},
                                                {"width", 3840},
                                                {"height", 2160}}}),
                        {"selected"}),
            "unrequested canvas accepted");
    nlohmann::json large = nlohmann::json::array();
    std::vector<std::string> ids;
    for (int i = 0; i < 9; i++) {
      ids.push_back(std::to_string(i));
      large.push_back({{"id", ids.back()}, {"width", 3840}, {"height", 2160}});
    }
    require(badCanvases(large, ids), "aggregate canvas budget not enforced");
    std::mt19937 rng(19790);
    for (int i = 0; i < 10000; i++) {
      std::vector<uint8_t> b(rng() % 1024);
      for (auto &x : b)
        x = (uint8_t)rng();
      try {
        su_remote::parseEnvelope(b);
      } catch (const std::exception &) {
      }
    }
    std::cout << "{\"ok\":true,\"tests\":[\"payload "
                 "boundary\",\"truncation\",\"header limit\",\"object "
                 "validation\",\"depth limit\",\"tile bounds\",\"allocation "
                 "limit\",\"integer overflow\",\"10000 malformed messages "
                 "under sanitizers\"]}\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << "\n";
    return 1;
  }
}
