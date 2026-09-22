#pragma once

// These test modes use synthetic displays and loopback fixtures only.
namespace portlight_popup {
static bool selfTestRequested = false, visualTestRequested = false,
            integrationTestRequested = false;
static int testStage = 0;
static ULONGLONG stageStarted = 0;
static uint64_t frozenRevision = 0;
static uint64_t observedFrameCount = 0, framesAtMessagingStart = 0;
static ULONGLONG lastDecodedFrameAt = 0, maxDecodedFrameGap = 0;
static ULONGLONG lastVisibleSampleAt = 0, maxVisibleSampleGap = 0;
static uint64_t visibleCanvasSamples = 0, visibleCanvasMismatches = 0;
static std::vector<std::string> frozenSelection;
static json testReport = json::object();
static const wchar_t *testDraft = L"Ready\U0001f3acGo";
static void require(bool okay, const char *message) {
  if (!okay)
    throw std::runtime_error(message);
}
static json targetState(bool showing, std::vector<std::string> ids) {
  return {{"type", "popupMessageState"}, {"active", showing},
           {"displayIDs", ids},
           {"availableDisplays", json::array({
               {{"id", "fixture-1"}, {"name", "Studio display"}, {"index", 1}},
               {{"id", "fixture-2"}, {"name", "Preview display"}, {"index", 2}},
               {{"id", "fixture-3"}, {"name", "Third display"}, {"index", 3}}})}};
}
static void setTestCapabilities() {
  receive({{"type", "welcome"}, {"capabilities", {{"popupMessages",
      {{"maxCharacters", 250}, {"maxDurationSeconds", 10800},
       {"richText", true}, {"targetDisplays", true}}}}}});
  receive(targetState(false, {"fixture-2"}));
}
static void setTestDraft() {
  SetWindowTextW(items[Editor], testDraft);
  selectRange(5, 7);
  formatSelection(CFM_COLOR | CFM_UNDERLINE, RGB(255, 176, 0), true);
}
static void exerciseCanvasInput() {
  require(panel && IsWindowVisible(panel), "Composer must remain open during control test");
  RECT bounds{};
  GetClientRect(canvas, &bounds);
  int x = bounds.right / 2, y = bounds.bottom / 2;
  SendMessageW(canvas, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(x, y));
  require(heldButtons == 1, "Canvas did not accept the pointer press with the composer open");
  SendMessageW(canvas, WM_LBUTTONUP, 0, MAKELPARAM(x, y));
  require(heldButtons == 0, "Canvas did not release the pointer");
  POINT point{x, y};
  ClientToScreen(canvas, &point);
  SendMessageW(canvas, WM_MOUSEWHEEL, MAKEWPARAM(0, WHEEL_DELTA), MAKELPARAM(point.x, point.y));
  SendMessageW(canvas, WM_KEYDOWN, VK_LEFT, 0);
  require(heldKeys.count(VK_LEFT) == 1, "Canvas did not accept key down with the composer open");
  SendMessageW(canvas, WM_KEYUP, VK_LEFT, 0);
  require(heldKeys.count(VK_LEFT) == 0, "Canvas did not release the key");
  SendMessageW(canvas, WM_CHAR, 'Z', 0);
  require(IsWindowVisible(panel), "Canvas interaction closed the composer");
}
static uint64_t controlPaintHash(HWND hwnd) {
  RECT bounds{};
  GetClientRect(hwnd, &bounds);
  BITMAPINFO format{};
  format.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  format.bmiHeader.biWidth = bounds.right;
  format.bmiHeader.biHeight = -bounds.bottom;
  format.bmiHeader.biPlanes = 1;
  format.bmiHeader.biBitCount = 32;
  format.bmiHeader.biCompression = BI_RGB;
  void *pixels = nullptr;
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP bitmap = CreateDIBSection(dc, &format, DIB_RGB_COLORS, &pixels, nullptr, 0);
  require(bitmap && pixels, "Could not allocate a toolbar paint-test bitmap");
  auto previous = SelectObject(dc, bitmap);
  size_t count = size_t(bounds.right) * bounds.bottom * 4;
  memset(pixels, 0, count);
  SendMessageW(hwnd, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc), PRF_CLIENT);
  GdiFlush();
  uint64_t hash = 1469598103934665603ULL;
  for (size_t index = 0; index < count; ++index)
    hash = (hash ^ static_cast<uint8_t *>(pixels)[index]) * 1099511628211ULL;
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  return hash;
}
static void assertToolbarPreserved() {
  require(!toolbarGroups.empty() && toolbarGroups.back() == std::vector<int>{Launcher},
           "Message toolbar group is missing");
  for (int width : {720, 1100, 1500}) {
    for (bool labels : {false, true}) {
      toolbarLabels = labels;
      SetWindowPos(mainWindow, nullptr, 0, 0, px(width), px(760), SWP_NOMOVE | SWP_NOZORDER);
      toolbarGroups.pop_back();
      ShowWindow(launcher, SW_HIDE);
      layout();
      std::map<int, RECT> rectangles;
      std::map<int, uint64_t> hashes;
      for (const auto &entry : controls) {
        if (entry.first == Launcher || GetParent(entry.second) != mainWindow ||
            !(GetWindowLongW(entry.second, GWL_STYLE) & WS_VISIBLE))
          continue;
        GetWindowRect(entry.second, &rectangles[entry.first]);
        hashes[entry.first] = controlPaintHash(entry.second);
      }
      toolbarGroups.push_back({Launcher});
      layout();
      for (const auto &entry : rectangles) {
        RECT current{};
        GetWindowRect(controls[entry.first], &current);
        require(EqualRect(&entry.second, &current), "An existing toolbar control moved");
        require(hashes[entry.first] == controlPaintHash(controls[entry.first]),
                 "An existing toolbar control changed appearance");
      }
      RECT client{}, bubble{};
      GetClientRect(mainWindow, &client);
      GetWindowRect(launcher, &bubble);
      MapWindowPoints(nullptr, mainWindow, reinterpret_cast<POINT *>(&bubble), 2);
      require((GetWindowLongW(launcher, GWL_STYLE) & WS_VISIBLE) &&
               bubble.left >= 0 && bubble.top >= 0 && bubble.right <= client.right &&
               bubble.bottom <= px(toolbarHeight), "Message button is outside the toolbar");
    }
  }
}
static json runNativeTests(const std::wstring &folder) {
  json checks = json::object();
  connected = true;
  visualDesktop();
  setTestCapabilities();
  ShowWindow(mainWindow, SW_SHOW);
  for (int theme : {0, 1}) {
    forcedTheme = theme;
    applyTheme();
    assertToolbarPreserved();
  }
  checks["existingToolbarRectsAndPaintUnchanged"] = true;
  fullscreen = true;
  layout();
  require(IsWindowVisible(launcher), "Message launcher is hidden in fullscreen");
  checks["fullscreenLauncherVisible"] = true;
  fullscreen = false;
  toolbarLabels = false;
  SetWindowPos(mainWindow, nullptr, 40, 40, px(1100), px(760), SWP_NOZORDER);
  layout();
  size_t oldControlCount = controls.size();
  SendMessageW(mainWindow, WM_COMMAND, MAKEWPARAM(Launcher, BN_CLICKED), reinterpret_cast<LPARAM>(launcher));
  require(panel && IsWindowVisible(panel), "Message launcher did not open its window");
  require(controls.size() == oldControlCount, "Composer changed the shared control registry");
  require(IsWindowVisible(items[Clear]), "Clear Message is missing from the composer");
  require(!IsWindowEnabled(items[ScreenFirst + 1]), "The last selected message screen can be unchecked");
  setTestDraft();
  require(messageText() == u"Ready\U0001f3acGo", "Message draft changed unexpectedly");
  auto runs = messageRuns(messageText());
  require(runs == json::array({{{"start", 5}, {"length", 2}, {"color", "#FFB000"},
                                {"underline", true}}}), "Rich-text selection did not survive formatting");
  checks["composerAndFormatting"] = true;
  auto selected = selection();
  auto oldRevision = revision;
  receive(targetState(true, {"fixture-1", "fixture-2"}));
  require(SendMessageW(items[ScreenFirst], BM_GETCHECK, 0, 0) == BST_CHECKED &&
           SendMessageW(items[ScreenFirst + 1], BM_GETCHECK, 0, 0) == BST_CHECKED,
           "Acknowledged message screens are not checked");
  receive(targetState(true, {"fixture-1"}));
  require(!IsWindowEnabled(items[ScreenFirst]) && IsWindowEnabled(items[ScreenFirst + 1]),
           "Single-screen selection protection is incorrect");
  require(selection() == selected && revision == oldRevision,
           "Message-screen state changed the viewing subscription");
  checks["screenAcknowledgementsIndependentOfViewing"] = true;
  check(ID_VIEWONLY, false);
  check(ID_PAUSE, false);
  exerciseCanvasInput();
  checks["canvasHandlersWorkWithComposerOpen"] = true;
  std::wstring longText(251, L'A');
  SetWindowTextW(items[Editor], longText.c_str());
  require(messageText().size() == 250, "Composer accepted more than 250 characters");
  setTestDraft();
  SendMessageW(panel, WM_CLOSE, 0, 0);
  open();
  require(messageText() == u"Ready\U0001f3acGo", "Closing the composer erased its draft");
  checks["characterLimitAndRetainedDraft"] = true;
  if (!folder.empty()) {
    CreateDirectoryW(folder.c_str(), nullptr);
    for (int theme : {0, 1}) {
      forcedTheme = theme;
      applyTheme();
      for (bool labels : {false, true}) {
        toolbarLabels = labels;
        layout();
        settleVisualWindow(mainWindow);
        std::wstring suffix = (theme ? L"dark" : L"light") +
                              std::wstring(labels ? L"-labels" : L"-icons");
        require(captureWindowPNG(mainWindow, folder + L"\\popup-toolbar-" + suffix + L".png"),
                 "Could not capture the message toolbar");
      }
    }
    settleVisualWindow(panel);
    require(captureWindowPNG(panel, folder + L"\\popup-composer.png"),
             "Could not capture the message composer");
    fullscreen = true;
    layout();
    settleVisualWindow(mainWindow);
    require(captureWindowPNG(mainWindow, folder + L"\\popup-fullscreen-toolbar.png"),
             "Could not capture the fullscreen message toolbar");
    fullscreen = false;
  }
  return {{"ok", true}, {"checks", checks}};
}
static json rectangleJSON(const RECT &rect) {
  return {rect.left, rect.top, rect.right, rect.bottom};
}
static RECT testWorkArea() {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  require(GetMonitorInfoW(MonitorFromWindow(mainWindow, MONITOR_DEFAULTTONEAREST), &monitor),
           "Could not read the test monitor work area");
  return monitor.rcWork;
}
static json visibleTestGeometry() {
  json windows = json::object();
  for (auto entry : {std::make_pair("main", mainWindow), std::make_pair("canvas", canvas),
                     std::make_pair("composer", panel)}) {
    RECT outer{}, client{};
    GetWindowRect(entry.second, &outer);
    GetClientRect(entry.second, &client);
    MapWindowPoints(entry.second, nullptr, reinterpret_cast<POINT *>(&client), 2);
    windows[entry.first] = {{"window", rectangleJSON(outer)},
                             {"clientOnScreen", rectangleJSON(client)},
                             {"visible", bool(IsWindowVisible(entry.second))}};
  }
  auto origin = canvasOrigin();
  windows["workArea"] = rectangleJSON(testWorkArea());
  windows["zoom"] = zoom;
  windows["canvasOrigin"] = {origin.x, origin.y};
  return windows;
}
static void arrangeVisibleTestWindow() {
  RECT work = testWorkArea();
  int margin = px(8);
  int width = std::min(px(1100), int(work.right - work.left) - margin * 2);
  int height = std::min(px(760), int(work.bottom - work.top) - margin * 2);
  require(width >= px(720) && height >= px(480),
           "The desktop work area is too small for the visible-canvas test");
  SetWindowPos(mainWindow, HWND_TOP, work.left + margin, work.top + margin,
                 width, height, SWP_SHOWWINDOW);
  SetForegroundWindow(mainWindow);
}
static void arrangeVisibleTestComposer() {
  RECT work = testWorkArea(), bounds{}, owner{};
  GetWindowRect(panel, &bounds);
  GetWindowRect(mainWindow, &owner);
  int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
  require(width < work.right - work.left && height < work.bottom - work.top,
           "The composer does not fit within the test monitor work area");
  int x = std::clamp(int(owner.left + px(8)), int(work.left), int(work.right) - width);
  int y = std::clamp(int(owner.top + px(64)), int(work.top), int(work.bottom) - height);
  SetWindowPos(panel, HWND_TOP, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
  testReport["testWindowGeometry"] = visibleTestGeometry();
}
static bool captureVisibleDesktopPNG(const std::wstring &path) {
  int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  HDC source = GetDC(nullptr), memory = CreateCompatibleDC(source);
  HBITMAP bitmap = CreateCompatibleBitmap(source, width, height);
  auto old = SelectObject(memory, bitmap);
  BOOL copied = BitBlt(memory, 0, 0, width, height, source, left, top, SRCCOPY | CAPTUREBLT);
  SelectObject(memory, old);
  DeleteDC(memory);
  ReleaseDC(nullptr, source);
  IWICBitmap *image = nullptr;
  IWICStream *stream = nullptr;
  IWICBitmapEncoder *encoder = nullptr;
  IWICBitmapFrameEncode *frame = nullptr;
  IPropertyBag2 *properties = nullptr;
  HRESULT hr = copied && bitmap ? imaging->CreateBitmapFromHBITMAP(
                                      bitmap, nullptr, WICBitmapIgnoreAlpha, &image) : E_FAIL;
  if (SUCCEEDED(hr)) hr = imaging->CreateStream(&stream);
  if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE);
  if (SUCCEEDED(hr)) hr = imaging->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
  if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &properties);
  if (SUCCEEDED(hr)) hr = frame->Initialize(properties);
  if (SUCCEEDED(hr)) hr = frame->SetSize(width, height);
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr)) hr = frame->WriteSource(image, nullptr);
  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();
  if (properties) properties->Release();
  if (frame) frame->Release();
  if (encoder) encoder->Release();
  if (stream) stream->Release();
  if (image) image->Release();
  if (bitmap) DeleteObject(bitmap);
  return SUCCEEDED(hr);
}
static void sampleVisibleCanvas() {
  auto now = GetTickCount64();
  require(IsWindowVisible(canvas) && !IsIconic(mainWindow),
           "The streaming canvas is not visible during the pixel test");
  auto frames = monitorLayout();
  auto frame = frames.find("fixture-1");
  require(frame != frames.end(), "The pixel-test display is missing");
  const auto &rect = frame->second;
  auto origin = canvasOrigin();
  RECT bounds{};
  GetClientRect(canvas, &bounds);
  json blockedPoints = json::array();
  // Read visible pixels without requesting a repaint or reading CanvasBuffer.
  for (double nx : {0.96, 0.92, 0.84, 0.12, 0.5}) {
    for (double ny : {0.8, 0.6, 0.9, 0.3, 0.15}) {
      POINT client{int((rect.x + rect.w * nx) * zoom) + origin.x,
                   int((rect.y + rect.h * ny) * zoom) + origin.y};
      if (!PtInRect(&bounds, client))
        continue;
      POINT screen = client;
      ClientToScreen(canvas, &screen);
      HWND covering = WindowFromPoint(screen);
      if (covering != canvas) {
        wchar_t className[128]{};
        GetClassNameW(covering, className, 128);
        blockedPoints.push_back({{"client", {client.x, client.y}},
                                  {"screen", {screen.x, screen.y}},
                                  {"coveringClass", narrow(className)}});
        continue;
      }
      HDC windowDC = GetDC(canvas), screenDC = GetDC(nullptr);
      require(windowDC && screenDC, "Could not read the visible canvas device context");
      COLORREF windowPixel = GetPixel(windowDC, client.x, client.y);
      COLORREF screenPixel = GetPixel(screenDC, screen.x, screen.y);
      ReleaseDC(canvas, windowDC);
      ReleaseDC(nullptr, screenDC);
      auto isFixture = [](COLORREF color) {
        return color != CLR_INVALID && GetRValue(color) == 22 && GetBValue(color) == 130 &&
               GetGValue(color) >= 70 && GetGValue(color) < 220;
      };
      ++visibleCanvasSamples;
      maxVisibleSampleGap = std::max(maxVisibleSampleGap, now - lastVisibleSampleAt);
      lastVisibleSampleAt = now;
      bool matches = isFixture(windowPixel) && isFixture(screenPixel);
      if (!matches) {
        ++visibleCanvasMismatches;
        testReport["failedVisibleSample"] = {
            {"client", {client.x, client.y}}, {"screen", {screen.x, screen.y}},
            {"windowRGB", {GetRValue(windowPixel), GetGValue(windowPixel), GetBValue(windowPixel)}},
            {"screenRGB", {GetRValue(screenPixel), GetGValue(screenPixel), GetBValue(screenPixel)}}};
      }
      require(matches, "Visible canvas pixels stopped matching the streamed fixture");
      return;
    }
  }
  testReport["coveredPixelTestPoints"] = blockedPoints;
  require(now - lastVisibleSampleAt < 1500,
           "The composer or another window covered every visible pixel-test point");
}
static void finishIntegration(const std::string &error = "") {
  KillTimer(mainWindow, 3);
  KillTimer(mainWindow, 5);
  if (!error.empty()) {
    testReport["failureGeometry"] = visibleTestGeometry();
    CreateDirectoryW(L"design-review", nullptr);
    testReport["failureScreenshots"] = {
        {"desktop", captureVisibleDesktopPNG(L"design-review\\popup-integration-failure-desktop.png")},
        {"main", captureWindowPNG(mainWindow, L"design-review\\popup-integration-failure-main.png")},
        {"composer", panel && captureWindowPNG(panel, L"design-review\\popup-integration-failure-composer.png")}};
  }
  testReport["error"] = error;
  testReport["ok"] = error.empty();
  testReport["framesDecoded"] = receivedFrames;
  testReport["framesDecodedAfterMessaging"] = receivedFrames - framesAtMessagingStart;
  testReport["durationMs"] = GetTickCount64() - integrationStarted;
  testReport["maxDecodedFrameGapMs"] = maxDecodedFrameGap;
  testReport["visibleCanvasSamples"] = visibleCanvasSamples;
  testReport["visibleCanvasMismatches"] = visibleCanvasMismatches;
  testReport["maxVisibleSampleGapMs"] = maxVisibleSampleGap;
  testReport["visibleCanvasStable"] = visibleCanvasSamples >= 1200 &&
                                      visibleCanvasMismatches == 0 && maxVisibleSampleGap < 1500;
  testReport["rejectedFrames"] = integrationRejected;
  testReport["subscriptions"] = integrationSubscriptions;
  testReport["revisionUnchanged"] = revision == frozenRevision;
  testReport["viewingSelectionUnchanged"] = selection() == frozenSelection;
  testReport["draftRetained"] = panel && messageText() == u"Ready\U0001f3acGo";
  if (error.empty())
    testReport["ok"] = testReport["revisionUnchanged"].get<bool>() &&
                        testReport["viewingSelectionUnchanged"].get<bool>() &&
                        testReport["draftRetained"].get<bool>() && integrationRejected == 0 &&
                        maxDecodedFrameGap < 3000 && receivedFrames > framesAtMessagingStart + 100 &&
                        testReport["visibleCanvasStable"].get<bool>();
  integrationExitCode = testReport["ok"].get<bool>() ? 0 : 1;
  std::string output = testReport.dump(2) + "\n";
  std::ofstream file(wide(integrationReport).c_str(), std::ios::binary | std::ios::trunc);
  file << output;
  file.close();
  DWORD written = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(), DWORD(output.size()), &written, nullptr);
  DestroyWindow(mainWindow);
}
static bool integrationTimer(WPARAM timer) {
  if (timer != 3 && timer != 5)
    return false;
  try {
    if (timer == 5) {
      sampleVisibleCanvas();
      return true;
    }
    auto now = GetTickCount64();
    require(now - integrationStarted < 140000, "Popup integration timed out");
    require(integrationFailure.empty(), integrationFailure.c_str());
    if (frozenRevision && receivedFrames != observedFrameCount) {
      if (lastDecodedFrameAt)
        maxDecodedFrameGap = std::max(maxDecodedFrameGap, now - lastDecodedFrameAt);
      lastDecodedFrameAt = now;
      observedFrameCount = receivedFrames;
    }
    if (frozenRevision) {
      require(revision == frozenRevision && selection() == frozenSelection,
               "Messaging changed the viewing subscription during the stream");
      require(!lastDecodedFrameAt || now - lastDecodedFrameAt < 3000,
               "Decoded pictures stopped for 3 seconds during messaging");
    }
    if (!connected || !supported || selectedTargets.empty() || !receivedFrames)
      return true;
    if (testStage == 0) {
      require(targetSelectionSupported, "Host did not advertise message-screen selection");
      arrangeVisibleTestWindow();
      check(ID_VIEWONLY, false);
      check(ID_PAUSE, false);
      for (size_t index = 0; index < displays.size(); ++index)
        SendMessageW(controls[ID_MONITORS], LB_SETSEL, displays[index].id == "fixture-1", index);
      updateScroll();
      sendSubscription();
      stageStarted = now;
      testStage = 1;
    } else if (testStage == 1 && now - stageStarted >= 700) {
      if (!frozenRevision) {
        frozenRevision = revision;
        frozenSelection = selection();
        framesAtMessagingStart = observedFrameCount = receivedFrames;
        lastDecodedFrameAt = now;
      }
      open();
      arrangeVisibleTestComposer();
      setTestDraft();
      if (!lastVisibleSampleAt) {
        lastVisibleSampleAt = now;
        SetTimer(mainWindow, 5, 25, nullptr);
      }
      testReport["composerOpened"] = panel && IsWindowVisible(panel);
      exerciseCanvasInput();
      testReport["controlWithComposerOpen"] = true;
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(Sticky, BN_CLICKED), 0);
      require(pending, "Sticky message did not reach the transport");
      testStage = 2;
    } else if (testStage == 2 && active && !pending) {
      testReport["stickyAcknowledged"] = true;
      int nextScreen = selectedTargets == std::vector<std::string>{"fixture-1"}
                           ? ScreenFirst + 1 : ScreenFirst;
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(nextScreen, BN_CLICKED), 0);
      require(targetChangePending, "Both-screen selection did not reach the transport");
      testStage = 3;
    } else if (testStage == 3 && !targetChangePending && selectedTargets.size() == 2) {
      testReport["bothTargetsAcknowledged"] = true;
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(ScreenFirst + 1, BN_CLICKED), 0);
      require(targetChangePending, "Single-screen selection did not reach the transport");
      testStage = 4;
    } else if (testStage == 4 && !targetChangePending &&
               selectedTargets == std::vector<std::string>{"fixture-1"}) {
      testReport["targetSelectionAcknowledged"] = true;
      require(active, "Changing message screens cleared the active message");
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(ScreenFirst, BN_CLICKED), 0);
      require(!targetChangePending && !IsWindowEnabled(items[ScreenFirst]),
               "The composer allowed the last screen to be unchecked");
      testReport["lastTargetProtected"] = true;
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(Clear, BN_CLICKED), 0);
      require(pending, "Clear Message did not reach the transport");
      testStage = 5;
    } else if (testStage == 5 && !active && !pending) {
      testReport["clearAcknowledged"] = true;
      duration = 1;
      SendMessageW(panel, WM_COMMAND, MAKEWPARAM(Timed, BN_CLICKED), 0);
      require(pending, "Timed message did not reach the transport");
      testStage = 6;
    } else if (testStage == 6 && active && !pending) {
      testReport["timedAcknowledged"] = true;
      testStage = 7;
    } else if (testStage == 7 && !active && !pending) {
      testReport["timedExpired"] = true;
      testReport["cycles"] = testReport.value("cycles", 0) + 1;
      if (now - integrationStarted >= 120000)
        finishIntegration();
      else {
        stageStarted = now;
        testStage = 1;
      }
    }
  } catch (const std::exception &error) {
    finishIntegration(error.what());
  }
  return true;
}
static void configureTests(LPWSTR arguments) {
  std::wstring value = arguments ? arguments : L"";
  selfTestRequested = value == L"--popup-self-test";
  visualTestRequested = value.rfind(L"--popup-visual-test", 0) == 0;
  integrationTestRequested = value == L"--popup-integration-test";
  if (selfTestRequested || visualTestRequested)
    visualMode = true;
  if (integrationTestRequested) {
    integrationMode = true;
    testTimerHook = integrationTimer;
  }
}
static int runTests(LPWSTR) {
  if (!selfTestRequested && !visualTestRequested)
    return -1;
  std::wstring folder;
  if (visualTestRequested) {
    int count = 0;
    auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    folder = count >= 3 ? arguments[2] : L"popup-visuals";
    LocalFree(arguments);
    CreateDirectoryW(folder.c_str(), nullptr);
  }
  json report;
  try {
    report = runNativeTests(folder);
  } catch (const std::exception &error) {
    report = {{"ok", false}, {"error", error.what()}};
  }
  std::string output = report.dump(2) + "\n";
  if (!folder.empty()) {
    std::ofstream file((folder + L"\\popup-report.json").c_str());
    file << output;
  }
  DWORD written = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(), DWORD(output.size()), &written, nullptr);
  DestroyWindow(mainWindow);
  if (imaging)
    imaging->Release();
  CoUninitialize();
  return report.value("ok", false) ? 0 : 1;
}
} // namespace portlight_popup
