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
static constexpr int PANEL = 250, TOP = 44, FOOT = 26;
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
static HWND mainWindow, canvas, statusLabel, sidebar;
static int sidebarScroll = 0;
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
struct NetworkBinary {
  uint64_t generation;
  std::vector<uint8_t> data;
};
static std::atomic<uint64_t> receivedBytes{0};
static uint64_t previousBytes = 0, receivedFrames = 0, previousFrames = 0,
                lastLatency = 0;
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
  SetWindowTextW(statusLabel, s.c_str());
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
    throw std::runtime_error("Cannot fingerprint server certificate");
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
      L"Remote server:\n\n" +
      wide(hash) +
      L"\n\nOnly trust it if the fingerprints match. Trust and connect?";
  if (MessageBoxW(mainWindow, msg.c_str(), L"Verify SU Remote server",
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
    status(L"Enter the server password before activating its network");
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
        L"Save this preset first to review its ZeroTier network policy.",
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
    throw std::runtime_error("Invalid server address");
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
    throw std::runtime_error("SU Remote uses the /remote endpoint");
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
static void connectNow() {
  if (connecting || connected) {
    releaseInput();
    closeTransport();
    stopAudio();
    SetWindowTextW(controls[ID_CONNECT], L"Connect");
    status(L"Disconnected");
    return;
  }
  std::string host = narrow(controlText(ID_HOST));
  std::string password = narrow(controlText(ID_PASSWORD));
  if (host.empty()) {
    SetFocus(controls[ID_HOST]);
    return;
  }
  if (password.empty()) {
    status(L"Enter the server password to connect");
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
      session = WinHttpOpen(L"SU Remote/0.1", WINHTTP_ACCESS_TYPE_NO_PROXY,
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
            "Server unavailable or TLS connection failed (" +
            std::to_string(GetLastError()) + ")");
      PCCERT_CONTEXT cert = nullptr;
      DWORD bytes = sizeof(cert);
      if (!WinHttpQueryOption(request, WINHTTP_OPTION_SERVER_CERT_CONTEXT,
                              &cert, &bytes) ||
          !cert)
        throw std::runtime_error("Server did not supply a certificate");
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
        throw std::runtime_error("Server did not accept WebSocket connection");
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
          throw std::runtime_error("Server exceeded message limit");
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
            throw std::runtime_error("Invalid server JSON");
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
  status(L"Resolution adjusted to the selected monitor's native size");
}
static void storePreset() {
  std::string name = narrow(controlText(ID_PRESETS));
  if (name.empty())
    name = "Default";
  json p = {{"host", narrow(controlText(ID_HOST))},
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
    if (MessageBoxW(mainWindow, msg.c_str(), L"Save ZeroTier preset",
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
  status(L"Preset saved — password stays in memory only");
}
static std::vector<std::string> pendingSelection;
static void recallPreset(const std::string &name) {
  json p;
  {
    std::lock_guard<std::mutex> lock(settingsMutex);
    auto presets = settings.value("presets", json::object());
    if (!presets.contains(name)) {
      status(L"Preset not found");
      return;
    }
    p = presets[name];
  }
  SetWindowTextW(controls[ID_HOST], wide(p.value("host", "")).c_str());
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
  status(L"Preset recalled");
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
          {"audio", checked(ID_AUDIO)}};
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
          throw std::runtime_error("Unknown monitor ID");
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
        throw std::runtime_error("Resolution exceeds selected monitor");
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
  case WM_PAINT: {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);
    HBRUSH bg = CreateSolidBrush(RGB(18, 21, 26));
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
      SetTextColor(dc, RGB(180, 190, 200));
      SetBkMode(dc, TRANSPARENT);
      std::wstring t = connected ? L"Select one or more monitors"
                                 : L"SU Remote\nStudio Upgrade\n\nConnect to "
                                   L"view and control your Mac.";
      DrawTextW(dc, t.c_str(), -1, &rc, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
    }
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
static HWND add(HWND parent, const wchar_t *cls, const wchar_t *text,
                DWORD style, int id, int x, int y, int w, int h) {
  HWND c = CreateWindowExW(
      (cls == std::wstring(L"EDIT") || cls == std::wstring(L"LISTBOX"))
          ? WS_EX_CLIENTEDGE
          : 0,
      cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, parent,
      (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
  SendMessageW(c, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), TRUE);
  if (id)
    controls[id] = c;
  return c;
}
static void label(const wchar_t *t, int y) {
  add(mainWindow, L"STATIC", t, 0, 0, 12, y, 226, 18);
}
static void combo(int id, const std::vector<std::wstring> &items, int y,
                  int sel, bool owner = false) {
  add(mainWindow, L"COMBOBOX", L"",
      CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL |
          (owner ? CBS_OWNERDRAWFIXED | CBS_HASSTRINGS : 0),
      id, 12, y, 226, 200);
  for (auto &s : items)
    SendMessageW(controls[id], CB_ADDSTRING, 0, (LPARAM)s.c_str());
  SendMessageW(controls[id], CB_SETCURSEL, sel, 0);
}
static LRESULT CALLBACK sidebarProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_COMMAND || msg == WM_DRAWITEM || msg == WM_MEASUREITEM)
    return SendMessageW(mainWindow, msg, wp, lp);
  if (msg == WM_SIZE) {
    SCROLLINFO si{sizeof(si),
                  SIF_RANGE | SIF_PAGE | SIF_POS,
                  0,
                  730,
                  (UINT)HIWORD(lp),
                  sidebarScroll,
                  0};
    SetScrollInfo(hwnd, SB_VERT, &si, TRUE);
    return 0;
  }
  if (msg == WM_VSCROLL || msg == WM_MOUSEWHEEL) {
    SCROLLINFO si{};
    si.cbSize = sizeof(si);
    si.fMask = SIF_ALL;
    GetScrollInfo(hwnd, SB_VERT, &si);
    int next = sidebarScroll;
    if (msg == WM_MOUSEWHEEL)
      next -= GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA * 40;
    else
      switch (LOWORD(wp)) {
      case SB_LINEUP:
        next -= 30;
        break;
      case SB_LINEDOWN:
        next += 30;
        break;
      case SB_PAGEUP:
        next -= (int)si.nPage;
        break;
      case SB_PAGEDOWN:
        next += (int)si.nPage;
        break;
      case SB_THUMBTRACK:
        next = si.nTrackPos;
        break;
      default:
        return 0;
      }
    next = std::clamp(next, 0, std::max<int>(0, si.nMax - (int)si.nPage + 1));
    int delta = sidebarScroll - next;
    sidebarScroll = next;
    ScrollWindowEx(hwnd, 0, delta, nullptr, nullptr, nullptr, nullptr,
                   SW_SCROLLCHILDREN | SW_INVALIDATE | SW_ERASE);
    si.fMask = SIF_POS;
    si.nPos = next;
    SetScrollInfo(hwnd, SB_VERT, &si, TRUE);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static void layout() {
  RECT r;
  GetClientRect(mainWindow, &r);
  ShowWindow(sidebar, fullscreen ? SW_HIDE : SW_SHOW);
  for (int id : {ID_HOST, ID_PASSWORD, ID_CONNECT})
    ShowWindow(controls[id], fullscreen ? SW_HIDE : SW_SHOW);
  ShowWindow(statusLabel, fullscreen ? SW_HIDE : SW_SHOW);
  if (fullscreen) {
    MoveWindow(canvas, 0, 0, r.right, r.bottom, TRUE);
    updateScroll();
    return;
  }
  int hostW = std::max<int>(160, (r.right - 390) / 2);
  MoveWindow(controls[ID_HOST], 12, 10, hostW, 24, TRUE);
  MoveWindow(controls[ID_PASSWORD], 24 + hostW, 10,
             std::max<int>(120, r.right - hostW - 140), 24, TRUE);
  MoveWindow(controls[ID_CONNECT], r.right - 104, 9, 92, 26, TRUE);
  MoveWindow(sidebar, 0, TOP, PANEL, std::max<int>(1, r.bottom - TOP - FOOT),
             TRUE);
  MoveWindow(canvas, PANEL, TOP, std::max<int>(1, r.right - PANEL),
             std::max<int>(1, r.bottom - TOP - FOOT), TRUE);
  MoveWindow(statusLabel, 8, r.bottom - FOOT + 4,
             std::max<int>(1, r.right - 16), 22, TRUE);
  updateScroll();
}

static void populateDisplays(const json &msg) {
  auto previously = selection();
  if (!pendingSelection.empty())
    previously = pendingSelection;
  displays.clear();
  SendMessageW(controls[ID_MONITORS], LB_RESETCONTENT, 0, 0);
  for (const auto &d : msg.value("displays", json::array())) {
    Display v{d.value("id", ""), d.value("name", "Monitor"),
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
    connected = true;
    connecting = false;
    revision = 0;
    SetWindowTextW(controls[ID_CONNECT], L"Disconnect");
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
      integrationFailure = msg.value("message", "Server error");
    status(wide(msg.value("message", "Server error")));
    if (msg.value("code", "") == "authentication") {
      closeTransport();
      restoreZeroTier();
      SetWindowTextW(controls[ID_CONNECT], L"Connect");
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
                 {"error", integrationFailure}};
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
    writeIntegrationReport();
    DestroyWindow(mainWindow);
  }
}
static LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_CREATE: {
    mainWindow = hwnd;
    add(hwnd, L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, ID_HOST, 12, 10, 320,
        24);
    SendMessageW(controls[ID_HOST], EM_SETCUEBANNER, TRUE,
                 (LPARAM)L"Mac address or hostname (port 5920)");
    add(hwnd, L"EDIT", L"", WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
        ID_PASSWORD, 340, 10, 200, 24);
    SendMessageW(controls[ID_PASSWORD], EM_SETCUEBANNER, TRUE,
                 (LPARAM)L"Server password");
    add(hwnd, L"BUTTON", L"Connect", BS_PUSHBUTTON | WS_TABSTOP, ID_CONNECT,
        550, 9, 92, 26);
    label(L"MONITORS · select one or several", TOP + 10);
    add(hwnd, L"LISTBOX", L"",
        LBS_MULTIPLESEL | LBS_NOTIFY | WS_VSCROLL | WS_TABSTOP, ID_MONITORS, 12,
        TOP + 30, 226, 112);
    label(L"Transmission resolution", 196);
    combo(ID_RES,
          {L"HD · 1280 × 720", L"FHD · 1920 × 1080", L"QHD · 2560 × 1440",
           L"UHD · 3840 × 2160", L"Native · no upscaling"},
          216, 1, true);
    label(L"Color", 249);
    combo(ID_COLOR,
          {L"Full color", L"16 shades of gray", L"256 colors",
           L"16-bit color (RGB565)"},
          268, 0);
    label(L"Compression", 300);
    combo(ID_QUALITY,
          {L"Adaptive · desktop + motion", L"Desktop · sharp text",
           L"Motion · lower bandwidth"},
          320, 0);
    add(hwnd, L"STATIC", L"FPS", 0, 0, 12, 356, 70, 18);
    add(hwnd, L"STATIC", L"Cap (kbps, 0 = auto)", 0, 0, 90, 356, 148, 18);
    add(hwnd, L"EDIT", L"15", WS_TABSTOP | ES_NUMBER, ID_FPS, 12, 375, 64, 24);
    add(hwnd, L"EDIT", L"4000", WS_TABSTOP | ES_NUMBER, ID_CAP, 90, 375, 148,
        24);
    add(hwnd, L"BUTTON", L"Audio (192 kbps)", BS_AUTOCHECKBOX | WS_TABSTOP,
        ID_AUDIO, 12, 407, 226, 22);
    add(hwnd, L"BUTTON", L"Pause stream", BS_AUTOCHECKBOX | WS_TABSTOP,
        ID_PAUSE, 12, 431, 112, 22);
    add(hwnd, L"BUTTON", L"View only", BS_AUTOCHECKBOX | WS_TABSTOP,
        ID_VIEWONLY, 126, 431, 112, 22);
    add(hwnd, L"BUTTON", L"Fit", BS_PUSHBUTTON | WS_TABSTOP, ID_FIT, 12, 466,
        36, 26);
    add(hwnd, L"BUTTON", L"−", BS_PUSHBUTTON | WS_TABSTOP, ID_ZOUT, 53, 466, 26,
        26);
    add(hwnd, L"BUTTON", L"+", BS_PUSHBUTTON | WS_TABSTOP, ID_ZIN, 84, 466, 26,
        26);
    add(hwnd, L"BUTTON", L"100%", BS_PUSHBUTTON | WS_TABSTOP, ID_Z100, 115, 466,
        48, 26);
    add(hwnd, L"BUTTON", L"Fullscreen", BS_PUSHBUTTON | WS_TABSTOP, ID_FULL,
        168, 466, 70, 26);
    add(hwnd, L"BUTTON", L"Pan by following pointer",
        BS_AUTOCHECKBOX | WS_TABSTOP, ID_FOLLOW, 12, 501, 226, 22);
    label(L"Saved connection / view preset", 534);
    add(hwnd, L"COMBOBOX", L"Default", CBS_DROPDOWN | WS_VSCROLL | WS_TABSTOP,
        ID_PRESETS, 12, 554, 142, 200);
    if (settings.contains("presets") && settings["presets"].is_object())
      for (auto it = settings["presets"].begin();
           it != settings["presets"].end(); ++it)
        SendMessageW(controls[ID_PRESETS], CB_ADDSTRING, 0,
                     (LPARAM)wide(it.key()).c_str());
    SetWindowTextW(controls[ID_PRESETS], L"Default");
    add(hwnd, L"BUTTON", L"Save", BS_PUSHBUTTON | WS_TABSTOP, ID_SAVE, 160, 553,
        78, 25);
    add(hwnd, L"BUTTON", L"Recall preset", BS_PUSHBUTTON | WS_TABSTOP, ID_LOAD,
        12, 585, 226, 25);
    label(L"ZeroTier required network (optional)", 623);
    add(hwnd, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_ZTNETWORK, 12, 642,
        226, 24);
    label(L"Exclusive managed IDs (comma-separated)", 675);
    add(hwnd, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, ID_ZTMANAGED, 12, 694,
        226, 24);
    add(hwnd, L"BUTTON", L"ZeroTier network status", BS_PUSHBUTTON | WS_TABSTOP,
        ID_ZTSTATUS, 12, 727, 226, 26);
    sidebar =
        CreateWindowExW(WS_EX_CONTROLPARENT, L"SURemoteSidebar", L"",
                        WS_CHILD | WS_VISIBLE | WS_VSCROLL, 0, TOP, PANEL, 730,
                        hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
    std::vector<HWND> children;
    for (HWND child = GetWindow(hwnd, GW_CHILD); child;
         child = GetWindow(child, GW_HWNDNEXT))
      if (child != sidebar && child != controls[ID_HOST] &&
          child != controls[ID_PASSWORD] && child != controls[ID_CONNECT])
        children.push_back(child);
    for (HWND child : children) {
      RECT cr;
      GetWindowRect(child, &cr);
      MapWindowPoints(nullptr, hwnd, (POINT *)&cr, 2);
      SetParent(child, sidebar);
      MoveWindow(child, cr.left, cr.top - TOP, cr.right - cr.left,
                 cr.bottom - cr.top, TRUE);
    }
    canvas = CreateWindowExW(
        0, L"SURemoteCanvas", L"",
        WS_CHILD | WS_VISIBLE | WS_HSCROLL | WS_VSCROLL | WS_TABSTOP, PANEL,
        TOP, 400, 400, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
    statusLabel =
        add(hwnd, L"STATIC", L"Ready · OSC localhost:19790 · F11 fullscreen", 0,
            0, 8, 760, 500, 22);
    SetTimer(hwnd, 1, 1000, nullptr);
    layout();
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
    ((MINMAXINFO *)lp)->ptMinTrackSize = {720, 480};
    return 0;
  case WM_COMMAND: {
    int id = LOWORD(wp), code = HIWORD(wp);
    if (id == ID_CONNECT && code == BN_CLICKED)
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
    else if (id == ID_SAVE)
      storePreset();
    else if (id == ID_LOAD)
      recallPreset(narrow(controlText(ID_PRESETS)));
    else if (id == ID_ZTSTATUS)
      zeroTierOperation({{"action", "status"}}, "status");
    return 0;
  }
  case WM_MEASUREITEM:
    ((MEASUREITEMSTRUCT *)lp)->itemHeight = 22;
    return TRUE;
  case WM_DRAWITEM: {
    auto *d = (DRAWITEMSTRUCT *)lp;
    if (d->CtlID != ID_RES || d->itemID == (UINT)-1)
      break;
    wchar_t text[256]{};
    SendMessageW(controls[ID_RES], CB_GETLBTEXT, d->itemID, (LPARAM)text);
    bool selected = (d->itemState & ODS_SELECTED) != 0,
         supported = resolutionSupported((int)d->itemID);
    FillRect(d->hDC, &d->rcItem,
             GetSysColorBrush(selected ? COLOR_HIGHLIGHT : COLOR_WINDOW));
    SetBkMode(d->hDC, TRANSPARENT);
    SetTextColor(d->hDC, GetSysColor(!supported ? COLOR_GRAYTEXT
                                     : selected ? COLOR_HIGHLIGHTTEXT
                                                : COLOR_WINDOWTEXT));
    RECT r = d->rcItem;
    r.left += 4;
    DrawTextW(d->hDC, text, -1, &r, DT_SINGLELINE | DT_VCENTER);
    return TRUE;
  }
  case WM_NET: {
    pendingControlMessages--;
    std::unique_ptr<json> p((json *)lp);
    try {
      handleNetwork(*p);
    } catch (...) {
      status(L"Invalid server response");
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
      double kbps = (bytes - previousBytes) * 8 / 1000.;
      uint64_t updates = frames - previousFrames;
      previousBytes = bytes;
      previousFrames = frames;
      std::wostringstream t;
      t << L"Connected · " << std::fixed << std::setprecision(0) << kbps
        << L" kbps · " << updates << L" updates/s · " << lastLatency
        << L" ms · " << selection().size() << L" monitor(s) · "
        << (int)(zoom * 100) << L"% · " << wide(resolutionName())
        << L" · OSC 19790";
      status(t.str());
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
    test("letterbox never targets remote monitor",
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
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR arguments, int show) {
  integrationMode =
      arguments && std::wstring(arguments) == L"--integration-test";
  SetProcessDPIAware();
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&imaging));
  INITCOMMONCONTROLSEX cc{sizeof(cc), ICC_STANDARD_CLASSES};
  InitCommonControlsEx(&cc);
  if (!integrationMode &&
      !(arguments && std::wstring(arguments) == L"--self-test"))
    loadSettings();
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = windowProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
  wc.lpszClassName = L"SURemoteViewer";
  RegisterClassExW(&wc);
  wc.lpfnWndProc = sidebarProc;
  wc.lpszClassName = L"SURemoteSidebar";
  RegisterClassExW(&wc);
  wc.lpfnWndProc = canvasProc;
  wc.hbrBackground = nullptr;
  wc.lpszClassName = L"SURemoteCanvas";
  RegisterClassExW(&wc);
  mainWindow =
      CreateWindowExW(0, L"SURemoteViewer", L"SU Remote — Studio Upgrade",
                      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280,
                      860, nullptr, nullptr, instance, nullptr);
  if (!mainWindow)
    return 1;
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
