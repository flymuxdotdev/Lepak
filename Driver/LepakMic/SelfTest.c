// LepakMic 驱动自测：不安装，按系统加载插件的方式（CFPlugIn）在本进程里加载 dist/LepakMic.driver，
// 查设备信息，再模拟一次「输入端写入 → 麦克风读出」。用法见 scripts/test-mic-driver.sh。

#include <CoreAudio/AudioServerPlugIn.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("失败：" __VA_ARGS__); printf("\n"); } } while (0)

static OSStatus StubPropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a)
{ (void)h; (void)o; (void)n; (void)a; return 0; }
static OSStatus StubCopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* d)
{ (void)h; (void)k; if (d) *d = NULL; return 0; }
static OSStatus StubWriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d)
{ (void)h; (void)k; (void)d; return 0; }
static OSStatus StubDeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k)
{ (void)h; (void)k; return 0; }
static OSStatus StubRequestChange(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void* i)
{ (void)h; (void)o; (void)a; (void)i; return 0; }

static AudioServerPlugInHostInterface host = {
    StubPropertiesChanged, StubCopyFromStorage, StubWriteToStorage, StubDeleteFromStorage, StubRequestChange,
};

static AudioServerPlugInDriverRef driver;

static UInt32 GetUInt32(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    UInt32 value = 0xFFFFFFFF, size = 0;
    OSStatus status = (*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, sizeof(value), &size, &value);
    CHECK(status == 0, "读取对象 %u 属性 '%.4s' 出错 %d", object, (char*)&selector, (int)status);
    return value;
}

static void PrintString(AudioObjectID object, AudioObjectPropertySelector selector, const char* label)
{
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef value = NULL;
    UInt32 size = 0;
    OSStatus status = (*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, sizeof(value), &size, &value);
    CHECK(status == 0 && value != NULL, "读取 %s 出错 %d", label, (int)status);
    if (value) {
        char text[256];
        CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8);
        printf("%s：%s\n", label, text);
        CFRelease(value);
    }
}

static void RunIO(AudioObjectID device, UInt32 operation, Float64 sampleTime, Float32* buffer, UInt32 frames)
{
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    cycle.mInputTime.mSampleTime = sampleTime;
    cycle.mOutputTime.mSampleTime = sampleTime;
    AudioObjectID stream = device + 1;
    OSStatus status = (*driver)->DoIOOperation(driver, device, stream, 1, operation, frames, &cycle, buffer, NULL);
    CHECK(status == 0, "IO 出错 %d", (int)status);
}

static void RoundTrip(Float64 sampleTime, UInt32 frames)
{
    Float32 written[4096], read[4096];
    for (UInt32 i = 0; i < frames; i++) written[i] = (Float32)(i + 1) / 10000.0f;
    RunIO(4, kAudioServerPlugInIOOperationWriteMix, sampleTime, written, frames);
    memset(read, 0, sizeof(read));
    RunIO(2, kAudioServerPlugInIOOperationReadInput, sampleTime, read, frames);
    CHECK(memcmp(written, read, frames * sizeof(Float32)) == 0, "采样时间 %.0f 写入的声音没有原样读出来", sampleTime);
    RunIO(2, kAudioServerPlugInIOOperationReadInput, sampleTime, read, frames);
    Float32 sum = 0;
    for (UInt32 i = 0; i < frames; i++) sum += read[i] < 0 ? -read[i] : read[i];
    CHECK(sum == 0, "采样时间 %.0f 读过一次后没有清零", sampleTime);
}

int main(int argc, const char* argv[])
{
    if (argc < 2) { printf("用法：SelfTest <LepakMic.driver>\n"); return 2; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    CHECK(plugin != NULL, "加载不了插件");
    if (!plugin) return 1;
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(factories && CFArrayGetCount(factories) == 1, "Info.plist 里找不到音频插件的工厂");
    if (!factories || CFArrayGetCount(factories) == 0) return 1;
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl** unknown = (IUnknownVTbl**)CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    CHECK(unknown != NULL, "工厂函数没有返回对象");
    if (!unknown) return 1;
    void* iface = NULL;
    HRESULT result = (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    CHECK(result == S_OK && iface != NULL, "QueryInterface 失败");
    driver = (AudioServerPlugInDriverRef)iface;
    CHECK((*driver)->Initialize(driver, &host) == 0, "Initialize 失败");

    // 设备列表和 UID。
    AudioObjectPropertyAddress listAddress = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID devices[4] = { 0 };
    UInt32 size = 0;
    (*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &listAddress, 0, NULL, sizeof(devices), &size, devices);
    CHECK(size == 2 * sizeof(AudioObjectID) && devices[0] == 2 && devices[1] == 4, "设备列表不对");
    AudioObjectPropertyAddress translate = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("local.lepak.mic");
    AudioObjectID found = 0;
    (*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &translate, sizeof(uid), &uid, sizeof(found), &size, &found);
    CHECK(found == 2, "按 UID 找不到麦克风");

    PrintString(2, kAudioObjectPropertyName, "麦克风名字");
    PrintString(4, kAudioObjectPropertyName, "输入端名字");
    CHECK(GetUInt32(2, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "麦克风不应该隐藏");
    CHECK(GetUInt32(4, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "输入端应该隐藏");
    CHECK(GetUInt32(2, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 0, "麦克风不应该当系统默认输入");
    CHECK(GetUInt32(2, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) != kAudioDeviceTransportTypeVirtual,
          "不能报虚拟设备（Typeless 会把它过滤掉）");
    CHECK(GetUInt32(4, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "输入端不能当默认输出");
    CHECK(GetUInt32(3, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1, "麦克风的流应该是输入");
    CHECK(GetUInt32(5, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0, "输入端的流应该是输出");

    // 麦克风在输出范围没有流，输入端在输入范围没有流。
    AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    (*driver)->GetPropertyDataSize(driver, 2, 0, &streams, 0, NULL, &size);
    CHECK(size == 0, "麦克风不应该有输出流");
    streams.mScope = kAudioObjectPropertyScopeInput;
    (*driver)->GetPropertyDataSize(driver, 2, 0, &streams, 0, NULL, &size);
    CHECK(size == sizeof(AudioObjectID), "麦克风应该有一个输入流");

    AudioObjectPropertyAddress formatAddress = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioStreamBasicDescription format;
    (*driver)->GetPropertyData(driver, 3, 0, &formatAddress, 0, NULL, sizeof(format), &size, &format);
    CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 1 && format.mBitsPerChannel == 32, "流格式不对");
    printf("格式：%.0f Hz，%u 声道，%u 位浮点\n", format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel);

    // 大小不够时要报错，不能越界写。
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 small = 0;
    OSStatus status = (*driver)->GetPropertyData(driver, 2, 0, &rateAddress, 0, NULL, sizeof(small), &size, &small);
    CHECK(status == kAudioHardwareBadPropertySizeError, "缓冲区太小时应该报错");

    // IO：开始、时间戳、写入后读出、跨过缓冲区末尾、停止。
    CHECK((*driver)->StartIO(driver, 4, 1) == 0 && (*driver)->StartIO(driver, 2, 2) == 0, "StartIO 失败");
    Float64 sampleTime = -1;
    UInt64 hostTime = 0, seed = 0;
    (*driver)->GetZeroTimeStamp(driver, 2, 2, &sampleTime, &hostTime, &seed);
    CHECK(sampleTime >= 0 && hostTime > 0, "零点时间戳不对");
    CHECK(GetUInt32(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1, "麦克风应该在运行");
    RoundTrip(1000, 512);
    RoundTrip(16384 - 100, 512);   // 跨过缓冲区末尾
    RoundTrip(16384 * 7 + 3, 4096);
    Float32 silence[256];
    RunIO(2, kAudioServerPlugInIOOperationReadInput, 50000, silence, 256);
    Float32 sum = 0;
    for (int i = 0; i < 256; i++) sum += silence[i] < 0 ? -silence[i] : silence[i];
    CHECK(sum == 0, "没写过的地方应该是静音");
    CHECK((*driver)->StopIO(driver, 2, 2) == 0 && (*driver)->StopIO(driver, 4, 1) == 0, "StopIO 失败");
    CHECK(GetUInt32(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "麦克风应该已停止");

    (*driver)->Release(driver);
    (*unknown)->Release(unknown);
    printf(failures == 0 ? "自测通过\n" : "自测失败：%d 项\n", failures);
    return failures == 0 ? 0 : 1;
}
