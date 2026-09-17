#pragma once
#include <condition_variable>
#include <deque>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

// A separate, bounded worker owns decoder and output device. Video revisions do
// not reset audio. Only session, pause/off, or audio format changes do.
class RemoteAudio {
  template <class T> using ComPtr = Microsoft::WRL::ComPtr<T>;
  struct Encoded {
    json header;
    std::vector<uint8_t> bytes;
    uint64_t epoch;
  };
  struct PCM {
    WAVEHDR header{};
    std::vector<int16_t> samples;
  };
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Encoded> queue;
  bool exiting = false, enabled = false;
  uint64_t session = 0, epoch = 0;
  std::thread worker;
  HWAVEOUT device = nullptr;
  std::deque<std::unique_ptr<PCM>> playing;
  ComPtr<IMFTransform> decoder;
  int channels = 0, rate = 0;
  std::string cookie;
  bool priming = true;
  static void require(HRESULT hr) {
    if (FAILED(hr))
      throw std::runtime_error("Audio decoder unavailable");
  }
  void reset() {
    if (device) {
      waveOutReset(device);
      for (auto &p : playing)
        waveOutUnprepareHeader(device, &p->header, sizeof(WAVEHDR));
      playing.clear();
      waveOutClose(device);
      device = nullptr;
    }
    decoder.Reset();
    channels = rate = 0;
    cookie.clear();
    priming = true;
  }
  void configureAAC(int count, const std::string &metadata) {
    reset();
    channels = count;
    rate = 48000;
    cookie = metadata;
    require(CoCreateInstance(CLSID_CMSAACDecMFT, nullptr, CLSCTX_INPROC_SERVER,
                             IID_PPV_ARGS(&decoder)));
    ComPtr<IMFMediaType> input, output;
    require(MFCreateMediaType(&input));
    require(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    require(input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC));
    require(input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000));
    require(input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, count));
    require(input->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0));
    // Portlight's wire contract is AAC-LC, 48 kHz, 1024 samples, mono/stereo.
    // Translate that to Windows HEAACWAVEINFO + AudioSpecificConfig. The Mac
    // cookie is an AudioConverter magic cookie (not a Windows media type).
    BYTE config[14] = {0, 0, 0xfe, 0, 0, 0,    0,
                       0, 0, 0,    0, 0, 0x11, (BYTE)(0x80 | (count << 3))};
    require(input->SetBlob(MF_MT_USER_DATA, config, sizeof(config)));
    require(decoder->SetInputType(0, input.Get(), 0));
    require(MFCreateMediaType(&output));
    require(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
    require(output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM));
    require(output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000));
    require(output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, count));
    require(output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
    require(output->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, count * 2));
    require(
        output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 48000 * count * 2));
    require(decoder->SetOutputType(0, output.Get(), 0));
    require(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0));
    require(decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
  }
  std::vector<int16_t> decode(const Encoded &p) {
    bool aac = p.header.value("codec", "") == "aac";
    int count = p.header.value("channels", 0);
    std::vector<int16_t> pcm;
    if (!aac) {
      if (rate != 24000 || channels != 1) {
        reset();
        rate = 24000;
        channels = 1;
      }
      pcm.resize(p.bytes.size());
      for (size_t i = 0; i < p.bytes.size(); ++i) {
        unsigned u = (uint8_t)~p.bytes[i];
        int v = (((u & 15) << 3) + 132) << ((u & 112) >> 4);
        pcm[i] = (int16_t)((u & 128) ? 132 - v : v - 132);
      }
      return pcm;
    }
    auto metadata = p.header.value("cookie", "");
    if (!decoder || channels != count || cookie != metadata)
      configureAAC(count, metadata);
    ComPtr<IMFSample> input;
    ComPtr<IMFMediaBuffer> buffer;
    require(MFCreateSample(&input));
    require(MFCreateMemoryBuffer((DWORD)p.bytes.size(), &buffer));
    BYTE *bytes = nullptr;
    require(buffer->Lock(&bytes, nullptr, nullptr));
    memcpy(bytes, p.bytes.data(), p.bytes.size());
    buffer->Unlock();
    require(buffer->SetCurrentLength((DWORD)p.bytes.size()));
    require(input->AddBuffer(buffer.Get()));
    require(decoder->ProcessInput(0, input.Get(), 0));
    for (int n = 0; n < 4; ++n) {
      MFT_OUTPUT_STREAM_INFO info{};
      require(decoder->GetOutputStreamInfo(0, &info));
      ComPtr<IMFSample> output;
      ComPtr<IMFMediaBuffer> out;
      require(MFCreateSample(&output));
      require(MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, 16384), &out));
      require(output->AddBuffer(out.Get()));
      MFT_OUTPUT_DATA_BUFFER result{0, output.Get(), 0, nullptr};
      DWORD status = 0;
      HRESULT hr = decoder->ProcessOutput(0, 1, &result, &status);
      if (result.pEvents)
        result.pEvents->Release();
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
        break;
      require(hr);
      DWORD length = 0;
      require(out->Lock(&bytes, nullptr, &length));
      if (length <= 16384 && length % (channels * 2) == 0) {
        auto start = pcm.size();
        pcm.resize(start + length / 2);
        memcpy(pcm.data() + start, bytes, length);
      }
      out->Unlock();
    }
    return pcm;
  }
  void enqueue(std::vector<int16_t> samples) {
    for (auto it = playing.begin(); it != playing.end();) {
      if ((*it)->header.dwFlags & WHDR_DONE) {
        waveOutUnprepareHeader(device, &(*it)->header, sizeof(WAVEHDR));
        it = playing.erase(it);
      } else
        ++it;
    }
    if (samples.empty() || playing.size() >= 8)
      return;
    if (!device) {
      WAVEFORMATEX format{WAVE_FORMAT_PCM,
                          (WORD)channels,
                          (DWORD)rate,
                          (DWORD)(rate * channels * 2),
                          (WORD)(channels * 2),
                          16,
                          0};
      if (waveOutOpen(&device, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) !=
          MMSYSERR_NOERROR) {
        device = nullptr;
        return;
      }
      waveOutPause(device);
      priming = true;
    }
    auto pcm = std::make_unique<PCM>();
    pcm->samples = std::move(samples);
    pcm->header.lpData = (char *)pcm->samples.data();
    pcm->header.dwBufferLength = (DWORD)(pcm->samples.size() * 2);
    if (waveOutPrepareHeader(device, &pcm->header, sizeof(WAVEHDR)) !=
        MMSYSERR_NOERROR)
      return;
    if (waveOutWrite(device, &pcm->header, sizeof(WAVEHDR)) !=
        MMSYSERR_NOERROR) {
      waveOutUnprepareHeader(device, &pcm->header, sizeof(WAVEHDR));
      return;
    }
    playing.push_back(std::move(pcm));
    if (priming && playing.size() >= 3) {
      waveOutRestart(device);
      priming = false;
    }
  }
  void run() {
    auto co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool mf = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET));
    uint64_t current = 0;
    for (;;) {
      Encoded packet;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [&] {
          return exiting || epoch != current || !queue.empty();
        });
        if (exiting)
          break;
        if (epoch != current) {
          current = epoch;
          lock.unlock();
          reset();
          continue;
        }
        packet = std::move(queue.front());
        queue.pop_front();
      }
      try {
        if (packet.header.value("codec", "") == "aac" && !mf) {
          failures++;
          continue;
        }
        auto samples = decode(packet);
        decodedSamples += samples.size() / std::max(1, channels);
        std::lock_guard<std::mutex> lock(mutex);
        if (packet.epoch == epoch && enabled && !validationOnly)
          enqueue(std::move(samples));
      } catch (...) {
        reset();
        failures++;
      }
    }
    reset();
    if (mf)
      MFShutdown();
    if (SUCCEEDED(co))
      CoUninitialize();
  }

public:
  std::atomic<unsigned> failures{0};
  std::atomic<uint64_t> decodedSamples{0};
  std::atomic<bool> validationOnly{false};
  RemoteAudio() : worker([this] { run(); }) {}
  ~RemoteAudio() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      exiting = true;
    }
    wake.notify_one();
    worker.join();
  }
  void configure(uint64_t generation, bool on) {
    std::lock_guard<std::mutex> lock(mutex);
    if (session != generation || enabled != on) {
      session = generation;
      enabled = on;
      ++epoch;
      queue.clear();
      wake.notify_one();
    }
  }
  void stop() {
    std::lock_guard<std::mutex> lock(mutex);
    enabled = false;
    ++epoch;
    queue.clear();
    wake.notify_one();
  }
  bool route(const std::vector<uint8_t> &data, uint64_t generation) {
    auto e = su_remote::parseEnvelope(data);
    auto &h = e.header;
    if (h.value("type", "") != "audio")
      return false;
    size_t length = data.size() - e.payloadOffset;
    auto codec = h.value("codec", "");
    int count = h.value("channels", 0);
    bool valid = codec == "mulaw" && count == 1 &&
                 h.value("sampleRate", 0) == 24000 && length > 0 &&
                 length <= 4800 && h.value("samples", 0) == (int)length;
    if (codec == "aac") {
      std::string c = h.value("cookie", "");
      DWORD bytes = 0;
      valid = (count == 1 || count == 2) && h.value("sampleRate", 0) == 48000 &&
              h.value("samples", 0) == 1024 && length > 0 && length <= 16384 &&
              !c.empty() && c.size() <= 5464 &&
              CryptStringToBinaryA(c.data(), (DWORD)c.size(),
                                   CRYPT_STRING_BASE64 | CRYPT_STRING_STRICT,
                                   nullptr, &bytes, nullptr, nullptr) &&
              bytes > 0 && bytes <= 4096;
    }
    if (!valid) {
      failures++;
      return true;
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!enabled || generation != session)
      return true;
    if (queue.size() >= 12)
      queue.pop_front();
    queue.push_back(
        {h, std::vector<uint8_t>(data.begin() + e.payloadOffset, data.end()),
         epoch});
    wake.notify_one();
    return true;
  }
};
