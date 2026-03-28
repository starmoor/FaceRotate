// FaceRotate（随脸旋转）跨进程共享协议：
// SpringBoard（Tweak.xm）与 Preferences（FaceRotatePrefs.m / FRAppListController.m）
// 共用同一套域名、通知名、位掩码、偏好键/范围/默认值以及 64-bit 采样打包格式。

#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <math.h>

#define FR_VERSION           "1.0.0"
#define FR_PREFS_DOMAIN      "com.starmoor.facerotate"
#define FR_PREFS_PATH        "/var/mobile/Library/Preferences/com.starmoor.facerotate.plist"

// Darwin 跨进程通知与 notify_set_state 通道（零磁盘 I/O）
#define FR_NOTE_PREFS_CHANGED "com.starmoor.facerotate.prefschanged" // Prefs -> SB：参数变更热重载
#define FR_NOTE_STATUS_REQ    "com.starmoor.facerotate.statusreq"    // Prefs -> SB：请求立刻刷新状态位掩码
#define FR_NOTE_RUNTIME_STATE "com.starmoor.facerotate.state"        // SB -> Prefs：64-bit 运行状态位掩码
#define FR_NOTE_LAST_SAMPLE   "com.starmoor.facerotate.sample"       // SB -> Prefs：64-bit 最近一次采样结果
#define FR_NOTE_LANG_CHANGED  "com.starmoor.facerotate.langchanged"  // 进程内：语言切换同步刷新

// FR_NOTE_RUNTIME_STATE 位掩码
#define FRSTATE_SB_ALIVE       (1ULL << 0) // SpringBoard 注入存活
#define FRSTATE_ENABLED        (1ULL << 1) // 总开关开启
#define FRSTATE_AW_SUPPORTED   (1ULL << 2) // 存在 AWAttentionAwarenessConfiguration
#define FRSTATE_ATTENTION_ON   (1ULL << 3) // 系统「注视感知功能」开启（supportedEvents & 0x80）
#define FRSTATE_SCREEN_LOCKED  (1ULL << 4) // 锁屏 / 息屏暂停中
#define FRSTATE_PORTRAIT_LOCK  (1ULL << 5) // 控制中心竖排方向锁定已开
#define FRSTATE_IOS15_LEGACY   (1ULL << 6) // 运行在 iOS 15 传统路径（否则为 TraitsArbiter）
#define FRSTATE_BLACKLISTED_FG (1ULL << 7) // 当前前台 App 命中黑名单

// 采样状态枚举（bit 0..3；0 表示尚无采样）
enum {
    FRSampleStatusNone         = 0,
    FRSampleStatusValid        = 1, // 人脸姿态有效
    FRSampleStatusNoFace       = 2, // 无脸 / 超时 -> 回退重力
    FRSampleStatusObstructed   = 3, // 遮挡 / 元数据无效 -> 回退重力
    FRSampleStatusUpsideDown   = 4, // 倒置（|roll| >= 135°）-> 回退重力
    FRSampleStatusAttentionOff = 5, // 注视感知关闭 -> 回退重力
};

// 偏好键
#define FRKEY_ENABLED         "enabled"
#define FRKEY_ENTER_ANGLE     "enterAngle"
#define FRKEY_HYSTERESIS      "hysteresis"
#define FRKEY_DEBOUNCE_MS     "debounceMs"
#define FRKEY_POLL_TIMEOUT_MS "pollTimeoutMs"
#define FRKEY_BLACKLIST       "blacklist"
#define FRKEY_DEBUG_LOG       "debugLog"
#define FRKEY_LANG            "language"

// 参数范围与默认值
#define FRMIN_ENTER_ANGLE     35
#define FRMAX_ENTER_ANGLE     75
#define FRSTEP_ENTER_ANGLE    5
#define FRDEF_ENTER_ANGLE     50

#define FRMIN_HYSTERESIS      5
#define FRMAX_HYSTERESIS      25
#define FRSTEP_HYSTERESIS     5
#define FRDEF_HYSTERESIS      15

#define FRMIN_DEBOUNCE_MS     0
#define FRMAX_DEBOUNCE_MS     250
#define FRSTEP_DEBOUNCE_MS    10
#define FRDEF_DEBOUNCE_MS     80

#define FRMIN_POLL_TIMEOUT_MS 200
#define FRMAX_POLL_TIMEOUT_MS 600
#define FRSTEP_POLL_TIMEOUT_MS 50
#define FRDEF_POLL_TIMEOUT_MS 350

#define FRDEF_ENABLED         1
#define FRDEF_DEBUG_LOG       0

static inline int FRClampInt(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline int FRRoundStepInt(double v, int lo, int hi, int step) {
    if (!(v == v)) return lo;
    int r = (step > 1) ? (int)(llround(v / (double)step) * step) : (int)llround(v);
    return FRClampInt(r, lo, hi);
}

static inline int FRComputeExitAngle(int enterAngle, int hysteresis) {
    int exitA = enterAngle - hysteresis;
    return (exitA < 20) ? 20 : exitA;
}

static inline NSArray<NSString *> *FRDefaultBlacklist(void) {
    return @[ @"com.apple.camera" ];
}

// 64-bit 最近采样打包 / 解包：
// bit 0..3:   status (1..5)
// bit 4..7:   outOri (0/1/3/4)
// bit 8..11:  rawOri (0..6)
// bit 12..27: rollBiased = round(roll * 10) + 1800, 限幅 0..3600
// bit 28..43: latencyMs (0..9999)
// bit 44..63: seq (mod 0xFFFFF)
typedef struct {
    uint8_t status;
    uint8_t outOri;
    uint8_t rawOri;
    double roll;
    uint16_t latencyMs;
    uint32_t seq;
} FRSampleInfo;

static inline uint64_t FRPackSample(uint8_t status, uint8_t outOri, uint8_t rawOri,
                                    double roll, int latencyMs, uint32_t seq) {
    if (status == FRSampleStatusNone) return 0ULL;
    double clampedRoll = (roll == roll) ? fmax(-180.0, fmin(180.0, roll)) : 0.0;
    int rollBiased = FRClampInt((int)llround(clampedRoll * 10.0) + 1800, 0, 3600);
    int lat = FRClampInt(latencyMs, 0, 9999);

    uint64_t v = 0ULL;
    v |= ((uint64_t)(status & 0xF));
    v |= ((uint64_t)(outOri & 0xF)) << 4;
    v |= ((uint64_t)(rawOri & 0xF)) << 8;
    v |= ((uint64_t)(rollBiased & 0xFFFF)) << 12;
    v |= ((uint64_t)(lat & 0xFFFF)) << 28;
    v |= ((uint64_t)(seq & 0xFFFFFULL)) << 44;
    return v;
}

static inline BOOL FRUnpackSample(uint64_t packed, FRSampleInfo *outInfo) {
    if (packed == 0ULL) return NO;
    uint8_t st = (uint8_t)(packed & 0xFULL);
    if (st == FRSampleStatusNone) return NO;
    if (outInfo) {
        outInfo->status = st;
        outInfo->outOri = (uint8_t)((packed >> 4) & 0xFULL);
        outInfo->rawOri = (uint8_t)((packed >> 8) & 0xFULL);
        int rollBiased = (int)((packed >> 12) & 0xFFFFULL);
        outInfo->roll = ((double)rollBiased - 1800.0) / 10.0;
        outInfo->latencyMs = (uint16_t)((packed >> 28) & 0xFFFFULL);
        outInfo->seq = (uint32_t)((packed >> 44) & 0xFFFFFULL);
    }
    return YES;
}
