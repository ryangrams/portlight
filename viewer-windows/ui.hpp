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
static void drawToolbarIcon(HDC dc, int id, RECT r, COLORREF color) {
  int cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
  RECT box{cx - px(10), cy - px(10), cx + px(10), cy + px(10)};
  if (id >= ID_HD && id <= ID_UHD) {
    int n = id - ID_HD + 2;
    for (int y = 0; y < n; ++y)
      for (int x = 0; x < n; ++x) {
        RECT cell{
            box.left + px(20) * x / n + px(1), box.top + px(20) * y / n + px(1),
            box.left + px(20) * (x + 1) / n, box.top + px(20) * (y + 1) / n};
        fill(dc, cell, color);
      }
    return;
  }
  if (id == ID_FULL_COLOR || id == ID_256 || id == ID_GRAY) {
    for (int y = 0; y < 20; ++y)
      for (int x = 0; x < 20; ++x) {
        COLORREF c;
        if (id == ID_GRAY) {
          int v = (x / 5) * 85;
          c = RGB(v, v, v);
        } else {
          double h = (id == ID_FULL_COLOR ? x / 20. : double(x / 5) / 4) * 6;
          double saturation = id == ID_FULL_COLOR ? .9 : double(y / 5 + 1) / 4;
          double value = id == ID_FULL_COLOR ? 1. - .35 * y / 20. : .9;
          double f = h - std::floor(h), a = value * (1 - saturation),
                 b = value * (1 - f * saturation),
                 d = value * (1 - (1 - f) * saturation);
          double red = 0, green = 0, blue = 0;
          switch ((int)h % 6) {
          case 0:
            red = value;
            green = d;
            blue = a;
            break;
          case 1:
            red = b;
            green = value;
            blue = a;
            break;
          case 2:
            red = a;
            green = value;
            blue = d;
            break;
          case 3:
            red = a;
            green = b;
            blue = value;
            break;
          case 4:
            red = d;
            green = a;
            blue = value;
            break;
          default:
            red = value;
            green = a;
            blue = b;
          }
          c = RGB((int)(255 * red), (int)(255 * green), (int)(255 * blue));
        }
        RECT dot{box.left + px(x), box.top + px(y), box.left + px(x + 1),
                 box.top + px(y + 1)};
        fill(dc, dot, c);
      }
    return;
  }
  HPEN pen = CreatePen(PS_SOLID, px(2), color);
  auto oldPen = SelectObject(dc, pen),
       oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  auto line = [&](int x1, int y1, int x2, int y2) {
    MoveToEx(dc, cx + px(x1), cy + px(y1), nullptr);
    LineTo(dc, cx + px(x2), cy + px(y2));
  };
  if (id == ID_SIDEBAR) {
    Rectangle(dc, box.left, box.top + px(2), box.right, box.bottom - px(2));
    line(-3, -8, -3, 8);
    line(-8, -4, -5, -4);
    line(-8, 0, -5, 0);
  } else if (id == ID_ZIN || id == ID_ZOUT) {
    Ellipse(dc, cx - px(10), cy - px(10), cx + px(4), cy + px(4));
    line(2, 2, 9, 9);
    line(-7, -3, 1, -3);
    if (id == ID_ZIN)
      line(-3, -7, -3, 1);
  } else if (id == ID_PAUSE) {
    if (checked(ID_PAUSE)) {
      POINT points[] = {
          {cx - px(6), cy - px(9)}, {cx + px(8), cy}, {cx - px(6), cy + px(9)}};
      Polygon(dc, points, 3);
    } else {
      line(-5, -9, -5, 9);
      line(5, -9, 5, 9);
    }
  } else if (id == ID_AUDIO_TOOL) {
    POINT points[] = {{cx - px(9), cy - px(4)}, {cx - px(4), cy - px(4)},
                      {cx + px(1), cy - px(9)}, {cx + px(1), cy + px(9)},
                      {cx - px(4), cy + px(4)}, {cx - px(9), cy + px(4)}};
    Polygon(dc, points, 6);
    if (checked(ID_AUDIO))
      Arc(dc, cx, cy - px(8), cx + px(12), cy + px(8), cx + px(4), cy - px(8),
          cx + px(4), cy + px(8));
    else {
      line(5, -4, 11, 4);
      line(11, -4, 5, 4);
    }
  } else if (id == ID_FULL || id == ID_FIT) {
    line(-9, -3, -9, -8);
    line(-9, -8, -3, -8);
    line(3, -8, 9, -8);
    line(9, -8, 9, -3);
    line(-9, 3, -9, 8);
    line(-9, 8, -3, 8);
    line(3, 8, 9, 8);
    line(9, 8, 9, 3);
    if (id == ID_FIT)
      Rectangle(dc, cx - px(5), cy - px(4), cx + px(5), cy + px(4));
  } else if (id == ID_FOLLOW) {
    line(-10, 0, 10, 0);
    line(0, -10, 0, 10);
    line(-10, 0, -6, -4);
    line(10, 0, 6, 4);
    line(0, -10, 4, -6);
    line(0, 10, -4, 6);
  } else if (id == ID_ALLOW_CONTROL) {
    auto t = checked(ID_PAUSE)      ? L"Paused"
             : checked(ID_VIEWONLY) ? L"View Only"
                                    : L"Control On";
    textAt(dc, t, r, fontStrong, color, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  } else if (id == ID_SETTINGS_TOOL)
    textAt(dc, L"Mbps ▾", r, fontSmall, color,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  else if (id == ID_BACK_CONNECTIONS)
    textAt(dc, L"Disconnect", r, fontSmall, color,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  else if (id == ID_Z100)
    textAt(dc, L"100%", r, fontSmall, color,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  SelectObject(dc, oldBrush);
  SelectObject(dc, oldPen);
  DeleteObject(pen);
}
static LRESULT CALLBACK themedControl(HWND h, UINT msg, WPARAM wp, LPARAM lp,
                                      UINT_PTR, DWORD_PTR) {
  if (msg == WM_CONTEXTMENU && GetParent(h) == mainWindow) {
    POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    toolbarMenu(point);
    return 0;
  }
  if (msg == WM_LBUTTONUP && GetDlgCtrlID(h) == ID_DISPLAYS_MENU) {
    RECT r;
    GetClientRect(h, &r);
    if (!displayMapNeedsExpansion(r)) {
      DefSubclassProc(h, WM_CANCELMODE, 0, 0);
      toggleDisplayAt({GET_X_LPARAM(lp), GET_Y_LPARAM(lp)}, r, false);
      return 0;
    }
  }
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
    bool tool = GetParent(h) == mainWindow;
    bool toggle = !tool && (kind == BS_AUTOCHECKBOX || kind == BS_CHECKBOX);
    bool on = SendMessageW(h, BM_GETCHECK, 0, 0) == BST_CHECKED;
    bool primary = id == ID_CONNECT;
    bool bare = id == ID_NEW_CONNECTION || id == ID_REMOVE || id == ID_SIDEBAR;
    bool active =
        (id >= ID_HD && id <= ID_UHD && comboIndex(ID_RES) == id - ID_HD) ||
        (id == ID_FULL_COLOR && comboIndex(ID_COLOR) == 0) ||
        (id == ID_256 && comboIndex(ID_COLOR) == 2) ||
        (id == ID_GRAY && comboIndex(ID_COLOR) == 1) ||
        (id == ID_ALLOW_CONTROL && !checked(ID_VIEWONLY) &&
         !checked(ID_PAUSE)) ||
        (id == ID_PAUSE && checked(ID_PAUSE)) ||
        (id == ID_AUDIO_TOOL && checked(ID_AUDIO)) || (id == ID_FIT && fit) ||
        (id == ID_FOLLOW && follow);
    COLORREF bg = primary || (active && id == ID_ALLOW_CONTROL) ? palette.accent
                  : active || hover || pressed                  ? palette.hover
                                                                : palette.card;
    fill(dc, r,
         GetParent(h) == connectionsPage && !bare ? palette.page
                                                  : palette.card);
    if (toggle) {
      RECT box{px(1), r.bottom / 2 - px(8), px(17), r.bottom / 2 + px(8)};
      rounded(dc, box, on ? palette.accent : palette.field,
              on ? palette.accent : palette.line, 4);
      if (on)
        textAt(dc, L"✓", box, fontSmall, palette.accentText,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      r.left = px(26);
    } else if (!bare) {
      RECT shape = r;
      InflateRect(&shape, -px(2), -px(3));
      rounded(dc, shape, bg,
              active ? palette.accent : (hover ? palette.line : bg), 8);
      if (active) {
        InflateRect(&shape, -px(1), -px(1));
        rounded(dc, shape, bg, palette.accent, 7);
      }
    }
    COLORREF fg =
        disabled                                        ? palette.secondary
        : primary || (active && id == ID_ALLOW_CONTROL) ? palette.accentText
        : bare ? (pressed ? (darkTheme ? RGB(255, 255, 255) : RGB(0, 0, 0))
                          : palette.secondary)
               : palette.text;
    if (id == ID_DISPLAYS_MENU)
      drawDisplayMap(dc, r, false);
    else if (tool || id == ID_SIDEBAR) {
      RECT icon = r;
      if (toolbarLabels && tool)
        icon.bottom = icon.top + px(30);
      drawToolbarIcon(dc, id, icon, fg);
      if (toolbarLabels && tool) {
        RECT label = r;
        label.top = px(30);
        textAt(dc, buttonText(h), label, fontSmall, fg,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      }
    } else
      textAt(dc, buttonText(h), r, fontBody, fg,
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
  bool page = GetParent((HWND)lp) == connectionsPage;
  SetBkColor(dc, page ? palette.page : palette.card);
  SetBkMode(dc, TRANSPARENT);
  return (LRESULT)(page ? pageBrush : cardBrush);
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
          ? Palette{RGB(29, 29, 29),    RGB(55, 55, 55),    RGB(40, 40, 40),
                    RGB(242, 244, 249), RGB(166, 174, 190), RGB(65, 70, 82),
                    RGB(103, 152, 255), RGB(12, 27, 52),    RGB(50, 56, 68),
                    RGB(15, 17, 22)}
          : Palette{RGB(250, 250, 250), RGB(232, 232, 232), RGB(255, 255, 255),
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
static std::wstring askName(const wchar_t *title, const std::wstring &initial) {
  RECT owner;
  GetWindowRect(mainWindow, &owner);
  HWND dialog =
      CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"STATIC",
                      title, WS_POPUP | WS_CAPTION | WS_SYSMENU,
                      owner.left + px(60), owner.top + px(90), px(340), px(150),
                      mainWindow, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND edit = CreateWindowExW(
      WS_EX_CLIENTEDGE, L"EDIT", initial.c_str(),
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, px(16), px(18),
      px(292), px(30), dialog, (HMENU)100, GetModuleHandleW(nullptr), nullptr);
  HWND ok = CreateWindowW(L"BUTTON", L"Save",
                          WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                          px(216), px(64), px(92), px(30), dialog, (HMENU)IDOK,
                          GetModuleHandleW(nullptr), nullptr);
  HWND cancel =
      CreateWindowW(L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                    px(116), px(64), px(92), px(30), dialog, (HMENU)IDCANCEL,
                    GetModuleHandleW(nullptr), nullptr);
  for (auto h : {edit, ok, cancel})
    SendMessageW(h, WM_SETFONT, (WPARAM)fontBody, TRUE);
  EnableWindow(mainWindow, FALSE);
  ShowWindow(dialog, SW_SHOW);
  SetFocus(edit);
  SendMessageW(edit, EM_SETSEL, 0, -1);
  std::wstring result;
  MSG msg{};
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if ((msg.hwnd == dialog &&
         (msg.message == WM_CLOSE ||
          (msg.message == WM_COMMAND &&
           (LOWORD(msg.wParam) == IDOK || LOWORD(msg.wParam) == IDCANCEL)))) ||
        (msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE)) {
      if (msg.message == WM_COMMAND && LOWORD(msg.wParam) == IDOK)
        result = buttonText(edit);
      break;
    }
    if (msg.message == WM_KEYDOWN && msg.wParam == VK_RETURN) {
      result = buttonText(edit);
      break;
    }
    if (!IsDialogMessageW(dialog, &msg)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  EnableWindow(mainWindow, TRUE);
  DestroyWindow(dialog);
  SetForegroundWindow(mainWindow);
  return result;
}
static std::vector<std::string> orderedPresets() {
  auto presets = settings.value("presets", json::object());
  std::vector<std::string> result;
  for (auto &item : settings.value("presetOrder", json::array()))
    if (item.is_string() && presets.contains(item.get<std::string>()) &&
        std::find(result.begin(), result.end(), item.get<std::string>()) ==
            result.end())
      result.push_back(item.get<std::string>());
  for (auto it = presets.begin(); it != presets.end(); ++it)
    if (std::find(result.begin(), result.end(), it.key()) == result.end())
      result.push_back(it.key());
  return result;
}
static void refreshSavedConnections() {
  savedNames.clear();
  savedRows.clear();
  auto list = controls[ID_SAVED_LIST];
  SendMessageW(list, WM_SETREDRAW, FALSE, 0);
  SendMessageW(list, LB_RESETCONTENT, 0, 0);
  auto presets = settings.value("presets", json::object()),
       groups = settings.value("groups", json::object());
  auto order = orderedPresets();
  auto row = [&](std::string name, bool group) {
    savedRows.push_back({name, group});
    savedNames.push_back(name);
    SendMessageW(list, LB_ADDSTRING, 0, (LPARAM)wide(name).c_str());
  };
  for (auto &name : order) {
    auto group = presets[name].value("group", "");
    if (group.empty() || !groups.contains(group))
      row(name, false);
  }
  std::vector<std::string> groupOrder;
  for (auto &g : settings.value("groupOrder", json::array()))
    if (g.is_string() && groups.contains(g.get<std::string>()))
      groupOrder.push_back(g.get<std::string>());
  for (auto it = groups.begin(); it != groups.end(); ++it)
    if (std::find(groupOrder.begin(), groupOrder.end(), it.key()) ==
        groupOrder.end())
      groupOrder.push_back(it.key());
  for (auto &group : groupOrder) {
    row(group, true);
    if (groups[group].value("expanded", true))
      for (auto &name : order)
        if (presets[name].value("group", "") == group)
          row(name, false);
  }
  for (size_t i = 0; i < savedRows.size(); ++i)
    if (!savedRows[i].group && savedRows[i].name == editingPreset)
      SendMessageW(list, LB_SETCURSEL, i, 0);
  SendMessageW(list, WM_SETREDRAW, TRUE, 0);
  InvalidateRect(list, nullptr, FALSE);
  InvalidateRect(connectionsPage, nullptr, FALSE);
}
static bool savedListCommand(int code) {
  int index = (int)SendMessageW(controls[ID_SAVED_LIST], LB_GETCURSEL, 0, 0);
  if (index < 0 || index >= (int)savedRows.size())
    return true;
  auto row = savedRows[index];
  if (row.group) {
    if (code == -42) {
      auto &group = settings["groups"][row.name];
      group["expanded"] = !group.value("expanded", true);
      saveSettings();
      refreshSavedConnections();
      for (size_t i = 0; i < savedRows.size(); ++i)
        if (savedRows[i].group && savedRows[i].name == row.name)
          SendMessageW(controls[ID_SAVED_LIST], LB_SETCURSEL, i, 0);
    }
  } else if (code == LBN_SELCHANGE)
    recallPreset(row.name);
  else if (code == LBN_DBLCLK) {
    recallPreset(row.name);
    startConnection();
  }
  return true;
}
static void newConnection() {
  if (zeroTierActivating)
    cancelZeroTierActivation();
  editingPreset.clear();
  for (int id : std::vector<int>{ID_PRESETS, ID_HOST, ID_PASSWORD, ID_ZTNETWORK,
                                 ID_ZTMANAGED})
    SetWindowTextW(controls[id], L"");
  SetWindowTextW(controls[ID_PORT], L"5920");
  SetWindowTextW(controls[ID_CONNECTION_SAVE], L"Save Connection");
  SendMessageW(controls[ID_PASSWORD], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Password");
  check(ID_REMEMBER, false);
  check(ID_ZT_DISCONNECT, false);
  SendMessageW(controls[ID_SAVED_LIST], LB_SETCURSEL, -1, 0);
  SetFocus(controls[ID_PRESETS]);
  status(L"");
}
static void showNewMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 1, L"New Connection");
  AppendMenuW(menu, MF_STRING, 2, L"New Group…");
  RECT r;
  GetWindowRect(controls[ID_NEW_CONNECTION], &r);
  int chosen = TrackPopupMenu(menu, TPM_RETURNCMD, r.left, r.top, 0, mainWindow,
                              nullptr);
  DestroyMenu(menu);
  if (chosen == 1)
    newConnection();
  if (chosen == 2) {
    auto name = narrow(askName(L"New Group", L"New Group"));
    if (!name.empty()) {
      settings["groups"][name] = {{"expanded", true}};
      saveSettings();
      refreshSavedConnections();
    }
  }
}
static void removeSaved() {
  int index = (int)SendMessageW(controls[ID_SAVED_LIST], LB_GETCURSEL, 0, 0);
  if (index < 0 || index >= (int)savedRows.size())
    return;
  auto row = savedRows[index];
  if (row.group) {
    settings["groups"].erase(row.name);
    for (auto &p : settings["presets"])
      if (p.value("group", "") == row.name)
        p["group"] = "";
  } else {
    auto target = credentialTarget(settings["presets"][row.name]);
    if (!target.empty())
      CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
    settings["presets"].erase(row.name);
    if (editingPreset == row.name)
      newConnection();
  }
  saveSettings();
  refreshSavedConnections();
}
static LRESULT CALLBACK savedListProc(HWND h, UINT msg, WPARAM wp, LPARAM lp,
                                      UINT_PTR, DWORD_PTR) {
  static POINT down{};
  static int source = -1;
  static bool dragging = false;
  if (msg == WM_LBUTTONDOWN) {
    down = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    DWORD item = (DWORD)SendMessageW(h, LB_ITEMFROMPOINT, 0, lp);
    source = HIWORD(item) ? -1 : LOWORD(item);
    dragging = false;
    if (source >= 0 && source < (int)savedRows.size() &&
        savedRows[source].group) {
      SetFocus(h);
      SendMessageW(h, LB_SETCURSEL, source, 0);
      savedListCommand(-42);
      return 0;
    }
  }
  if (msg == WM_LBUTTONDBLCLK && source >= 0 &&
      source < (int)savedRows.size() && savedRows[source].group)
    return 0;
  if (msg == WM_KEYDOWN && (wp == VK_LEFT || wp == VK_RIGHT)) {
    int i = (int)SendMessageW(h, LB_GETCURSEL, 0, 0);
    if (i >= 0 && i < (int)savedRows.size() && savedRows[i].group &&
        settings["groups"][savedRows[i].name].value("expanded", true) !=
            (wp == VK_RIGHT))
      savedListCommand(-42);
    return 0;
  }
  if (msg == WM_MOUSEMOVE && (wp & MK_LBUTTON) && source >= 0 && !dragging &&
      (abs(GET_X_LPARAM(lp) - down.x) > px(5) ||
       abs(GET_Y_LPARAM(lp) - down.y) > px(5))) {
    dragging = true;
    SetCapture(h);
  }
  if (msg == WM_LBUTTONUP && dragging) {
    DWORD item = (DWORD)SendMessageW(h, LB_ITEMFROMPOINT, 0, lp);
    int dest = HIWORD(item) ? -1 : LOWORD(item);
    ReleaseCapture();
    dragging = false;
    if (source < (int)savedRows.size()) {
      auto row = savedRows[source];
      auto order = orderedPresets();
      if (!row.group) {
        std::string group;
        if (dest >= 0 && dest < (int)savedRows.size()) {
          auto target = savedRows[dest];
          group = target.group
                      ? target.name
                      : settings["presets"][target.name].value("group", "");
          if (!target.group && row.name != target.name) {
            order.erase(std::remove(order.begin(), order.end(), row.name),
                        order.end());
            order.insert(std::find(order.begin(), order.end(), target.name),
                         row.name);
          }
        }
        settings["presets"][row.name]["group"] = group;
        settings["presetOrder"] = order;
      } else if (dest >= 0 && dest < (int)savedRows.size() &&
                 savedRows[dest].group && savedRows[dest].name != row.name) {
        std::vector<std::string> groups;
        for (auto &r : savedRows)
          if (r.group && r.name != row.name)
            groups.push_back(r.name);
        groups.insert(
            std::find(groups.begin(), groups.end(), savedRows[dest].name),
            row.name);
        settings["groupOrder"] = groups;
      }
      saveSettings();
      refreshSavedConnections();
    }
    source = -1;
    return 0;
  }
  if (msg == WM_CONTEXTMENU || (msg == WM_KEYDOWN && wp == VK_F2)) {
    int i = (int)SendMessageW(h, LB_GETCURSEL, 0, 0);
    if (i < 0 || i >= (int)savedRows.size())
      return 0;
    auto row = savedRows[i];
    if (msg == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu(), groups = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Rename…");
      AppendMenuW(menu, MF_STRING, 2, L"Remove");
      std::vector<std::string> destinations{""};
      if (!row.group) {
        AppendMenuW(groups, MF_STRING, 100, L"Outside Groups");
        for (auto it = settings["groups"].begin();
             it != settings["groups"].end(); ++it) {
          destinations.push_back(it.key());
          AppendMenuW(groups, MF_STRING, 99 + destinations.size(),
                      wide(it.key()).c_str());
        }
        AppendMenuW(menu, MF_POPUP, (UINT_PTR)groups, L"Move to Group");
      } else
        DestroyMenu(groups);
      POINT point{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      if (point.x == -1) {
        RECT r;
        GetWindowRect(h, &r);
        point = {r.left + px(20), r.top + px(20)};
      }
      int action = TrackPopupMenu(menu, TPM_RETURNCMD, point.x, point.y, 0,
                                  mainWindow, nullptr);
      DestroyMenu(menu);
      if (action == 2) {
        removeSaved();
        return 0;
      }
      if (action >= 100 && action < 100 + (int)destinations.size()) {
        settings["presets"][row.name]["group"] = destinations[action - 100];
        saveSettings();
        refreshSavedConnections();
        return 0;
      }
      if (action != 1)
        return 0;
    }
    auto newName = narrow(askName(
        row.group ? L"Rename Group" : L"Rename Connection", wide(row.name)));
    if (!newName.empty() && newName != row.name) {
      auto &collection = settings[row.group ? "groups" : "presets"];
      if (collection.contains(newName)) {
        status(L"This name is already in use");
        return 0;
      }
      collection[newName] = collection[row.name];
      collection.erase(row.name);
      if (row.group) {
        for (auto &p : settings["presets"])
          if (p.value("group", "") == row.name)
            p["group"] = newName;
      } else if (editingPreset == row.name) {
        editingPreset = newName;
        SetWindowTextW(controls[ID_PRESETS], wide(newName).c_str());
      }
      auto key = row.group ? "groupOrder" : "presetOrder";
      if (settings.contains(key))
        for (auto &v : settings[key])
          if (v == row.name)
            v = newName;
      saveSettings();
      refreshSavedConnections();
    }
    return 0;
  }
  if (msg == WM_NCDESTROY)
    RemoveWindowSubclass(h, savedListProc, 2);
  return DefSubclassProc(h, msg, wp, lp);
}
static void refreshToolbar() {
  if (!controls.count(ID_AUDIO_TOOL))
    return;
  check(ID_ALLOW_CONTROL, !checked(ID_VIEWONLY));
  for (int id = ID_HD; id <= ID_UHD; ++id)
    check(id, comboIndex(ID_RES) == id - ID_HD);
  check(ID_FULL_COLOR, comboIndex(ID_COLOR) == 0);
  check(ID_256, comboIndex(ID_COLOR) == 2);
  check(ID_GRAY, comboIndex(ID_COLOR) == 1);
  SetWindowTextW(controls[ID_ALLOW_CONTROL],
                 checked(ID_VIEWONLY) ? L"View Only" : L"Control On");
  EnableWindow(controls[ID_ALLOW_CONTROL], !checked(ID_PAUSE));
  EnableWindow(controls[ID_AUDIO_TOOL], IsWindowEnabled(controls[ID_AUDIO]));
  EnableWindow(controls[ID_AUDIO_QUALITY], aacAvailable || !connected);
  EnableWindow(controls[ID_DITHER],
               comboIndex(ID_QUALITY) == 2 && comboIndex(ID_COLOR) != 0);
  for (int id = ID_HD; id <= ID_UHD; ++id)
    EnableWindow(controls[id], resolutionSupported(id - ID_HD));
  for (auto &item : controls)
    if (GetParent(item.second) == mainWindow)
      InvalidateRect(item.second, nullptr, FALSE);
  InvalidateRect(mainWindow, nullptr, FALSE);
}
static int connectionMinWidth() { return sidebarVisible ? 680 : 440; }
static void toggleSidebar() {
  sidebarVisible = !sidebarVisible;
  settings["sidebarVisible"] = sidebarVisible;
  saveSettings();
  if (sidebarVisible) {
    RECT r;
    GetWindowRect(mainWindow, &r);
    int minimum = px(connectionMinWidth());
    if (r.right - r.left < minimum)
      SetWindowPos(mainWindow, nullptr, 0, 0, minimum, r.bottom - r.top,
                   SWP_NOMOVE | SWP_NOZORDER);
  }
  sidebarFrom = sidebarWidth;
  sidebarTo = sidebarVisible ? 216 : 0;
  sidebarStarted = GetTickCount64();
  sidebarAnimating = !reducedMotion;
  if (sidebarAnimating)
    SetTimer(mainWindow, 4, 16, nullptr);
  else {
    sidebarWidth = sidebarTo;
    layout();
  }
  SetFocus(controls[ID_SIDEBAR]);
}
static void layoutConnections() {
  if (!connectionsPage)
    return;
  RECT r;
  GetClientRect(connectionsPage, &r);
  int width = MulDiv(r.right, 96, uiDpi), height = MulDiv(r.bottom, 96, uiDpi),
      side = (int)std::round(sidebarWidth);
  savedCard = logicalRect(0, 0, side, height);
  connectCard = logicalRect(side, 56, width - side, height - 56);
  button(ID_SIDEBAR, 14, 12, 36, 32);
  bool visible = side > 20;
  for (int id : {ID_SAVED_LIST, ID_NEW_CONNECTION, ID_REMOVE})
    ShowWindow(controls[id], visible ? SW_SHOW : SW_HIDE);
  place(controls[ID_SAVED_LIST], 8, 62, std::max(1, side - 16),
        std::max(1, height - 104));
  SendMessageW(controls[ID_SAVED_LIST], LB_SETITEMHEIGHT, 0, px(28));
  button(ID_NEW_CONNECTION, 8, height - 34, 28, 28);
  button(ID_REMOVE, 44, height - 34, 28, 28);
  int area = width - side, w = std::min(430, area - 48),
      x = side + (area - w) / 2;
  int top = 64;
  pageScroll = std::clamp(pageScroll, 0, std::max(0, 500 - height));
  top -= pageScroll;
  field(ID_PRESETS, x, top + 28, w, 36);
  field(ID_HOST, x, top + 102, w, 36);
  field(ID_PASSWORD, x, top + 176, w - 104, 36);
  field(ID_PORT, x + w - 88, top + 176, 88, 36);
  button(ID_REMEMBER, x, top + 220, w, 26);
  button(ID_ADVANCED, x, top + 258, 100, 30);
  button(ID_CONNECTION_SAVE, x, top + 310, w - 128, 36);
  button(ID_CONNECT, x + w - 116, top + 310, 116, 36);
  place(statusLabel, x, top + 364, w, 66);
  ShowWindow(statusLabel, uiStatus.empty() ? SW_HIDE : SW_SHOW);
  SCROLLINFO scroll{sizeof(scroll),
                    SIF_RANGE | SIF_PAGE | SIF_POS,
                    0,
                    px(500),
                    (UINT)r.bottom,
                    px(pageScroll),
                    0};
  SetScrollInfo(connectionsPage, SB_VERT, &scroll, TRUE);
  InvalidateRect(connectionsPage, nullptr, FALSE);
}
static void paintConnections(HWND hwnd, HDC dc) {
  RECT r;
  GetClientRect(hwnd, &r);
  fill(dc, r, palette.page);
  fill(dc, savedCard, palette.card);
  if (savedCard.right > 0) {
    RECT divider{savedCard.right - 1, 0, savedCard.right, r.bottom};
    fill(dc, divider, palette.line);
    RECT bottom{0, r.bottom - px(40), savedCard.right, r.bottom - px(39)};
    fill(dc, bottom, palette.line);
    RECT sep{px(39), r.bottom - px(29), px(40), r.bottom - px(11)};
    fill(dc, sep, palette.line);
  }
  textAt(dc, L"Portlight", logicalRect(60, 16, 180, 26), fontStrong,
         palette.text, DT_SINGLELINE | DT_VCENTER);
  int x = fieldRects[ID_PRESETS].left, w = fieldRects[ID_PRESETS].right - x;
  auto label = [&](const wchar_t *title, int id) {
    RECT f = fieldRects[id];
    f.top -= px(23);
    f.bottom = f.top + px(20);
    textAt(dc, title, f, fontSmall, palette.secondary);
  };
  label(L"Connection name · optional", ID_PRESETS);
  label(L"Computer", ID_HOST);
  label(L"Password", ID_PASSWORD);
  label(L"Port", ID_PORT);
  RECT branding{x, r.bottom - px(24), x + w, r.bottom - px(6)};
  textAt(dc, L"Studio Upgrade", branding, fontSmall, palette.secondary,
         DT_RIGHT | DT_SINGLELINE);
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
    HDC target = msg == WM_PRINTCLIENT ? (HDC)wp : BeginPaint(hwnd, &ps);
    RECT r;
    GetClientRect(hwnd, &r);
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bitmap = CreateCompatibleBitmap(target, std::max<LONG>(1, r.right),
                                            std::max<LONG>(1, r.bottom));
    auto old = SelectObject(dc, bitmap);
    paintConnections(hwnd, dc);
    BitBlt(target, 0, 0, r.right, r.bottom, dc, 0, 0, SRCCOPY);
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    if (msg == WM_PAINT)
      EndPaint(hwnd, &ps);
    return 0;
  }
  if (msg == WM_SIZE) {
    layoutConnections();
    return 0;
  }
  if (msg == WM_VSCROLL || msg == WM_MOUSEWHEEL) {
    if (msg == WM_MOUSEWHEEL)
      pageScroll -= GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA * 36;
    else {
      SCROLLINFO si{};
      si.cbSize = sizeof(si);
      si.fMask = SIF_ALL;
      GetScrollInfo(hwnd, SB_VERT, &si);
      switch (LOWORD(wp)) {
      case SB_THUMBTRACK:
        pageScroll = MulDiv(si.nTrackPos, 96, uiDpi);
        break;
      case SB_LINEUP:
        pageScroll -= 28;
        break;
      case SB_LINEDOWN:
        pageScroll += 28;
        break;
      case SB_PAGEUP:
        pageScroll -= 150;
        break;
      case SB_PAGEDOWN:
        pageScroll += 150;
        break;
      }
    }
    layoutConnections();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static void layoutSettings() {
  if (!settingsPanel)
    return;
  place(controls[ID_QUALITY], 20, 48, 290, 180);
  field(ID_BANDWIDTH, 20, 126, 290, 36);
  place(controls[ID_AUDIO_QUALITY], 20, 218, 290, 180);
  button(ID_DITHER, 20, 280, 290, 28);
  button(ID_SETTINGS_DONE, 210, 338, 100, 32);
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
    HDC dc = msg == WM_PRINTCLIENT ? (HDC)wp : BeginPaint(hwnd, &ps);
    RECT r;
    GetClientRect(hwnd, &r);
    fill(dc, r, palette.card);
    for (auto line : std::vector<std::pair<int, const wchar_t *>>{
             {20, L"Optimize video for"},
             {100, L"Video limit · Mbps"},
             {168, L"Blank or 0 = Automatic"},
             {192, L"Audio quality"},
             {310, L"Smoothing uses more data; Video mode only."}})
      textAt(dc, line.second, logicalRect(20, line.first, 292, 24), fontSmall,
             palette.secondary);
    drawFields(hwnd, dc);
    if (msg == WM_PAINT)
      EndPaint(hwnd, &ps);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static void openSettings() {
  int cap = numberControl(ID_CAP, 0, 0, 100000);
  std::wostringstream text;
  if (cap)
    text << cap / 1000.;
  SetWindowTextW(controls[ID_BANDWIDTH], text.str().c_str());
  RECT anchor;
  GetWindowRect(controls[ID_SETTINGS_TOOL], &anchor);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfoW(MonitorFromWindow(mainWindow, MONITOR_DEFAULTTONEAREST), &mi);
  SetWindowPos(
      settingsPanel, HWND_TOP,
      std::clamp<int>(anchor.right - px(340), mi.rcWork.left,
                      std::max<int>(mi.rcWork.left, mi.rcWork.right - px(340))),
      std::clamp<int>(anchor.bottom, mi.rcWork.top,
                      std::max<int>(mi.rcWork.top, mi.rcWork.bottom - px(420))),
      px(340), px(420), SWP_SHOWWINDOW);
  layoutSettings();
  SetFocus(controls[ID_QUALITY]);
}
static std::map<std::string, RECT> mapRects(RECT area) {
  auto frames = monitorLayout(false, false);
  auto size = portlight::bounds(frames);
  std::map<std::string, RECT> result;
  if (size.w <= 0 || size.h <= 0)
    return result;
  double scale = std::min((area.right - area.left - px(8)) / size.w,
                          (area.bottom - area.top - px(8)) / size.h);
  double x = area.left + (area.right - area.left - size.w * scale) / 2,
         y = area.top + (area.bottom - area.top - size.h * scale) / 2;
  for (auto &p : frames) {
    auto f = p.second;
    result[p.first] = {(LONG)(x + f.x * scale + px(1)),
                       (LONG)(y + f.y * scale + px(1)),
                       (LONG)(x + (f.x + f.w) * scale - px(1)),
                       (LONG)(y + (f.y + f.h) * scale - px(1))};
  }
  return result;
}
static bool displayMapNeedsExpansion(RECT area) {
  auto rectangles = mapRects(area);
  for (auto &p : rectangles)
    if (p.second.right - p.second.left < px(28) ||
        p.second.bottom - p.second.top < px(20))
      return true;
  return rectangles.empty();
}
static void drawDisplayMap(HDC dc, RECT area, bool expanded) {
  auto ids = selection();
  if (!expanded && displayMapNeedsExpansion(area)) {
    int cy = (area.top + area.bottom) / 2;
    RECT one{area.left + px(8), cy - px(6), area.left + px(24), cy + px(5)},
        two = one;
    OffsetRect(&two, px(6), -px(5));
    rounded(dc, two, palette.card, palette.secondary, 2);
    rounded(dc, one, palette.card, palette.text, 2);
    area.left += px(38);
    textAt(dc, L"Displays (" + std::to_wstring(ids.size()) + L") ▾", area,
           fontSmall, palette.text, DT_SINGLELINE | DT_VCENTER);
    return;
  }
  auto rectangles = mapRects(area);
  for (size_t i = 0; i < displays.size(); ++i) {
    auto id = displays[i].id;
    auto r = rectangles[id];
    bool on = std::find(ids.begin(), ids.end(), id) != ids.end();
    rounded(dc, r, on ? palette.accent : palette.canvas,
            on ? palette.accent : palette.secondary, 3);
    textAt(dc, std::to_wstring(i + 1), r, fontSmall,
           on ? palette.accentText : palette.secondary,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
}
static void toggleDisplayAt(POINT point, RECT area, bool expanded) {
  if (!expanded && displayMapNeedsExpansion(area))
    return;
  auto rectangles = mapRects(area);
  for (size_t i = 0; i < displays.size(); ++i)
    if (PtInRect(&rectangles[displays[i].id], point)) {
      auto list = controls[ID_MONITORS];
      SendMessageW(list, LB_SETSEL, SendMessageW(list, LB_GETSEL, i, 0) <= 0,
                   i);
      SendMessageW(mainWindow, WM_COMMAND,
                   MAKEWPARAM(ID_MONITORS, LBN_SELCHANGE), 0);
      if (mapPanel)
        InvalidateRect(mapPanel, nullptr, FALSE);
      break;
    }
}
static void showDisplaysMenu() {
  HMENU menu = CreatePopupMenu();
  auto selected = selection();
  for (size_t i = 0; i < displays.size(); ++i) {
    bool on = std::find(selected.begin(), selected.end(), displays[i].id) !=
              selected.end();
    AppendMenuW(
        menu, MF_STRING | (on ? MF_CHECKED : 0), 1000 + i,
        (std::to_wstring(i + 1) + L" · " + wide(displays[i].name)).c_str());
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 1090, L"All Displays");
  RECT r;
  GetWindowRect(controls[ID_DISPLAYS_MENU], &r);
  int chosen = TrackPopupMenu(menu, TPM_RETURNCMD, r.left, r.bottom, 0,
                              mainWindow, nullptr);
  DestroyMenu(menu);
  if (chosen == 1090)
    SendMessageW(controls[ID_MONITORS], LB_SETSEL, TRUE, -1);
  else if (chosen >= 1000 && chosen < 1000 + (int)displays.size())
    SendMessageW(
        controls[ID_MONITORS], LB_SETSEL,
        SendMessageW(controls[ID_MONITORS], LB_GETSEL, chosen - 1000, 0) <= 0,
        chosen - 1000);
  else
    return;
  SendMessageW(mainWindow, WM_COMMAND, MAKEWPARAM(ID_MONITORS, LBN_SELCHANGE),
               0);
}
static LRESULT CALLBACK mapProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_ERASEBKGND)
    return 1;
  if (msg == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE) {
    ShowWindow(h, SW_HIDE);
    return 0;
  }
  if (msg == WM_CLOSE || (msg == WM_KEYDOWN && wp == VK_ESCAPE)) {
    ShowWindow(h, SW_HIDE);
    SetFocus(controls[ID_DISPLAYS_MENU]);
    return 0;
  }
  if (msg == WM_PAINT || msg == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    HDC dc = msg == WM_PRINTCLIENT ? (HDC)wp : BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    fill(dc, r, palette.card);
    drawDisplayMap(dc, logicalRect(8, 8, 280, 140), true);
    textAt(dc, L"Click a display · Space for accessible list",
           logicalRect(8, 150, 280, 24), fontSmall, palette.secondary,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (msg == WM_PAINT)
      EndPaint(h, &ps);
    return 0;
  }
  if (msg == WM_LBUTTONUP) {
    toggleDisplayAt({GET_X_LPARAM(lp), GET_Y_LPARAM(lp)},
                    logicalRect(8, 8, 280, 140), true);
    return 0;
  }
  if (msg == WM_KEYDOWN && (wp == VK_SPACE || wp == VK_RETURN)) {
    showDisplaysMenu();
    InvalidateRect(h, nullptr, FALSE);
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}
static void openDisplayMap() {
  RECT r;
  GetWindowRect(controls[ID_DISPLAYS_MENU], &r);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfoW(MonitorFromWindow(mainWindow, MONITOR_DEFAULTTONEAREST), &mi);
  SetWindowPos(
      mapPanel, HWND_TOP,
      std::clamp<int>(r.left, mi.rcWork.left,
                      std::max<int>(mi.rcWork.left, mi.rcWork.right - px(298))),
      std::clamp<int>(r.bottom, mi.rcWork.top,
                      std::max<int>(mi.rcWork.top, mi.rcWork.bottom - px(184))),
      px(298), px(184), SWP_SHOWWINDOW);
  SetFocus(mapPanel);
}
static void toolbarMenu(POINT p) {
  if (!connected)
    return;
  if (p.x == -1) {
    RECT r;
    GetWindowRect(mainWindow, &r);
    p = {r.left + px(40), r.top + px(60)};
  }
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING | (!toolbarLabels ? MF_CHECKED : 0), 1, L"Icons");
  AppendMenuW(menu, MF_STRING | (toolbarLabels ? MF_CHECKED : 0), 2,
              L"Icons and Text");
  int chosen =
      TrackPopupMenu(menu, TPM_RETURNCMD, p.x, p.y, 0, mainWindow, nullptr);
  DestroyMenu(menu);
  if (chosen) {
    toolbarLabels = chosen == 2;
    settings["toolbarLabels"] = toolbarLabels;
    saveSettings();
    layout();
    fitWindowToDisplays();
  }
}
static void showZoomMenu() { SendMessageW(mainWindow, WM_COMMAND, ID_FIT, 0); }
static std::vector<std::string> zeroTierIds;
static void refreshZeroTierList(const json &response) {
  if (response.contains("networks"))
    for (auto &net : response["networks"]) {
      auto id = net.value("id", "");
      if (id.size() == 16)
        settings["zeroTierKnown"][id] = {{"name", net.value("name", id)},
                                         {"status", net.value("status", "")}};
    }
  SendMessageW(controls[ID_ZT_LIST], CB_RESETCONTENT, 0, 0);
  zeroTierIds = {""};
  SendMessageW(controls[ID_ZT_LIST], CB_ADDSTRING, 0, (LPARAM)L"None");
  auto desired = narrow(controlText(ID_ZTNETWORK));
  int selected = 0;
  auto networks = settings.value("zeroTierKnown", json::object());
  if (!desired.empty() && !networks.contains(desired))
    networks[desired] = {{"name", desired}};
  for (auto it = networks.begin(); it != networks.end(); ++it) {
    zeroTierIds.push_back(it.key());
    auto row = wide(it.value().value("name", it.key())) + L" · " +
               wide(it.key()) + L" · " +
               wide(it.value().value("status", "Inactive"));
    SendMessageW(controls[ID_ZT_LIST], CB_ADDSTRING, 0, (LPARAM)row.c_str());
    if (it.key() == desired)
      selected = (int)zeroTierIds.size() - 1;
  }
  SendMessageW(controls[ID_ZT_LIST], CB_SETCURSEL, selected, 0);
  saveSettings();
}
static LRESULT CALLBACK zeroTierProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CLOSE) {
    ShowWindow(h, SW_HIDE);
    SetFocus(controls[ID_ADVANCED]);
    return 0;
  }
  if (msg == WM_COMMAND) {
    int id = LOWORD(wp);
    if (id == ID_ZT_LIST && HIWORD(wp) == CBN_SELCHANGE) {
      int selected = comboIndex(ID_ZT_LIST);
      if (selected >= 0 && selected < (int)zeroTierIds.size())
        SetWindowTextW(controls[ID_ZTNETWORK],
                       wide(zeroTierIds[selected]).c_str());
      return 0;
    }
    if (id == ID_ZT_ADD) {
      auto name = askName(L"Add ZeroTier Network", L"");
      auto value = narrow(name);
      if (value.size() != 16 ||
          !std::all_of(value.begin(), value.end(),
                       [](unsigned char c) { return std::isxdigit(c); })) {
        status(L"A ZeroTier network ID needs 16 hexadecimal characters");
        return 0;
      }
      std::transform(value.begin(), value.end(), value.begin(),
                     [](unsigned char c) { return (char)std::tolower(c); });
      settings["zeroTierKnown"][value] = {{"name", value}};
      SetWindowTextW(controls[ID_ZTNETWORK], wide(value).c_str());
      refreshZeroTierList(json::object());
      return 0;
    }
    if (id == ID_ZT_DISCONNECT)
      return 0;
    return SendMessageW(mainWindow, msg, wp, lp);
  }
  if (msg == WM_CTLCOLORSTATIC || msg == WM_CTLCOLOREDIT ||
      msg == WM_CTLCOLORLISTBOX || msg == WM_CTLCOLORBTN)
    return controlColor(msg, wp, lp);
  if (msg == WM_ERASEBKGND)
    return 1;
  if (msg == WM_PAINT || msg == WM_PRINTCLIENT) {
    PAINTSTRUCT ps{};
    HDC dc = msg == WM_PRINTCLIENT ? (HDC)wp : BeginPaint(h, &ps);
    RECT r;
    GetClientRect(h, &r);
    fill(dc, r, palette.card);
    textAt(dc, L"Pair this connection with one network",
           logicalRect(20, 20, 380, 24), fontStrong, palette.text);
    textAt(dc,
           L"Disconnecting the network makes reconnecting take longer while "
           L"ZeroTier establishes the connection again.",
           logicalRect(20, 152, 380, 52), fontSmall, palette.secondary,
           DT_WORDBREAK);
    textAt(dc,
           L"Only networks previously paired in Portlight may be paused when "
           L"switching connections. Other networks are left alone.",
           logicalRect(20, 226, 380, 70), fontSmall, palette.secondary,
           DT_WORDBREAK);
    if (msg == WM_PAINT)
      EndPaint(h, &ps);
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}
static void openZeroTier() {
  refreshZeroTierList(json::object());
  RECT r;
  GetWindowRect(mainWindow, &r);
  SetWindowPos(zeroTierPanel, HWND_TOP, r.left + px(40), r.top + px(70),
               px(430), px(346), SWP_SHOWWINDOW);
  SetFocus(controls[ID_ZT_LIST]);
  if (!zeroTierBusy)
    zeroTierOperation({{"action", "status"}}, "list");
}
static std::vector<std::vector<int>> toolbarGroups = {
    {ID_ALLOW_CONTROL, ID_PAUSE, ID_AUDIO_TOOL},
    {ID_HD, ID_FHD, ID_QHD, ID_UHD},
    {ID_FULL_COLOR, ID_256, ID_GRAY},
    {ID_DISPLAYS_MENU},
    {ID_ZIN, ID_ZOUT, ID_Z100, ID_FIT},
    {ID_FOLLOW, ID_FULL, ID_SETTINGS_TOOL}};
static std::vector<RECT> toolbarDividers;
static void layout() {
  if (!mainWindow || !connectionsPage || !canvas)
    return;
  RECT r;
  GetClientRect(mainWindow, &r);
  int width = MulDiv(r.right, 96, uiDpi);
  bool viewing = connected;
  ShowWindow(connectionsPage, viewing ? SW_HIDE : SW_SHOW);
  ShowWindow(canvas, viewing ? SW_SHOW : SW_HIDE);
  for (auto &group : toolbarGroups)
    for (int id : group)
      ShowWindow(controls[id], viewing ? SW_SHOW : SW_HIDE);
  ShowWindow(controls[ID_BACK_CONNECTIONS], viewing ? SW_SHOW : SW_HIDE);
  ShowWindow(controls[ID_ZOOM_MENU], SW_HIDE);
  if (!viewing) {
    MoveWindow(connectionsPage, 0, 0, r.right, r.bottom, TRUE);
    ShowWindow(settingsPanel, SW_HIDE);
    ShowWindow(mapPanel, SW_HIDE);
    layoutConnections();
  } else {
    ShowWindow(zeroTierPanel, SW_HIDE);
    int h = toolbarLabels ? 52 : 36, y = 10, x = 148, limit = width - 106;
    toolbarDividers.clear();
    auto itemWidth = [&](int id) {
      if (id == ID_ALLOW_CONTROL)
        return 90;
      if (id == ID_DISPLAYS_MENU)
        return 150;
      if (id == ID_SETTINGS_TOOL)
        return 60;
      if (id == ID_Z100)
        return 44;
      return toolbarLabels ? 52 : 32;
    };
    for (auto &group : toolbarGroups) {
      int w = 0;
      for (int id : group)
        w += itemWidth(id);
      w += 4;
      if (x + w > limit) {
        x = 12;
        y += h + 8;
        limit = width - 12;
      }
      for (int id : group) {
        button(id, x, y, itemWidth(id), h);
        x += itemWidth(id);
      }
      toolbarDividers.push_back(logicalRect(x + 6, y + 8, 1, h - 16));
      x += 16;
    }
    toolbarHeight = y + h + 8;
    button(ID_BACK_CONNECTIONS, width - 102, 10, 94, h);
    MoveWindow(canvas, 0, px(toolbarHeight), r.right,
               std::max<int>(1, r.bottom - px(toolbarHeight)), TRUE);
    refreshToolbar();
    updateScroll();
  }
  InvalidateRect(mainWindow, nullptr, FALSE);
}
static void fitWindowToDisplays() {
  if (!connected || !fit || fullscreen || IsZoomed(mainWindow) ||
      IsIconic(mainWindow))
    return;
  auto size = desktopSize();
  if (size.cx <= 0 || size.cy <= 0)
    return;
  RECT outer, client;
  GetWindowRect(mainWindow, &outer);
  GetClientRect(mainWindow, &client);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfoW(MonitorFromWindow(mainWindow, MONITOR_DEFAULTTONEAREST), &mi);
  int nonclient = (outer.bottom - outer.top) - client.bottom;
  int height = (int)std::round(client.right * double(size.cy) / size.cx) +
               px(toolbarHeight) + nonclient;
  height = std::min<int>(height, mi.rcWork.bottom - mi.rcWork.top);
  SetWindowPos(mainWindow, nullptr, 0, 0, outer.right - outer.left,
               std::max(px(240), height),
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}
static void buildUI(HWND hwnd) {
  mainWindow = hwnd;
  using GetDpiFn = UINT(WINAPI *)(HWND);
  auto dpi = (GetDpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                      "GetDpiForWindow");
  if (dpi)
    uiDpi = dpi(hwnd);
  applyTheme();
  sidebarVisible = settings.value("sidebarVisible", true);
  sidebarWidth = sidebarVisible ? 216 : 0;
  toolbarLabels = settings.value("toolbarLabels", false);
  tooltipWindow = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr,
                                  WS_POPUP | TTS_ALWAYSTIP, 0, 0, 0, 0, hwnd,
                                  nullptr, GetModuleHandleW(nullptr), nullptr);
  connectionsPage = CreateWindowExW(
      WS_EX_CONTROLPARENT, L"SURemoteConnections", L"",
      WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 1, 1, hwnd,
      nullptr, GetModuleHandleW(nullptr), nullptr);
  settingsPanel = CreateWindowExW(
      WS_EX_CONTROLPARENT | WS_EX_TOOLWINDOW, L"SURemoteSettings", L"Data Rate",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, 0, 0, px(340), px(420), hwnd,
      nullptr, GetModuleHandleW(nullptr), nullptr);
  mapPanel =
      CreateWindowExW(WS_EX_TOOLWINDOW, L"PortlightDisplayMap",
                      L"Select Displays", WS_POPUP | WS_BORDER, 0, 0, 1, 1,
                      hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  zeroTierPanel = CreateWindowExW(
      WS_EX_CONTROLPARENT | WS_EX_TOOLWINDOW, L"PortlightZeroTier", L"ZeroTier",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, 0, 0, 1, 1, hwnd, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  add(connectionsPage, L"BUTTON", L"Toggle Sidebar", BS_PUSHBUTTON | WS_TABSTOP,
      ID_SIDEBAR, 0, 0, 1, 1);
  add(connectionsPage, L"LISTBOX", L"Connections",
      LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_VSCROLL |
          WS_TABSTOP,
      ID_SAVED_LIST, 0, 0, 1, 1);
  SetWindowSubclass(controls[ID_SAVED_LIST], savedListProc, 2, 0);
  add(connectionsPage, L"BUTTON", L"+", BS_PUSHBUTTON | WS_TABSTOP,
      ID_NEW_CONNECTION, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"−", BS_PUSHBUTTON | WS_TABSTOP, ID_REMOVE,
      0, 0, 1, 1);
  // These fields share one control parent and a continuous native tab order.
  for (int id : std::vector<int>{ID_PRESETS, ID_HOST, ID_PASSWORD, ID_PORT})
    add(connectionsPage, L"EDIT", id == ID_PORT ? L"5920" : L"",
        ES_AUTOHSCROLL | WS_TABSTOP | (id == ID_PASSWORD ? ES_PASSWORD : 0), id,
        0, 0, 1, 1);
  SendMessageW(controls[ID_PRESETS], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Saved Connection");
  SendMessageW(controls[ID_HOST], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Name or IP address");
  add(connectionsPage, L"BUTTON", L"Save password securely",
      BS_AUTOCHECKBOX | WS_TABSTOP, ID_REMEMBER, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"ZeroTier…", BS_PUSHBUTTON | WS_TABSTOP,
      ID_ADVANCED, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"Save Connection",
      BS_PUSHBUTTON | WS_TABSTOP, ID_CONNECTION_SAVE, 0, 0, 1, 1);
  add(connectionsPage, L"BUTTON", L"Connect", BS_DEFPUSHBUTTON | WS_TABSTOP,
      ID_CONNECT, 0, 0, 1, 1);
  for (int id : {ID_ZTNETWORK, ID_ZTMANAGED}) {
    add(connectionsPage, L"EDIT", L"", ES_AUTOHSCROLL, id, 0, 0, 1, 1);
    ShowWindow(controls[id], SW_HIDE);
  }
  statusLabel = add(connectionsPage, L"STATIC", L"", SS_LEFT, 0, 0, 0, 1, 1);
  add(zeroTierPanel, L"COMBOBOX", L"Paired network",
      CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, ID_ZT_LIST, 20, 52, 380, 180);
  add(zeroTierPanel, L"BUTTON", L"Add Network…", BS_PUSHBUTTON | WS_TABSTOP,
      ID_ZT_ADD, 20, 90, 140, 30);
  add(zeroTierPanel, L"BUTTON", L"Refresh", BS_PUSHBUTTON | WS_TABSTOP,
      ID_ZTSTATUS, 296, 90, 104, 30);
  add(zeroTierPanel, L"BUTTON", L"Disconnect network when session ends",
      BS_AUTOCHECKBOX | WS_TABSTOP, ID_ZT_DISCONNECT, 20, 124, 380, 28);
  add(settingsPanel, L"LISTBOX", L"", LBS_MULTIPLESEL | LBS_NOTIFY, ID_MONITORS,
      0, 0, 1, 1);
  ShowWindow(controls[ID_MONITORS], SW_HIDE);
  auto combo = [&](int id, std::vector<std::wstring> items, int selected) {
    add(settingsPanel, L"COMBOBOX", L"",
        CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, id, 0, 0, 100, 180);
    for (auto &t : items)
      SendMessageW(controls[id], CB_ADDSTRING, 0, (LPARAM)t.c_str());
    SendMessageW(controls[id], CB_SETCURSEL, selected, 0);
    SendMessageW(controls[id], CB_SETITEMHEIGHT, -1, px(26));
  };
  combo(ID_RES, {L"HD", L"FHD", L"QHD", L"UHD", L"Native"}, 1);
  combo(ID_COLOR, {L"Full Color", L"16 Shades of Gray", L"256 Colors"}, 0);
  for (int id : {ID_RES, ID_COLOR})
    ShowWindow(controls[id], SW_HIDE);
  combo(ID_QUALITY, {L"Automatic", L"Text & Controls", L"Video"}, 0);
  combo(ID_AUDIO_QUALITY,
        {L"Mono · 48 kbps", L"Stereo · 96 kbps", L"Stereo · 160 kbps",
         L"Stereo · 320 kbps"},
        1);
  add(settingsPanel, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_BANDWIDTH, 0,
      0, 1, 1);
  SendMessageW(controls[ID_BANDWIDTH], EM_SETCUEBANNER, TRUE,
               (LPARAM)L"Automatic");
  add(settingsPanel, L"BUTTON", L"Smooth gradients",
      BS_AUTOCHECKBOX | WS_TABSTOP, ID_DITHER, 0, 0, 1, 1);
  add(settingsPanel, L"BUTTON", L"Done", BS_PUSHBUTTON | WS_TABSTOP,
      ID_SETTINGS_DONE, 0, 0, 1, 1);
  for (int id : {ID_FPS, ID_CAP}) {
    add(settingsPanel, L"EDIT", id == ID_FPS ? L"60" : L"0", ES_NUMBER, id, 0,
        0, 1, 1);
    ShowWindow(controls[id], SW_HIDE);
  }
  for (int id : {ID_VIEWONLY, ID_AUDIO}) {
    add(settingsPanel, L"BUTTON", L"", BS_AUTOCHECKBOX, id, 0, 0, 1, 1);
    ShowWindow(controls[id], SW_HIDE);
  }
  std::vector<std::pair<int, const wchar_t *>> tools = {
      {ID_ALLOW_CONTROL, L"Control On"},
      {ID_PAUSE, L"Pause"},
      {ID_AUDIO_TOOL, L"Audio"},
      {ID_HD, L"HD"},
      {ID_FHD, L"FHD"},
      {ID_QHD, L"QHD"},
      {ID_UHD, L"UHD"},
      {ID_FULL_COLOR, L"Full"},
      {ID_256, L"256"},
      {ID_GRAY, L"Gray"},
      {ID_DISPLAYS_MENU, L"Displays"},
      {ID_ZIN, L"Zoom In"},
      {ID_ZOUT, L"Zoom Out"},
      {ID_Z100, L"100%"},
      {ID_FIT, L"Fit"},
      {ID_FOLLOW, L"Pan"},
      {ID_FULL, L"Full Screen"},
      {ID_SETTINGS_TOOL, L"Data Rate"},
      {ID_BACK_CONNECTIONS, L"Disconnect"},
      {ID_ZOOM_MENU, L"Zoom"}};
  for (auto t : tools) {
    bool toggle = t.first == ID_ALLOW_CONTROL || t.first == ID_PAUSE ||
                  t.first == ID_FOLLOW;
    add(hwnd, L"BUTTON", t.second,
        (toggle                                     ? BS_AUTOCHECKBOX
         : (t.first >= ID_HD && t.first <= ID_GRAY) ? BS_RADIOBUTTON
                                                    : BS_PUSHBUTTON) |
            WS_TABSTOP,
        t.first, 0, 0, 1, 1);
    tooltip(controls[t.first], t.second);
  }
  check(ID_ALLOW_CONTROL, true);
  tooltip(controls[ID_SIDEBAR], L"Show or hide the connections sidebar");
  tooltip(controls[ID_NEW_CONNECTION], L"New connection or group");
  tooltip(controls[ID_REMOVE], L"Remove selected connection or group");
  tooltip(controls[ID_FULL_COLOR], L"Full Color");
  tooltip(controls[ID_256], L"256 Colors");
  tooltip(controls[ID_GRAY], L"16 Shades of Gray");
  tooltip(controls[ID_HD], L"HD · 720p");
  tooltip(controls[ID_FHD], L"FHD · 1080p");
  tooltip(controls[ID_QHD], L"QHD · 1440p");
  tooltip(controls[ID_UHD], L"UHD · 2160p");
  tooltip(controls[ID_FOLLOW],
          L"Follow pointer when zoomed; off uses scroll bars");
  tooltip(controls[ID_SETTINGS_TOOL],
          L"Video bandwidth, audio quality and optimization");
  canvas =
      CreateWindowExW(0, L"SURemoteCanvas", L"Remote Desktop",
                      WS_CHILD | WS_HSCROLL | WS_VSCROLL | WS_TABSTOP, 0, 0, 1,
                      1, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  refreshSavedConnections();
  layoutSettings();
  applyTheme();
  SetTimer(hwnd, 1, 1000, nullptr);
  layout();
}
