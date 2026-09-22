#pragma once
#include "popup_message.hpp"
#include <commdlg.h>
#include <richedit.h>

// The message window owns its controls, fonts, timers, and saved draft.
namespace portlight_popup {
enum Control {
  Launcher = 1000, Editor, Color, Underline, Sticky, Timed, Duration, Clear,
  Count, Feedback, Hint, Footer, ScreensLabel, ScreenFirst = 1100
};
static HWND launcher = nullptr, panel = nullptr;
static std::map<int, HWND> items;
static HFONT bodyFont = nullptr;
static UINT dpi = 96, editorDpi = 96;
static bool supported = false, active = false, editing = false, pending = false;
static int duration = 20;
static std::wstring feedback, draftPath;
static HMODULE richEditModule = nullptr;
struct TargetDisplay { std::string id; std::wstring name; int index; };
static bool targetSelectionSupported = false, targetChangePending = false;
static std::vector<TargetDisplay> availableTargets;
static std::vector<std::string> selectedTargets;
static bool (*testTimerHook)(WPARAM) = nullptr;
static void refresh();
static void saveDraft();
static void open();
static void layoutPanel();
static HWND add(const wchar_t *, const wchar_t *, DWORD, int);
static int unit(int value) { return MulDiv(value, dpi, 96); }
static UINT windowDpi(HWND hwnd) {
  using Fn = UINT(WINAPI *)(HWND);
  auto fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                              "GetDpiForWindow"));
  UINT result = fn ? fn(hwnd) : 0;
  return result ? result : 96;
}
static void setText(HWND hwnd, const std::wstring &text) {
  int size = GetWindowTextLengthW(hwnd);
  std::wstring current(size + 1, 0);
  GetWindowTextW(hwnd, current.data(), size + 1);
  current.resize(size);
  if (current != text)
    SetWindowTextW(hwnd, text.c_str());
}
static void enable(HWND hwnd, bool value) {
  if (bool(IsWindowEnabled(hwnd)) != value)
    EnableWindow(hwnd, value);
}
static std::u16string messageText() {
  std::wstring text(502, 0);
  GETTEXTEX options{DWORD(text.size() * sizeof(wchar_t)), GT_DEFAULT, 1200,
                    nullptr, nullptr};
  auto count = SendMessageW(items[Editor], EM_GETTEXTEX,
                            reinterpret_cast<WPARAM>(&options),
                            reinterpret_cast<LPARAM>(text.data()));
  text.resize(std::max<LRESULT>(0, count));
  std::u16string result(text.begin(), text.end());
  std::replace(result.begin(), result.end(), u'\r', u'\n');
  return result;
}
static void selectRange(LONG first, LONG last) {
  CHARRANGE range{first, last};
  SendMessageW(items[Editor], EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&range));
}
static json messageRuns(const std::u16string &text) {
  auto parsed = su_remote::popupText(text);
  HWND edit = items[Editor];
  CHARRANGE selection{};
  POINT scroll{};
  SendMessageW(edit, EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&selection));
  SendMessageW(edit, EM_GETSCROLLPOS, 0, reinterpret_cast<LPARAM>(&scroll));
  bool priorEditing = editing;
  editing = true;
  SendMessageW(edit, WM_SETREDRAW, FALSE, 0);
  json runs = json::array();
  for (size_t i = 0; i + 1 < parsed.boundaries.size(); ++i) {
    int first = int(parsed.boundaries[i]);
    int length = int(parsed.boundaries[i + 1]) - first;
    selectRange(first, first + length);
    CHARFORMAT2W format{};
    format.cbSize = sizeof(format);
    SendMessageW(edit, EM_GETCHARFORMAT, SCF_SELECTION,
                 reinterpret_cast<LPARAM>(&format));
    COLORREF color = format.dwEffects & CFE_AUTOCOLOR
                         ? RGB(255, 255, 255) : format.crTextColor;
    bool underline = (format.dwEffects & CFE_UNDERLINE) != 0;
    if (color == RGB(255, 255, 255) && !underline)
      continue;
    char hex[8];
    snprintf(hex, sizeof(hex), "#%02X%02X%02X", GetRValue(color),
             GetGValue(color), GetBValue(color));
    if (!runs.empty() && runs.back()["color"] == hex &&
        runs.back()["underline"] == underline &&
        runs.back()["start"].get<int>() + runs.back()["length"].get<int>() == first)
      runs.back()["length"] = runs.back()["length"].get<int>() + length;
    else
      runs.push_back({{"start", first}, {"length", length},
                      {"color", hex}, {"underline", underline}});
  }
  SendMessageW(edit, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&selection));
  SendMessageW(edit, EM_SETSCROLLPOS, 0, reinterpret_cast<LPARAM>(&scroll));
  SendMessageW(edit, WM_SETREDRAW, TRUE, 0);
  InvalidateRect(edit, nullptr, FALSE);
  editing = priorEditing;
  return runs;
}
static void prepareDraftPath() {
  if (visualMode || integrationMode ||
      std::wstring(GetCommandLineW()).find(L"--self-test") != std::wstring::npos)
    return;
  wchar_t path[MAX_PATH]{};
  if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, path))) {
    std::wstring folder = std::wstring(path) + L"\\Portlight";
    CreateDirectoryW(folder.c_str(), nullptr);
    draftPath = folder + L"\\message-draft.json";
  }
}
static void saveDraft() {
  if (!panel || editing || draftPath.empty())
    return;
  try {
    auto text = messageText();
    auto parsed = su_remote::popupText(text);
    if (parsed.boundaries.size() > 251)
      return;
    json draft{{"text", parsed.utf8}, {"runs", messageRuns(text)},
               {"durationSeconds", duration}};
    std::ofstream file(draftPath.c_str(), std::ios::binary | std::ios::trunc);
    if (file)
      file << draft.dump(2);
  } catch (...) {
    // An incomplete character can remain in the editor until input finishes.
  }
}
static void restoreDraft() {
  if (draftPath.empty())
    return;
  try {
    std::ifstream file(draftPath.c_str());
    if (!file)
      return;
    json draft;
    file >> draft;
    auto text = wide(draft.value("text", ""));
    auto runs = draft.value("runs", json::array());
    int seconds = draft.value("durationSeconds", 20);
    if (!text.empty())
      su_remote::popupCommand(std::u16string(text.begin(), text.end()), seconds, runs);
    else if (!runs.is_array() || !runs.empty())
      return;
    duration = seconds > 0 && seconds <= 10800 ? seconds : 20;
    SetWindowTextW(items[Editor], text.c_str());
    for (const auto &run : runs) {
      int first = run.at("start").get<int>();
      selectRange(first, first + run.at("length").get<int>());
      unsigned color = std::stoul(run.value("color", "#FFFFFF").substr(1), nullptr, 16);
      CHARFORMAT2W format{};
      format.cbSize = sizeof(format);
      format.dwMask = CFM_COLOR | CFM_UNDERLINE;
      format.crTextColor = RGB((color >> 16) & 255, (color >> 8) & 255, color & 255);
      format.dwEffects = run.value("underline", false) ? CFE_UNDERLINE : 0;
      SendMessageW(items[Editor], EM_SETCHARFORMAT, SCF_SELECTION,
                   reinterpret_cast<LPARAM>(&format));
    }
    selectRange(LONG(text.size()), LONG(text.size()));
  } catch (...) {
    SetWindowTextW(items[Editor], L"");
  }
}
static void refresh() {
  if (!panel || editing)
    return;
  size_t count = 0;
  bool valid = false;
  std::wstring detail;
  try {
    auto text = messageText();
    count = su_remote::popupText(text).boundaries.size() - 1;
    su_remote::popupCommand(text, duration, json::array());
    valid = true;
  } catch (const std::exception &error) {
    detail = wide(error.what());
  }
  bool ready = connected && supported && !pending && !targetChangePending &&
               (!targetSelectionSupported || !selectedTargets.empty());
  enable(items[Sticky], ready && valid);
  enable(items[Timed], ready && valid);
  enable(items[Clear], ready && active);
  setText(items[Count], std::to_wstring(count) + L" / 250 characters");
  setText(items[Timed], L"Popup for " + std::to_wstring(duration) + L"s");
  if (!connected)
    detail = L"Connect to a Host to send this message.";
  else if (!supported)
    detail = L"This Host does not support popup messages.";
  else if (!feedback.empty())
    detail = feedback;
  else if (messageText().empty())
    detail.clear();
  setText(items[Feedback], detail);
  for (size_t index = 0; index < availableTargets.size(); ++index) {
    auto found = items.find(ScreenFirst + int(index));
    if (found == items.end())
      continue;
    bool selected = std::find(selectedTargets.begin(), selectedTargets.end(),
                              availableTargets[index].id) != selectedTargets.end();
    SendMessageW(found->second, BM_SETCHECK, selected ? BST_CHECKED : BST_UNCHECKED, 0);
    enable(found->second, connected && targetSelectionSupported && !targetChangePending &&
                               !pending && (!selected || selectedTargets.size() > 1));
  }
}
static void finishPending(const std::wstring &text) {
  pending = false;
  targetChangePending = false;
  feedback = text;
  if (panel)
    KillTimer(panel, 2);
  refresh();
}
static void send(int seconds, bool clear = false) {
  if (!connected || !supported || pending || targetChangePending)
    return;
  try {
    json command = clear ? json{{"type", "clearPopupMessage"}}
                         : su_remote::popupCommand(messageText(), seconds,
                                                    messageRuns(messageText()));
    saveDraft();
    if (!sendMessage(command))
      throw std::runtime_error("The message could not be sent. Check the connection.");
    pending = true;
    feedback = clear ? L"Clearing message…" : L"Sending message…";
    SetTimer(panel, 2, 10000, nullptr);
  } catch (const std::exception &error) {
    feedback = wide(error.what());
  }
  refresh();
}
static void updateTargetsUI() {
  if (!panel)
    return;
  for (auto iterator = items.begin(); iterator != items.end();) {
    if (iterator->first >= ScreenFirst) {
      DestroyWindow(iterator->second);
      iterator = items.erase(iterator);
    } else
      ++iterator;
  }
  bool showTargets = targetSelectionSupported && !availableTargets.empty();
  ShowWindow(items[ScreensLabel], showTargets ? SW_SHOW : SW_HIDE);
  if (showTargets) {
    for (size_t index = 0; index < availableTargets.size(); ++index) {
      const auto &display = availableTargets[index];
      std::wstring label = std::to_wstring(display.index) + L": " + display.name;
      HWND checkbox = add(L"BUTTON", label.c_str(), BS_AUTOCHECKBOX | WS_TABSTOP,
                           ScreenFirst + int(index));
      if (bodyFont)
        SendMessageW(checkbox, WM_SETFONT, reinterpret_cast<WPARAM>(bodyFont), TRUE);
    }
  }
  RECT bounds{};
  GetWindowRect(panel, &bounds);
  int rows = showTargets ? int((availableTargets.size() + 1) / 2) : 0;
  int minimum = unit(360 + (rows ? 24 + rows * 28 : 0));
  if (bounds.bottom - bounds.top < minimum)
    SetWindowPos(panel, nullptr, 0, 0, bounds.right - bounds.left, minimum,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  layoutPanel();
  refresh();
}
static void toggleTarget(size_t index) {
  if (!connected || !targetSelectionSupported || pending || targetChangePending ||
      index >= availableTargets.size())
    return;
  auto proposed = selectedTargets;
  auto found = std::find(proposed.begin(), proposed.end(), availableTargets[index].id);
  if (found == proposed.end())
    proposed.push_back(availableTargets[index].id);
  else if (proposed.size() > 1)
    proposed.erase(found);
  else {
    feedback = L"Keep at least one message screen selected.";
    refresh();
    return;
  }
  if (sendMessage({{"type", "setPopupMessageDisplays"}, {"displayIDs", proposed}})) {
    targetChangePending = true;
    feedback = L"Updating message screens…";
    SetTimer(panel, 2, 10000, nullptr);
  } else
    feedback = L"The screen selection could not be sent. Check the connection.";
  refresh();
}
static void formatSelection(DWORD mask, COLORREF color, bool underline) {
  CHARFORMAT2W format{};
  format.cbSize = sizeof(format);
  format.dwMask = mask;
  format.crTextColor = color;
  format.dwEffects = underline ? CFE_UNDERLINE : 0;
  SendMessageW(items[Editor], EM_SETCHARFORMAT, SCF_SELECTION,
               reinterpret_cast<LPARAM>(&format));
  saveDraft();
  SetFocus(items[Editor]);
}
static void chooseColor() {
  using Fn = BOOL(WINAPI *)(LPCHOOSECOLORW);
  HMODULE library = LoadLibraryExW(L"comdlg32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  auto choose = library ? reinterpret_cast<Fn>(GetProcAddress(library, "ChooseColorW")) : nullptr;
  if (choose) {
    static COLORREF custom[16]{};
    CHARFORMAT2W format{};
    format.cbSize = sizeof(format);
    SendMessageW(items[Editor], EM_GETCHARFORMAT, SCF_SELECTION,
                 reinterpret_cast<LPARAM>(&format));
    CHOOSECOLORW choice{};
    choice.lStructSize = sizeof(choice);
    choice.hwndOwner = panel;
    choice.rgbResult = format.crTextColor;
    choice.lpCustColors = custom;
    choice.Flags = CC_FULLOPEN | CC_RGBINIT;
    if (choose(&choice))
      formatSelection(CFM_COLOR, choice.rgbResult, false);
  }
  if (library)
    FreeLibrary(library);
}
static void place(int id, int x, int y, int width, int height) {
  MoveWindow(items[id], unit(x), unit(y), unit(width), unit(height), TRUE);
}
static void layoutPanel() {
  if (!panel || !items.count(Editor))
    return;
  RECT bounds{};
  GetClientRect(panel, &bounds);
  int width = MulDiv(bounds.right, 96, dpi);
  int height = MulDiv(bounds.bottom, 96, dpi);
  int targetRows = targetSelectionSupported ? int((availableTargets.size() + 1) / 2) : 0;
  int targetsHeight = targetRows ? 24 + targetRows * 28 : 0;
  int editorHeight = std::max(80, height - 210 - targetsHeight);
  place(Hint, 20, 16, width - 40, 24);
  place(Editor, 20, 46, width - 40, editorHeight);
  int y = 56 + editorHeight;
  place(Color, 20, y, 112, 30);
  place(Underline, 140, y, 100, 30);
  place(Count, width - 196, y + 6, 176, 24);
  place(Feedback, 20, y + 40, width - 40, 30);
  place(ScreensLabel, 20, y + 76, width - 40, 22);
  for (size_t index = 0; index < availableTargets.size(); ++index) {
    int id = ScreenFirst + int(index);
    if (items.count(id))
      place(id, 20 + int(index % 2) * ((width - 40) / 2),
             y + 100 + int(index / 2) * 28, (width - 48) / 2, 26);
  }
  place(Sticky, 20, height - 76, 138, 34);
  place(Timed, 168, height - 76, 144, 34);
  place(Duration, 314, height - 76, 30, 34);
  place(Clear, width - 158, height - 76, 138, 34);
  place(Footer, 20, height - 30, width - 40, 24);
  RECT inset{unit(10), unit(8), unit(width - 60), unit(editorHeight - 8)};
  SendMessageW(items[Editor], EM_SETRECT, 0, reinterpret_cast<LPARAM>(&inset));
}
static void updateFont() {
  HFONT next = CreateFontW(-unit(14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                           CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  for (const auto &entry : items)
    if (entry.first != Editor)
      SendMessageW(entry.second, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
  if (bodyFont)
    DeleteObject(bodyFont);
  bodyFont = next;
  if (items.count(Editor))
    SendMessageW(items[Editor], EM_SETZOOM, dpi, editorDpi);
}
static LRESULT CALLBACK editorProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp,
                                    UINT_PTR, DWORD_PTR) {
  if (message == WM_KEYDOWN && (GetKeyState(VK_CONTROL) & 0x8000) &&
      (wp == 'B' || wp == 'I'))
    return 0;
  if (message == WM_PASTE) {
    if (OpenClipboard(hwnd)) {
      HANDLE data = GetClipboardData(CF_UNICODETEXT);
      auto text = data ? static_cast<const wchar_t *>(GlobalLock(data)) : nullptr;
      if (text) {
        std::wstring plain;
        for (size_t i = 0; text[i] && plain.size() < 1000; ++i) {
          if (text[i] == L'\r' && text[i + 1] == L'\n')
            continue;
          plain += text[i] == L'\n' ? L'\r' : text[i];
        }
        GlobalUnlock(data);
        SendMessageW(hwnd, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(plain.c_str()));
      }
      CloseClipboard();
    }
    return 0;
  }
  if (message == WM_NCDESTROY)
    RemoveWindowSubclass(hwnd, editorProc, 1);
  return DefSubclassProc(hwnd, message, wp, lp);
}
static LRESULT CALLBACK panelProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_DPICHANGED) {
    dpi = HIWORD(wp) ? HIWORD(wp) : 96;
    auto rect = reinterpret_cast<RECT *>(lp);
    SetWindowPos(hwnd, nullptr, rect->left, rect->top,
                 rect->right - rect->left, rect->bottom - rect->top,
                 SWP_NOACTIVATE | SWP_NOZORDER);
    updateFont();
    layoutPanel();
    return 0;
  }
  if (message == WM_SIZE) {
    layoutPanel();
    return 0;
  }
  if (message == WM_GETMINMAXINFO) {
    int rows = targetSelectionSupported ? int((availableTargets.size() + 1) / 2) : 0;
    reinterpret_cast<MINMAXINFO *>(lp)->ptMinTrackSize =
        {unit(560), unit(360 + (rows ? 24 + rows * 28 : 0))};
    return 0;
  }
  if (message == WM_COMMAND) {
    int id = LOWORD(wp);
    if (id == Editor && HIWORD(wp) == EN_CHANGE && !editing) {
      try {
        auto parsed = su_remote::popupText(messageText());
        if (parsed.boundaries.size() > 251) {
          editing = true;
          selectRange(LONG(parsed.boundaries[250]), -1);
          SendMessageW(items[Editor], EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(L""));
          editing = false;
          MessageBeep(MB_OK);
        }
      } catch (...) {
      }
      feedback.clear();
      refresh();
      SetTimer(hwnd, 1, 400, nullptr);
    } else if (id >= ScreenFirst && id < ScreenFirst + int(availableTargets.size()))
      toggleTarget(size_t(id - ScreenFirst));
    else if (id == Color)
      chooseColor();
    else if (id == Underline) {
      CHARFORMAT2W format{};
      format.cbSize = sizeof(format);
      SendMessageW(items[Editor], EM_GETCHARFORMAT, SCF_SELECTION,
                   reinterpret_cast<LPARAM>(&format));
      formatSelection(CFM_UNDERLINE, 0, (format.dwEffects & CFE_UNDERLINE) == 0);
    } else if (id == Sticky)
      send(0);
    else if (id == Timed)
      send(duration);
    else if (id == Clear)
      send(0, true);
    else if (id == Duration) {
      HMENU menu = CreatePopupMenu();
      for (int seconds : {5, 10, 20, 30, 60, 120, 300, 600, 1800, 3600, 10800}) {
        std::wstring label = seconds < 60 ? std::to_wstring(seconds) + L" seconds"
                                          : std::to_wstring(seconds / 60) + L" minutes";
        AppendMenuW(menu, MF_STRING | (seconds == duration ? MF_CHECKED : 0),
                     seconds, label.c_str());
      }
      RECT anchor{};
      GetWindowRect(items[Duration], &anchor);
      int selected = TrackPopupMenu(menu, TPM_RETURNCMD, anchor.left, anchor.bottom,
                                    0, hwnd, nullptr);
      DestroyMenu(menu);
      if (selected) {
        duration = selected;
        saveDraft();
        refresh();
      }
    } else if (id == IDCANCEL)
      SendMessageW(hwnd, WM_CLOSE, 0, 0);
    return 0;
  }
  if (message == WM_TIMER) {
    KillTimer(hwnd, wp);
    if (wp == 1)
      saveDraft();
    else if (wp == 2)
      finishPending(L"No reply from the Host. You can try again.");
    return 0;
  }
  if (message == WM_CLOSE) {
    saveDraft();
    ShowWindow(hwnd, SW_HIDE);
    SetFocus(launcher);
    return 0;
  }
  if (message == WM_DESTROY) {
    KillTimer(hwnd, 1);
    KillTimer(hwnd, 2);
    if (bodyFont)
      DeleteObject(bodyFont);
    bodyFont = nullptr;
    panel = nullptr;
    items.clear();
  }
  return DefWindowProcW(hwnd, message, wp, lp);
}
static HWND add(const wchar_t *cls, const wchar_t *text, DWORD style, int id) {
  HWND result = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style,
                                 0, 0, 1, 1, panel, reinterpret_cast<HMENU>(INT_PTR(id)),
                                 GetModuleHandleW(nullptr), nullptr);
  items[id] = result;
  return result;
}
static void open() {
  if (!panel) {
    if (!richEditModule)
      richEditModule = LoadLibraryExW(L"Msftedit.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!richEditModule) {
      MessageBoxW(mainWindow, L"Windows could not open the message editor.",
                   L"Portlight", MB_OK | MB_ICONERROR);
      return;
    }
    WNDCLASSEXW cls{};
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = panelProc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
    cls.lpszClassName = L"PortlightPopupComposer";
    RegisterClassExW(&cls);
    RECT owner{};
    GetWindowRect(mainWindow, &owner);
    dpi = windowDpi(mainWindow);
    panel = CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_TOOLWINDOW,
                             cls.lpszClassName, L"Send Message",
                             WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME |
                                 WS_CLIPCHILDREN,
                             owner.left + unit(32), owner.top + unit(64),
                             unit(620), unit(490), mainWindow, nullptr,
                             cls.hInstance, nullptr);
    if (!panel)
      return;
    dpi = windowDpi(panel);
    editing = true;
    add(L"STATIC", L"Select text to change its color or underline it.", 0, Hint);
    HWND edit = add(MSFTEDIT_CLASS, L"", ES_MULTILINE | ES_AUTOVSCROLL |
                      ES_WANTRETURN | ES_NOHIDESEL | WS_VSCROLL | WS_TABSTOP, Editor);
    if (!edit) {
      DestroyWindow(panel);
      editing = false;
      return;
    }
    HDC dc = GetDC(edit);
    editorDpi = GetDeviceCaps(dc, LOGPIXELSY);
    ReleaseDC(edit, dc);
    if (!editorDpi)
      editorDpi = 96;
    SetWindowSubclass(edit, editorProc, 1, 0);
    SendMessageW(edit, EM_EXLIMITTEXT, 0, 500);
    SendMessageW(edit, EM_SETEVENTMASK, 0, ENM_CHANGE);
    SendMessageW(edit, EM_SETBKGNDCOLOR, 0, RGB(32, 32, 32));
    CHARFORMAT2W format{};
    format.cbSize = sizeof(format);
    format.dwMask = CFM_FACE | CFM_SIZE | CFM_BOLD | CFM_COLOR | CFM_UNDERLINE;
    format.dwEffects = CFE_BOLD;
    format.yHeight = 360;
    format.crTextColor = RGB(255, 255, 255);
    wcscpy_s(format.szFaceName, L"Helvetica");
    SendMessageW(edit, EM_SETCHARFORMAT, SCF_ALL, reinterpret_cast<LPARAM>(&format));
    add(L"BUTTON", L"Text color…", BS_PUSHBUTTON | WS_TABSTOP, Color);
    add(L"BUTTON", L"Underline", BS_PUSHBUTTON | WS_TABSTOP, Underline);
    add(L"BUTTON", L"Popup Message", BS_PUSHBUTTON | WS_TABSTOP, Sticky);
    add(L"BUTTON", L"Popup for 20s", BS_PUSHBUTTON | WS_TABSTOP, Timed);
    add(L"BUTTON", L"▾", BS_PUSHBUTTON | WS_TABSTOP, Duration);
    add(L"BUTTON", L"Clear Message", BS_PUSHBUTTON | WS_TABSTOP, Clear);
    add(L"STATIC", L"", 0, Count);
    add(L"STATIC", L"", 0, Feedback);
    add(L"STATIC", L"Message screens", 0, ScreensLabel);
    add(L"STATIC", L"Popup Message stays until cleared, up to 3 hours.", 0, Footer);
    prepareDraftPath();
    restoreDraft();
    editing = false;
    updateFont();
    updateTargetsUI();
    layoutPanel();
  }
  refresh();
  ShowWindow(panel, SW_SHOW);
  SetForegroundWindow(panel);
  SetFocus(items[Editor]);
}
static bool drawIcon(HDC dc, int id, RECT bounds, COLORREF color) {
  if (id != Launcher)
    return false;
  int cx = (bounds.left + bounds.right) / 2, cy = (bounds.top + bounds.bottom) / 2;
  HPEN pen = CreatePen(PS_SOLID, std::max(1, px(2)), color);
  auto oldPen = SelectObject(dc, pen);
  auto oldBrush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  RoundRect(dc, cx - px(9), cy - px(7), cx + px(9), cy + px(5), px(4), px(4));
  MoveToEx(dc, cx - px(5), cy + px(5), nullptr);
  LineTo(dc, cx - px(5), cy + px(10));
  LineTo(dc, cx + px(1), cy + px(5));
  SelectObject(dc, oldPen);
  SelectObject(dc, oldBrush);
  DeleteObject(pen);
  return true;
}
static void layoutLauncher() {
  if (!launcher)
    return;
  enable(launcher, connected && supported);
  if (!connected) {
    supported = active = pending = targetChangePending = false;
    if (panel)
      KillTimer(panel, 2);
  }
  refresh();
}
static bool receive(const json &message) {
  std::string type = message.value("type", "");
  try {
    if (type == "welcome") {
      supported = active = pending = targetChangePending = targetSelectionSupported = false;
      availableTargets.clear();
      selectedTargets.clear();
      feedback.clear();
      auto capability = message.value("capabilities", json::object())
                               .value("popupMessages", json::object());
      supported = capability.is_object() && capability.value("maxCharacters", 0) >= 250 &&
                  capability.value("maxDurationSeconds", 0) >= 10800 &&
                  capability.value("richText", false);
      targetSelectionSupported = supported && capability.value("targetDisplays", false);
      updateTargetsUI();
    } else if (type == "popupMessageState") {
      if (supported) {
        if (targetSelectionSupported) {
          const auto &targets = message.at("availableDisplays");
          const auto &selection = message.at("displayIDs");
          if (!targets.is_array() || targets.size() > 64 || !selection.is_array() ||
              selection.empty())
            throw std::runtime_error("Invalid message screens.");
          std::vector<TargetDisplay> available;
          std::vector<std::string> selected;
          for (const auto &target : targets) {
            auto id = target.at("id").get<std::string>();
            if (id.empty() || std::find_if(available.begin(), available.end(),
                  [&](const TargetDisplay &value) { return value.id == id; }) != available.end())
              throw std::runtime_error("Invalid message screen ID.");
            available.push_back({id, wide(target.at("name").get<std::string>()),
                                  target.at("index").get<int>()});
          }
          for (const auto &entry : selection) {
            auto id = entry.get<std::string>();
            if (std::find_if(available.begin(), available.end(),
                  [&](const TargetDisplay &value) { return value.id == id; }) == available.end() ||
                std::find(selected.begin(), selected.end(), id) != selected.end())
              throw std::runtime_error("Invalid selected message screen.");
            selected.push_back(id);
          }
          bool changed = available.size() != availableTargets.size();
          for (size_t index = 0; !changed && index < available.size(); ++index)
            changed = available[index].id != availableTargets[index].id ||
                      available[index].name != availableTargets[index].name ||
                      available[index].index != availableTargets[index].index;
          availableTargets = std::move(available);
          selectedTargets = std::move(selected);
          if (changed)
            updateTargetsUI();
        }
        active = message.value("active", false);
        finishPending(active ? L"Message is showing on the Host."
                              : L"No message is showing on the Host.");
      }
      return true;
    } else if (type == "error" && (message.value("code", "") == "popupMessage" ||
                                   message.value("code", "") == "popupMessageDisplays")) {
      finishPending(wide(message.value("message", "The message was not accepted.")));
      return true;
    } else if (type == "disconnected") {
      supported = active = pending = targetChangePending = false;
      feedback.clear();
    }
  } catch (...) {
    if (type == "welcome")
      supported = false;
    else if (type == "popupMessageState") {
      finishPending(L"The Host sent an invalid message response.");
      return true;
    }
  }
  return false;
}
static LRESULT CALLBACK ownerProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp,
                                  UINT_PTR, DWORD_PTR) {
  if (message == WM_TIMER && testTimerHook && testTimerHook(wp))
    return 0;
  if (message == WM_COMMAND && LOWORD(wp) == Launcher) {
    open();
    return 0;
  }
  if (message == WM_CLOSE || message == WM_DESTROY)
    saveDraft();
  if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE) {
    LRESULT result = DefSubclassProc(hwnd, message, wp, lp);
    if (launcher)
      InvalidateRect(launcher, nullptr, FALSE);
    return result;
  }
  if (message == WM_NCDESTROY)
    RemoveWindowSubclass(hwnd, ownerProc, 1);
  return DefSubclassProc(hwnd, message, wp, lp);
}
static void install() {
  launcher = ::add(mainWindow, L"BUTTON", L"Message", BS_PUSHBUTTON | WS_TABSTOP,
                    Launcher, 0, 0, 1, 1);
  toolbarGroups.push_back({Launcher});
  SetWindowSubclass(mainWindow, ownerProc, 1, 0);
  tooltip(launcher, L"Send a popup message to the Host");
  layout();
}
static bool dialogMessage(MSG &message) {
  return panel && IsWindowVisible(panel) &&
         (message.hwnd == panel || IsChild(panel, message.hwnd)) &&
         IsDialogMessageW(panel, &message);
}
} // namespace portlight_popup
