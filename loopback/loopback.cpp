// loopback.exe - record the audio a single process (and its children) plays.
//
//   loopback.exe <pid> <out.wav>
//
// Uses WASAPI process loopback (Windows 10 2004+ / build 19041+), the same
// API as OBS "Application Audio Capture". Records 48 kHz 32-bit float stereo
// (the Windows mix format, so normally no conversion at all; when the device
// runs at another rate the engine converts with its high-quality resampler)
// until a line arrives on stdin, <out.wav>.stop appears or the target
// process exits, then finalises the WAV.
//
// Next to the WAV it writes <out.wav>.start containing the QueryPerformance-
// Counter time (seconds) of the first recorded sample, so a caller can line
// the track up with its own clock (LÖVE's love.timer.getTime() uses the same
// counter on Windows). Gaps in the stream (the process was silent and no
// packets arrived) are filled with silence using the packets' QPC positions,
// so the track never drifts.
//
// Based on Microsoft's ApplicationLoopback sample (MIT License).

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <wrl/implements.h>
#include <cstdio>
#include <cstdint>
#include <vector>

#pragma comment(lib, "mmdevapi.lib")
#pragma comment(lib, "ole32.lib")

using namespace Microsoft::WRL;

static const int RATE = 48000, CHANNELS = 2, BYTES_PER_FRAME = 8;   // float32 stereo

class ActivateHandler : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase,
                                             IActivateAudioInterfaceCompletionHandler> {
public:
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_FAIL;
    ComPtr<IAudioClient> client;
    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* op) override {
        ComPtr<IUnknown> unk;
        HRESULT hr = op->GetActivateResult(&result, &unk);
        if (SUCCEEDED(hr) && SUCCEEDED(result)) result = unk.As(&client);
        SetEvent(done);
        return S_OK;
    }
};

static HANDLE g_stop;
static uint64_t g_packets = 0;

// Stop on a line from stdin (only real data counts: some launchers hand
// over a stdin that reports EOF at once)
static DWORD WINAPI StdinWatcher(LPVOID) {
    char buf[64];
    DWORD n = 0;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    if (in && in != INVALID_HANDLE_VALUE && ReadFile(in, buf, sizeof(buf), &n, nullptr) && n > 0)
        SetEvent(g_stop);
    return 0;
}

static void WriteU32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void WriteU16(FILE* f, uint16_t v) { fwrite(&v, 2, 1, f); }

static void WriteHeader(FILE* f, uint32_t dataBytes) {
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f); WriteU32(f, 36 + dataBytes); fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); WriteU32(f, 16); WriteU16(f, 3 /* IEEE float */); WriteU16(f, CHANNELS);
    WriteU32(f, RATE); WriteU32(f, RATE * BYTES_PER_FRAME); WriteU16(f, BYTES_PER_FRAME); WriteU16(f, 32);
    fwrite("data", 1, 4, f); WriteU32(f, dataBytes);
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) { fwprintf(stderr, L"usage: loopback <pid> <out.wav>\n"); return 2; }
    DWORD pid = (DWORD)_wtoi(argv[1]);
    const wchar_t* outPath = argv[2];

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    CreateThread(nullptr, 0, StdinWatcher, nullptr, 0, nullptr);

    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = (BYTE*)&params;

    auto handler = Make<ActivateHandler>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
                                             &pv, handler.Get(), &op);
    if (FAILED(hr)) { fwprintf(stderr, L"activate failed 0x%08x\n", hr); return 1; }
    WaitForSingleObject(handler->done, INFINITE);
    if (FAILED(handler->result)) { fwprintf(stderr, L"activate result 0x%08x\n", handler->result); return 1; }
    ComPtr<IAudioClient> client = handler->client;

    WAVEFORMATEX fmt = {};
    fmt.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    fmt.nChannels = CHANNELS;
    fmt.nSamplesPerSec = RATE;
    fmt.wBitsPerSample = 32;
    fmt.nBlockAlign = BYTES_PER_FRAME;
    fmt.nAvgBytesPerSec = RATE * BYTES_PER_FRAME;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                            200000, 0, &fmt, nullptr);
    if (FAILED(hr)) { fwprintf(stderr, L"initialize failed 0x%08x\n", hr); return 1; }
    HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    client->SetEventHandle(ready);
    ComPtr<IAudioCaptureClient> capture;
    hr = client->GetService(IID_PPV_ARGS(&capture));
    if (FAILED(hr)) { fwprintf(stderr, L"capture client failed 0x%08x\n", hr); return 1; }

    FILE* f = _wfopen(outPath, L"wb");
    if (!f) { fwprintf(stderr, L"cannot open output\n"); return 1; }
    WriteHeader(f, 0);

    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    // QPC time (s) of the moment capture started; refined by the first packet
    LARGE_INTEGER t0;
    QueryPerformanceCounter(&t0);
    double startSec = -1;
    uint64_t written = 0;               // frames written so far
    std::vector<uint8_t> zeros;

    client->Start();
    // ...or when <out.wav>.stop appears (easiest for scripts / game code)
    wchar_t stopPath[MAX_PATH];
    swprintf(stopPath, MAX_PATH, L"%s.stop", outPath);
    DeleteFileW(stopPath);
    // also stop when the target process exits (a killed game must not leave
    // this recorder running, capturing and holding its exe locked)
    HANDLE target = OpenProcess(SYNCHRONIZE, FALSE, pid);
    HANDLE waits[3] = { g_stop, ready, target };
    DWORD nWaits = target ? 3 : 2;
    for (;;) {
        DWORD w = WaitForMultipleObjects(nWaits, waits, FALSE, 50);
        if (w == WAIT_OBJECT_0) break;
        if (target && w == WAIT_OBJECT_0 + 2) break;
        if (GetFileAttributesW(stopPath) != INVALID_FILE_ATTRIBUTES) { DeleteFileW(stopPath); break; }
        UINT32 packet = 0;
        while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
            BYTE* data; UINT32 frames; DWORD flags; UINT64 devPos, qpcPos;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, &devPos, &qpcPos))) break;
            g_packets++;
            double pktSec = qpcPos * 1e-7;               // qpcPos is in 100 ns units
            if (startSec < 0) startSec = pktSec;
            // fill silent gaps so the track keeps wall-clock time
            uint64_t expected = (uint64_t)((pktSec - startSec) * RATE + 0.5);
            if (expected > written + RATE / 50) {        // > 20 ms missing
                uint64_t gap = expected - written;
                zeros.assign((size_t)gap * BYTES_PER_FRAME, 0);
                fwrite(zeros.data(), 1, zeros.size(), f);
                written += gap;
            }
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                zeros.assign((size_t)frames * BYTES_PER_FRAME, 0);
                fwrite(zeros.data(), 1, zeros.size(), f);
            } else {
                fwrite(data, BYTES_PER_FRAME, frames, f);
            }
            written += frames;
            capture->ReleaseBuffer(frames);
        }
    }
    client->Stop();

    // pad to the stop time so the length matches the wall-clock duration
    LARGE_INTEGER t1;
    QueryPerformanceCounter(&t1);
    double endSec = (double)t1.QuadPart / freq.QuadPart;
    if (startSec < 0) startSec = (double)t0.QuadPart / freq.QuadPart;
    uint64_t total = (uint64_t)((endSec - startSec) * RATE);
    if (total > written) {
        zeros.assign((size_t)(total - written) * BYTES_PER_FRAME, 0);
        fwrite(zeros.data(), 1, zeros.size(), f);
        written = total;
    }
    WriteHeader(f, (uint32_t)(written * BYTES_PER_FRAME));
    fclose(f);
    fprintf(stderr, "frames=%llu packets=%llu start=%.6f end=%.6f t0=%.6f\n",
            (unsigned long long)written, (unsigned long long)g_packets, startSec, endSec,
            (double)t0.QuadPart / freq.QuadPart);

    wchar_t side[MAX_PATH];
    swprintf(side, MAX_PATH, L"%s.start", outPath);
    FILE* s = _wfopen(side, L"w");
    if (s) { fprintf(s, "%.6f\n", startSec); fclose(s); }
    CoUninitialize();
    return 0;
}
