// LepakMic：Lepak 的虚拟麦克风（Core Audio 音频服务插件，装在 /Library/Audio/Plug-Ins/HAL）。
//
// 提供两个设备，共用同一个时钟和一块环形缓冲区：
// - 「Lepak 麦克风」：普通的单声道输入设备，Typeless 等语音输入选它。
// - 「Lepak 麦克风输入端」：隐藏的单声道输出设备，只有 Lepak 往里写声音（AI Passport 经蓝牙传来的）。
// 输入端写进来的声音，几毫秒后从麦克风读出来。读过的部分清零，所以 Lepak 不写的时候麦克风是静音。
//
// 分成两个设备，是为了让 Lepak 知道「有程序在用这个麦克风」（系统对每个设备单独报告是否有程序在读写），
// 只在这时让 AI Passport 开麦。
//
// 按苹果公开的 AudioServerPlugIn.h 接口从头写，不含第三方代码。只处理声音，不碰键盘。

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

// MARK: 常量

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Mic = 2,
    kObjectID_MicStream = 3,
    kObjectID_Feed = 4,
    kObjectID_FeedStream = 5,
};

#define kSampleRate 48000.0
#define kBytesPerFrame 4u            // 单声道 Float32
#define kRingFrames 16384u           // 约 0.34 秒，也是时钟的零点周期
#define kMicUID "local.lepak.mic"
#define kFeedUID "local.lepak.mic.feed"
#define kModelUID "local.lepak.mic.model"

// MARK: 状态

static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;

static CFStringRef gMicName = NULL;
static CFStringRef gFeedName = NULL;
static CFStringRef gManufacturer = NULL;
static CFStringRef gMicUID = NULL;
static CFStringRef gFeedUID = NULL;
static CFStringRef gModelUID = NULL;

// 时钟：两个设备共用。有任何一个在运行时时钟就在走。
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gMicRunning = 0;
static UInt32 gFeedRunning = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;

// 环形缓冲区：下标 = 采样时间 % kRingFrames。两个设备在不同的实时线程上读写，用一把很短的锁。
static os_unfair_lock gRingLock = OS_UNFAIR_LOCK_INIT;
static Float32 gRing[kRingFrames];

static CFStringRef MakeString(const char* text)
{
    return CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
}

static void ClearRing(void)
{
    os_unfair_lock_lock(&gRingLock);
    memset(gRing, 0, sizeof(gRing));
    os_unfair_lock_unlock(&gRingLock);
}

// MARK: 接口声明

static HRESULT LepakMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG LepakMic_AddRef(void* inDriver);
static ULONG LepakMic_Release(void* inDriver);
static OSStatus LepakMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus LepakMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                      const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus LepakMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus LepakMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus LepakMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                            const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus LepakMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction, void* inChangeInfo);
static OSStatus LepakMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void* inChangeInfo);
static Boolean LepakMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress* inAddress);
static OSStatus LepakMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus LepakMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                             const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                             const void* inQualifierData, UInt32* outDataSize);
static OSStatus LepakMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                         const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus LepakMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                         const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus LepakMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus LepakMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus LepakMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                          Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus LepakMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                           UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus LepakMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                          UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus LepakMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                       UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus LepakMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    LepakMic_QueryInterface,
    LepakMic_AddRef,
    LepakMic_Release,
    LepakMic_Initialize,
    LepakMic_CreateDevice,
    LepakMic_DestroyDevice,
    LepakMic_AddDeviceClient,
    LepakMic_RemoveDeviceClient,
    LepakMic_PerformDeviceConfigurationChange,
    LepakMic_AbortDeviceConfigurationChange,
    LepakMic_HasProperty,
    LepakMic_IsPropertySettable,
    LepakMic_GetPropertyDataSize,
    LepakMic_GetPropertyData,
    LepakMic_SetPropertyData,
    LepakMic_StartIO,
    LepakMic_StopIO,
    LepakMic_GetZeroTimeStamp,
    LepakMic_WillDoIOOperation,
    LepakMic_BeginIOOperation,
    LepakMic_DoIOOperation,
    LepakMic_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: 工厂和 IUnknown

__attribute__((visibility("default")))
void* LepakMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

static HRESULT LepakMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG LepakMic_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG LepakMic_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// MARK: 基本操作

static OSStatus LepakMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    if (gMicName == NULL) {
        gMicName = MakeString("Lepak 麦克风");
        gFeedName = MakeString("Lepak 麦克风输入端");
        gManufacturer = MakeString("Lepak");
        gMicUID = MakeString(kMicUID);
        gFeedUID = MakeString(kFeedUID);
        gModelUID = MakeString(kModelUID);
    }
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1000000000.0 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    ClearRing();
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                      const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus LepakMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus LepakMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDeviceObjectID; (void)inClientInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus LepakMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                            const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDeviceObjectID; (void)inClientInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus LepakMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus LepakMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// MARK: 属性：辅助

static Boolean IsDevice(AudioObjectID inObjectID)
{
    return inObjectID == kObjectID_Mic || inObjectID == kObjectID_Feed;
}

static Boolean IsStream(AudioObjectID inObjectID)
{
    return inObjectID == kObjectID_MicStream || inObjectID == kObjectID_FeedStream;
}

static AudioObjectID StreamOf(AudioObjectID inDevice)
{
    return inDevice == kObjectID_Mic ? kObjectID_MicStream : kObjectID_FeedStream;
}

static AudioObjectID DeviceOf(AudioObjectID inStream)
{
    return inStream == kObjectID_MicStream ? kObjectID_Mic : kObjectID_Feed;
}

/// 这个设备在这个范围里有没有流：麦克风只有输入，输入端只有输出，全局范围两个都算。
static Boolean DeviceHasStreamInScope(AudioObjectID inDevice, AudioObjectPropertyScope inScope)
{
    if (inScope == kAudioObjectPropertyScopeGlobal) return true;
    if (inDevice == kObjectID_Mic) return inScope == kAudioObjectPropertyScopeInput;
    return inScope == kAudioObjectPropertyScopeOutput;
}

static AudioStreamBasicDescription StreamFormat(void)
{
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    return format;
}

#define kMonoLayoutSize ((UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription)))

// MARK: 属性：HasProperty

static Boolean LepakMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
        }
    }
    if (IsDevice(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return inAddress->mScope == kAudioObjectPropertyScopeInput
                || inAddress->mScope == kAudioObjectPropertyScopeOutput;
        default:
            return false;
        }
    }
    if (IsStream(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
        }
    }
    return false;
}

static OSStatus LepakMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!LepakMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    // 格式和采样率都是固定的（48 kHz 单声道），什么都不能改。
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

// MARK: 属性：大小

static OSStatus LepakMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                             const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                             const void* inQualifierData, UInt32* outDataSize)
{
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!LepakMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;

    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
    } else if (IsDevice(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize = DeviceHasStreamInScope(inObjectID, inAddress->mScope) ? sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = kMonoLayoutSize;
            return kAudioHardwareNoError;
        }
    } else if (IsStream(inObjectID)) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: 属性：取值

#define REQUIRE_SIZE(type) \
    do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *outDataSize = sizeof(type); } while (0)

static OSStatus LepakMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                         const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!LepakMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;

    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioPlugInClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(AudioObjectID);
            *(AudioObjectID*)outData = kAudioObjectUnknown;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = (CFStringRef)CFRetain(gManufacturer);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyResourceBundle:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = CFSTR("");
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[2] = { kObjectID_Mic, kObjectID_Feed };
            UInt32 count = inDataSize / sizeof(AudioObjectID);
            if (count > 2) count = 2;
            memcpy(outData, devices, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            REQUIRE_SIZE(AudioObjectID);
            AudioObjectID result = kAudioObjectUnknown;
            if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                CFStringRef uid = *(const CFStringRef*)inQualifierData;
                if (uid != NULL && CFEqual(uid, gMicUID)) result = kObjectID_Mic;
                else if (uid != NULL && CFEqual(uid, gFeedUID)) result = kObjectID_Feed;
            }
            *(AudioObjectID*)outData = result;
            return kAudioHardwareNoError;
        }
        }
    } else if (IsDevice(inObjectID)) {
        Boolean isMic = inObjectID == kObjectID_Mic;
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioDeviceClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(AudioObjectID);
            *(AudioObjectID*)outData = kObjectID_PlugIn;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = (CFStringRef)CFRetain(isMic ? gMicName : gFeedName);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = (CFStringRef)CFRetain(gManufacturer);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = (CFStringRef)CFRetain(isMic ? gMicUID : gFeedUID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            REQUIRE_SIZE(CFStringRef);
            *(CFStringRef*)outData = (CFStringRef)CFRetain(gModelUID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (DeviceHasStreamInScope(inObjectID, inAddress->mScope) && inDataSize >= sizeof(AudioObjectID)) {
                *(AudioObjectID*)outData = StreamOf(inObjectID);
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            REQUIRE_SIZE(AudioObjectID);
            *(AudioObjectID*)outData = inObjectID;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
            // 不报「虚拟设备」：Chromium 系的程序（Typeless 等）会在名字后面加上「(Virtual)」，
            // Typeless 的麦克风列表直接把带这个后缀的设备过滤掉，用户就选不到了。
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = kAudioDeviceTransportTypeUnknown;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 1;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            REQUIRE_SIZE(UInt32);
            pthread_mutex_lock(&gStateMutex);
            *(UInt32*)outData = (isMic ? gMicRunning : gFeedRunning) > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // 都不能当系统默认设备：麦克风只给在程序里专门选它的用（比如 Typeless）。
            // 能当默认的话，装好驱动时 macOS 会自动把默认麦克风换成它，开会软件等都会跟着用它。
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyIsHidden:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = isMic ? 0 : 1;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = kRingFrames;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            REQUIRE_SIZE(Float64);
            *(Float64*)outData = kSampleRate;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) {
                *outDataSize = 0;
                return kAudioHardwareNoError;
            }
            AudioValueRange range = { kSampleRate, kSampleRate };
            *(AudioValueRange*)outData = range;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32* channels = (UInt32*)outData;
            channels[0] = 1;
            channels[1] = 1;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            if (inDataSize < kMonoLayoutSize) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, kMonoLayoutSize);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = 1;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            *outDataSize = kMonoLayoutSize;
            return kAudioHardwareNoError;
        }
        }
    } else if (IsStream(inObjectID)) {
        Boolean isMic = inObjectID == kObjectID_MicStream;
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioObjectClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            REQUIRE_SIZE(AudioClassID);
            *(AudioClassID*)outData = kAudioStreamClassID;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            REQUIRE_SIZE(AudioObjectID);
            *(AudioObjectID*)outData = DeviceOf(inObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 1;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = isMic ? 1 : 0;   // 1 = 输入，0 = 输出
            return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = isMic ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 1;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyLatency:
            REQUIRE_SIZE(UInt32);
            *(UInt32*)outData = 0;
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            REQUIRE_SIZE(AudioStreamBasicDescription);
            *(AudioStreamBasicDescription*)outData = StreamFormat();
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) {
                *outDataSize = 0;
                return kAudioHardwareNoError;
            }
            AudioStreamRangedDescription ranged;
            ranged.mFormat = StreamFormat();
            ranged.mSampleRateRange.mMinimum = kSampleRate;
            ranged.mSampleRateRange.mMaximum = kSampleRate;
            *(AudioStreamRangedDescription*)outData = ranged;
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus LepakMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                         const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!LepakMic_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: IO

static OSStatus LepakMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    Boolean clockWasStopped = gMicRunning == 0 && gFeedRunning == 0;
    Boolean micStarting = inDeviceObjectID == kObjectID_Mic && gMicRunning == 0;
    if (inDeviceObjectID == kObjectID_Mic) gMicRunning++; else gFeedRunning++;
    if (clockWasStopped) {
        gAnchorHostTime = mach_absolute_time();
        gNumberTimeStamps = 0;
    }
    pthread_mutex_unlock(&gStateMutex);
    // 麦克风刚开始被读：清掉以前留下的声音，免得读出上一次没读完的尾巴。
    if (micStarting) ClearRing();
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (inDeviceObjectID == kObjectID_Mic) {
        if (gMicRunning > 0) gMicRunning--;
    } else {
        if (gFeedRunning > 0) gFeedRunning--;
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                          Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    // 时钟每 kRingFrames 帧走一个零点，按主机时间算。两个设备用同一个起点，采样时间对得上。
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                           UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    Boolean willDo = false;
    if (inDeviceObjectID == kObjectID_Mic) willDo = inOperationID == kAudioServerPlugInIOOperationReadInput;
    else willDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                          UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static UInt32 RingIndex(Float64 sampleTime)
{
    SInt64 time = (SInt64)sampleTime;
    SInt64 index = time % (SInt64)kRingFrames;
    if (index < 0) index += kRingFrames;
    return (UInt32)index;
}

static OSStatus LepakMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                       UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inIOCycleInfo == NULL || ioMainBuffer == NULL) return kAudioHardwareNoError;
    UInt32 frames = inIOBufferFrameSize > kRingFrames ? kRingFrames : inIOBufferFrameSize;
    Float32* buffer = (Float32*)ioMainBuffer;

    if (inDeviceObjectID == kObjectID_Feed && inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // Lepak 写进来的声音：放进环形缓冲区，等麦克风那边读到这个采样时间时取走。
        UInt32 start = RingIndex(inIOCycleInfo->mOutputTime.mSampleTime);
        UInt32 first = kRingFrames - start;
        if (first > frames) first = frames;
        os_unfair_lock_lock(&gRingLock);
        memcpy(gRing + start, buffer, first * kBytesPerFrame);
        if (frames > first) memcpy(gRing, buffer + first, (frames - first) * kBytesPerFrame);
        os_unfair_lock_unlock(&gRingLock);
    } else if (inDeviceObjectID == kObjectID_Mic && inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // 麦克风：读出这段，再把它清零（Lepak 不写的时候就是静音）。
        UInt32 start = RingIndex(inIOCycleInfo->mInputTime.mSampleTime);
        UInt32 first = kRingFrames - start;
        if (first > frames) first = frames;
        os_unfair_lock_lock(&gRingLock);
        memcpy(buffer, gRing + start, first * kBytesPerFrame);
        memset(gRing + start, 0, first * kBytesPerFrame);
        if (frames > first) {
            memcpy(buffer + first, gRing, (frames - first) * kBytesPerFrame);
            memset(gRing, 0, (frames - first) * kBytesPerFrame);
        }
        os_unfair_lock_unlock(&gRingLock);
        if (frames < inIOBufferFrameSize) {
            memset(buffer + frames, 0, (inIOBufferFrameSize - frames) * kBytesPerFrame);
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus LepakMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return inDriver == gDriverRef ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
