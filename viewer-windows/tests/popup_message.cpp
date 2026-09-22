#include "../popup_message.hpp"
#include <cassert>
#include <iostream>
#include <random>

using nlohmann::json;
static bool rejected(const std::u16string &text, int seconds = 20,
                     const json &runs = json::array()) {
  try {
    su_remote::popupCommand(text, seconds, runs);
    return false;
  } catch (...) {
    return true;
  }
}
int main() {
  auto plain = su_remote::popupCommand(u"Ready", 20, json::array());
  assert(plain["type"] == "popupMessage" && plain["text"] == "Ready");
  assert(plain["durationSeconds"] == 20 && plain["runs"].empty());
  assert(!rejected(u"Ready", 0));
  assert(!rejected(u"Ready", 10800));
  assert(rejected(u"Ready", -1) && rejected(u"Ready", 10801));
  assert(rejected(u"") && rejected(u" \n\t"));
  assert(!rejected(std::u16string(250, u'A')));
  assert(rejected(std::u16string(251, u'A')));
  std::u16string emoji;
  for (int i = 0; i < 250; ++i)
    emoji += u"\U0001f600";
  assert(su_remote::popupText(emoji).boundaries.size() == 251);
  assert(!rejected(emoji));
  emoji += u"A";
  assert(rejected(emoji));
  assert(rejected(std::u16string(1, char16_t(0xd800))));
  assert(rejected(std::u16string(1, char16_t(0xdc00))));
  for (char16_t control : {char16_t(0), char16_t(1), char16_t(13), char16_t(127),
                           char16_t(0x061c), char16_t(0x202e), char16_t(0x2066)})
    assert(rejected(std::u16string{u'A', control}));
  assert(!rejected(u"Line one\nLine two\tReady"));
  auto styled = json::array({{{"start", 1}, {"length", 2},
                              {"color", "#FF2400"}, {"underline", true}}});
  assert(!rejected(u"A\U0001f600B", 20, styled));
  styled[0]["length"] = 1;
  assert(rejected(u"A\U0001f600B", 20, styled));
  styled[0]["length"] = 2;
  styled[0]["start"] = 2;
  assert(rejected(u"A\U0001f600B", 20, styled));
  styled[0]["start"] = 1;
  styled[0]["color"] = "red";
  assert(rejected(u"A\U0001f600B", 20, styled));
  styled[0]["color"] = "#ff2400";
  styled[0]["underline"] = 1;
  assert(rejected(u"A\U0001f600B", 20, styled));
  styled[0]["underline"] = true;
  styled.push_back(styled[0]);
  assert(rejected(u"A\U0001f600B", 20, styled));
  assert(rejected(u"Ready", 20, json::object()));
  std::mt19937 random(1234);
  for (int trial = 0; trial < 10000; ++trial) {
    std::u16string text;
    for (unsigned length = random() % 600; length; --length)
      text += char16_t(random());
    try {
      auto command = su_remote::popupCommand(text, 20, json::array());
      assert(command.dump().size() < 30000);
      assert(su_remote::popupText(text).boundaries.size() <= 251);
    } catch (const std::exception &) {
    }
  }
  std::cout << "Popup message validation passed, including 10000 malformed-input cases.\n";
}
