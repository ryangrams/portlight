#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
// clang-format off
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
// clang-format on
#include "protocol_validation.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <commctrl.h>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <map>
#include <memory>
#include <mmsystem.h>
#include <mutex>
#include <shlobj.h>
#include <shellapi.h>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <wincodec.h>
#include <wincrypt.h>
#include <windowsx.h>
#include <winhttp.h>
using json = nlohmann::json;
static constexpr UINT WM_NET = WM_APP + 1, WM_FRAME = WM_APP + 2,
                      WM_OSC = WM_APP + 3;
static constexpr int TOP = 56;
enum {
  ID_HOST = 100,
  ID_PASSWORD,
  ID_CONNECT,
  ID_MONITORS,
  ID_RES,
  ID_COLOR,
  ID_FPS,
  ID_CAP,
  ID_AUDIO,
  ID_PAUSE,
  ID_VIEWONLY,
  ID_FIT,
  ID_ZIN,
  ID_ZOUT,
  ID_FULL,
  ID_FOLLOW,
  ID_SAVE,
  ID_LOAD,
  ID_QUALITY
};
struct Display {
  std::string id, name;
  int width = 0, height = 0;
};
struct Frame {
  std::string id;
  uint64_t revision = 0;
  int x = 0, y = 0, w = 0, h = 0, fullW = 0, fullH = 0;
  std::vector<uint8_t> pixels;
};
struct Surface {
  int width = 0, height = 0;
  std::vector<uint8_t> pixels;
};
static HWND mainWindow, canvas, statusLabel;
static std::map<int, HWND> controls;
static std::vector<Display> displays;
static std::map<std::string, Surface> surfaces;
static std::atomic<bool> connected{false}, connecting{false}, stopping{false};
static std::atomic<size_t> pendingFrameBytes{0};
static std::atomic<unsigned> pendingControlMessages{0};
static bool integrationMode = false;
static std::string integrationFingerprint, integrationFailure,
    integrationReport;
static ULONGLONG integrationStarted = 0;
static int integrationStage = 0;
static json integrationSubscriptions = json::array(),
            integrationFrames = json::object();
static uint64_t integrationRejected = 0;
static bool integrationConnectionsAtStart = false,
            integrationViewingAfterAuth = false,
            integrationConnectionsAfterDisconnect = false;
struct NetworkBinary {
  uint64_t generation;
  std::vector<uint8_t> data;
};
static std::atomic<uint64_t> receivedBytes{0};
static uint64_t previousBytes = 0, receivedFrames = 0, previousFrames = 0,
                lastLatency = 0, currentUpdates = 0;
static double currentKbps = 0;
static std::mutex transportMutex;
static HINTERNET webSocket = nullptr, activeRequest = nullptr,
                 activeConnection = nullptr, activeSession = nullptr;
static uint64_t revision = 0;
static float zoom = 1.f;
static bool fit = true, fullscreen = false, follow = false;
static int panX = 0, panY = 0;
static RECT savedWindow{};
static json settings = json::object();
static std::wstring settingsPath;
static std::string currentHost;
static std::string lastPointerDisplay;
static double lastPointerX = 0, lastPointerY = 0;
static int heldButtons = 0;
static SOCKET oscSocket = INVALID_SOCKET;
static IWICImagingFactory *imaging = nullptr;
static std::string remoteCursorDisplay;
static double remoteCursorX = 0, remoteCursorY = 0;
static std::atomic<uint64_t> connectGeneration{0};
static const wchar_t *productName = L"Portlight";
static HWND connectionsPage = nullptr, settingsPanel = nullptr,
            tooltipWindow = nullptr;
static HFONT fontBody = nullptr, fontSmall = nullptr, fontTitle = nullptr,
             fontHero = nullptr, fontStrong = nullptr;
static UINT uiDpi = 96;
static bool darkTheme = false, highContrast = false, reducedMotion = false,
            advancedOpen = false, visualMode = false;
static int forcedTheme = -1;
static int pageScroll = 0;
static std::wstring connectionTitle = L"Connected", uiStatus = L"";
struct Palette {
  COLORREF page, card, field, text, secondary, line, accent, accentText, hover,
      canvas;
};
static Palette palette{RGB(247, 248, 250), RGB(255, 255, 255),
                       RGB(245, 246, 248), RGB(29, 32, 39),
                       RGB(105, 111, 123), RGB(224, 228, 235),
                       RGB(48, 105, 223),  RGB(255, 255, 255),
                       RGB(237, 241, 247), RGB(232, 235, 240)};
static HBRUSH pageBrush = nullptr, cardBrush = nullptr, fieldBrush = nullptr;
static constexpr int ID_SAVED_LIST = 170, ID_NEW_CONNECTION = 171,
                     ID_ADVANCED = 172, ID_PORT = 173, ID_DISPLAYS_MENU = 176,
                     ID_ZOOM_MENU = 177, ID_AUDIO_TOOL = 178,
                     ID_SETTINGS_TOOL = 179, ID_SETTINGS_DONE = 180,
                     ID_BACK_CONNECTIONS = 181, ID_ALLOW_CONTROL = 182,
                     ID_BANDWIDTH = 183;
static std::map<int, RECT> fieldRects;
static std::vector<std::string> savedNames;
static RECT savedCard{}, connectCard{};
static int px(int value) { return MulDiv(value, uiDpi, 96); }
static void layout();
static void refreshToolbar();
static void refreshSavedConnections();
static void applyTheme();
static void openSettings();
static std::wstring wide(const std::string &s) {
  if (s.empty())
    return {};
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              (int)s.size(), nullptr, 0);
  std::wstring r(n, 0);
  if (n)
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), r.data(), n);
  return r;
}
static std::string narrow(const std::wstring &s) {
  if (s.empty())
    return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0,
                              nullptr, nullptr);
  std::string r(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), r.data(), n, nullptr,
                      nullptr);
  return r;
}
static std::wstring controlText(int id) {
  int n = GetWindowTextLengthW(controls[id]);
  std::wstring s(n + 1, 0);
  GetWindowTextW(controls[id], s.data(), n + 1);
  s.resize(n);
  return s;
}
static bool checked(int id) {
  return SendMessageW(controls[id], BM_GETCHECK, 0, 0) == BST_CHECKED;
}
static void check(int id, bool value) {
  SendMessageW(controls[id], BM_SETCHECK, value ? BST_CHECKED : BST_UNCHECKED,
               0);
}
static void status(const std::wstring &s) {
  uiStatus = s;
  if (statusLabel) {
    SetWindowTextW(statusLabel, s.c_str());
    ShowWindow(statusLabel, !connected && !s.empty() ? SW_SHOW : SW_HIDE);
  }
  if (connectionsPage)
    InvalidateRect(connectionsPage, nullptr, FALSE);
}

static bool post(json msg) {
  if (stopping)
    return false;
  if (pendingControlMessages.fetch_add(1) >= 64) {
    pendingControlMessages--;
    return false;
  }
  auto *message = new json(std::move(msg));
  if (!PostMessageW(mainWindow, WM_NET, 0, (LPARAM)message)) {
    delete message;
    pendingControlMessages--;
    return false;
  }
  return true;
}

static void saveSettings() {
  std::ofstream f(settingsPath.c_str(), std::ios::binary | std::ios::trunc);
  if (f)
    f << settings.dump(2);
}
static void loadSettings() {
  wchar_t path[MAX_PATH];
  if (SUCCEEDED(
          SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, path))) {
    std::wstring dir = std::wstring(path) + L"\\Studio Upgrade";
    CreateDirectoryW(dir.c_str(), nullptr);
    dir += L"\\SU Remote";
    CreateDirectoryW(dir.c_str(), nullptr);
    settingsPath = dir + L"\\viewer.json";
    std::ifstream f(settingsPath.c_str());
    if (f) {
      try {
        f >> settings;
      } catch (...) {
        settings = json::object();
      }
    }
  }
}
static int comboIndex(int id) {
  return (int)SendMessageW(controls[id], CB_GETCURSEL, 0, 0);
}
static std::string resolutionName() {
  static const char *a[] = {"hd", "fhd", "qhd", "uhd", "native"};
  return a[std::clamp(comboIndex(ID_RES), 0, 4)];
}
static std::string colorName() {
  static const char *a[] = {"full", "gray16", "color256", "rgb565"};
  return a[std::clamp(comboIndex(ID_COLOR), 0, 3)];
}
static int numberControl(int id, int def, int low, int high) {
  try {
    return std::clamp(std::stoi(controlText(id)), low, high);
  } catch (...) {
    return def;
  }
}
static std::vector<std::string> selection() {
  std::vector<std::string> ids;
  for (size_t i = 0; i < displays.size(); ++i)
    if (SendMessageW(controls[ID_MONITORS], LB_GETSEL, i, 0) > 0)
      ids.push_back(displays[i].id);
  return ids;
}
static bool sendMessage(const json &data) {
  std::string bytes = data.dump();
  std::lock_guard<std::mutex> lock(transportMutex);
  return webSocket &&
         WinHttpWebSocketSend(
             webSocket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
             (void *)bytes.data(), (DWORD)bytes.size()) == NO_ERROR;
}
static void releaseInput() {
  if (connected && heldButtons && !lastPointerDisplay.empty())
    sendMessage({{"type", "pointer"},
                 {"display", lastPointerDisplay},
                 {"x", lastPointerX},
                 {"y", lastPointerY},
                 {"buttons", 0}});
  heldButtons = 0;
}

static SIZE canvasSize() {
  RECT r{};
  GetClientRect(canvas, &r);
  return {r.right, r.bottom};
}
static SIZE slotSize() {
  int w = 0, h = 0;
  for (const auto &id : selection()) {
    auto it = surfaces.find(id);
    if (it != surfaces.end()) {
      w = std::max(w, it->second.width);
      h = std::max(h, it->second.height);
    }
  }
  return {w, h};
}
static SIZE desktopSize() {
  auto size = slotSize();
  size.cx *= (LONG)selection().size();
  return size;
}

static void updateScroll() {
  SIZE c = canvasSize(), d = desktopSize();
  if (fit && d.cx && d.cy)
    zoom = std::min((float)c.cx / d.cx, (float)c.cy / d.cy);
  zoom = std::clamp(zoom, .05f, 8.f);
  panX = std::clamp(panX, 0, std::max<int>(0, (int)(d.cx * zoom) - c.cx));
  panY = std::clamp(panY, 0, std::max<int>(0, (int)(d.cy * zoom) - c.cy));
  SCROLLINFO h{sizeof(h),  SIF_RANGE | SIF_PAGE | SIF_POS,
               0,          std::max<int>(0, (int)(d.cx * zoom) - 1),
               (UINT)c.cx, panX,
               0};
  SetScrollInfo(canvas, SB_HORZ, &h, TRUE);
  h.nMax = std::max<int>(0, (int)(d.cy * zoom) - 1);
  h.nPage = c.cy;
  h.nPos = panY;
  SetScrollInfo(canvas, SB_VERT, &h, TRUE);
  InvalidateRect(canvas, nullptr, FALSE);
  refreshToolbar();
}
static void sendSubscription(bool force = false) {
  (void)force;
  if (!connected)
    return;
  ++revision;
  auto ids = selection();
  if (integrationMode && integrationSubscriptions.size() < 64)
    integrationSubscriptions.push_back(
        {{"revision", revision}, {"displays", ids}});
  for (auto it = surfaces.begin(); it != surfaces.end();) {
    if (std::find(ids.begin(), ids.end(), it->first) == ids.end())
      it = surfaces.erase(it);
    else
      ++it;
  }
  json regions = json::object();
  SIZE c = canvasSize(), slot = slotSize();
  int offset = 0;
  for (const auto &id : ids) {
    auto it = surfaces.find(id);
    if (it != surfaces.end() && it->second.width > 0) {
      const auto &s = it->second;
      double imageX = offset + (slot.cx - s.width) / 2.,
             imageY = (slot.cy - s.height) / 2.;
      double left = std::max(0., panX / (double)zoom - imageX),
             top = std::max(0., panY / (double)zoom - imageY);
      double right = std::min((double)s.width,
                              (panX + c.cx) / (double)zoom - imageX),
             bottom = std::min((double)s.height,
                               (panY + c.cy) / (double)zoom - imageY);
      if (right > left && bottom > top)
        regions[id] = {{"x", left / s.width},
                       {"y", top / s.height},
                       {"width", (right - left) / s.width},
                       {"height", (bottom - top) / s.height}};
      else
        regions[id] = {{"x", 0}, {"y", 0}, {"width", 0}, {"height", 0}};
      offset += slot.cx;
    }
  }
  int widths[] = {1280, 1920, 2560, 3840, 0},
      heights[] = {720, 1080, 1440, 2160, 0};
  int ri = std::clamp(comboIndex(ID_RES), 0, 4);
  int mw = widths[ri], mh = heights[ri];
  if (ri == 4) {
    mw = 1280;
    mh = 720;
  }
  static const char *q[] = {"auto", "desktop", "motion"};
  sendMessage({{"type", "subscribe"},
               {"revision", revision},
               {"displays", ids},
               {"maxWidth", mw},
               {"maxHeight", mh},
               {"color", colorName()},
               {"fps", numberControl(ID_FPS, 15, 1, 60)},
               {"bandwidthKbps", numberControl(ID_CAP, 4000, 0, 100000)},
               {"quality", q[std::clamp(comboIndex(ID_QUALITY), 0, 2)]},
               {"audio", checked(ID_AUDIO)},
               {"viewOnly", checked(ID_VIEWONLY)},
               {"paused", checked(ID_PAUSE) || IsIconic(mainWindow)},
               {"regions", regions}});
}

static void toggleFullscreen(bool on) {
  if (on == fullscreen)
    return;
  fullscreen = on;
  if (on) {
    GetWindowRect(mainWindow, &savedWindow);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(MonitorFromWindow(mainWindow, MONITOR_DEFAULTTONEAREST),
                    &mi);
    SetWindowLongPtrW(mainWindow, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    SetWindowPos(mainWindow, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtrW(mainWindow, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
    SetWindowPos(mainWindow, nullptr, savedWindow.left, savedWindow.top,
                 savedWindow.right - savedWindow.left,
                 savedWindow.bottom - savedWindow.top,
                 SWP_FRAMECHANGED | SWP_NOZORDER);
  }
  if (on)
    SetFocus(canvas);
  updateScroll();
  sendSubscription();
}
static bool mapPointer(int x, int y, std::string &id, double &nx, double &ny) {
  double dx = (x + panX) / zoom, dy = (y + panY) / zoom;
  SIZE slot = slotSize();
  for (const auto &sid : selection()) {
    auto it = surfaces.find(sid);
    if (it == surfaces.end())
      continue;
    auto &s = it->second;
    double imageX = (slot.cx - s.width) / 2.,
           imageY = (slot.cy - s.height) / 2.;
    if (dx >= imageX && dx < imageX + s.width && dy >= imageY &&
        dy < imageY + s.height) {
      id = sid;
      nx = std::clamp((dx - imageX) / s.width, 0., .999999);
      ny = std::clamp((dy - imageY) / s.height, 0., .999999);
      return true;
    }
    dx -= slot.cx;
  }
  return false;
}

static std::string certificateHash(PCCERT_CONTEXT cert) {
  BYTE hash[32];
  DWORD n = 32;
  if (!CryptHashCertificate2(L"SHA256", 0, nullptr, cert->pbCertEncoded,
                             cert->cbCertEncoded, hash, &n))
    throw std::runtime_error(
        "Cannot read the computer’s certificate fingerprint");
  std::ostringstream out;
  for (DWORD i = 0; i < n; i++) {
    if (i)
      out << ":";
    out << std::uppercase << std::hex << std::setw(2) << std::setfill('0')
        << (int)hash[i];
  }
  return out.str();
}
static std::mutex settingsMutex;
static bool trustCertificate(const std::string &host, const std::string &hash) {
  if (integrationMode)
    return host.rfind("127.0.0.1:", 0) == 0 && hash == integrationFingerprint;
  std::string previous;
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    previous =
        settings.value("trustedCertificates", json::object()).value(host, "");
  }
  if (previous == hash)
    return true;
  std::wstring msg =
      (previous.empty() ? L"First connection to "
                        : L"WARNING: The certificate changed for ") +
      wide(host) +
      L".\n\nConfirm this SHA-256 fingerprint against the one shown in the SU "
      L"Portlight Host:\n\n" +
      wide(hash) +
      L"\n\nOnly trust it if the fingerprints match. Trust and connect?";
  if (MessageBoxW(mainWindow, msg.c_str(), L"Verify Portlight Host",
                  MB_YESNO | MB_DEFBUTTON2 |
                      (previous.empty() ? MB_ICONQUESTION : MB_ICONWARNING)) !=
      IDYES)
    return false;
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    settings["trustedCertificates"][host] = hash;
    saveSettings();
  }
  return true;
}
static bool decodeImage(const uint8_t *data, size_t size, Frame &f) {
  if (!imaging || size > 32 * 1024 * 1024)
    return false;
  IWICStream *stream = nullptr;
  IWICBitmapDecoder *decoder = nullptr;
  IWICBitmapFrameDecode *decoded = nullptr;
  IWICFormatConverter *convert = nullptr;
  HRESULT hr = imaging->CreateStream(&stream);
  if (SUCCEEDED(hr))
    hr = stream->InitializeFromMemory((BYTE *)data, (DWORD)size);
  if (SUCCEEDED(hr))
    hr = imaging->CreateDecoderFromStream(
        stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder);
  if (SUCCEEDED(hr))
    hr = decoder->GetFrame(0, &decoded);
  UINT w = 0, h = 0;
  if (SUCCEEDED(hr))
    hr = decoded->GetSize(&w, &h);
  if (w != (UINT)f.w || h != (UINT)f.h || w > 3840 || h > 3840)
    hr = E_INVALIDARG;
  if (SUCCEEDED(hr))
    hr = imaging->CreateFormatConverter(&convert);
  if (SUCCEEDED(hr))
    hr = convert->Initialize(decoded, GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0,
                             WICBitmapPaletteTypeCustom);
  if (SUCCEEDED(hr)) {
    f.pixels.resize((size_t)w * h * 4);
    hr = convert->CopyPixels(nullptr, w * 4, (UINT)f.pixels.size(),
                             f.pixels.data());
  }
  if (convert)
    convert->Release();
  if (decoded)
    decoded->Release();
  if (decoder)
    decoder->Release();
  if (stream)
    stream->Release();
  return SUCCEEDED(hr);
}
struct AudioPacket {
  WAVEHDR header{};
  std::vector<int16_t> samples;
};
static HWAVEOUT waveDevice = nullptr;
static std::vector<std::unique_ptr<AudioPacket>> audioPackets;
static void stopAudio() {
  if (waveDevice) {
    waveOutReset(waveDevice);
    for (auto &p : audioPackets)
      waveOutUnprepareHeader(waveDevice, &p->header, sizeof(WAVEHDR));
    audioPackets.clear();
    waveOutClose(waveDevice);
    waveDevice = nullptr;
  }
}
static void playAudio(const uint8_t *data, size_t size) {
  if (!checked(ID_AUDIO) || size > 4800)
    return;
  if (!waveDevice) {
    WAVEFORMATEX fmt{WAVE_FORMAT_PCM, 1, 24000, 48000, 2, 16, 0};
    if (waveOutOpen(&waveDevice, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) !=
        MMSYSERR_NOERROR)
      return;
  }
  for (auto it = audioPackets.begin(); it != audioPackets.end();) {
    if ((*it)->header.dwFlags & WHDR_DONE) {
      waveOutUnprepareHeader(waveDevice, &(*it)->header, sizeof(WAVEHDR));
      it = audioPackets.erase(it);
    } else
      ++it;
  }
  if (audioPackets.size() >= 8) {
    waveOutReset(waveDevice);
    return;
  }
  auto packet = std::make_unique<AudioPacket>();
  packet->samples.resize(size);
  for (size_t i = 0; i < size; i++) {
    uint8_t u = (uint8_t)~data[i];
    int v = (((u & 15) << 3) + 132) << ((u & 112) >> 4);
    packet->samples[i] = (int16_t)((u & 128) ? 132 - v : v - 132);
  }
  packet->header.lpData = (char *)packet->samples.data();
  packet->header.dwBufferLength = (DWORD)(size * 2);
  if (waveOutPrepareHeader(waveDevice, &packet->header, sizeof(WAVEHDR)) ==
      MMSYSERR_NOERROR) {
    waveOutWrite(waveDevice, &packet->header, sizeof(WAVEHDR));
    audioPackets.push_back(std::move(packet));
  }
}
static void handleBinary(const std::vector<uint8_t> &data) {
  try {
    auto envelope = su_remote::parseEnvelope(data);
    json h = std::move(envelope.header);
    auto payload = data.data() + envelope.payloadOffset;
    size_t len = data.size() - envelope.payloadOffset;
    auto type = h.value("type", "");
    if (h.value("revision", uint64_t(0)) != revision) {
      if (type == "frame")
        sendMessage({{"type", "frameAck"},
                     {"sequence", h.value("sequence", uint64_t(0))}});
      return;
    }
    if (type == "audio") {
      if (h.value("codec", "") == "mulaw" &&
          h.value("sampleRate", 0) == 24000 && h.value("channels", 0) == 1 &&
          h.value("samples", 0) == (int)len)
        playAudio(payload, len);
      return;
    }
    if (type != "frame")
      return;
    Frame f;
    f.id = h.value("display", "");
    f.revision = h.value("revision", uint64_t(0));
    f.x = h.value("x", -1);
    f.y = h.value("y", -1);
    f.w = h.value("width", 0);
    f.h = h.value("height", 0);
    f.fullW = h.value("canvasWidth", 0);
    f.fullH = h.value("canvasHeight", 0);
    auto ids = selection();
    if (std::find(ids.begin(), ids.end(), f.id) == ids.end() ||
        !su_remote::validImageRect(f.x, f.y, f.w, f.h, f.fullW, f.fullH))
      return;
    std::string codec = h.value("codec", "");
    if (codec != "png" && codec != "jpeg")
      return;
    if (!decodeImage(payload, len, f))
      return;
    auto found = surfaces.find(f.id);
    if (found == surfaces.end() || found->second.width != f.fullW ||
        found->second.height != f.fullH)
      return;
    auto &s = found->second;
    for (int y = 0; y < f.h; y++)
      memcpy(s.pixels.data() + ((size_t)(f.y + y) * s.width + f.x) * 4,
             f.pixels.data() + (size_t)y * f.w * 4, (size_t)f.w * 4);
    ++receivedFrames;
    if (integrationMode)
      integrationFrames[f.id] = integrationFrames.value(f.id, uint64_t(0)) + 1;
    updateScroll();
    sendMessage(
        {{"type", "frameAck"}, {"sequence", h.value("sequence", uint64_t(0))}});
  } catch (const std::exception &) {
    if (integrationMode)
      integrationRejected++;
    status(L"Rejected malformed image message");
  }
}
static void closeTransport() {
  connected = false;
  connecting = false;
  connectGeneration++;
  std::lock_guard<std::mutex> lock(transportMutex);
  if (webSocket) {
    WinHttpWebSocketClose(webSocket, 1000, nullptr, 0);
    WinHttpCloseHandle(webSocket);
    webSocket = nullptr;
  }
  if (activeRequest) {
    WinHttpCloseHandle(activeRequest);
    activeRequest = nullptr;
  }
  if (activeConnection) {
    WinHttpCloseHandle(activeConnection);
    activeConnection = nullptr;
  }
  if (activeSession) {
    WinHttpCloseHandle(activeSession);
    activeSession = nullptr;
  }
}
static constexpr int ID_PRESETS = 140, ID_ZTSTATUS = 141, ID_ZTNETWORK = 142,
                     ID_ZTMANAGED = 143, ID_Z100 = 144;
static std::string zeroTierTransaction;
static std::atomic<bool> zeroTierBusy{false};
static json runZeroTier(const json &request) {
  wchar_t module[MAX_PATH]{};
  GetModuleFileNameW(nullptr, module, MAX_PATH);
  std::wstring executable(module);
  executable = executable.substr(0, executable.find_last_of(L"\\/")) +
               L"\\su-zerotier.exe";
  if (GetFileAttributesW(executable.c_str()) == INVALID_FILE_ATTRIBUTES)
    return {{"ok", false},
            {"message", "The optional su-zerotier.exe helper is missing. Keep "
                        "it alongside the viewer."}};
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE childIn = nullptr, parentIn = nullptr, parentOut = nullptr,
         childOut = nullptr;
  if (!CreatePipe(&childIn, &parentIn, &sa, 0) ||
      !CreatePipe(&parentOut, &childOut, &sa, 0))
    return {{"ok", false}, {"message", "Cannot start ZeroTier helper"}};
  SetHandleInformation(parentIn, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(parentOut, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = childIn;
  startup.hStdOutput = childOut;
  startup.hStdError = childOut;
  PROCESS_INFORMATION process{};
  BOOL launched =
      CreateProcessW(executable.c_str(), nullptr, nullptr, nullptr, TRUE,
                     CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
  CloseHandle(childIn);
  CloseHandle(childOut);
  if (!launched) {
    CloseHandle(parentIn);
    CloseHandle(parentOut);
    return {{"ok", false}, {"message", "Could not launch ZeroTier helper"}};
  }
  std::string input = request.dump();
  DWORD wrote = 0;
  WriteFile(parentIn, input.data(), (DWORD)input.size(), &wrote, nullptr);
  CloseHandle(parentIn);
  std::string output;
  ULONGLONG deadline = GetTickCount64() + 45000;
  bool timeout = false;
  for (;;) {
    DWORD available = 0;
    if (PeekNamedPipe(parentOut, nullptr, 0, nullptr, &available, nullptr) &&
        available) {
      char buffer[4096];
      DWORD count = 0;
      if (ReadFile(parentOut, buffer,
                   std::min<DWORD>(available, sizeof(buffer)), &count, nullptr))
        output.append(buffer, count);
      if (output.size() > 2 * 1024 * 1024) {
        timeout = true;
        break;
      }
    } else if (WaitForSingleObject(process.hProcess, 20) == WAIT_OBJECT_0)
      break;
    if (GetTickCount64() > deadline) {
      timeout = true;
      break;
    }
  }
  if (timeout)
    TerminateProcess(process.hProcess, 1);
  CloseHandle(parentOut);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  if (timeout)
    return {
        {"ok", false},
        {"message",
         "ZeroTier operation timed out; check network status for recovery."}};
  try {
    return json::parse(output);
  } catch (...) {
    return {{"ok", false},
            {"message", "ZeroTier helper returned an invalid response"}};
  }
}
static void zeroTierOperation(const json &request, const std::string &purpose) {
  if (zeroTierBusy.exchange(true)) {
    status(L"A ZeroTier operation is already in progress");
    return;
  }
  std::thread([request, purpose] {
    auto result = runZeroTier(request);
    result["type"] = "zeroTierResult";
    result["purpose"] = purpose;
    zeroTierBusy = false;
    post(result);
  }).detach();
}
static void restoreZeroTier() {
  if (zeroTierTransaction.empty())
    return;
  std::string id = zeroTierTransaction;
  zeroTierTransaction.clear();
  zeroTierOperation({{"action", "restore"}, {"transactionId", id}}, "restore");
}
static void connectNow();
static void startConnection() {
  if (connected || connecting) {
    connectNow();
    restoreZeroTier();
    return;
  }
  auto desired = narrow(controlText(ID_ZTNETWORK));
  if (desired.empty()) {
    connectNow();
    return;
  }
  if (zeroTierBusy) {
    status(L"Wait for the current ZeroTier operation");
    return;
  }
  if (controlText(ID_PASSWORD).empty()) {
    status(L"Enter the computer’s password before activating its network");
    SetFocus(controls[ID_PASSWORD]);
    return;
  }
  std::string name = narrow(controlText(ID_PRESETS));
  std::string group = narrow(controlText(ID_ZTMANAGED));
  bool approved = false;
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    auto presets = settings.value("presets", json::object());
    if (presets.contains(name))
      approved = presets[name].value("zeroTierNetwork", "") == desired &&
                 presets[name].value("zeroTierManaged", "") == group;
  }
  if (!approved) {
    MessageBoxW(
        mainWindow,
        L"Save this connection first to review its ZeroTier network policy.",
        L"Review network policy", MB_OK | MB_ICONINFORMATION);
    return;
  }
  json managed = json::array();
  std::stringstream stream(group);
  std::string id;
  while (std::getline(stream, id, ',')) {
    id.erase(std::remove_if(id.begin(), id.end(),
                            [](unsigned char ch) { return std::isspace(ch); }),
             id.end());
    if (!id.empty())
      managed.push_back(id);
  }
  status(L"Preparing the saved ZeroTier network…");
  zeroTierOperation(
      {{"action", "activate"},
       {"networkId", desired},
       {"managedNetworkIds", managed},
       {"sessionId", "windows-" + std::to_string(GetCurrentProcessId())}},
      "activate");
}
struct Endpoint {
  std::wstring host;
  INTERNET_PORT port;
};
static Endpoint parseEndpoint(std::string address) {
  if (address.empty() || address.size() > 2048)
    throw std::runtime_error("Invalid computer address");
  if (address.find("://") == std::string::npos)
    address = "https://" + address;
  else if (address.rfind("wss://", 0) == 0)
    address.replace(0, 6, "https://");
  std::wstring url = wide(address);
  URL_COMPONENTSW u{};
  u.dwStructSize = sizeof(u);
  u.dwHostNameLength = (DWORD)-1;
  u.dwUrlPathLength = (DWORD)-1;
  u.dwUserNameLength = (DWORD)-1;
  u.dwPasswordLength = (DWORD)-1;
  u.dwExtraInfoLength = (DWORD)-1;
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &u) ||
      u.nScheme != INTERNET_SCHEME_HTTPS || u.dwHostNameLength == 0 ||
      u.dwUserNameLength || u.dwPasswordLength || u.dwExtraInfoLength)
    throw std::runtime_error("Use a hostname, https://, or wss:// address "
                             "without credentials or query parameters");
  std::wstring path(u.lpszUrlPath ? u.lpszUrlPath : L"", u.dwUrlPathLength);
  if (!path.empty() && path != L"/" && path != L"/remote")
    throw std::runtime_error("Portlight uses the /remote endpoint");
  size_t start = address.find("://") + 3,
         end = address.find_first_of("/?#", start);
  std::string authority = address.substr(
      start, end == std::string::npos ? std::string::npos : end - start);
  bool explicitPort = authority.front() == '['
                          ? authority.find("]:") != std::string::npos
                          : authority.find(':') != std::string::npos;
  return {std::wstring(u.lpszHostName, u.dwHostNameLength),
          explicitPort ? u.nPort : INTERNET_PORT(5920)};
}
static std::string connectionAddress() {
  auto raw = narrow(controlText(ID_HOST));
  if (!controls.count(ID_PORT))
    return raw;
  auto p = controlText(ID_PORT);
  if (p.empty() || p == L"5920")
    return raw;
  try {
    auto endpoint = parseEndpoint(raw);
    int port = std::stoi(p);
    if (port < 1 || port > 65535)
      throw std::runtime_error("Port must be between1and65535");
    auto host = narrow(endpoint.host);
    if (host.find(':') != std::string::npos && host.front() != '[')
      host = "[" + host + "]";
    return host + ":" + std::to_string(port);
  } catch (...) {
    return raw;
  }
}
static void connectNow() {
  if (connecting || connected) {
    releaseInput();
    closeTransport();
    stopAudio();
    SetWindowTextW(controls[ID_CONNECT], L"Connect");
    status(L"Disconnected");
    layout();
    return;
  }
  if (controls.count(ID_PORT)) {
    try {
      int port = std::stoi(controlText(ID_PORT));
      if (port < 1 || port > 65535)
        throw std::runtime_error("port");
    } catch (...) {
      status(L"Enter a port between 1 and 65535.");
      SetFocus(controls[ID_PORT]);
      return;
    }
  }
  std::string host = connectionAddress();
  std::string password = narrow(controlText(ID_PASSWORD));
  if (host.empty()) {
    SetFocus(controls[ID_HOST]);
    return;
  }
  if (password.empty()) {
    status(L"Enter the computer’s password to connect");
    SetFocus(controls[ID_PASSWORD]);
    return;
  }
  currentHost = host;
  connecting = true;
  stopping = false;
  auto generation = ++connectGeneration;
  SetWindowTextW(controls[ID_CONNECT], L"Cancel");
  status(L"Connecting securely…");
  std::thread([host, password, generation]() mutable {
    HINTERNET session = nullptr, connection = nullptr, request = nullptr,
              socket = nullptr;
    bool adopted = false;
    auto postNetwork = [generation](json msg) {
      msg["_generation"] = generation;
      return post(std::move(msg));
    };
    try {
      auto endpoint = parseEndpoint(host);
      std::wstring hostname = endpoint.host;
      INTERNET_PORT port = endpoint.port;
      session = WinHttpOpen(L"Portlight/0.2", WINHTTP_ACCESS_TYPE_NO_PROXY,
                            nullptr, nullptr, 0);
      if (!session)
        throw std::runtime_error("Cannot initialize TLS transport");
      WinHttpSetTimeouts(session, 5000, 5000, 5000, 1000);
      connection = WinHttpConnect(session, hostname.c_str(), port, 0);
      request = WinHttpOpenRequest(
          connection, L"GET", L"/remote", nullptr, WINHTTP_NO_REFERER,
          WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
      if (!request)
        throw std::runtime_error("Cannot create secure connection");
      DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                    SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                    SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                    SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
      WinHttpSetOption(request, WINHTTP_OPTION_SECURITY_FLAGS, &flags,
                       sizeof(flags));
      if (!WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
                            nullptr, 0) ||
          !WinHttpSendRequest(request, nullptr, 0, nullptr, 0, 0, 0) ||
          !WinHttpReceiveResponse(request, nullptr))
        throw std::runtime_error(
            "Computer unavailable or secure connection failed (" +
            std::to_string(GetLastError()) + ")");
      PCCERT_CONTEXT cert = nullptr;
      DWORD bytes = sizeof(cert);
      if (!WinHttpQueryOption(request, WINHTTP_OPTION_SERVER_CERT_CONTEXT,
                              &cert, &bytes) ||
          !cert)
        throw std::runtime_error("Computer did not supply a certificate");
      auto hash = certificateHash(cert);
      CertFreeCertificateContext(cert);
      std::string identity = narrow(hostname) + ":" + std::to_string(port);
      if (generation != connectGeneration)
        throw std::runtime_error("Cancelled");
      if (!trustCertificate(identity, hash))
        throw std::runtime_error("Certificate was not trusted");
      DWORD code = 0;
      bytes = sizeof(code);
      WinHttpQueryHeaders(request,
                          WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                          nullptr, &code, &bytes, nullptr);
      if (code != 101)
        throw std::runtime_error(
            "Computer did not accept the secure connection");
      socket = WinHttpWebSocketCompleteUpgrade(request, 0);
      if (!socket)
        throw std::runtime_error("WebSocket upgrade failed");
      DWORD closeTimeout = 1000;
      WinHttpSetOption(socket, WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT,
                       &closeTimeout, sizeof(closeTimeout));
      WinHttpCloseHandle(request);
      request = nullptr;
      {
        std::lock_guard<std::mutex> lock(transportMutex);
        if (generation != connectGeneration)
          throw std::runtime_error("Cancelled");
        webSocket = socket;
        activeSession = session;
        activeConnection = connection;
        adopted = true;
      }
      sendMessage({{"type", "hello"},
                   {"version", 1},
                   {"password", password},
                   {"codecs", {"png", "jpeg"}}});
      SecureZeroMemory(password.data(), password.size());
      password.clear();
      std::vector<uint8_t> message;
      message.reserve(1024 * 1024);
      std::vector<uint8_t> buffer(65536);
      while (generation == connectGeneration && !stopping) {
        DWORD count = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
        DWORD err = WinHttpWebSocketReceive(
            socket, buffer.data(), (DWORD)buffer.size(), &count, &type);
        if (err == ERROR_WINHTTP_TIMEOUT)
          continue;
        if (err != NO_ERROR)
          throw std::runtime_error("Connection ended (" + std::to_string(err) +
                                   ")");
        if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE)
          break;
        receivedBytes += count;
        if (message.size() + count > 32 * 1024 * 1024)
          throw std::runtime_error("Computer exceeded the message limit");
        message.insert(message.end(), buffer.begin(), buffer.begin() + count);
        if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
          try {
            if (message.size() > 65536)
              throw std::runtime_error("JSON response too large");
            if (!postNetwork(json::parse(
                    message.begin(), message.end(),
                    [](int depth, json::parse_event_t, json &) {
                      if (depth > 16)
                        throw std::runtime_error("JSON nesting too deep");
                      return true;
                    })))
              throw std::runtime_error(
                  "Control message queue exceeded safety limit");
          } catch (...) {
            throw std::runtime_error("The computer sent an invalid response");
          }
          message.clear();
        } else if (type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
          if (!stopping) {
            if (pendingFrameBytes.load() + message.size() > 64 * 1024 * 1024)
              throw std::runtime_error("Image queue exceeded the safety limit");
            pendingFrameBytes += message.size();
            auto *frame = new NetworkBinary{generation, std::move(message)};
            if (!PostMessageW(mainWindow, WM_FRAME, 0, (LPARAM)frame)) {
              pendingFrameBytes -= frame->data.size();
              delete frame;
              throw std::runtime_error("Cannot queue image");
            }
          }
          message.clear();
        }
      }
      if (generation == connectGeneration)
        postNetwork({{"type", "disconnected"}, {"message", "Disconnected"}});
    } catch (const std::exception &e) {
      if (generation == connectGeneration)
        postNetwork({{"type", "disconnected"}, {"message", e.what()}});
    }
    SecureZeroMemory(password.data(), password.size());
    {
      std::lock_guard<std::mutex> lock(transportMutex);
      if (webSocket == socket)
        webSocket = nullptr;
      if (activeSession == session)
        activeSession = nullptr;
      if (activeConnection == connection)
        activeConnection = nullptr;
    }
    // Handles adopted by closeTransport have already been closed during
    // cancellation.
    if (generation == connectGeneration || !adopted) {
      if (socket)
        WinHttpCloseHandle(socket);
      if (request)
        WinHttpCloseHandle(request);
      if (connection)
        WinHttpCloseHandle(connection);
      if (session)
        WinHttpCloseHandle(session);
    }
  }).detach();
}

static bool resolutionSupported(int i, std::string *limiter = nullptr) {
  if (i == 4) {
    for (const auto &id : selection())
      for (const auto &d : displays)
        if (d.id == id && (std::max(d.width, d.height) < 1280 ||
                           std::min(d.width, d.height) < 720))
          return true;
    return false;
  }
  int w[] = {1280, 1920, 2560, 3840}, h[] = {720, 1080, 1440, 2160};
  for (auto &id : selection())
    for (const auto &d : displays)
      if (d.id == id) {
        if (std::max(d.width, d.height) < w[i] ||
            std::min(d.width, d.height) < h[i]) {
          if (limiter)
            *limiter = d.name;
          return false;
        }
      }
  return true;
}
static void enforceResolution() {
  int i = comboIndex(ID_RES);
  if (resolutionSupported(i))
    return;
  int best = 4;
  for (int n = 0; n < 4; n++)
    if (resolutionSupported(n))
      best = n;
  SendMessageW(controls[ID_RES], CB_SETCURSEL, best, 0);
  status(L"Resolution adjusted to the selected display’s native size");
}
static void storePreset() {
  std::string name = narrow(controlText(ID_PRESETS));
  if (name.empty())
    name = "Default";
  json p = {{"host", connectionAddress()},
            {"displays", selection()},
            {"resolution", comboIndex(ID_RES)},
            {"color", comboIndex(ID_COLOR)},
            {"quality", comboIndex(ID_QUALITY)},
            {"fps", numberControl(ID_FPS, 15, 1, 60)},
            {"bandwidthKbps", numberControl(ID_CAP, 4000, 0, 100000)},
            {"zoom", zoom},
            {"fit", fit},
            {"follow", follow},
            {"viewOnly", checked(ID_VIEWONLY)},
            {"audio", checked(ID_AUDIO)},
            {"fullscreen", fullscreen},
            {"zeroTierNetwork", narrow(controlText(ID_ZTNETWORK))},
            {"zeroTierManaged", narrow(controlText(ID_ZTMANAGED))}};
  if (!p["zeroTierNetwork"].get<std::string>().empty()) {
    std::wstring msg =
        L"Save this ZeroTier policy?\n\nRequired network: " +
        controlText(ID_ZTNETWORK) + L"\nExclusive managed group: " +
        controlText(ID_ZTMANAGED) +
        L"\n\nOnly explicitly listed networks may be suspended. Their previous "
        L"state will be restored after disconnect.";
    if (MessageBoxW(mainWindow, msg.c_str(), L"Save ZeroTier connection",
                    MB_OKCANCEL | MB_DEFBUTTON2 | MB_ICONINFORMATION) != IDOK)
      return;
  }
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    settings["presets"][name] = p;
    saveSettings();
  }
  if (SendMessageW(controls[ID_PRESETS], CB_FINDSTRINGEXACT, -1,
                   (LPARAM)wide(name).c_str()) == CB_ERR)
    SendMessageW(controls[ID_PRESETS], CB_ADDSTRING, 0,
                 (LPARAM)wide(name).c_str());
  SetWindowTextW(controls[ID_PRESETS], wide(name).c_str());
  status(L"Saved connection updated. Your password is not saved.");
}
static std::vector<std::string> pendingSelection;
static void recallPreset(const std::string &name) {
  json p;
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    auto presets = settings.value("presets", json::object());
    if (!presets.contains(name)) {
      status(L"Saved connection not found");
      return;
    }
    p = presets[name];
  }
  SetWindowTextW(controls[ID_HOST], wide(p.value("host", "")).c_str());
  try {
    auto endpoint = parseEndpoint(p.value("host", ""));
    SetWindowTextW(controls[ID_PORT], std::to_wstring(endpoint.port).c_str());
  } catch (...) {
  }
  SetWindowTextW(controls[ID_PRESETS], wide(name).c_str());
  SendMessageW(controls[ID_RES], CB_SETCURSEL,
               std::clamp(p.value("resolution", 1), 0, 4), 0);
  SendMessageW(controls[ID_COLOR], CB_SETCURSEL,
               std::clamp(p.value("color", 0), 0, 3), 0);
  SendMessageW(controls[ID_QUALITY], CB_SETCURSEL,
               std::clamp(p.value("quality", 0), 0, 2), 0);
  SetWindowTextW(controls[ID_FPS], std::to_wstring(p.value("fps", 15)).c_str());
  SetWindowTextW(controls[ID_CAP],
                 std::to_wstring(p.value("bandwidthKbps", 4000)).c_str());
  zoom = std::clamp(p.value("zoom", 1.f), .05f, 8.f);
  fit = p.value("fit", true);
  follow = p.value("follow", false);
  check(ID_FOLLOW, follow);
  check(ID_VIEWONLY, p.value("viewOnly", false));
  check(ID_AUDIO, p.value("audio", false));
  SetWindowTextW(controls[ID_ZTNETWORK],
                 wide(p.value("zeroTierNetwork", "")).c_str());
  SetWindowTextW(controls[ID_ZTMANAGED],
                 wide(p.value("zeroTierManaged", "")).c_str());
  pendingSelection = p.value("displays", std::vector<std::string>{});
  for (size_t i = 0; i < displays.size(); i++)
    SendMessageW(controls[ID_MONITORS], LB_SETSEL,
                 std::find(pendingSelection.begin(), pendingSelection.end(),
                           displays[i].id) != pendingSelection.end(),
                 i);
  toggleFullscreen(p.value("fullscreen", false));
  enforceResolution();
  updateScroll();
  sendSubscription();
  status(L"Saved connection ready");
}
struct OSCCommand {
  std::string address;
  json args;
  sockaddr_in sender;
};
static bool oscString(const std::vector<uint8_t> &b, size_t &pos,
                      std::string &out) {
  size_t start = pos;
  while (pos < b.size() && b[pos])
    pos++;
  if (pos == b.size())
    return false;
  out.assign((const char *)b.data() + start, pos - start);
  pos = (pos + 4) & ~size_t(3);
  return pos <= b.size();
}
static void appendOSC(std::vector<uint8_t> &b, const std::string &s) {
  b.insert(b.end(), s.begin(), s.end());
  b.push_back(0);
  while (b.size() % 4)
    b.push_back(0);
}
static void oscReply(const sockaddr_in &addr, const std::string &path,
                     const std::string &text) {
  std::vector<uint8_t> b;
  appendOSC(b, path);
  appendOSC(b, ",s");
  appendOSC(b, text);
  sendto(oscSocket, (char *)b.data(), (int)b.size(), 0, (const sockaddr *)&addr,
         sizeof(addr));
}
static void startOSC() {
  WSADATA w{};
  if (WSAStartup(MAKEWORD(2, 2), &w) != 0)
    return;
  oscSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(19790);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(oscSocket, (sockaddr *)&addr, sizeof(addr)) != 0) {
    closesocket(oscSocket);
    oscSocket = INVALID_SOCKET;
    status(L"OSC port 19790 is already in use");
    return;
  }
  std::thread([] {
    while (!stopping) {
      std::vector<uint8_t> b(8192);
      sockaddr_in source{};
      int len = sizeof(source);
      int n = recvfrom(oscSocket, (char *)b.data(), (int)b.size(), 0,
                       (sockaddr *)&source, &len);
      if (n <= 0)
        break;
      b.resize(n);
      size_t pos = 0;
      std::string path, tags;
      if (!oscString(b, pos, path) || !oscString(b, pos, tags) ||
          tags.empty() || tags[0] != ',')
        continue;
      json args = json::array();
      bool valid = true;
      for (size_t i = 1; i < tags.size(); i++) {
        if (tags[i] == 's') {
          std::string s;
          if (!oscString(b, pos, s)) {
            valid = false;
            break;
          }
          args.push_back(s);
        } else if ((tags[i] == 'i' || tags[i] == 'f') && pos + 4 <= b.size()) {
          uint32_t raw = (uint32_t)b[pos] << 24 | (uint32_t)b[pos + 1] << 16 |
                         (uint32_t)b[pos + 2] << 8 | b[pos + 3];
          pos += 4;
          if (tags[i] == 'i')
            args.push_back((int32_t)raw);
          else {
            float f;
            memcpy(&f, &raw, 4);
            if (!std::isfinite(f)) {
              valid = false;
              break;
            }
            args.push_back(f);
          }
        } else {
          valid = false;
          break;
        }
      }
      if (valid && !stopping)
        PostMessageW(mainWindow, WM_OSC, 0,
                     (LPARAM) new OSCCommand{path, args, source});
      else
        oscReply(source, "/su/remote/error", "Invalid OSC arguments");
    }
  }).detach();
}
static json publicState() {
  return {{"version", 1},
          {"connected", connected.load()},
          {"host", currentHost},
          {"displays", selection()},
          {"resolution", resolutionName()},
          {"color", colorName()},
          {"zoom", zoom},
          {"panMode", follow ? "follow" : "manual"},
          {"fullscreen", fullscreen},
          {"paused", checked(ID_PAUSE)},
          {"viewOnly", checked(ID_VIEWONLY)},
          {"audio", checked(ID_AUDIO)},
          {"bitrateKbps", currentKbps},
          {"frameUpdates", currentUpdates},
          {"latencyMs", lastLatency}};
}
static void handleOSC(const OSCCommand &c) {
  try {
    auto p = c.address;
    auto a = c.args;
    bool resub = false;
    if (p == "/su/remote/state/get") {
      oscReply(c.sender, "/su/remote/state", publicState().dump());
      return;
    }
    if (p == "/su/remote/disconnect") {
      if (connected || connecting)
        startConnection();
    } else if (p == "/su/remote/connect") {
      if (!a.empty()) {
        auto name = a.at(0).get<std::string>();
        bool known = false;
        {
          std::lock_guard<std::mutex> lock(settingsMutex);
          known = settings.value("presets", json::object()).contains(name);
        }
        if (known)
          recallPreset(name);
        else
          SetWindowTextW(controls[ID_HOST], wide(name).c_str());
      }
      if (!connected && !connecting)
        startConnection();
    } else if (p == "/su/remote/preset/recall") {
      recallPreset(a.at(0).get<std::string>());
    } else if (p == "/su/remote/monitors/select") {
      auto ids = a.get<std::vector<std::string>>();
      for (const auto &id : ids)
        if (std::none_of(displays.begin(), displays.end(),
                         [&](const Display &d) { return d.id == id; }))
          throw std::runtime_error("Unknown display ID");
      for (size_t i = 0; i < displays.size(); i++)
        SendMessageW(
            controls[ID_MONITORS], LB_SETSEL,
            std::find(ids.begin(), ids.end(), displays[i].id) != ids.end(), i);
      enforceResolution();
      resub = true;
    } else if (p == "/su/remote/resolution" || p == "/su/remote/color") {
      std::vector<std::string> values =
          p == "/su/remote/resolution"
              ? std::vector<std::string>{"hd", "fhd", "qhd", "uhd"}
              : std::vector<std::string>{"full", "gray16", "color256",
                                         "rgb565"};
      auto v = a.at(0).get<std::string>();
      auto it = std::find(values.begin(), values.end(), v);
      if (it == values.end())
        throw std::runtime_error("Unknown option");
      int i = (int)(it - values.begin());
      if (p == "/su/remote/resolution" && !resolutionSupported(i))
        throw std::runtime_error("Resolution exceeds the selected display");
      SendMessageW(controls[p == "/su/remote/resolution" ? ID_RES : ID_COLOR],
                   CB_SETCURSEL, i, 0);
      resub = true;
    } else if (p == "/su/remote/zoom") {
      zoom = std::clamp(a.at(0).get<float>(), .05f, 8.f);
      fit = false;
      updateScroll();
      resub = true;
    } else if (p == "/su/remote/zoom/fit") {
      fit = true;
      panX = panY = 0;
      updateScroll();
      resub = true;
    } else if (p == "/su/remote/fullscreen") {
      toggleFullscreen(a.at(0).get<int>() != 0);
    } else if (p == "/su/remote/pan/mode") {
      auto mode = a.at(0).get<std::string>();
      if (mode != "follow" && mode != "manual")
        throw std::runtime_error("Use follow or manual");
      follow = mode == "follow";
      check(ID_FOLLOW, follow);
    } else if (p == "/su/remote/paused" || p == "/su/remote/viewonly" ||
               p == "/su/remote/audio") {
      int id = p == "/su/remote/paused"     ? ID_PAUSE
               : p == "/su/remote/viewonly" ? ID_VIEWONLY
                                            : ID_AUDIO;
      check(id, a.at(0).get<int>() != 0);
      if (id == ID_AUDIO && !checked(ID_AUDIO))
        stopAudio();
      releaseInput();
      resub = true;
    } else
      throw std::runtime_error("Unknown OSC command");
    if (resub) {
      updateScroll();
      sendSubscription();
    }
    oscReply(c.sender, "/su/remote/state", publicState().dump());
  } catch (const std::exception &e) {
    oscReply(c.sender, "/su/remote/error", e.what());
  }
}
static uint32_t keySym(WPARAM key) {
  switch (key) {
  case VK_RETURN:
    return 0xff0d;
  case VK_ESCAPE:
    return 0xff1b;
  case VK_BACK:
    return 0xff08;
  case VK_TAB:
    return 0xff09;
  case VK_LEFT:
    return 0xff51;
  case VK_UP:
    return 0xff52;
  case VK_RIGHT:
    return 0xff53;
  case VK_DOWN:
    return 0xff54;
  case VK_DELETE:
    return 0xffff;
  case VK_INSERT:
    return 0xff63;
  case VK_HOME:
    return 0xff50;
  case VK_END:
    return 0xff57;
  case VK_PRIOR:
    return 0xff55;
  case VK_NEXT:
    return 0xff56;
  case VK_SHIFT:
  case VK_LSHIFT:
    return 0xffe1;
  case VK_RSHIFT:
    return 0xffe2;
  case VK_CONTROL:
  case VK_LCONTROL:
    return 0xffe3;
  case VK_RCONTROL:
    return 0xffe4;
  case VK_MENU:
  case VK_LMENU:
    return 0xffe9;
  case VK_RMENU:
    return 0xffea;
  case VK_LWIN:
    return 0xffeb;
  case VK_RWIN:
    return 0xffec;
  default:
    if (key >= VK_F1 && key <= VK_F24)
      return 0xffbe + (uint32_t)key - VK_F1;
    if ((GetKeyState(VK_CONTROL) & 0x8000) || (GetKeyState(VK_MENU) & 0x8000)) {
      if (key >= L'A' && key <= L'Z')
        return (uint32_t)key + 32;
      if (key >= L'0' && key <= L'9')
        return (uint32_t)key;
    }
    return 0;
  }
}
static std::map<WPARAM, uint32_t> heldKeys;
static ULONGLONG lastMove = 0;
static void releaseAll() {
  releaseInput();
  for (const auto &k : heldKeys)
    sendMessage({{"type", "key"}, {"key", k.second}, {"down", false}});
  heldKeys.clear();
}
static LRESULT CALLBACK canvasProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_ERASEBKGND:
    return 1;
  case WM_PRINTCLIENT:
  case WM_PAINT: {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);
    HBRUSH bg = CreateSolidBrush(palette.canvas);
    FillRect(dc, &rc, bg);
    DeleteObject(bg);
    SetStretchBltMode(dc, COLORONCOLOR);
    int offset = 0;
    SIZE slot = slotSize();
    auto selected = selection();
    for (const auto &id : selected) {
      auto it = surfaces.find(id);
      if (it == surfaces.end())
        continue;
      auto &s = it->second;
      BITMAPINFO bi{};
      bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bi.bmiHeader.biWidth = s.width;
      bi.bmiHeader.biHeight = -s.height;
      bi.bmiHeader.biPlanes = 1;
      bi.bmiHeader.biBitCount = 32;
      bi.bmiHeader.biCompression = BI_RGB;
      if (!s.pixels.empty())
        StretchDIBits(
            dc, (int)((offset + (slot.cx - s.width) / 2.) * zoom) - panX,
            (int)((slot.cy - s.height) / 2. * zoom) - panY,
            (int)(s.width * zoom), (int)(s.height * zoom), 0, 0, s.width,
            s.height, s.pixels.data(), &bi, DIB_RGB_COLORS, SRCCOPY);
      if (id == remoteCursorDisplay) {
        int cursorX = (int)((offset + (slot.cx - s.width) / 2. +
                             remoteCursorX * s.width) *
                            zoom) -
                      panX;
        int cursorY =
            (int)(((slot.cy - s.height) / 2. + remoteCursorY * s.height) *
                  zoom) -
            panY;
        DrawIconEx(dc, cursorX, cursorY, LoadCursorW(nullptr, IDC_ARROW), 0, 0,
                   0, nullptr, DI_NORMAL);
      }
      offset += slot.cx;
    }
    if (selected.empty() || !connected) {
      SetTextColor(dc, palette.secondary);
      SetBkMode(dc, TRANSPARENT);
      std::wstring t = L"Choose a display from the Displays menu";
      DrawTextW(dc, t.c_str(), -1, &rc, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
    }
    if (!printing)
      EndPaint(hwnd, &ps);
    return 0;
  }
  case WM_SIZE:
    updateScroll();
    return 0;
  case WM_HSCROLL:
  case WM_VSCROLL: {
    SCROLLINFO si{};
    si.cbSize = sizeof(si);
    si.fMask = SIF_ALL;
    int bar = msg == WM_HSCROLL ? SB_HORZ : SB_VERT;
    GetScrollInfo(hwnd, bar, &si);
    int value = si.nPos;
    switch (LOWORD(wp)) {
    case SB_LINELEFT:
      value -= 30;
      break;
    case SB_LINERIGHT:
      value += 30;
      break;
    case SB_PAGELEFT:
      value -= (int)si.nPage;
      break;
    case SB_PAGERIGHT:
      value += (int)si.nPage;
      break;
    case SB_THUMBTRACK:
      value = si.nTrackPos;
      break;
    default:
      return 0;
    }
    if (bar == SB_HORZ)
      panX = value;
    else
      panY = value;
    updateScroll();
    SetTimer(mainWindow, 2, 100, nullptr);
    return 0;
  }
  case WM_MOUSEMOVE:
  case WM_LBUTTONDOWN:
  case WM_LBUTTONUP:
  case WM_RBUTTONDOWN:
  case WM_RBUTTONUP:
  case WM_MBUTTONDOWN:
  case WM_MBUTTONUP: {
    if (!connected || checked(ID_PAUSE) || checked(ID_VIEWONLY))
      return 0;
    int x = GET_X_LPARAM(lp), y = GET_Y_LPARAM(lp);
    if (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN ||
        msg == WM_MBUTTONDOWN) {
      SetFocus(hwnd);
      SetCapture(hwnd);
    }
    if (msg == WM_LBUTTONUP || msg == WM_RBUTTONUP || msg == WM_MBUTTONUP)
      ReleaseCapture();
    int mask = ((wp & MK_LBUTTON) ? 1 : 0) | ((wp & MK_RBUTTON) ? 2 : 0) |
               ((wp & MK_MBUTTON) ? 4 : 0);
    if (msg == WM_MOUSEMOVE) {
      ULONGLONG now = GetTickCount64();
      if (now - lastMove < 16)
        return 0;
      lastMove = now;
      if (follow && !fit) {
        SIZE c = canvasSize();
        int oldx = panX, oldy = panY;
        if (x < 40)
          panX -= 12;
        if (x > c.cx - 40)
          panX += 12;
        if (y < 40)
          panY -= 12;
        if (y > c.cy - 40)
          panY += 12;
        updateScroll();
        if (oldx != panX || oldy != panY)
          SetTimer(mainWindow, 2, 100, nullptr);
      }
    }
    std::string id;
    double nx, ny;
    if (mapPointer(x, y, id, nx, ny)) {
      lastPointerDisplay = id;
      lastPointerX = nx;
      lastPointerY = ny;
      heldButtons = mask;
      sendMessage({{"type", "pointer"},
                   {"display", id},
                   {"x", nx},
                   {"y", ny},
                   {"buttons", mask}});
    } else if (mask == 0)
      releaseInput();
    return 0;
  }
  case WM_MOUSEWHEEL: {
    if (GetKeyState(VK_CONTROL) & 0x8000) {
      fit = false;
      zoom *= GET_WHEEL_DELTA_WPARAM(wp) > 0 ? 1.2f : 1 / 1.2f;
      updateScroll();
      SetTimer(mainWindow, 2, 100, nullptr);
      return 0;
    }
    if (!connected || checked(ID_VIEWONLY) || checked(ID_PAUSE))
      return 0;
    POINT p{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    ScreenToClient(hwnd, &p);
    std::string id;
    double nx, ny;
    if (mapPointer(p.x, p.y, id, nx, ny))
      sendMessage({{"type", "wheel"},
                   {"display", id},
                   {"x", nx},
                   {"y", ny},
                   {"dx", 0},
                   {"dy", GET_WHEEL_DELTA_WPARAM(wp) / (double)WHEEL_DELTA}});
    return 0;
  }
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN:
  case WM_KEYUP:
  case WM_SYSKEYUP: {
    bool down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
    if (wp == VK_F11 && down) {
      toggleFullscreen(!fullscreen);
      return 0;
    }
    if (wp == VK_ESCAPE && fullscreen && down) {
      toggleFullscreen(false);
      return 0;
    }
    if (!connected || checked(ID_VIEWONLY) || checked(ID_PAUSE))
      return 0;
    uint32_t key = keySym(wp);
    if (!down && heldKeys.count(wp))
      key = heldKeys[wp];
    if (key) {
      sendMessage({{"type", "key"}, {"key", key}, {"down", down}});
      if (down)
        heldKeys[wp] = key;
      else
        heldKeys.erase(wp);
    }
    return 0;
  }
  case WM_CHAR:
    if (connected && !checked(ID_VIEWONLY) && !checked(ID_PAUSE) && wp >= 32 &&
        wp != 127 && !(GetKeyState(VK_CONTROL) & 0x8000) &&
        !(GetKeyState(VK_MENU) & 0x8000)) {
      static wchar_t high = 0;
      std::wstring chars;
      if (wp >= 0xd800 && wp <= 0xdbff) {
        high = (wchar_t)wp;
        return 0;
      }
      if (wp >= 0xdc00 && wp <= 0xdfff && high) {
        chars += high;
        high = 0;
      }
      chars += (wchar_t)wp;
      sendMessage({{"type", "text"}, {"text", narrow(chars)}});
    }
    return 0;
  case WM_KILLFOCUS:
    releaseAll();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
#include "ui.hpp"

static void populateDisplays(const json &msg) {
  auto previously = selection();
  if (!pendingSelection.empty())
    previously = pendingSelection;
  displays.clear();
  SendMessageW(controls[ID_MONITORS], LB_RESETCONTENT, 0, 0);
  for (const auto &d : msg.value("displays", json::array())) {
    Display v{d.value("id", ""), d.value("name", "Display"),
              d.value("width", 0), d.value("height", 0)};
    if (v.id.empty() || v.id.size() > 256 || v.name.size() > 512 ||
        v.width <= 0 || v.height <= 0 || v.width > 32768 || v.height > 32768 ||
        std::any_of(displays.begin(), displays.end(),
                    [&](const Display &old) { return old.id == v.id; }) ||
        displays.size() >= 32)
      continue;
    displays.push_back(v);
    std::wstring title = std::to_wstring(displays.size()) + L" · " +
                         wide(v.name) + L"  " + std::to_wstring(v.width) +
                         L"×" + std::to_wstring(v.height);
    SendMessageW(controls[ID_MONITORS], LB_ADDSTRING, 0, (LPARAM)title.c_str());
    bool selected = previously.empty()
                        ? displays.size() == 1
                        : std::find(previously.begin(), previously.end(),
                                    v.id) != previously.end();
    SendMessageW(controls[ID_MONITORS], LB_SETSEL, selected,
                 displays.size() - 1);
  }
  pendingSelection.clear();
  enforceResolution();
  InvalidateRect(controls[ID_RES], nullptr, TRUE);
}
static void handleNetwork(const json &msg) {
  if (msg.contains("_generation") &&
      msg["_generation"].get<uint64_t>() != connectGeneration)
    return;
  auto type = msg.value("type", "");
  if (type == "zeroTierResult") {
    std::string purpose = msg.value("purpose", "");
    if (!msg.value("ok", false)) {
      MessageBoxW(
          mainWindow,
          wide(msg.value("message", "ZeroTier operation failed")).c_str(),
          L"ZeroTier", MB_OK | MB_ICONINFORMATION);
      return;
    }
    if (purpose == "activate") {
      zeroTierTransaction = msg.value("transactionId", "");
      connectNow();
      if (!connected && !connecting)
        restoreZeroTier();
    } else if (purpose == "status") {
      std::wstring text = msg.value("online", false)
                              ? L"ZeroTier is online.\n\n"
                              : L"ZeroTier is offline.\n\n";
      for (const auto &n : msg.value("networks", json::array())) {
        text += wide(n.value("id", "") + "  " + n.value("name", "") + "  " +
                     n.value("status", "")) +
                L"\n";
        for (const auto &ip : n.value("assignedAddresses", json::array()))
          if (ip.is_string())
            text += L"    " + wide(ip.get<std::string>()) + L"\n";
      }
      auto pending = msg.value("pendingTransactions", json::array());
      if (!pending.empty())
        text += L"\nSaved network transactions need review.\n";
      MessageBoxW(mainWindow, text.c_str(), L"ZeroTier network status",
                  MB_OK | MB_ICONINFORMATION);
      for (const auto &tx : pending) {
        std::string id = tx.value("transactionId", "");
        if (id == zeroTierTransaction)
          continue;
        std::wstring question =
            L"Review saved network transaction " + wide(id) +
            L".\n\nThis may belong to another running viewer. Only change it "
            L"if that viewer has stopped.\n\nYes: restore the previous "
            L"networks.\nNo: keep the current networks and clear this saved "
            L"transaction.\nCancel: leave the transaction pending.";
        int choice = MessageBoxW(
            mainWindow, question.c_str(), L"Review pending recovery",
            MB_YESNOCANCEL | MB_DEFBUTTON3 | MB_ICONQUESTION);
        if (choice != IDCANCEL) {
          zeroTierOperation({{"action", choice == IDYES ? "restore" : "forget"},
                             {"transactionId", id}},
                            choice == IDYES ? "restore" : "forget");
          break;
        }
      }
    } else
      status(purpose == "forget"
                 ? L"Current networks kept; saved transaction cleared"
                 : L"Previous ZeroTier network state restored");
    return;
  }
  if (type == "welcome") {
    surfaces.clear();
    remoteCursorDisplay.clear();
    connected = true;
    connecting = false;
    revision = 0;
    SetWindowTextW(controls[ID_CONNECT], L"Disconnect");
    connectionTitle = wide(msg.value("serverName", currentHost));
    uiStatus = L"";
    layout();
    if (integrationMode)
      integrationViewingAfterAuth =
          (GetWindowLongW(canvas, GWL_STYLE) & WS_VISIBLE) &&
          !(GetWindowLongW(connectionsPage, GWL_STYLE) & WS_VISIBLE);
    populateDisplays(msg);
    bool audio = false;
    for (const auto &codec : msg.value("capabilities", json::object())
                                 .value("audio", json::array()))
      if (codec == "mulaw")
        audio = true;
    EnableWindow(controls[ID_AUDIO], audio);
    if (!audio)
      check(ID_AUDIO, false);
    status(L"Connected to " + wide(msg.value("serverName", currentHost)));
    sendSubscription();
  } else if (type == "cursor") {
    auto id = msg.value("display", "");
    double x = msg.value("x", 0.), y = msg.value("y", 0.);
    if (std::isfinite(x) && std::isfinite(y) && x >= 0 && x <= 1 && y >= 0 &&
        y <= 1) {
      remoteCursorDisplay = id;
      remoteCursorX = x;
      remoteCursorY = y;
      InvalidateRect(canvas, nullptr, FALSE);
    }
  } else if (type == "displays") {
    releaseAll();
    populateDisplays(msg);
    sendSubscription();
  } else if (type == "subscribed") {
    if (msg.value("revision", uint64_t(0)) != revision)
      return;
    auto acknowledged = msg.value("displays", json::array());
    su_remote::validateCanvasList(acknowledged, selection());
    bool geometryChanged = false;
    for (const auto &d : acknowledged) {
      std::string id = d.value("id", "");
      int w = d.value("width", 0), h = d.value("height", 0);
      if (!su_remote::validImageRect(0, 0, w, h, w, h))
        continue;
      auto &s = surfaces[id];
      if (s.width != w || s.height != h) {
        geometryChanged = true;
        s.width = w;
        s.height = h;
        s.pixels.assign((size_t)w * h * 4, 0);
      }
    }
    updateScroll();
    if (geometryChanged && !fit)
      SetTimer(mainWindow, 2, 100, nullptr);
  } else if (type == "error") {
    if (integrationMode)
      integrationFailure = msg.value("message", "Computer error");
    status(wide(msg.value("message", "Computer error")));
    if (msg.value("code", "") == "authentication") {
      closeTransport();
      restoreZeroTier();
      SetWindowTextW(controls[ID_CONNECT], L"Connect");
      layout();
    }
  } else if (type == "disconnected") {
    if (integrationMode)
      integrationFailure = msg.value("message", "Disconnected");
    restoreZeroTier();
    connected = false;
    connecting = false;
    stopAudio();
    SetWindowTextW(controls[ID_CONNECT], L"Connect");
    status(wide(msg.value("message", "Disconnected")));
    layout();
    InvalidateRect(canvas, nullptr, FALSE);
  } else if (type == "pong") {
    auto sent = msg.value("time", uint64_t(0));
    if (sent && sent <= GetTickCount64())
      lastLatency = GetTickCount64() - sent;
  }
}
static int integrationExitCode = 0;
static std::string testEnvironment(const wchar_t *name) {
  DWORD needed = GetEnvironmentVariableW(name, nullptr, 0);
  if (!needed)
    return {};
  std::wstring value(needed, 0);
  GetEnvironmentVariableW(name, value.data(), needed);
  value.resize(needed - 1);
  return narrow(value);
}
static void writeIntegrationReport() {
  bool okay = integrationFailure.empty() && integrationStage == 2 &&
              integrationConnectionsAtStart && integrationViewingAfterAuth &&
              integrationConnectionsAfterDisconnect &&
              integrationFrames.value("fixture-1", uint64_t(0)) > 0 &&
              integrationFrames.value("fixture-3", uint64_t(0)) > 0 &&
              integrationFrames.value("fixture-2", uint64_t(0)) == 0;
  integrationExitCode = okay ? 0 : 1;
  json report = {{"ok", okay},
                 {"framesDecoded", receivedFrames},
                 {"framesByDisplay", integrationFrames},
                 {"rejectedFrames", integrationRejected},
                 {"subscriptions", integrationSubscriptions},
                 {"stage", integrationStage},
                 {"error", integrationFailure},
                 {"uiTransitions",
                  {{"connectionsAtStart", integrationConnectionsAtStart},
                   {"viewingAfterAuthentication", integrationViewingAfterAuth},
                   {"connectionsAfterDisconnect",
                    integrationConnectionsAfterDisconnect}}}};
  std::string output = report.dump(2) + "\n";
  if (!integrationReport.empty()) {
    std::ofstream f(wide(integrationReport).c_str(),
                    std::ios::binary | std::ios::trunc);
    f << output;
  }
  DWORD count = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(),
            (DWORD)output.size(), &count, nullptr);
}
static void integrationTick() {
  ULONGLONG elapsed = GetTickCount64() - integrationStarted;
  if (connected && ((elapsed >= 2000 && integrationStage == 0) ||
                    (elapsed >= 4000 && integrationStage == 1))) {
    bool first = integrationStage == 1;
    SendMessageW(controls[ID_MONITORS], LB_SETSEL, FALSE, -1);
    for (size_t i = 0; i < displays.size(); i++)
      if (displays[i].id == "fixture-3" ||
          (first && displays[i].id == "fixture-1"))
        SendMessageW(controls[ID_MONITORS], LB_SETSEL, TRUE, i);
    ++integrationStage;
    enforceResolution();
    updateScroll();
    sendSubscription();
  }
  if (elapsed >= 7000) {
    KillTimer(mainWindow, 3);
    if (connected || connecting)
      startConnection();
    integrationConnectionsAfterDisconnect =
        (GetWindowLongW(connectionsPage, GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(canvas, GWL_STYLE) & WS_VISIBLE);
    writeIntegrationReport();
    DestroyWindow(mainWindow);
  }
}
static LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_CREATE:
    buildUI(hwnd);
    return 0;
  case WM_ERASEBKGND:
    return 1;
  case WM_PRINTCLIENT:
  case WM_PAINT: {
    PAINTSTRUCT ps{};
    bool printing = msg == WM_PRINTCLIENT;
    HDC dc = printing ? (HDC)wp : BeginPaint(hwnd, &ps);
    RECT r;
    GetClientRect(hwnd, &r);
    fill(dc, r, palette.page);
    if (connected && !fullscreen) {
      RECT bar{0, 0, r.right, px(TOP)};
      fill(dc, bar, palette.card);
      textAt(dc, connectionTitle,
             logicalRect(68, 9, std::max(80, MulDiv(r.right, 96, uiDpi) - 550),
                         22),
             fontStrong, palette.text, DT_SINGLELINE | DT_END_ELLIPSIS);
      textAt(dc, L"Connected", logicalRect(68, 31, 260, 18), fontSmall,
             palette.secondary);
    }
    if (!printing)
      EndPaint(hwnd, &ps);
    return 0;
  }
  case WM_CTLCOLORSTATIC:
  case WM_CTLCOLOREDIT:
  case WM_CTLCOLORLISTBOX:
  case WM_CTLCOLORBTN:
    return controlColor(msg, wp, lp);
  case WM_SETTINGCHANGE:
  case WM_THEMECHANGED:
    applyTheme();
    layout();
    return 0;
  case WM_DPICHANGED: {
    uiDpi = HIWORD(wp);
    RECT *r = (RECT *)lp;
    SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left,
                 r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
    applyTheme();
    layout();
    layoutSettings();
    return 0;
  }
  case WM_SIZE:
    layout();
    if (wp == SIZE_MINIMIZED)
      releaseAll();
    if (connected)
      sendSubscription();
    return 0;
  case WM_GETMINMAXINFO:
    ((MINMAXINFO *)lp)->ptMinTrackSize = {px(720), px(480)};
    return 0;
  case WM_COMMAND: {
    int id = LOWORD(wp), code = HIWORD(wp);
    if (id == IDCANCEL && IsWindowVisible(settingsPanel)) {
      ShowWindow(settingsPanel, SW_HIDE);
      SetFocus(canvas);
    } else if (id == IDOK && IsWindowVisible(settingsPanel)) {
      ShowWindow(settingsPanel, SW_HIDE);
      SetFocus(canvas);
    } else if (id == IDOK && !connected)
      startConnection();
    else if (id == ID_ADVANCED) {
      advancedOpen = !advancedOpen;
      SetWindowTextW(controls[id],
                     advancedOpen ? L"Advanced  ▴" : L"Advanced  ▾");
      layoutConnections();
    } else if (id == ID_NEW_CONNECTION) {
      SetWindowTextW(controls[ID_HOST], L"");
      SetWindowTextW(controls[ID_PASSWORD], L"");
      SetWindowTextW(controls[ID_PORT], L"5920");
      SetWindowTextW(controls[ID_ZTNETWORK], L"");
      SetWindowTextW(controls[ID_ZTMANAGED], L"");
      SetWindowTextW(controls[ID_PRESETS], L"New connection");
      SetFocus(controls[ID_HOST]);
    } else if (id == ID_SAVED_LIST && code == LBN_SELCHANGE) {
      int index = (int)SendMessageW(controls[id], LB_GETCURSEL, 0, 0);
      if (index >= 0 && index < (int)savedNames.size()) {
        recallPreset(savedNames[index]);
        SetFocus(controls[ID_PASSWORD]);
      }
    } else if (id == ID_DISPLAYS_MENU)
      showDisplaysMenu();
    else if (id == ID_ZOOM_MENU)
      showZoomMenu();
    else if (id == ID_SETTINGS_TOOL)
      openSettings();
    else if (id == ID_SETTINGS_DONE) {
      ShowWindow(settingsPanel, SW_HIDE);
      SetFocus(canvas);
    } else if (id == ID_ALLOW_CONTROL) {
      check(ID_VIEWONLY, !checked(ID_ALLOW_CONTROL));
      SendMessageW(hwnd, WM_COMMAND, MAKEWPARAM(ID_VIEWONLY, BN_CLICKED), 0);
    } else if (id == ID_BANDWIDTH && code == EN_KILLFOCUS) {
      double mbps = 0;
      try {
        mbps = std::stod(controlText(ID_BANDWIDTH));
      } catch (...) {
      }
      int kbps = std::clamp((int)std::round(mbps * 1000), 0, 100000);
      SetWindowTextW(controls[ID_CAP], std::to_wstring(kbps).c_str());
      sendSubscription();
    } else if (id == ID_AUDIO_TOOL) {
      check(ID_AUDIO, !checked(ID_AUDIO));
      SendMessageW(hwnd, WM_COMMAND, MAKEWPARAM(ID_AUDIO, BN_CLICKED), 0);
    } else if (id == ID_BACK_CONNECTIONS) {
      if (connected || connecting)
        startConnection();
      layout();
    } else if (id == ID_CONNECT && code == BN_CLICKED)
      startConnection();
    else if (id == ID_MONITORS && code == LBN_SELCHANGE) {
      releaseAll();
      enforceResolution();
      updateScroll();
      sendSubscription();
      InvalidateRect(controls[ID_RES], nullptr, TRUE);
    } else if ((id == ID_RES || id == ID_COLOR || id == ID_QUALITY) &&
               code == CBN_SELCHANGE) {
      if (id == ID_RES && !resolutionSupported(comboIndex(ID_RES))) {
        std::string limiting;
        resolutionSupported(comboIndex(ID_RES), &limiting);
        MessageBoxW(hwnd,
                    (L"This resolution would upscale " + wide(limiting) +
                     L". Select a smaller resolution.")
                        .c_str(),
                    L"Resolution unavailable", MB_OK | MB_ICONINFORMATION);
        enforceResolution();
      }
      sendSubscription();
    } else if ((id == ID_FPS || id == ID_CAP) && code == EN_KILLFOCUS)
      sendSubscription();
    else if ((id == ID_AUDIO || id == ID_PAUSE || id == ID_VIEWONLY) &&
             code == BN_CLICKED) {
      releaseAll();
      if (id == ID_AUDIO && !checked(ID_AUDIO))
        stopAudio();
      sendSubscription();
    } else if (id == ID_FIT) {
      fit = true;
      panX = panY = 0;
      updateScroll();
      sendSubscription();
    } else if (id == ID_Z100) {
      fit = false;
      zoom = 1.f;
      updateScroll();
      sendSubscription();
    } else if (id == ID_ZIN || id == ID_ZOUT) {
      fit = false;
      zoom *= id == ID_ZIN ? 1.2f : 1 / 1.2f;
      updateScroll();
      sendSubscription();
    } else if (id == ID_FULL)
      toggleFullscreen(!fullscreen);
    else if (id == ID_FOLLOW)
      follow = checked(ID_FOLLOW);
    else if (id == ID_SAVE) {
      storePreset();
      refreshSavedConnections();
    } else if (id == ID_LOAD)
      recallPreset(narrow(controlText(ID_PRESETS)));
    else if (id == ID_ZTSTATUS)
      zeroTierOperation({{"action", "status"}}, "status");
    refreshToolbar();
    return 0;
  }
  case WM_MEASUREITEM:
    if (((MEASUREITEMSTRUCT *)lp)->CtlType == ODT_MENU) {
      auto *m = (MEASUREITEMSTRUCT *)lp;
      m->itemHeight = px(36);
      m->itemWidth = px(300);
      return TRUE;
    }
    ((MEASUREITEMSTRUCT *)lp)->itemHeight =
        px(((MEASUREITEMSTRUCT *)lp)->CtlID == ID_SAVED_LIST ? 68 : 30);
    return TRUE;
  case WM_DRAWITEM: {
    auto *d = (DRAWITEMSTRUCT *)lp;
    if (d->CtlType == ODT_MENU) {
      bool selected = d->itemState & ODS_SELECTED;
      fill(d->hDC, d->rcItem, selected ? palette.hover : palette.card);
      RECT r = d->rcItem;
      r.left += px(36);
      textAt(d->hDC, *(const std::wstring *)d->itemData, r, fontBody,
             palette.text, DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      if (d->itemState & ODS_CHECKED) {
        r = d->rcItem;
        r.right = r.left + px(30);
        textAt(d->hDC, L"✓", r, fontBody, palette.accent,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      }
      return TRUE;
    }
    if (d->itemID == (UINT)-1)
      return TRUE;
    if (d->CtlID == ID_SAVED_LIST) {
      if (d->itemID >= savedNames.size())
        return TRUE;
      RECT r = d->rcItem;
      fill(d->hDC, r, palette.card);
      bool selected = d->itemState & ODS_SELECTED;
      RECT card = r;
      InflateRect(&card, -px(2), -px(3));
      if (selected)
        rounded(d->hDC, card, palette.hover, palette.hover, 12);
      auto name = savedNames[d->itemID];
      std::string host = settings.value("presets", json::object())
                             .value(name, json::object())
                             .value("host", "");
      r.left += px(14);
      r.top += px(10);
      textAt(d->hDC, wide(name), r, fontStrong, palette.text,
             DT_SINGLELINE | DT_END_ELLIPSIS);
      r.top += px(24);
      textAt(d->hDC, wide(host), r, fontSmall, palette.secondary,
             DT_SINGLELINE | DT_END_ELLIPSIS);
      return TRUE;
    }
    if (d->CtlID != ID_RES && d->CtlID != ID_COLOR && d->CtlID != ID_QUALITY)
      break;
    wchar_t text[256]{};
    SendMessageW(controls[d->CtlID], CB_GETLBTEXT, d->itemID, (LPARAM)text);
    bool selected = (d->itemState & ODS_SELECTED) != 0,
         supported = d->CtlID != ID_RES || resolutionSupported((int)d->itemID);
    fill(d->hDC, d->rcItem, selected ? palette.hover : palette.field);
    RECT r = d->rcItem;
    r.left += px(12);
    textAt(d->hDC, text, r, fontBody,
           supported ? palette.text : palette.secondary,
           DT_SINGLELINE | DT_VCENTER);
    return TRUE;
  }
  case WM_NET: {
    pendingControlMessages--;
    std::unique_ptr<json> p((json *)lp);
    try {
      handleNetwork(*p);
    } catch (...) {
      status(L"Invalid computer response");
    }
    return 0;
  }
  case WM_FRAME: {
    std::unique_ptr<NetworkBinary> p((NetworkBinary *)lp);
    pendingFrameBytes -= p->data.size();
    if (p->generation == connectGeneration)
      handleBinary(p->data);
    return 0;
  }
  case WM_OSC: {
    std::unique_ptr<OSCCommand> p((OSCCommand *)lp);
    handleOSC(*p);
    return 0;
  }
  case WM_TIMER:
    if (wp == 3) {
      integrationTick();
      return 0;
    }
    if (wp == 2) {
      KillTimer(hwnd, 2);
      sendSubscription();
    } else if (wp == 1 && connected) {
      uint64_t bytes = receivedBytes.load(), frames = receivedFrames;
      currentKbps = (bytes - previousBytes) * 8 / 1000.;
      currentUpdates = frames - previousFrames;
      previousBytes = bytes;
      previousFrames = frames;
      refreshToolbar();
      sendMessage({{"type", "ping"}, {"time", GetTickCount64()}});
    }
    return 0;
  case WM_ACTIVATE:
    if (LOWORD(wp) == WA_INACTIVE)
      releaseAll();
    return 0;
  case WM_DESTROY:
    releaseAll();
    if (!zeroTierTransaction.empty())
      runZeroTier(
          {{"action", "restore"}, {"transactionId", zeroTierTransaction}});
    stopping = true;
    closeTransport();
    stopAudio();
    if (oscSocket != INVALID_SOCKET)
      closesocket(oscSocket);
    KillTimer(hwnd, 1);
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static int selfTest() {
  json tests = json::array();
  auto test = [&](const char *name, bool success) {
    tests.push_back({{"name", name}, {"passed", success}});
    if (!success)
      throw std::runtime_error(name);
  };
  try {
    std::string header = R"({"type":"frame","revision":1})";
    std::vector<uint8_t> binary{0, 0, 0, (uint8_t)header.size()};
    binary.insert(binary.end(), header.begin(), header.end());
    binary.push_back(42);
    auto envelope = su_remote::parseEnvelope(binary);
    test("binary framing preserves payload",
         envelope.header["revision"] == 1 &&
             binary[envelope.payloadOffset] == 42);
    auto rejects = [](const std::vector<uint8_t> &b) {
      try {
        su_remote::parseEnvelope(b);
        return false;
      } catch (...) {
        return true;
      }
    };
    test("truncated binary header rejected", rejects({0, 0, 0, 8, '{', '}'}));
    test("oversized header rejected", rejects({0, 1, 0, 1, '{'}));
    test("non-object header rejected", rejects({0, 0, 0, 2, '[', ']'}));
    test("valid edge tile",
         su_remote::validImageRect(1800, 1000, 120, 80, 1920, 1080));
    test("out-of-bounds tile rejected",
         !su_remote::validImageRect(1801, 1000, 120, 80, 1920, 1080));
    test("integer overflow dimensions rejected",
         !su_remote::validImageRect(INT32_MAX, 0, INT32_MAX, 1, 1920, 1080));
    test("excessive allocation rejected",
         !su_remote::validImageRect(0, 0, 3840, 3840, 3840, 3840));
    auto rejectsCanvases = [](const json &c,
                              const std::vector<std::string> &ids) {
      try {
        su_remote::validateCanvasList(c, ids);
        return false;
      } catch (...) {
        return true;
      }
    };
    test("unknown canvas ID rejected before allocation",
         rejectsCanvases(
             json::array(
                 {{{"id", "intruder"}, {"width", 3840}, {"height", 2160}}}),
             {"selected"}));
    test("duplicate canvas ID rejected",
         rejectsCanvases(
             json::array(
                 {{{"id", "selected"}, {"width", 1280}, {"height", 720}},
                  {{"id", "selected"}, {"width", 1280}, {"height", 720}}}),
             {"selected", "other"}));
    json large = json::array();
    std::vector<std::string> ids;
    for (int i = 0; i < 9; i++) {
      ids.push_back(std::to_string(i));
      large.push_back({{"id", ids.back()}, {"width", 3840}, {"height", 2160}});
    }
    test("aggregate framebuffer budget enforced", rejectsCanvases(large, ids));
    size_t at = 0;
    std::string str;
    test("truncated OSC string rejected", !oscString({'/', 'a'}, at, str));
    std::vector<uint8_t> osc;
    appendOSC(osc, "/su/remote/zoom");
    appendOSC(osc, ",f");
    at = 0;
    test("OSC padding parsed",
         oscString(osc, at, str) && str == "/su/remote/zoom" && at % 4 == 0);
    test("default secure endpoint", parseEndpoint("example.test").port == 5920);
    test("explicit secure endpoint",
         parseEndpoint("wss://example.test:8443/remote").port == 8443);
    auto rejectsAddress = [](const std::string &address) {
      try {
        parseEndpoint(address);
        return false;
      } catch (...) {
        return true;
      }
    };
    test("plaintext endpoint rejected", rejectsAddress("http://example.test"));
    test("URL credentials rejected",
         rejectsAddress("https://name:password@example.test"));
    BYTE abc[] = {'a', 'b', 'c'};
    CERT_CONTEXT cert{};
    cert.pbCertEncoded = abc;
    cert.cbCertEncoded = 3;
    test("SHA-256 certificate fingerprint",
         certificateHash(&cert) ==
             "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:"
             "17:7A:9C:B4:10:FF:61:F2:00:15:AD");
    populateDisplays({{"displays", json::array({{{"id", "landscape"},
                                                 {"name", "FHD"},
                                                 {"width", 1920},
                                                 {"height", 1080}},
                                                {{"id", "portrait"},
                                                 {"name", "Portrait UHD"},
                                                 {"width", 2160},
                                                 {"height", 3840}}})}});
    SendMessageW(controls[ID_MONITORS], LB_SETSEL, TRUE, -1);
    surfaces["landscape"] = {1920, 1080, {}};
    surfaces["portrait"] = {608, 1080, {}};
    fit = false;
    zoom = .5f;
    panX = 100;
    panY = 0;
    std::string id;
    double nx = 0, ny = 0;
    test("mixed-aspect pointer map after zoom/pan",
         mapPointer(1340, 270, id, nx, ny) && id == "portrait" &&
             std::abs(nx - .5) < .001 && std::abs(ny - .5) < .001);
    test("letterbox never targets a remote display",
         !mapPointer(900, 270, id, nx, ny));
    test("common resolution constrained by smallest source",
         resolutionSupported(1) && !resolutionSupported(2) &&
             !resolutionSupported(3));
    test("public OSC state contains no password",
         !publicState().contains("password"));
    const char *png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+"
                      "KAAAADklEQVR4nGP4z8DwHwQBEPgD/U6VwW8AAAAASUVORK5CYII=";
    DWORD count = 0;
    CryptStringToBinaryA(png, 0, CRYPT_STRING_BASE64, nullptr, &count, nullptr,
                         nullptr);
    std::vector<uint8_t> pixels(count);
    CryptStringToBinaryA(png, 0, CRYPT_STRING_BASE64, pixels.data(), &count,
                         nullptr, nullptr);
    Frame f;
    f.w = 2;
    f.h = 1;
    test("native WIC PNG decode",
         decodeImage(pixels.data(), pixels.size(), f) && f.pixels.size() == 8 &&
             f.pixels[2] == 255 && f.pixels[5] == 255);
    f.w = 3;
    test("decoded dimensions must match metadata",
         !decodeImage(pixels.data(), pixels.size(), f));
    test("corrupt image rejected", !decodeImage((const uint8_t *)"bad", 3, f));
    const char *grayPNG = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAABBAAAAAAZp70QAAAAC0lE"
                          "QVR4nGNgXQ8AALwAtYJBgpwAAAAASUVORK5CYII=";
    DWORD graySize = 0;
    CryptStringToBinaryA(grayPNG, 0, CRYPT_STRING_BASE64, nullptr, &graySize,
                         nullptr, nullptr);
    std::vector<uint8_t> grayBytes(graySize);
    CryptStringToBinaryA(grayPNG, 0, CRYPT_STRING_BASE64, grayBytes.data(),
                         &graySize, nullptr, nullptr);
    Frame gray;
    gray.w = 4;
    gray.h = 1;
    test("native 4-bit grayscale PNG exact pixels",
         decodeImage(grayBytes.data(), grayBytes.size(), gray) &&
             gray.pixels[0] == 0 && gray.pixels[4] == 85 &&
             gray.pixels[8] == 170 && gray.pixels[12] == 255);
    std::string result = json{{"ok", true}, {"tests", tests}}.dump() + "\n";
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), result.data(),
              (DWORD)result.size(), &n, nullptr);
    return 0;
  } catch (const std::exception &e) {
    std::string result =
        json{{"ok", false}, {"tests", tests}, {"error", e.what()}}.dump() +
        "\n";
    DWORD n = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), result.data(),
              (DWORD)result.size(), &n, nullptr);
    return 1;
  }
}
static bool captureWindowPNG(HWND window, const std::wstring &path) {
  RECT bounds;
  GetWindowRect(window, &bounds);
  int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
  HDC source = GetWindowDC(window), memory = CreateCompatibleDC(source);
  HBITMAP bitmap = CreateCompatibleBitmap(source, width, height);
  auto old = SelectObject(memory, bitmap);
  RedrawWindow(window, nullptr, nullptr,
               RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
  BOOL painted = PrintWindow(window, memory, 2);
  if (!painted)
    painted = BitBlt(memory, 0, 0, width, height, source, 0, 0, SRCCOPY);
  SelectObject(memory, old);
  DeleteDC(memory);
  ReleaseDC(window, source);
  IWICBitmap *image = nullptr;
  IWICStream *stream = nullptr;
  IWICBitmapEncoder *encoder = nullptr;
  IWICBitmapFrameEncode *frame = nullptr;
  IPropertyBag2 *properties = nullptr;
  HRESULT hr = painted ? imaging->CreateBitmapFromHBITMAP(
                             bitmap, nullptr, WICBitmapIgnoreAlpha, &image)
                       : E_FAIL;
  if (SUCCEEDED(hr))
    hr = imaging->CreateStream(&stream);
  if (SUCCEEDED(hr))
    hr = stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE);
  if (SUCCEEDED(hr))
    hr = imaging->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr))
    hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
  if (SUCCEEDED(hr))
    hr = encoder->CreateNewFrame(&frame, &properties);
  if (SUCCEEDED(hr))
    hr = frame->Initialize(properties);
  if (SUCCEEDED(hr))
    hr = frame->SetSize(width, height);
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr))
    hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr))
    hr = frame->WriteSource(image, nullptr);
  if (SUCCEEDED(hr))
    hr = frame->Commit();
  if (SUCCEEDED(hr))
    hr = encoder->Commit();
  if (properties)
    properties->Release();
  if (frame)
    frame->Release();
  if (encoder)
    encoder->Release();
  if (stream)
    stream->Release();
  if (image)
    image->Release();
  DeleteObject(bitmap);
  return SUCCEEDED(hr);
}
static void visualDesktop() {
  displays = {{"visual-1", "Studio display", 1920, 1080},
              {"visual-2", "Preview display", 1920, 1080}};
  SendMessageW(controls[ID_MONITORS], LB_RESETCONTENT, 0, 0);
  for (auto &d : displays)
    SendMessageW(controls[ID_MONITORS], LB_ADDSTRING, 0,
                 (LPARAM)wide(d.name).c_str());
  SendMessageW(controls[ID_MONITORS], LB_SETSEL, TRUE, 0);
  auto &s = surfaces["visual-1"];
  s.width = 1920;
  s.height = 1080;
  s.pixels.resize(1920 * 1080 * 4);
  HDC screen = GetDC(nullptr), dc = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = 1920;
  bi.bmiHeader.biHeight = -1080;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void *bits = nullptr;
  HBITMAP b = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  auto old = SelectObject(dc, b);
  RECT r{0, 0, 1920, 1080};
  fill(dc, r, RGB(22, 27, 35));
  fill(dc, RECT{0, 0, 1920, 70}, RGB(32, 38, 48));
  HFONT heading =
            CreateFontW(-26, 0, 0, 0, 600, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                        ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI"),
        body =
            CreateFontW(-20, 0, 0, 0, 400, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                        ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  textAt(dc, L"Studio workspace", RECT{30, 20, 800, 55}, heading,
         RGB(235, 241, 251));
  textAt(dc, L"Live production", RECT{1630, 22, 1880, 55}, body,
         RGB(155, 170, 189));
  fill(dc, RECT{28, 100, 1300, 775}, RGB(13, 18, 28));
  for (int y = 140; y < 730; y++) {
    int shade = (y - 140) * 50 / 590;
    fill(dc, RECT{70, y, 1258, y + 1},
         RGB(26 + shade / 2, 48 + shade, 66 + shade));
  }
  textAt(dc, L"PROGRAM PREVIEW", RECT{100, 165, 800, 210}, body,
         RGB(150, 176, 201));
  textAt(dc, L"Your story, on screen.", RECT{210, 415, 1120, 500}, heading,
         RGB(236, 242, 250));
  fill(dc, RECT{1330, 100, 1890, 775}, RGB(31, 38, 49));
  textAt(dc, L"Audio mixer", RECT{1360, 128, 1840, 180}, heading,
         RGB(235, 241, 251));
  for (int i = 0; i < 6; i++) {
    RECT meter{1370 + i * 80, 230, 1404 + i * 80, 660};
    fill(dc, meter, RGB(18, 23, 31));
    meter.top = 300 + (i % 3) * 65;
    fill(dc, meter, RGB(65, 174, 124));
    textAt(dc, L"CH " + std::to_wstring(i + 1),
           RECT{1350 + i * 80, 685, 1430 + i * 80, 720}, body,
           RGB(162, 177, 195));
  }
  fill(dc, RECT{28, 810, 1890, 1050}, RGB(31, 38, 49));
  textAt(dc, L"Timeline", RECT{58, 840, 600, 880}, heading, RGB(230, 236, 246));
  for (int i = 0; i < 8; i++) {
    RECT clip{58 + i * 221, 908, 261 + i * 221, 1000};
    fill(dc, clip, i % 2 ? RGB(63, 94, 123) : RGB(69, 105, 105));
  }
  memcpy(s.pixels.data(), bits, s.pixels.size());
  SelectObject(dc, old);
  DeleteObject(b);
  DeleteObject(heading);
  DeleteObject(body);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
}
static int visualTest(const std::wstring &folder) {
  CreateDirectoryW(folder.c_str(), nullptr);
  json shots = json::array();
  try {
    settings["presets"] = {
        {"Studio Mac",
         {{"host", "studio-mac.local"}, {"displays", json::array()}}},
        {"Edit suite",
         {{"host", "edit-suite.local"}, {"displays", json::array()}}}};
    refreshSavedConnections();
    SetWindowTextW(controls[ID_HOST], L"studio-mac.local");
    SetWindowTextW(controls[ID_PASSWORD], L"");
    auto shot = [&](const std::wstring &name, HWND window) {
      UpdateWindow(window);
      if (!captureWindowPNG(window, folder + L"\\" + name + L".png"))
        throw std::runtime_error("Screenshot capture failed");
      shots.push_back(narrow(name) + ".png");
    };
    for (int theme = 0; theme < 2; theme++) {
      forcedTheme = theme;
      applyTheme();
      std::wstring suffix = theme ? L"dark" : L"light";
      connected = false;
      connecting = false;
      fullscreen = false;
      advancedOpen = false;
      pageScroll = 0;
      uiStatus.clear();
      SetWindowTextW(statusLabel, L"");
      SetWindowTextW(controls[ID_CONNECT], L"Connect");
      ShowWindow(settingsPanel, SW_HIDE);
      SetWindowPos(mainWindow, HWND_TOP, 40, 40, px(740), px(560),
                   SWP_SHOWWINDOW);
      layout();
      shot(L"connections-" + suffix, mainWindow);
      SetWindowPos(mainWindow, nullptr, 40, 40, px(720), px(480), SWP_NOZORDER);
      layout();
      shot(L"connections-" + suffix + L"-small", mainWindow);
      connected = true;
      connectionTitle = L"Studio Mac";
      fit = true;
      panX = panY = 0;
      visualDesktop();
      SetWindowPos(mainWindow, HWND_TOP, 40, 40, px(1100), px(760),
                   SWP_SHOWWINDOW);
      layout();
      shot(L"viewing-" + suffix, mainWindow);
      openSettings();
      shot(L"settings-" + suffix, settingsPanel);
      ShowWindow(settingsPanel, SW_HIDE);
      SetWindowPos(mainWindow, nullptr, 40, 40, px(720), px(480), SWP_NOZORDER);
      layout();
      shot(L"viewing-" + suffix + L"-small", mainWindow);
    }
    connected = false;
    json report = {{"ok", true},
                   {"screenshots", shots},
                   {"dpi", uiDpi},
                   {"highContrast", highContrast},
                   {"reducedMotion", reducedMotion}};
    std::ofstream out((folder + L"\\visual-report.json").c_str());
    out << report.dump(2);
    std::string text = report.dump() + "\n";
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text.data(), (DWORD)text.size(),
              &written, nullptr);
    return 0;
  } catch (const std::exception &e) {
    connected = false;
    std::ofstream out((folder + L"\\visual-report.json").c_str());
    out << json{{"ok", false}, {"error", e.what()}}.dump();
    return 1;
  }
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR arguments, int show) {
  visualMode =
      arguments && std::wstring(arguments).rfind(L"--visual-test", 0) == 0;
  integrationMode =
      arguments && std::wstring(arguments) == L"--integration-test";
  using DpiFn = BOOL(WINAPI *)(HANDLE);
  auto setDpi = (DpiFn)GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                      "SetProcessDpiAwarenessContext");
  if (setDpi)
    setDpi((HANDLE)-4);
  else
    SetProcessDPIAware();
  HDC screen = GetDC(nullptr);
  uiDpi = GetDeviceCaps(screen, LOGPIXELSX);
  ReleaseDC(nullptr, screen);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&imaging));
  INITCOMMONCONTROLSEX cc{sizeof(cc), ICC_STANDARD_CLASSES};
  InitCommonControlsEx(&cc);
  if (!integrationMode && !visualMode &&
      !(arguments && std::wstring(arguments) == L"--self-test"))
    loadSettings();
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = windowProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hIcon = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(101), IMAGE_ICON,
                               px(32), px(32), 0);
  wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
  wc.lpszClassName = L"SURemoteViewer";
  RegisterClassExW(&wc);
  wc.lpfnWndProc = pageProc;
  wc.lpszClassName = L"SURemoteConnections";
  RegisterClassExW(&wc);
  wc.lpfnWndProc = settingsProc;
  wc.lpszClassName = L"SURemoteSettings";
  RegisterClassExW(&wc);
  wc.lpfnWndProc = canvasProc;
  wc.hbrBackground = nullptr;
  wc.lpszClassName = L"SURemoteCanvas";
  RegisterClassExW(&wc);
  mainWindow = CreateWindowExW(
      0, L"SURemoteViewer", productName, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
      CW_USEDEFAULT, px(740), px(560), nullptr, nullptr, instance, nullptr);
  if (!mainWindow)
    return 1;
  if (visualMode) {
    int count = 0;
    LPWSTR *args = CommandLineToArgvW(GetCommandLineW(), &count);
    std::wstring folder = count >= 3 ? args[2] : L"visuals";
    LocalFree(args);
    ShowWindow(mainWindow, SW_SHOW);
    int result = visualTest(folder);
    DestroyWindow(mainWindow);
    if (imaging)
      imaging->Release();
    CoUninitialize();
    return result;
  }
  if (arguments && std::wstring(arguments) == L"--self-test") {
    int result = selfTest();
    DestroyWindow(mainWindow);
    if (imaging)
      imaging->Release();
    CoUninitialize();
    return result;
  }
  ShowWindow(mainWindow, integrationMode ? SW_HIDE : show);
  UpdateWindow(mainWindow);
  if (integrationMode) {
    integrationFingerprint = testEnvironment(L"SU_REMOTE_TEST_FINGERPRINT");
    integrationReport = testEnvironment(L"SU_REMOTE_TEST_REPORT");
    std::string host = testEnvironment(L"SU_REMOTE_TEST_HOST"),
                password = testEnvironment(L"SU_REMOTE_TEST_PASSWORD");
    try {
      auto endpoint = parseEndpoint(host);
      if (endpoint.host != L"127.0.0.1" ||
          integrationFingerprint.size() != 95 || password.empty())
        throw std::runtime_error(
            "Integration test requires localhost, expected SHA256 fingerprint, "
            "and fixture password");
      SetWindowTextW(controls[ID_HOST], wide(host).c_str());
      SetWindowTextW(controls[ID_PASSWORD], wide(password).c_str());
      integrationConnectionsAtStart =
          (GetWindowLongW(connectionsPage, GWL_STYLE) & WS_VISIBLE) &&
          !(GetWindowLongW(canvas, GWL_STYLE) & WS_VISIBLE);
      integrationStarted = GetTickCount64();
      SetTimer(mainWindow, 3, 100, nullptr);
      connectNow();
    } catch (const std::exception &e) {
      integrationFailure = e.what();
      writeIntegrationReport();
      DestroyWindow(mainWindow);
      return 1;
    }
    SecureZeroMemory(password.data(), password.size());
  } else
    startOSC();
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (IsWindowVisible(settingsPanel) && IsDialogMessageW(settingsPanel, &msg))
      continue;
    if (GetFocus() != canvas && IsDialogMessageW(mainWindow, &msg))
      continue;
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (imaging)
    imaging->Release();
  CoUninitialize();
  return integrationMode ? integrationExitCode : 0;
}
