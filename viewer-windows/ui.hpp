// Native presentation layer. Protocol, connection settings and OSC actions live
// in main.cpp.
static void fill(HDC dc, RECT r, COLORREF color) {
  HBRUSH b = CreateSolidBrush(color);
  FillRect(dc, &r, b);
  DeleteObject(b);
}
static void rounded(HDC dc, RECT r, COLORREF color, COLORREF border,
                    int radius = 12) {
  HPEN pen = CreatePen(PS_SOLID, px(1), border);
  HBRUSH brush = CreateSolidBrush(color);
  auto oldPen = SelectObject(dc, pen), oldBrush = SelectObject(dc, brush);
  RoundRect(dc, r.left, r.top, r.right, r.bottom, px(radius), px(radius));
  SelectObject(dc, oldPen);
  SelectObject(dc, oldBrush);
  DeleteObject(pen);
  DeleteObject(brush);
}
static void textAt(HDC dc, const std::wstring &text, RECT r, HFONT font,
                   COLORREF color,
                   UINT flags = DT_LEFT | DT_TOP | DT_NOPREFIX) {
  auto old = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, color);
  DrawTextW(dc, text.c_str(), -1, &r, flags);
  SelectObject(dc, old);
}
static RECT logicalRect(int x, int y, int w, int h) {
  return {px(x), px(y), px(x + w), px(y + h)};
}
static std::wstring buttonText(HWND h) {
  int n = GetWindowTextLengthW(h);
  std::wstring t(n + 1, 0);
  GetWindowTextW(h, t.data(), n + 1);
  t.resize(n);
  return t;
}
static LRESULT CALLBACK themedControl(HWND h, UINT msg, WPARAM wp, LPARAM lp,
                                      UINT_PTR, DWORD_PTR) {
  if (msg == WM_MOUSEMOVE) {
    if (!GetPropW(h, L"hover")) {
      SetPropW(h, L"hover", (HANDLE)1);
      TRACKMOUSEEVENT tracking{sizeof(tracking), TME_LEAVE, h, 0};
      TrackMouseEvent(&tracking);
      InvalidateRect(h, nullptr, FALSE);
    }
  }
  if (msg == WM_MOUSELEAVE) {
    RemovePropW(h, L"hover");
    InvalidateRect(h, nullptr, FALSE);
  }
  if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS) {
    InvalidateRect(GetParent(h), nullptr, FALSE);
    InvalidateRect(h, nullptr, FALSE);
  }
  if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP || msg == WM_KEYDOWN ||
      msg == WM_KEYUP || msg == BM_SETCHECK || msg == BM_SETSTATE) {
    LRESULT r = DefSubclassProc(h, msg, wp, lp);
    InvalidateRect(h, nullptr, FALSE);
    return r;
  }
  wchar_t cls[32]{};
  GetClassNameW(h, cls, 32);
  if ((msg == WM_PAINT || msg == WM_PRINTCLIENT) &&
      std::wstring(cls) == L"ComboBox" &&
      (GetWindowLongW(h, GWL_STYLE) & 3) == CBS_DROPDOWNLIST) {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    rounded(dc, r, palette.field,
            GetFocus() == h ? palette.accent : palette.line, 12);
    RECT t = r;
    t.left += px(12);
    t.right -= px(28);
    textAt(dc, buttonText(h), t, fontBody, palette.text,
           DT_SINGLELINE | DT_VCENTER);
    t = r;
    t.left = r.right - px(30);
    textAt(dc, L"▾", t, fontSmall, palette.secondary,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (!printing)
      EndPaint(h, &ps);
    return 0;
  }
  if ((msg == WM_PAINT || msg == WM_PRINTCLIENT) &&
      std::wstring(cls) == L"Button") {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    bool hover = GetPropW(h, L"hover") != nullptr,
         pressed = (SendMessageW(h, BM_GETSTATE, 0, 0) & BST_PUSHED) != 0,
         disabled = !IsWindowEnabled(h);
    int id = GetDlgCtrlID(h);
    DWORD kind = GetWindowLongW(h, GWL_STYLE) & BS_TYPEMASK;
    bool toggle = kind == BS_AUTOCHECKBOX || kind == BS_CHECKBOX;
    bool on = SendMessageW(h, BM_GETCHECK, 0, 0) == BST_CHECKED;
    bool primary = id == ID_CONNECT;
    COLORREF bg = primary ? palette.accent
                          : (hover || pressed ? palette.hover : palette.card);
    fill(dc, r, GetParent(h) == connectionsPage ? palette.card : palette.card);
    if (toggle) {
      RECT box{px(1), r.bottom / 2 - px(9), px(19), r.bottom / 2 + px(9)};
      rounded(dc, box, on ? palette.accent : palette.field,
              on ? palette.accent : palette.line, 6);
      if (on) {
        HPEN p = CreatePen(PS_SOLID, px(2), palette.accentText);
        auto old = SelectObject(dc, p);
        MoveToEx(dc, px(5), r.bottom / 2, nullptr);
        LineTo(dc, px(9), r.bottom / 2 + px(4));
        LineTo(dc, px(15), r.bottom / 2 - px(4));
        SelectObject(dc, old);
        DeleteObject(p);
      }
      r.left = px(30);
    } else {
      RECT shape = r;
      InflateRect(&shape, -px(1), -px(1));
      rounded(dc, shape, bg, primary ? bg : (hover ? palette.line : bg), 12);
    }
    auto label = buttonText(h);
    if (id == ID_BACK_CONNECTIONS)
      label = L"‹";
    if (id == ID_AUDIO_TOOL && checked(ID_AUDIO))
      label = L"Audio on";
    textAt(dc, label, r, fontBody,
           disabled ? palette.secondary
                    : (primary ? palette.accentText : palette.text),
           (toggle ? DT_LEFT : DT_CENTER) | DT_VCENTER | DT_SINGLELINE |
               DT_NOPREFIX);
    if (GetFocus() == h) {
      RECT focus = r;
      InflateRect(&focus, -px(3), -px(3));
      DrawFocusRect(dc, &focus);
    }
    if (!printing)
      EndPaint(h, &ps);
    return 0;
  }
  if (msg == WM_NCDESTROY)
    RemoveWindowSubclass(h, themedControl, 1);
  return DefSubclassProc(h, msg, wp, lp);
}
static HWND add(HWND parent, const wchar_t *cls, const wchar_t *text,
                DWORD style, int id, int x, int y, int w, int h) {
  HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, px(x),
                           px(y), px(w), px(h), parent, (HMENU)(INT_PTR)id,
                           GetModuleHandleW(nullptr), nullptr);
  SendMessageW(c, WM_SETFONT, (WPARAM)fontBody, TRUE);
  if (id)
    controls[id] = c;
  SetWindowSubclass(c, themedControl, 1, 0);
  return c;
}
static void place(HWND h, int x, int y, int w, int height) {
  MoveWindow(h, px(x), px(y), px(w), px(height), TRUE);
}
static void field(int id, int x, int y, int w, int height = 46) {
  fieldRects[id] = logicalRect(x, y, w, height);
  place(controls[id], x + 12, y + (height - 22) / 2, w - 24, 22);
}
static void button(int id, int x, int y, int w, int h = 40) {
  place(controls[id], x, y, w, h);
}
static void tooltip(HWND h, const wchar_t *label) {
  if (!tooltipWindow)
    return;
  TOOLINFOW t{};
  t.cbSize = sizeof(t);
  t.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
  t.hwnd = GetParent(h);
  t.uId = (UINT_PTR)h;
  t.lpszText = (wchar_t *)label;
  SendMessageW(tooltipWindow, TTM_ADDTOOLW, 0, (LPARAM)&t);
}
static void drawFields(HWND parent, HDC dc) {
  for (auto &entry : fieldRects) {
    auto found = controls.find(entry.first);
    if (found == controls.end() || GetParent(found->second) != parent ||
        !IsWindowVisible(found->second))
      continue;
    rounded(dc, entry.second, palette.field,
            GetFocus() == found->second ? palette.accent : palette.line, 12);
  }
}
static LRESULT controlColor(UINT msg, WPARAM wp, LPARAM lp) {
  HDC dc = (HDC)wp;
  SetTextColor(dc, palette.text);
  if (msg == WM_CTLCOLORLISTBOX && GetDlgCtrlID((HWND)lp) == ID_SAVED_LIST) {
    SetBkColor(dc, palette.card);
    return (LRESULT)cardBrush;
  }
  if (msg == WM_CTLCOLOREDIT || msg == WM_CTLCOLORLISTBOX) {
    SetBkColor(dc, palette.field);
    return (LRESULT)fieldBrush;
  }
  SetBkColor(dc, palette.card);
  SetBkMode(dc, TRANSPARENT);
  return (LRESULT)cardBrush;
}
static BOOL CALLBACK applyFontToChild(HWND h, LPARAM) {
  SendMessageW(h, WM_SETFONT, (WPARAM)fontBody, TRUE);
  return TRUE;
}
static void applyTheme() {
  HIGHCONTRASTW hc{};
  hc.cbSize = sizeof(hc);
  SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0);
  highContrast = (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
  BOOL animation = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animation, 0);
  reducedMotion = !animation;
  DWORD light = 1, size = sizeof(light);
  RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  darkTheme = forcedTheme < 0 ? !light : forcedTheme == 1;
  palette =
      darkTheme
          ? Palette{RGB(25, 27, 32),    RGB(35, 38, 45),    RGB(44, 47, 55),
                    RGB(242, 244, 249), RGB(166, 174, 190), RGB(65, 70, 82),
                    RGB(103, 152, 255), RGB(12, 27, 52),    RGB(50, 56, 68),
                    RGB(15, 17, 22)}
          : Palette{RGB(246, 247, 250), RGB(255, 255, 255), RGB(247, 248, 250),
                    RGB(27, 31, 39),    RGB(105, 113, 128), RGB(223, 227, 235),
                    RGB(49, 103, 222),  RGB(255, 255, 255), RGB(237, 242, 251),
                    RGB(233, 237, 243)};
  if (highContrast) {
    palette.page = palette.card = palette.field = palette.canvas =
        GetSysColor(COLOR_WINDOW);
    palette.text = GetSysColor(COLOR_WINDOWTEXT);
    palette.secondary = palette.text;
    palette.line = palette.text;
    palette.accent = GetSysColor(COLOR_HIGHLIGHT);
    palette.accentText = GetSysColor(COLOR_HIGHLIGHTTEXT);
    palette.hover = GetSysColor(COLOR_BTNFACE);
  }
  for (auto *b : {&pageBrush, &cardBrush, &fieldBrush})
    if (*b)
      DeleteObject(*b);
  pageBrush = CreateSolidBrush(palette.page);
  cardBrush = CreateSolidBrush(palette.card);
  fieldBrush = CreateSolidBrush(palette.field);
  for (auto *f : {&fontBody, &fontSmall, &fontTitle, &fontHero, &fontStrong})
    if (*f)
      DeleteObject(*f);
  auto font = [](int pixels, int weight) {
    return CreateFontW(-px(pixels), 0, 0, 0, weight, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                       CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  };
  fontBody = font(14, FW_NORMAL);
  fontSmall = font(12, FW_NORMAL);
  fontTitle = font(22, FW_SEMIBOLD);
  fontHero = font(30, FW_SEMIBOLD);
  fontStrong = font(14, FW_SEMIBOLD);
  if (mainWindow) {
    EnumChildWindows(mainWindow, applyFontToChild, 0);
    if (settingsPanel)
      EnumChildWindows(settingsPanel, applyFontToChild, 0);
    using DwmFn = HRESULT(WINAPI *)(HWND, DWORD, LPCVOID, DWORD);
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
      auto fn = (DwmFn)GetProcAddress(dwm, "DwmSetWindowAttribute");
      BOOL dark = darkTheme && !highContrast;
      if (fn) {
        fn(mainWindow, 20, &dark, sizeof(dark));
        if (settingsPanel)
          fn(settingsPanel, 20, &dark, sizeof(dark));
      }
      FreeLibrary(dwm);
    }
    RedrawWindow(mainWindow, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE);
    if (settingsPanel)
      RedrawWindow(settingsPanel, nullptr, nullptr,
                   RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE);
  }
}
static void refreshSavedConnections() {
  savedNames.clear();
  SendMessageW(controls[ID_SAVED_LIST], LB_RESETCONTENT, 0, 0);
  if (settings.contains("presets") && settings["presets"].is_object())
    for (auto it = settings["presets"].begin(); it != settings["presets"].end();
         ++it) {
      savedNames.push_back(it.key());
      SendMessageW(controls[ID_SAVED_LIST], LB_ADDSTRING, 0,
                   (LPARAM)wide(it.key()).c_str());
    }
  InvalidateRect(connectionsPage, nullptr, FALSE);
}
static void refreshToolbar() {
  if (!controls.count(ID_ZOOM_MENU))
    return;
  std::wstring z = fit ? L"Fit ▾" : std::to_wstring((int)(zoom * 100)) + L"% ▾";
  if (buttonText(controls[ID_ZOOM_MENU]) != z)
    SetWindowTextW(controls[ID_ZOOM_MENU], z.c_str());
  SetWindowTextW(controls[ID_AUDIO_TOOL],
                 checked(ID_AUDIO) ? L"Audio on" : L"Audio off");
  EnableWindow(controls[ID_AUDIO_TOOL], IsWindowEnabled(controls[ID_AUDIO]));
  InvalidateRect(mainWindow, nullptr, FALSE);
}
static void layoutConnections() {
  if (!connectionsPage)
    return;
  RECT r;
  GetClientRect(connectionsPage, &r);
  int width = MulDiv(r.right, 96, uiDpi);
  int contentBottom = 144 + (advancedOpen ? 650 : 376);
  pageScroll = std::clamp(
      pageScroll, 0, std::max(0, contentBottom - MulDiv(r.bottom, 96, uiDpi)));
  int outer = std::max(24, (width - 900) / 2), area = std::min(900, width - 48);
  int leftWidth = 220, gap = 24, rightX = outer + leftWidth + gap,
      rightWidth = area - leftWidth - gap, top = 144;
  savedCard = logicalRect(outer, top - pageScroll, leftWidth, 352);
  connectCard = logicalRect(rightX, top - pageScroll, rightWidth,
                            advancedOpen ? 626 : 352);
  place(controls[ID_SAVED_LIST], outer + 12, 192 - pageScroll, leftWidth - 24,
        232);
  SendMessageW(controls[ID_SAVED_LIST], LB_SETITEMHEIGHT, 0, px(68));
  button(ID_NEW_CONNECTION, outer + 12, 444 - pageScroll, leftWidth - 24, 36);
  int x = rightX + 24, w = rightWidth - 48, y = top - pageScroll;
  field(ID_HOST, x, y + 94, w, 42);
  field(ID_PASSWORD, x, y + 176, w, 42);
  button(ID_CONNECT, x, y + 238, w, 42);
  button(ID_ADVANCED, x, y + 298, w, 32);
  for (int id :
       {ID_PORT, ID_ZTNETWORK, ID_ZTMANAGED, ID_ZTSTATUS, ID_CONNECTION_SAVE})
    ShowWindow(controls[id], advancedOpen ? SW_SHOW : SW_HIDE);
  if (advancedOpen) {
    field(ID_PORT, x, y + 384, 88, 42);
    field(ID_ZTNETWORK, x + 104, y + 384, w - 104, 42);
    field(ID_ZTMANAGED, x, y + 466, w, 42);
    button(ID_ZTSTATUS, x, y + 524, w, 36);
    button(ID_CONNECTION_SAVE, x, y + 574, w, 36);
  }
  SCROLLINFO scroll{sizeof(scroll),
                    SIF_RANGE | SIF_PAGE | SIF_POS,
                    0,
                    px(contentBottom),
                    (UINT)r.bottom,
                    px(pageScroll),
                    0};
  SetScrollInfo(connectionsPage, SB_VERT, &scroll, TRUE);
  if (statusLabel) {
    place(statusLabel, rightX + 24,
          top + (advancedOpen ? 630 : 356) - pageScroll, rightWidth - 48, 36);
    ShowWindow(statusLabel, uiStatus.empty() ? SW_HIDE : SW_SHOW);
  }
  InvalidateRect(connectionsPage, nullptr, FALSE);
}
static void paintConnections(HWND hwnd, HDC dc) {
  RECT r;
  GetClientRect(hwnd, &r);
  fill(dc, r, palette.page);
  int outer = std::max(24, (MulDiv(r.right, 96, uiDpi) - 900) / 2);
  RECT badge = logicalRect(outer, 34 - pageScroll, 56, 56);
  HICON mark =
      (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101),
                        IMAGE_ICON, px(56), px(56), 0);
  if (mark) {
    DrawIconEx(dc, badge.left, badge.top, mark, px(56), px(56), 0, nullptr,
               DI_NORMAL);
    DestroyIcon(mark);
  }
  textAt(dc, productName, logicalRect(outer + 72, 29 - pageScroll, 500, 44),
         fontHero, palette.text);
  textAt(dc, L"Your screens, closer.",
         logicalRect(outer + 74, 75 - pageScroll, 500, 24), fontBody,
         palette.secondary);
  textAt(
      dc, L"by Studio Upgrade",
      logicalRect(MulDiv(r.right, 96, uiDpi) - 174, 48 - pageScroll, 150, 22),
      fontSmall, palette.secondary, DT_RIGHT | DT_SINGLELINE);
  rounded(dc, savedCard, palette.card, palette.line, 20);
  rounded(dc, connectCard, palette.card, palette.line, 20);
  RECT h = savedCard;
  h.left += px(24);
  h.top += px(22);
  h.bottom = h.top + px(24);
  textAt(dc, L"Saved connections", h, fontStrong, palette.text);
  if (savedNames.empty()) {
    RECT e = savedCard;
    e.left += px(24);
    e.top += px(85);
    e.right -= px(24);
    textAt(dc, L"Your favorite computers,\none click away.", e, fontBody,
           palette.secondary, DT_WORDBREAK);
  }
  RECT title = connectCard;
  title.left += px(24);
  title.top += px(24);
  title.bottom = title.top + px(32);
  textAt(dc, L"Connect to a computer", title, fontTitle, palette.text);
  int x = MulDiv(connectCard.left, 96, uiDpi) + 24,
      y = MulDiv(connectCard.top, 96, uiDpi),
      w = MulDiv(connectCard.right - connectCard.left, 96, uiDpi) - 48;
  textAt(dc, L"Computer", logicalRect(x, y + 68, w, 22), fontSmall,
         palette.secondary);
  textAt(dc, L"Password", logicalRect(x, y + 150, w, 22), fontSmall,
         palette.secondary);
  if (advancedOpen) {
    textAt(dc, L"Port", logicalRect(x, y + 360, 88, 22), fontSmall,
           palette.secondary);
    textAt(dc, L"ZeroTier network · optional",
           logicalRect(x + 104, y + 360, w - 104, 22), fontSmall,
           palette.secondary);
    textAt(dc, L"Networks to pause", logicalRect(x, y + 442, w, 22), fontSmall,
           palette.secondary);
  }
  drawFields(hwnd, dc);
}
static LRESULT CALLBACK pageProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_COMMAND || msg == WM_DRAWITEM || msg == WM_MEASUREITEM)
    return SendMessageW(mainWindow, msg, wp, lp);
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLOREDIT ||
      msg == WM_CTLCOLORLISTBOX || msg == WM_CTLCOLORBTN)
    return controlColor(msg, wp, lp);
  if (msg == WM_ERASEBKGND)
    return 1;
  if (msg == WM_PAINT || msg == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(hwnd, &ps);
    paintConnections(hwnd, dc);
    if (!printing)
      EndPaint(hwnd, &ps);
    return 0;
  }
  if (msg == WM_SIZE) {
    layoutConnections();
    return 0;
  }
  if (msg == WM_VSCROLL || msg == WM_MOUSEWHEEL) {
    int next = pageScroll;
    if (msg == WM_MOUSEWHEEL)
      next -= GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA * 48;
    else {
      SCROLLINFO si{};
      si.cbSize = sizeof(si);
      si.fMask = SIF_ALL;
      GetScrollInfo(hwnd, SB_VERT, &si);
      switch (LOWORD(wp)) {
      case SB_LINEUP:
        next -= 32;
        break;
      case SB_LINEDOWN:
        next += 32;
        break;
      case SB_PAGEUP:
        next -= 200;
        break;
      case SB_PAGEDOWN:
        next += 200;
        break;
      case SB_THUMBTRACK:
        next = MulDiv(si.nTrackPos, 96, uiDpi);
        break;
      default:
        break;
      }
    }
    SCROLLINFO si{};
    si.cbSize = sizeof(si);
    si.fMask = SIF_ALL;
    GetScrollInfo(hwnd, SB_VERT, &si);
    pageScroll = std::clamp(
        next, 0, std::max(0, MulDiv(si.nMax - (int)si.nPage, 96, uiDpi)));
    layoutConnections();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static void layoutSettings() {
  if (!settingsPanel)
    return;
  int x = 28, w = 488;
  for (auto id : {ID_RES, ID_COLOR, ID_QUALITY}) {
    int y = id == ID_RES ? 88 : id == ID_COLOR ? 152 : 216;
    place(controls[id], x, y, w, 180);
  }
  field(ID_FPS, x, 290, 144, 40);
  field(ID_BANDWIDTH, x + 168, 290, 320, 40);
  button(ID_FOLLOW, x, 354, w, 30);
  button(ID_PAUSE, x, 396, 220, 30);
  button(ID_ALLOW_CONTROL, x + 252, 396, 236, 30);
  field(ID_PRESETS, x, 474, 348, 40);
  button(ID_SAVE, x + 364, 474, 124, 40);
  button(ID_SETTINGS_DONE, x, 540, w, 42);
}
static LRESULT CALLBACK settingsProc(HWND hwnd, UINT msg, WPARAM wp,
                                     LPARAM lp) {
  if (msg == WM_COMMAND || msg == WM_DRAWITEM || msg == WM_MEASUREITEM)
    return SendMessageW(mainWindow, msg, wp, lp);
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLOREDIT ||
      msg == WM_CTLCOLORLISTBOX || msg == WM_CTLCOLORBTN)
    return controlColor(msg, wp, lp);
  if (msg == WM_CLOSE) {
    ShowWindow(hwnd, SW_HIDE);
    SetFocus(canvas);
    return 0;
  }
  if (msg == WM_ERASEBKGND)
    return 1;
  if (msg == WM_PAINT || msg == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(hwnd, &ps);
    RECT r;
    GetClientRect(hwnd, &r);
    fill(dc, r, palette.card);
    textAt(dc, L"Viewing settings", logicalRect(28, 24, 488, 36), fontTitle,
           palette.text);
    for (auto line : std::vector<std::pair<int, const wchar_t *>>{
             {66, L"Resolution"},
             {130, L"Color mode"},
             {194, L"Optimize for"},
             {266, L"Frame rate"},
             {452, L"Saved connection"}})
      textAt(dc, line.second, logicalRect(28, line.first, 488, 22), fontSmall,
             palette.secondary);
    textAt(dc, L"Bandwidth limit · Mbps", logicalRect(196, 266, 320, 22),
           fontSmall, palette.secondary);
    drawFields(hwnd, dc);
    if (!printing)
      EndPaint(hwnd, &ps);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static void openSettings() {
  if (!settingsPanel)
    return;
  check(ID_ALLOW_CONTROL, !checked(ID_VIEWONLY));
  int cap = numberControl(ID_CAP, 4000, 0, 100000);
  std::wostringstream capText;
  if (cap)
    capText << cap / 1000.;
  SetWindowTextW(controls[ID_BANDWIDTH], capText.str().c_str());
  RECT owner;
  GetWindowRect(mainWindow, &owner);
  RECT screen{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &screen, 0);
  int width = px(560), height = px(630);
  int x = std::clamp<int>(owner.right - width - px(20), screen.left,
                          std::max<int>(screen.left, screen.right - width));
  int y = std::clamp<int>(owner.top + px(64), screen.top,
                          std::max<int>(screen.top, screen.bottom - height));
  SetWindowPos(settingsPanel, HWND_TOP, x, y, width, height, SWP_SHOWWINDOW);
  layoutSettings();
  SetFocus(controls[ID_RES]);
}
static void menuEntry(HMENU menu, std::vector<std::wstring> &labels, UINT id,
                      const std::wstring &label, UINT flags = 0) {
  labels.push_back(label);
  AppendMenuW(menu, MF_STRING | flags, id, labels.back().c_str());
  MENUITEMINFOW item{};
  item.cbSize = sizeof(item);
  item.fMask = MIIM_FTYPE | MIIM_DATA;
  item.fType = MFT_OWNERDRAW;
  item.dwItemData = (ULONG_PTR)&labels.back();
  SetMenuItemInfoW(menu, id, FALSE, &item);
}
static HBRUSH menuBackground(HMENU menu) {
  HBRUSH b = CreateSolidBrush(palette.card);
  MENUINFO info{};
  info.cbSize = sizeof(info);
  info.fMask = MIM_BACKGROUND;
  info.hbrBack = b;
  SetMenuInfo(menu, &info);
  return b;
}
static void showDisplaysMenu() {
  HMENU menu = CreatePopupMenu();
  HBRUSH background = menuBackground(menu);
  std::vector<std::wstring> labels;
  labels.reserve(48);
  auto ids = selection();
  for (size_t i = 0; i < displays.size(); i++) {
    std::wstring label =
        std::to_wstring(i + 1) + L"  " + wide(displays[i].name);
    bool on = std::find(ids.begin(), ids.end(), displays[i].id) != ids.end();
    menuEntry(menu, labels, 1000 + (UINT)i, label, on ? MF_CHECKED : 0);
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  menuEntry(menu, labels, 1090, L"All displays");
  RECT anchor;
  GetWindowRect(controls[ID_DISPLAYS_MENU], &anchor);
  int action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_LEFTALIGN, anchor.left,
                              anchor.bottom + px(6), 0, mainWindow, nullptr);
  DestroyMenu(menu);
  DeleteObject(background);
  if (action >= 1000 && action < 1000 + (int)displays.size()) {
    int index = action - 1000;
    SendMessageW(controls[ID_MONITORS], LB_SETSEL,
                 SendMessageW(controls[ID_MONITORS], LB_GETSEL, index, 0) <= 0,
                 index);
  } else if (action == 1090)
    SendMessageW(controls[ID_MONITORS], LB_SETSEL, TRUE, -1);
  else
    return;
  SendMessageW(mainWindow, WM_COMMAND, MAKEWPARAM(ID_MONITORS, LBN_SELCHANGE),
               0);
}
static void showZoomMenu() {
  HMENU menu = CreatePopupMenu();
  HBRUSH background = menuBackground(menu);
  std::vector<std::wstring> labels;
  labels.reserve(8);
  menuEntry(menu, labels, ID_FIT, L"Fit displays", fit ? MF_CHECKED : 0);
  menuEntry(menu, labels, ID_Z100, L"Actual size · 100%");
  menuEntry(menu, labels, ID_ZIN, L"Zoom in");
  menuEntry(menu, labels, ID_ZOUT, L"Zoom out");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  menuEntry(menu, labels, ID_FULL, L"Fullscreen · F11");
  RECT anchor;
  GetWindowRect(controls[ID_ZOOM_MENU], &anchor);
  int id = TrackPopupMenu(menu, TPM_RETURNCMD, anchor.left,
                          anchor.bottom + px(6), 0, mainWindow, nullptr);
  DestroyMenu(menu);
  DeleteObject(background);
  if (id)
    SendMessageW(mainWindow, WM_COMMAND, id, 0);
}
static void layout() {
  if (!mainWindow || !connectionsPage || !canvas)
    return;
  RECT r;
  GetClientRect(mainWindow, &r);
  bool viewing = connected;
  ShowWindow(connectionsPage, viewing ? SW_HIDE : SW_SHOW);
  ShowWindow(canvas, viewing ? SW_SHOW : SW_HIDE);
  for (int id : {ID_BACK_CONNECTIONS, ID_DISPLAYS_MENU, ID_ZOOM_MENU,
                 ID_AUDIO_TOOL, ID_SETTINGS_TOOL})
    ShowWindow(controls[id], viewing && !fullscreen ? SW_SHOW : SW_HIDE);
  if (!viewing) {
    MoveWindow(connectionsPage, 0, 0, r.right, r.bottom, TRUE);
    ShowWindow(settingsPanel, SW_HIDE);
    layoutConnections();
  } else {
    int top = fullscreen ? 0 : px(TOP);
    MoveWindow(canvas, 0, top, r.right, std::max<int>(1, r.bottom - top), TRUE);
    int width = MulDiv(r.right, 96, uiDpi);
    button(ID_BACK_CONNECTIONS, 16, 10, 40, 36);
    button(ID_DISPLAYS_MENU, width - 454, 10, 120, 36);
    button(ID_ZOOM_MENU, width - 326, 10, 88, 36);
    button(ID_AUDIO_TOOL, width - 230, 10, 96, 36);
    button(ID_SETTINGS_TOOL, width - 126, 10, 110, 36);
    refreshToolbar();
    updateScroll();
  }
  InvalidateRect(mainWindow, nullptr, FALSE);
}
static void buildUI(HWND hwnd) {
  mainWindow = hwnd;
  using GetDpiFn = UINT(WINAPI *)(HWND);
  auto getDpi = (GetDpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                         "GetDpiForWindow");
  if (getDpi)
    uiDpi = getDpi(hwnd);
  applyTheme();
  tooltipWindow = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr,
                                  WS_POPUP | TTS_ALWAYSTIP, 0, 0, 0, 0, hwnd,
                                  nullptr, GetModuleHandleW(nullptr), nullptr);
  connectionsPage = CreateWindowExW(
      WS_EX_CONTROLPARENT, L"SURemoteConnections", L"",
      WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 1, 1, hwnd,
      nullptr, GetModuleHandleW(nullptr), nullptr);
  settingsPanel = CreateWindowExW(
      WS_EX_CONTROLPARENT | WS_EX_TOOLWINDOW, L"SURemoteSettings",
      L"Viewing settings", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, 0, 0,
      px(560), px(630), hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  add(connectionsPage, L"LISTBOX", L"",
      LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_TABSTOP,
      ID_SAVED_LIST, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"+  New connection",
      BS_PUSHBUTTON | WS_TABSTOP, ID_NEW_CONNECTION, 0, 0, 1, 1);
  add(connectionsPage, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_HOST, 0, 0,
      1, 1);
  SendMessageW(controls[ID_HOST], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Name or IP address");
  add(connectionsPage, L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP,
      ID_PASSWORD, 0, 0, 1, 1);
  SendMessageW(controls[ID_PASSWORD], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Enter the computer's password");
  add(connectionsPage, L"BUTTON", L"Connect", BS_DEFPUSHBUTTON | WS_TABSTOP,
      ID_CONNECT, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"Advanced  ▾", BS_PUSHBUTTON | WS_TABSTOP,
      ID_ADVANCED, 0, 0, 1, 1);
  add(connectionsPage, L"EDIT", L"5920", ES_NUMBER | WS_TABSTOP, ID_PORT, 0, 0,
      1, 1);
  add(connectionsPage, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_ZTNETWORK,
      0, 0, 1, 1);
  add(connectionsPage, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_ZTMANAGED,
      0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"ZeroTier network status",
      BS_PUSHBUTTON | WS_TABSTOP, ID_ZTSTATUS, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"Save connection",
      BS_PUSHBUTTON | WS_TABSTOP, ID_CONNECTION_SAVE, 0, 0, 1, 1);
  statusLabel = add(connectionsPage, L"STATIC", L"", 0, 0, 0, 0, 1, 1);
  add(settingsPanel, L"LISTBOX", L"", LBS_MULTIPLESEL | LBS_NOTIFY, ID_MONITORS,
      0, 0, 1, 1);
  ShowWindow(controls[ID_MONITORS], SW_HIDE);
  auto combo = [&](int id, std::vector<std::wstring> items, int selected) {
    add(settingsPanel, L"COMBOBOX", L"",
        CBS_DROPDOWNLIST | CBS_OWNERDRAWFIXED | CBS_HASSTRINGS | WS_TABSTOP |
            WS_VSCROLL,
        id, 0, 0, 100, 180);
    for (auto &t : items)
      SendMessageW(controls[id], CB_ADDSTRING, 0, (LPARAM)t.c_str());
    SendMessageW(controls[id], CB_SETCURSEL, selected, 0);
    SendMessageW(controls[id], CB_SETITEMHEIGHT, -1, px(34));
  };
  combo(ID_RES,
        {L"HD · 720p", L"FHD · 1080p", L"QHD · 1440p", L"UHD · 2160p",
         L"Native · smaller displays"},
        1);
  combo(
      ID_COLOR,
      {L"Full color", L"Grayscale · 16 shades", L"256 colors", L"16-bit color"},
      0);
  combo(ID_QUALITY, {L"Automatic", L"Text & controls", L"Video"}, 0);
  add(settingsPanel, L"EDIT", L"15", ES_NUMBER | WS_TABSTOP, ID_FPS, 0, 0, 1,
      1);
  add(settingsPanel, L"EDIT", L"4000", ES_NUMBER, ID_CAP, 0, 0, 1, 1);
  ShowWindow(controls[ID_CAP], SW_HIDE);
  add(settingsPanel, L"EDIT", L"4", ES_AUTOHSCROLL | WS_TABSTOP, ID_BANDWIDTH,
      0, 0, 1, 1);
  SendMessageW(controls[ID_BANDWIDTH], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Automatic");
  add(settingsPanel, L"BUTTON", L"Panning: follow pointer",
      BS_AUTOCHECKBOX | WS_TABSTOP, ID_FOLLOW, 0, 0, 1, 1);
  add(settingsPanel, L"BUTTON", L"Pause viewing", BS_AUTOCHECKBOX | WS_TABSTOP,
      ID_PAUSE, 0, 0, 1, 1);
  add(settingsPanel, L"BUTTON", L"", BS_AUTOCHECKBOX, ID_VIEWONLY, 0, 0, 1, 1);
  ShowWindow(controls[ID_VIEWONLY], SW_HIDE);
  add(settingsPanel, L"BUTTON", L"Allow control", BS_AUTOCHECKBOX | WS_TABSTOP,
      ID_ALLOW_CONTROL, 0, 0, 1, 1);
  check(ID_ALLOW_CONTROL, true);
  add(settingsPanel, L"BUTTON", L"Play computer audio", BS_AUTOCHECKBOX,
      ID_AUDIO, 0, 0, 1, 1);
  ShowWindow(controls[ID_AUDIO], SW_HIDE);
  add(settingsPanel, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_PRESETS, 0,
      0, 1, 22);
  SetWindowTextW(controls[ID_PRESETS], L"Default");
  add(settingsPanel, L"BUTTON", L"Save", BS_PUSHBUTTON | WS_TABSTOP, ID_SAVE, 0,
      0, 1, 1);
  add(settingsPanel, L"BUTTON", L"Done", BS_PUSHBUTTON | WS_TABSTOP,
      ID_SETTINGS_DONE, 0, 0, 1, 1);
  add(hwnd, L"BUTTON", L"Disconnect", BS_PUSHBUTTON | WS_TABSTOP,
      ID_BACK_CONNECTIONS, 0, 0, 1, 1);
  add(hwnd, L"BUTTON", L"Displays  ▾", BS_PUSHBUTTON | WS_TABSTOP,
      ID_DISPLAYS_MENU, 0, 0, 1, 1);
  add(hwnd, L"BUTTON", L"Fit  ▾", BS_PUSHBUTTON | WS_TABSTOP, ID_ZOOM_MENU, 0,
      0, 1, 1);
  add(hwnd, L"BUTTON", L"Audio off", BS_PUSHBUTTON | WS_TABSTOP, ID_AUDIO_TOOL,
      0, 0, 1, 1);
  add(hwnd, L"BUTTON", L"Settings", BS_PUSHBUTTON | WS_TABSTOP,
      ID_SETTINGS_TOOL, 0, 0, 1, 1);
  tooltip(controls[ID_BACK_CONNECTIONS],
          L"Disconnect and return to Connections");
  tooltip(controls[ID_DISPLAYS_MENU], L"Choose which displays to view");
  tooltip(controls[ID_ZOOM_MENU], L"Zoom and fullscreen options");
  tooltip(controls[ID_AUDIO_TOOL], L"Turn computer audio on or off");
  tooltip(controls[ID_SETTINGS_TOOL],
          L"Resolution, color, navigation and saved views");
  canvas =
      CreateWindowExW(0, L"SURemoteCanvas", L"",
                      WS_CHILD | WS_HSCROLL | WS_VSCROLL | WS_TABSTOP, 0, 0, 1,
                      1, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  refreshSavedConnections();
  layoutSettings();
  applyTheme();
  SetTimer(hwnd, 1, 1000, nullptr);
  layout();
}
