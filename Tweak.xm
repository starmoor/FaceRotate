#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>
#import <math.h>
#import <roothide.h>

#include "FRCommon.h"
#include "FRUpdateCheck.h"

#pragma mark - Private Interfaces

@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUserLocked;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstanceIfExists;
- (BOOL)screenIsOn;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstanceIfExists;
- (BOOL)isUILocked;
@end

@interface UIApplication (FRPrivate)
- (id)_accessibilityFrontMostApplication;
@end

@interface TRAArbiterUpdateContext : NSObject
- (void)setForceOrientationResolution:(BOOL)force;
@end

@interface TRAArbiter : NSObject
- (TRAArbiterUpdateContext *)_defaultUpdateContextWithReason:(NSString *)reason animatable:(BOOL)animatable;
- (void)setNeedsUpdateArbitrationWithContext:(TRAArbiterUpdateContext *)context;
- (void)_setNeedsUpdateArbitrationWithReason:(NSString *)reason animated:(BOOL)animated;
- (void)updateArbitrationIfNeeded;
@end

@interface TRAArbitrationDeviceOrientationInputs : NSObject
@property (nonatomic, readonly) long long currentDeviceOrientation;
@property (nonatomic, readonly) long long nonFlatDeviceOrientation;
- (instancetype)initWithCurrentDeviceOrientation:(long long)cur nonFlatDeviceOrientation:(long long)nonFlat;
@end

@interface TRAArbitrationInputs : NSObject
@property (nonatomic, readonly) id interfaceIdiomInputs;
@property (nonatomic, readonly) id userInterfaceStyleInputs;
@property (nonatomic, readonly) TRAArbitrationDeviceOrientationInputs *deviceOrientationInputs;
@property (nonatomic, readonly) id keyboardInputs;
@property (nonatomic, readonly) id ambientPresentationInputs;
- (instancetype)initWithInterfaceIdiomInputs:(id)idiom
                    userInterfaceStyleInputs:(id)style
                     deviceOrientationInputs:(id)devOri
                              keyboardInputs:(id)kbd
                   ambientPresentationInputs:(id)ambient;
- (instancetype)initWithInterfaceIdiomInputs:(id)idiom
                     deviceOrientationInputs:(id)devOri
                              keyboardInputs:(id)kbd
                   ambientPresentationInputs:(id)ambient;
@end

@interface SBDeviceOrientationUpdateManager : NSObject
- (void)_enqueueOrientationUpdateToDeviceOrientation:(long long)orientation;
- (long long)lastUpdatedDeviceOrientation;
@end

@interface AWAttentionAwarenessConfiguration : NSObject
+ (uint64_t)supportedEvents;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, assign) uint64_t eventMask;
@property (nonatomic, assign) double attentionLostTimeout;
@property (nonatomic, assign) BOOL activateAttentionDetection;
@property (nonatomic, assign) BOOL continuousFaceDetectMode;
@end

@interface AWAttentionEvent : NSObject
@end

@interface AWFaceDetectAttentionEvent : AWAttentionEvent
@property (nonatomic, readonly, getter=isMetadataValid) BOOL metadataValid;
@property (nonatomic, readonly) double pitch;
@property (nonatomic, readonly) double yaw;
@property (nonatomic, readonly) double roll;
@property (nonatomic, readonly) uint64_t orientation;
@property (nonatomic, readonly) BOOL isCameraObstructed;
@end

@interface AWAttentionAwarenessClient : NSObject
- (BOOL)setConfiguration:(AWAttentionAwarenessConfiguration *)config shouldReset:(BOOL)reset error:(NSError **)error;
- (void)setEventHandlerWithQueue:(dispatch_queue_t)queue block:(void (^)(AWAttentionEvent *event))block;
- (BOOL)resumeWithError:(NSError **)error;
- (BOOL)pollForAttentionWithTimeout:(double)timeout event:(AWAttentionEvent **)event error:(NSError **)error;
- (BOOL)invalidateWithError:(NSError **)error;
@end

#pragma mark - Global State

// 仅在 gPollQueue 串行队列上访问
static dispatch_queue_t gPollQueue = nil;
static AWAttentionAwarenessClient *gAWClient = nil;
static BOOL gAWReady = NO;

// 主线程状态
static NSHashTable<TRAArbiter *> *gArbiters = nil;
static NSHashTable<SBDeviceOrientationUpdateManager *> *gLegacyManagers = nil;
static BOOL gUsingLegacyPath = NO;
static BOOL gReplayingLegacyUpdate = NO;

static BOOL gEnabled = (FRDEF_ENABLED != 0);
static int gEnterAngle = FRDEF_ENTER_ANGLE;
static int gHysteresis = FRDEF_HYSTERESIS;
static int gDebounceMs = FRDEF_DEBOUNCE_MS;
static int gPollTimeoutMs = FRDEF_POLL_TIMEOUT_MS;
static NSSet<NSString *> *gBlacklistSet = nil;
static volatile BOOL gDebugLog = (FRDEF_DEBUG_LOG != 0);

static BOOL gAWSupported = NO;
static BOOL gAttentionOn = NO;

static long long gOverrideOri = 0;       // 0 = fail-open (纯重力), 1/3/4 = 随脸对齐方向
static long long gLastRawNonFlat = 0;
static uint64_t gDebounceGen = 0;
static BOOL gPollInFlight = NO;
static BOOL gPendingRepoll = NO;

static uint64_t gLastPublishedState = UINT64_MAX;
static uint32_t gSampleSeq = 0;

#pragma mark - Logging (Default Off / Zero Disk I/O)

static void FRLog(NSString *fmt, ...) {
    if (!gDebugLog) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%.3f] %@\n",
                      [[NSDate date] timeIntervalSince1970], msg];
    const char *path = jbroot("/tmp/facerotate.log");
    FILE *f = fopen(path, "a");
    if (f) {
        fputs(line.UTF8String, f);
        fclose(f);
    }
}

#pragma mark - Runtime Checks & Telemetry

static BOOL IsUserPortraitLocked(void) {
    Class lockCls = objc_getClass("SBOrientationLockManager");
    if (lockCls && [lockCls respondsToSelector:@selector(sharedInstance)]) {
        id mgr = ((id (*)(Class, SEL))objc_msgSend)(lockCls, @selector(sharedInstance));
        if (mgr && [mgr respondsToSelector:@selector(isUserLocked)]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isUserLocked));
        }
    }
    return NO;
}

static BOOL IsScreenLockedOrOff(void) {
    Class blCls = objc_getClass("SBBacklightController");
    if (blCls && [blCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        id bl = ((id (*)(Class, SEL))objc_msgSend)(blCls, @selector(sharedInstanceIfExists));
        if (bl && [bl respondsToSelector:@selector(screenIsOn)]) {
            if (!((BOOL (*)(id, SEL))objc_msgSend)(bl, @selector(screenIsOn))) {
                return YES;
            }
        }
    }
    Class lsCls = objc_getClass("SBLockScreenManager");
    if (lsCls && [lsCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        id ls = ((id (*)(Class, SEL))objc_msgSend)(lsCls, @selector(sharedInstanceIfExists));
        if (ls && [ls respondsToSelector:@selector(isUILocked)]) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(ls, @selector(isUILocked))) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *CurrentForegroundBundleID(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app && [app respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        id sbApp = ((id (*)(id, SEL))objc_msgSend)(app, @selector(_accessibilityFrontMostApplication));
        if (sbApp && [sbApp respondsToSelector:@selector(bundleIdentifier)]) {
            id bid = ((id (*)(id, SEL))objc_msgSend)(sbApp, @selector(bundleIdentifier));
            if ([bid isKindOfClass:[NSString class]]) {
                return (NSString *)bid;
            }
        }
    }
    return nil;
}

static BOOL IsForegroundBlacklisted(void) {
    if (!gBlacklistSet.count) return NO;
    NSString *fg = CurrentForegroundBundleID();
    return (fg.length > 0 && [gBlacklistSet containsObject:fg]);
}

static uint64_t ComputeRuntimeStateBits(void) {
    uint64_t bits = FRSTATE_SB_ALIVE;
    if (gEnabled) bits |= FRSTATE_ENABLED;
    if (gAWSupported) bits |= FRSTATE_AW_SUPPORTED;
    if (gAttentionOn) bits |= FRSTATE_ATTENTION_ON;
    if (IsScreenLockedOrOff()) bits |= FRSTATE_SCREEN_LOCKED;
    if (IsUserPortraitLocked()) bits |= FRSTATE_PORTRAIT_LOCK;
    if (gUsingLegacyPath) bits |= FRSTATE_IOS15_LEGACY;
    if (IsForegroundBlacklisted()) bits |= FRSTATE_BLACKLISTED_FG;
    return bits;
}

static void PublishRuntimeState(BOOL force) {
    static int tok = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(FR_NOTE_RUNTIME_STATE, &tok);
    });
    if (tok < 0) return;

    uint64_t bits = ComputeRuntimeStateBits();
    if (!force && bits == gLastPublishedState) return;
    gLastPublishedState = bits;
    notify_set_state(tok, bits);
}

static void PublishLastSample(uint8_t status, uint8_t outOri, uint8_t rawOri, double roll, int latencyMs) {
    static int tok = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(FR_NOTE_LAST_SAMPLE, &tok);
    });
    if (tok < 0) return;

    gSampleSeq++;
    uint64_t packed = FRPackSample(status, outOri, rawOri, roll, latencyMs, gSampleSeq);
    notify_set_state(tok, packed);
}

#pragma mark - Orientation Actuation

static void notifyOrientationUpdateOnMainThread(void) {
    if (gUsingLegacyPath) {
        NSArray<SBDeviceOrientationUpdateManager *> *mgrs = [gLegacyManagers allObjects];
        long long targetOri = (gOverrideOri != 0) ? gOverrideOri : gLastRawNonFlat;
        if (targetOri >= 1 && targetOri <= 4) {
            gReplayingLegacyUpdate = YES;
            for (SBDeviceOrientationUpdateManager *mgr in mgrs) {
                if ([mgr respondsToSelector:@selector(_enqueueOrientationUpdateToDeviceOrientation:)]) {
                    [mgr _enqueueOrientationUpdateToDeviceOrientation:targetOri];
                }
            }
            gReplayingLegacyUpdate = NO;
        }
        FRLog(@"Notified %lu legacy manager(s) -> targetOri=%lld (override=%lld)",
              (unsigned long)mgrs.count, targetOri, gOverrideOri);
        return;
    }

    NSArray<TRAArbiter *> *arbiters = [gArbiters allObjects];
    for (TRAArbiter *arb in arbiters) {
        if ([arb respondsToSelector:@selector(_defaultUpdateContextWithReason:animatable:)] &&
            [arb respondsToSelector:@selector(setNeedsUpdateArbitrationWithContext:)]) {
            TRAArbiterUpdateContext *ctx = [arb _defaultUpdateContextWithReason:@"FaceRotateUpdate" animatable:YES];
            if (ctx && [ctx respondsToSelector:@selector(setForceOrientationResolution:)]) {
                [ctx setForceOrientationResolution:YES];
            }
            [arb setNeedsUpdateArbitrationWithContext:ctx];
        } else if ([arb respondsToSelector:@selector(_setNeedsUpdateArbitrationWithReason:animated:)]) {
            [arb _setNeedsUpdateArbitrationWithReason:@"FaceRotateUpdate" animated:YES];
        }
        if ([arb respondsToSelector:@selector(updateArbitrationIfNeeded)]) {
            [arb updateArbitrationIfNeeded];
        }
    }
    FRLog(@"Notified %lu TRAArbiter(s) -> override=%lld", (unsigned long)arbiters.count, gOverrideOri);
}

static void resetOverrideAndCancelPending(BOOL triggerActuation) {
    BOOL hadOverride = (gOverrideOri != 0);
    gOverrideOri = 0;
    gLastRawNonFlat = 0;
    gDebounceGen++;
    gPendingRepoll = NO;
    PublishRuntimeState(NO);
    if (triggerActuation && hadOverride) {
        notifyOrientationUpdateOnMainThread();
    }
}

#pragma mark - AttentionAwareness Poll Queue

static void invalidateAWClientOnPollQueue(void) {
    if (gAWClient) {
        if ([gAWClient respondsToSelector:@selector(invalidateWithError:)]) {
            NSError *err = nil;
            [gAWClient invalidateWithError:&err];
        }
        gAWClient = nil;
    }
    gAWReady = NO;
}

static BOOL ensureAWLoadedAndCheckEvents(BOOL *outSupported, BOOL *outAttentionOn) {
    static dispatch_once_t dlOnce;
    dispatch_once(&dlOnce, ^{
        dlopen("/System/Library/PrivateFrameworks/AttentionAwareness.framework/AttentionAwareness", RTLD_LAZY);
    });

    Class cfgCls = objc_getClass("AWAttentionAwarenessConfiguration");
    BOOL supported = (cfgCls != Nil && [cfgCls respondsToSelector:@selector(supportedEvents)]);
    BOOL attentionOn = NO;
    if (supported) {
        uint64_t ev = [cfgCls supportedEvents];
        attentionOn = ((ev & 0x80) != 0);
    }
    if (outSupported) *outSupported = supported;
    if (outAttentionOn) *outAttentionOn = attentionOn;
    return supported && attentionOn;
}

static void probeAttentionStatusOnPollQueue(BOOL forcePublish) {
    BOOL supported = NO;
    BOOL attentionOn = NO;
    BOOL usable = ensureAWLoadedAndCheckEvents(&supported, &attentionOn);
    if (!usable && gAWClient) {
        invalidateAWClientOnPollQueue();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gAWSupported = supported;
        gAttentionOn = attentionOn;
        PublishRuntimeState(forcePublish);
    });
}

static BOOL ensureAWClientOnPollQueue(BOOL *outSupported, BOOL *outAttentionOn) {
    if (!ensureAWLoadedAndCheckEvents(outSupported, outAttentionOn)) {
        invalidateAWClientOnPollQueue();
        return NO;
    }
    if (gAWReady && gAWClient) return YES;

    Class cfgCls = objc_getClass("AWAttentionAwarenessConfiguration");
    Class clientCls = objc_getClass("AWAttentionAwarenessClient");
    if (!cfgCls || !clientCls) return NO;

    AWAttentionAwarenessConfiguration *cfg = [[cfgCls alloc] init];
    cfg.identifier = @"com.starmoor.facerotate.sb";
    cfg.eventMask = 0x80;
    cfg.attentionLostTimeout = 1.0;
    if ([cfg respondsToSelector:@selector(setActivateAttentionDetection:)]) {
        cfg.activateAttentionDetection = YES;
    }
    if ([cfg respondsToSelector:@selector(setContinuousFaceDetectMode:)]) {
        cfg.continuousFaceDetectMode = NO;
    }

    AWAttentionAwarenessClient *client = [[clientCls alloc] init];
    NSError *err = nil;
    if (![client setConfiguration:cfg shouldReset:YES error:&err]) {
        FRLog(@"AW setConfiguration failed: %@", err);
        return NO;
    }
    [client setEventHandlerWithQueue:gPollQueue block:^(__unused AWAttentionEvent *event) {}];
    if (![client resumeWithError:&err]) {
        FRLog(@"AW resume failed: %@", err);
        return NO;
    }

    gAWClient = client;
    gAWReady = YES;
    FRLog(@"AW client initialized and resumed");
    return YES;
}

static long long mapRollToDeviceOrientation(double roll, long long currentOverride, long long rawNonFlat,
                                            int enterAngle, int hysteresis, uint8_t *outSampleStatus) {
    double absRoll = fabs(roll);
    if (absRoll >= 135.0) {
        if (outSampleStatus) *outSampleStatus = FRSampleStatusUpsideDown;
        return 0; // 倒置回退纯重力
    }
    if (outSampleStatus) *outSampleStatus = FRSampleStatusValid;

    int exitAngle = FRComputeExitAngle(enterAngle, hysteresis);
    BOOL currentlyLandscape = (currentOverride == 3 || currentOverride == 4) ||
                              (currentOverride == 0 && (rawNonFlat == 3 || rawNonFlat == 4));
    double threshold = currentlyLandscape ? (double)exitAngle : (double)enterAngle;
    if (absRoll <= threshold) {
        return 1; // Portrait
    }
    return (roll > 0.0) ? 3 : 4; // LandscapeLeft : LandscapeRight
}

static void startAsyncFacePoll(long long rawNonFlat);

static void scheduleDebouncedFacePoll(long long rawNonFlat) {
    uint64_t gen = ++gDebounceGen;
    int delayMs = gDebounceMs;

    void (^fire)(void) = ^{
        if (gen != gDebounceGen) return;
        if (!gEnabled || IsUserPortraitLocked() || IsScreenLockedOrOff() || IsForegroundBlacklisted()) {
            return;
        }
        if (gPollInFlight) {
            gPendingRepoll = YES;
            return;
        }
        startAsyncFacePoll(rawNonFlat);
    };

    if (delayMs <= 0) {
        dispatch_async(dispatch_get_main_queue(), fire);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMs * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), fire);
    }
}

static void startAsyncFacePoll(long long rawNonFlat) {
    if (!gEnabled || IsUserPortraitLocked() || IsScreenLockedOrOff() || IsForegroundBlacklisted()) {
        return;
    }

    gPollInFlight = YES;
    gPendingRepoll = NO;

    long long prevOverride = gOverrideOri;
    int enterAngle = gEnterAngle;
    int hysteresis = gHysteresis;
    int timeoutMs = gPollTimeoutMs;

    dispatch_async(gPollQueue, ^{
        NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
        long long newOverride = 0;
        BOOL supported = NO;
        BOOL attentionOn = NO;
        uint8_t sampleStatus = FRSampleStatusNoFace;
        double recordedRoll = 0.0;

        if (!ensureAWClientOnPollQueue(&supported, &attentionOn)) {
            sampleStatus = attentionOn ? FRSampleStatusNoFace : FRSampleStatusAttentionOff;
            FRLog(@"POLL skipped: supported=%d attentionOn=%d -> fail-open", supported, attentionOn);
        } else {
            AWAttentionEvent *event = nil;
            NSError *err = nil;
            BOOL ok = [gAWClient pollForAttentionWithTimeout:((double)timeoutMs / 1000.0)
                                                        event:&event
                                                        error:&err];

            Class faceCls = objc_getClass("AWFaceDetectAttentionEvent");
            if (ok && event && faceCls && [event isKindOfClass:faceCls]) {
                AWFaceDetectAttentionEvent *fe = (AWFaceDetectAttentionEvent *)event;
                if (fe.metadataValid && !fe.isCameraObstructed) {
                    recordedRoll = fe.roll;
                    newOverride = mapRollToDeviceOrientation(fe.roll, prevOverride, rawNonFlat,
                                                             enterAngle, hysteresis, &sampleStatus);
                    FRLog(@"POLL ok raw=%lld roll=%.1f ori=%llu -> override=%lld (status=%u)",
                          rawNonFlat, fe.roll, fe.orientation, newOverride, sampleStatus);
                } else {
                    sampleStatus = FRSampleStatusObstructed;
                    FRLog(@"POLL obstructed/invalid (valid=%d obs=%d) -> fail-open",
                          fe.metadataValid, fe.isCameraObstructed);
                }
            } else {
                sampleStatus = FRSampleStatusNoFace;
                if (err) {
                    BOOL xpcLost = ([err.domain isEqualToString:NSCocoaErrorDomain] && (err.code == 4097 || err.code == 4099)) ||
                                   ([err.domain isEqualToString:NSPOSIXErrorDomain] && err.code == 57);
                    if (xpcLost) {
                        FRLog(@"POLL XPC connection lost (%@), resetting AW client", err);
                        invalidateAWClientOnPollQueue();
                    } else {
                        FRLog(@"POLL no-face/timeout err=%@ -> fail-open", err);
                    }
                } else {
                    FRLog(@"POLL timeout -> fail-open");
                }
            }
        }

        int latMs = (int)llround(([[NSDate date] timeIntervalSince1970] - t0) * 1000.0);

        dispatch_async(dispatch_get_main_queue(), ^{
            gPollInFlight = NO;
            gAWSupported = supported;
            gAttentionOn = attentionOn;

            PublishLastSample(sampleStatus,
                              (uint8_t)(newOverride >= 0 ? newOverride : 0),
                              (uint8_t)(rawNonFlat >= 0 && rawNonFlat <= 6 ? rawNonFlat : 0),
                              recordedRoll,
                              latMs);

            if (!gEnabled || IsUserPortraitLocked() || IsScreenLockedOrOff() || IsForegroundBlacklisted()) {
                gOverrideOri = 0;
                gPendingRepoll = NO;
                PublishRuntimeState(NO);
                return;
            }

            BOOL changed = (newOverride != gOverrideOri);
            gOverrideOri = newOverride;
            PublishRuntimeState(NO);

            if (changed) {
                notifyOrientationUpdateOnMainThread();
            }

            if (gPendingRepoll && gLastRawNonFlat >= 1 && gLastRawNonFlat <= 4) {
                gPendingRepoll = NO;
                startAsyncFacePoll(gLastRawNonFlat);
            }
        });
    });
}

#pragma mark - Preferences Loading & Notifications

static void ApplyPrefsDict(NSDictionary *p) {
    gEnabled = p[@FRKEY_ENABLED] ? [p[@FRKEY_ENABLED] boolValue] : (FRDEF_ENABLED != 0);
    gEnterAngle = FRClampInt([p[@FRKEY_ENTER_ANGLE] ?: @(FRDEF_ENTER_ANGLE) intValue], FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE);
    gHysteresis = FRClampInt([p[@FRKEY_HYSTERESIS] ?: @(FRDEF_HYSTERESIS) intValue], FRMIN_HYSTERESIS, FRMAX_HYSTERESIS);
    gDebounceMs = FRClampInt([p[@FRKEY_DEBOUNCE_MS] ?: @(FRDEF_DEBOUNCE_MS) intValue], FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS);
    gPollTimeoutMs = FRClampInt([p[@FRKEY_POLL_TIMEOUT_MS] ?: @(FRDEF_POLL_TIMEOUT_MS) intValue], FRMIN_POLL_TIMEOUT_MS, FRMAX_POLL_TIMEOUT_MS);
    gDebugLog = p[@FRKEY_DEBUG_LOG] ? [p[@FRKEY_DEBUG_LOG] boolValue] : (FRDEF_DEBUG_LOG != 0);

    id rawList = p[@FRKEY_BLACKLIST];
    if ([rawList isKindOfClass:[NSArray class]]) {
        NSMutableSet<NSString *> *set = [NSMutableSet set];
        for (id item in (NSArray *)rawList) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [set addObject:(NSString *)item];
            }
        }
        gBlacklistSet = [set copy];
    } else {
        gBlacklistSet = [NSSet setWithArray:FRDefaultBlacklist()];
    }
}

static void LoadPrefsFromDisk(void) {
    @autoreleasepool {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@FR_PREFS_PATH] ?: @{};
        ApplyPrefsDict(p);
    }
}

static NSDictionary *CopyLivePrefsDict(void) {
    CFStringRef domain = CFSTR(FR_PREFS_DOMAIN);
    CFPreferencesAppSynchronize(domain);
    CFDictionaryRef cfDict = CFPreferencesCopyMultiple(NULL, domain,
                                                       kCFPreferencesCurrentUser,
                                                       kCFPreferencesAnyHost);
    if (cfDict) {
        NSDictionary *d = CFBridgingRelease(cfDict);
        if (d.count > 0) return d;
    }
    return [NSDictionary dictionaryWithContentsOfFile:@FR_PREFS_PATH] ?: @{};
}

static void ReloadPrefsLiveAsync(BOOL isStartup) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDictionary *live = CopyLivePrefsDict();
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    BOOL oldEnabled = gEnabled;
                    int oldEnter = gEnterAngle;
                    int oldHyst = gHysteresis;
                    NSSet<NSString *> *oldBlacklist = gBlacklistSet;

                    ApplyPrefsDict(live);

                    if (!gEnabled) {
                        resetOverrideAndCancelPending(!isStartup && oldEnabled);
                    } else if (IsForegroundBlacklisted()) {
                        resetOverrideAndCancelPending(!isStartup);
                    } else {
                        PublishRuntimeState(YES);
                        BOOL tuningChanged = (oldEnter != gEnterAngle || oldHyst != gHysteresis ||
                                              (oldBlacklist && ![oldBlacklist isEqualToSet:gBlacklistSet]));
                        if (!isStartup && (!oldEnabled || tuningChanged) &&
                            !IsUserPortraitLocked() && !IsScreenLockedOrOff()) {
                            if (gLastRawNonFlat >= 1 && gLastRawNonFlat <= 4 && !gPollInFlight) {
                                startAsyncFacePoll(gLastRawNonFlat);
                            }
                        }
                    }

                    FRLog(@"Prefs %@: en=%d enter=%d hyst=%d deb=%d to=%d blk=%lu dbg=%d",
                          isStartup ? @"boot" : @"reload",
                          gEnabled, gEnterAngle, gHysteresis, gDebounceMs, gPollTimeoutMs,
                          (unsigned long)gBlacklistSet.count, gDebugLog);
                }
            });
        }
    });
}

static void PrefsChangedNote(CFNotificationCenterRef c, void *o, CFStringRef n,
                             const void *obj, CFDictionaryRef ui) {
    ReloadPrefsLiveAsync(NO);
}

static void StatusRequestNote(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef ui) {
    if (!gPollQueue) return;
    dispatch_async(gPollQueue, ^{
        probeAttentionStatusOnPollQueue(YES);
    });
}

static void DisplayStatusNote(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (IsScreenLockedOrOff()) {
            FRLog(@"DisplayStatus -> screen off/locked, resetting override");
            resetOverrideAndCancelPending(NO);
        } else {
            PublishRuntimeState(NO);
        }
    });
}

#pragma mark - Hook Group: iOS 16–17 TraitsArbiter

%group TraitsArbiterPath

%hook TRAArbiter

- (void)setNeedsUpdateArbitrationWithContext:(id)context {
    if (gArbiters && ![gArbiters containsObject:self]) {
        [gArbiters addObject:self];
    }
    %orig(context);
}

- (void)_setNeedsUpdateArbitrationWithReason:(id)reason animated:(BOOL)animated {
    if (gArbiters && ![gArbiters containsObject:self]) {
        [gArbiters addObject:self];
    }
    %orig(reason, animated);
}

%end

%hook SBTraitsInputsOrientationLockValidator

- (TRAArbitrationInputs *)validateInputs:(TRAArbitrationInputs *)inputs withContext:(id)context {
    TRAArbitrationInputs *res = %orig(inputs, context);
    if (!res) return res;

    if (!gEnabled || IsUserPortraitLocked() || IsScreenLockedOrOff() || IsForegroundBlacklisted()) {
        gOverrideOri = 0;
        gLastRawNonFlat = 0;
        gDebounceGen++;
        gPendingRepoll = NO;
        PublishRuntimeState(NO);
        return res;
    }

    long long rawNonFlat = res.deviceOrientationInputs.nonFlatDeviceOrientation;
    if (rawNonFlat >= 1 && rawNonFlat <= 4 && rawNonFlat != gLastRawNonFlat) {
        gLastRawNonFlat = rawNonFlat;
        scheduleDebouncedFacePoll(rawNonFlat);
    }

    PublishRuntimeState(NO);

    if (gOverrideOri == 0) {
        return res; // fail-open：纯重力
    }

    Class devOriCls = objc_getClass("TRAArbitrationDeviceOrientationInputs");
    Class inputsCls = objc_getClass("TRAArbitrationInputs");
    if (!devOriCls || !inputsCls) return res;

    TRAArbitrationDeviceOrientationInputs *newDevOri =
        [[devOriCls alloc] initWithCurrentDeviceOrientation:gOverrideOri nonFlatDeviceOrientation:gOverrideOri];

    TRAArbitrationInputs *newInputs = nil;
    if ([inputsCls instancesRespondToSelector:@selector(initWithInterfaceIdiomInputs:userInterfaceStyleInputs:deviceOrientationInputs:keyboardInputs:ambientPresentationInputs:)]) {
        newInputs = [[inputsCls alloc] initWithInterfaceIdiomInputs:res.interfaceIdiomInputs
                                           userInterfaceStyleInputs:res.userInterfaceStyleInputs
                                            deviceOrientationInputs:newDevOri
                                                     keyboardInputs:res.keyboardInputs
                                          ambientPresentationInputs:res.ambientPresentationInputs];
    } else if ([inputsCls instancesRespondToSelector:@selector(initWithInterfaceIdiomInputs:deviceOrientationInputs:keyboardInputs:ambientPresentationInputs:)]) {
        newInputs = [[inputsCls alloc] initWithInterfaceIdiomInputs:res.interfaceIdiomInputs
                                            deviceOrientationInputs:newDevOri
                                                     keyboardInputs:res.keyboardInputs
                                          ambientPresentationInputs:res.ambientPresentationInputs];
    }

    return newInputs ?: res;
}

%end

%end // TraitsArbiterPath

#pragma mark - Hook Group: iOS 15 Fallback

%group LegacyOrientationPath

%hook SBDeviceOrientationUpdateManager

- (void)_enqueueOrientationUpdateToDeviceOrientation:(long long)orientation {
    if (gLegacyManagers && ![gLegacyManagers containsObject:self]) {
        [gLegacyManagers addObject:self];
    }

    if (gReplayingLegacyUpdate) {
        %orig(orientation);
        return;
    }

    if (!gEnabled || IsUserPortraitLocked() || IsScreenLockedOrOff() || IsForegroundBlacklisted()) {
        gOverrideOri = 0;
        gLastRawNonFlat = 0;
        gDebounceGen++;
        gPendingRepoll = NO;
        PublishRuntimeState(NO);
        %orig(orientation);
        return;
    }

    if (orientation >= 1 && orientation <= 4) {
        if (orientation != gLastRawNonFlat) {
            gLastRawNonFlat = orientation;
            scheduleDebouncedFacePoll(orientation);
        }
        PublishRuntimeState(NO);
        long long finalOri = (gOverrideOri != 0) ? gOverrideOri : orientation;
        %orig(finalOri);
        return;
    }

    // 平放 (5/6) 或未知 (0)：维持原样透传
    PublishRuntimeState(NO);
    %orig(orientation);
}

%end

%end // LegacyOrientationPath

#pragma mark - Constructor & Cleanup

%ctor {
    gArbiters = [NSHashTable weakObjectsHashTable];
    gLegacyManagers = [NSHashTable weakObjectsHashTable];
    gPollQueue = dispatch_queue_create("com.starmoor.facerotate.poll", DISPATCH_QUEUE_SERIAL);
    gBlacklistSet = [NSSet setWithArray:FRDefaultBlacklist()];

    LoadPrefsFromDisk();

    if (objc_getClass("SBTraitsInputsOrientationLockValidator") != Nil) {
        gUsingLegacyPath = NO;
        %init(TraitsArbiterPath);
    } else if (objc_getClass("SBDeviceOrientationUpdateManager") != Nil) {
        gUsingLegacyPath = YES;
        %init(LegacyOrientationPath);
    }

    CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(dc, NULL, PrefsChangedNote,
                                    CFSTR(FR_NOTE_PREFS_CHANGED), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dc, NULL, StatusRequestNote,
                                    CFSTR(FR_NOTE_STATUS_REQ), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dc, NULL, DisplayStatusNote,
                                    CFSTR("com.apple.iokit.hid.displayStatus"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    PublishRuntimeState(YES);

    // 后台探测 AttentionAwareness 支持性、异步拉取 cfprefsd 真值，并注册 dpkg 安装场景的 trustcache
    dispatch_async(gPollQueue, ^{
        probeAttentionStatusOnPollQueue(YES);
    });
    ReloadPrefsLiveAsync(YES);
    FRUpdateCheckStart();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        const char *libjb = "/basebin/libjailbreak.dylib";
        if (access(libjb, F_OK) != 0) {
            libjb = jbroot("/basebin/libjailbreak.dylib");
        }
        void *h = dlopen(libjb, RTLD_NOW);
        if (!h) return;
        int (*add_dir)(const char *) = (int (*)(const char *))dlsym(h, "jb_trustcache_add_directory");
        if (add_dir) {
            const char *dirs[] = {
                jbroot("/Library/MobileSubstrate/DynamicLibraries"),
                jbroot("/usr/lib/TweakInject"),
                jbroot("/Library/PreferenceBundles"),
            };
            for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
                if (dirs[i] && access(dirs[i], F_OK) == 0) {
                    add_dir(dirs[i]);
                }
            }
        }
        dlclose(h);
    });
}

%dtor {
    if (gPollQueue) {
        dispatch_sync(gPollQueue, ^{
            invalidateAWClientOnPollQueue();
        });
    }
}
