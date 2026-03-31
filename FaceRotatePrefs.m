#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#import <roothide.h>

#include "FRCommon.h"
#include "FRLoc.h"
#import "FRAppListController.h"

@interface PSListController : UIViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(id)specifier animated:(BOOL)animated;
- (void)reloadSpecifierID:(NSString *)identifier animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier afterSpecifierID:(NSString *)afterID animated:(BOOL)animated;
- (void)removeSpecifierID:(NSString *)identifier animated:(BOOL)animated;
- (id)specifierForID:(NSString *)identifier;
- (id)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (NSIndexPath *)indexPathForSpecifier:(id)specifier;
- (UITableView *)table;
@end

enum {
    kFRGroupCell      = 0,
    kFRTitleValueCell = 4,
    kFRSliderCell     = 5,
    kFRSwitchCell     = 6,
    kFRButtonCell     = 13,
};

#pragma mark - PSSpecifier / Runtime Helpers

static inline NSString *FRSpecIdent(id sp) {
    if (!sp) return nil;
    if ([sp respondsToSelector:@selector(identifier)]) {
        return ((id (*)(id, SEL))objc_msgSend)(sp, @selector(identifier));
    }
    if ([sp respondsToSelector:@selector(propertyForKey:)]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(sp, @selector(propertyForKey:), @"id");
    }
    return nil;
}

static inline void FRSpecSetProp(id sp, id val, NSString *key) {
    if (sp && [sp respondsToSelector:@selector(setProperty:forKey:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(sp, @selector(setProperty:forKey:), val, key);
    }
}

static inline IMP FRSuperIMP(Class cls, SEL sel) {
    for (Class s = class_getSuperclass(cls); s; s = class_getSuperclass(s)) {
        Method m = class_getInstanceMethod(s, sel);
        if (m) return method_getImplementation(m);
    }
    return NULL;
}

static id FRMakeSpec(NSString *name, id target, SEL setSel, SEL getSel, long cellType, NSString *ident) {
    Class specCls = objc_getClass("PSSpecifier");
    if (!specCls) return nil;
    id sp = ((id (*)(Class, SEL, id, id, SEL, SEL, Class, long, BOOL))objc_msgSend)(
        specCls,
        @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:),
        name, target, setSel, getSel, Nil, cellType, NO);
    if (sp && ident) {
        FRSpecSetProp(sp, ident, @"id");
    }
    return sp;
}

static id FRMakeGroupSpec(NSString *ident, NSString *name, NSString *footer) {
    Class specCls = objc_getClass("PSSpecifier");
    if (!specCls) return nil;
    id grp = ((id (*)(Class, SEL, id, id))objc_msgSend)(
        specCls, @selector(groupSpecifierWithID:name:), ident, name);
    if (grp && footer) {
        FRSpecSetProp(grp, footer, @"footerText");
    }
    return grp;
}

#pragma mark - Prefs I/O

static int FRReadPrefInt(CFStringRef key, int defVal, int lo, int hi) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CFSTR(FR_PREFS_DOMAIN));
    if (!v) return defVal;
    id obj = CFBridgingRelease(v);
    if ([obj respondsToSelector:@selector(intValue)]) {
        return FRClampInt([obj intValue], lo, hi);
    }
    return defVal;
}

static BOOL FRReadPrefBool(CFStringRef key, BOOL defVal) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CFSTR(FR_PREFS_DOMAIN));
    if (!v) return defVal;
    id obj = CFBridgingRelease(v);
    if ([obj respondsToSelector:@selector(boolValue)]) {
        return [obj boolValue];
    }
    return defVal;
}

static NSUInteger FRReadBlacklistCount(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR(FRKEY_BLACKLIST), CFSTR(FR_PREFS_DOMAIN));
    if (!v) return FRDefaultBlacklist().count;
    id obj = CFBridgingRelease(v);
    return [obj isKindOfClass:[NSArray class]] ? [(NSArray *)obj count] : FRDefaultBlacklist().count;
}

static void FRWritePrefValue(CFStringRef key, CFPropertyListRef value) {
    CFPreferencesSetValue(key, value, CFSTR(FR_PREFS_DOMAIN),
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    notify_post(FR_NOTE_PREFS_CHANGED);
}

#pragma mark - FRRootListController

@interface FRRootListController : PSListController {
    int _renderedLangCode;
    NSTimer *_pollTimer;
    int _stateTok;
    int _sampleTok;
    uint64_t _lastStateBits;
    uint64_t _lastSamplePacked;
    BOOL _showingAttentionBtn;
    id _fgObserver;
    id _langObserver;
}
@end

@implementation FRRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateTok = -1;
        _sampleTok = -1;
        notify_register_check(FR_NOTE_RUNTIME_STATE, &_stateTok);
        notify_register_check(FR_NOTE_LAST_SAMPLE, &_sampleTok);
    }
    return self;
}

- (void)dealloc {
    [_pollTimer invalidate];
    _pollTimer = nil;
    if (_fgObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_fgObserver];
        _fgObserver = nil;
    }
    if (_langObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_langObserver];
        _langObserver = nil;
    }
    if (_stateTok >= 0) notify_cancel(_stateTok);
    if (_sampleTok >= 0) notify_cancel(_sampleTok);
}

- (void)updateLocalizedTitle {
    self.title = FRLoc(@"随脸旋转", @"FaceRotate", @"FaceRotate");
}

- (uint64_t)readRuntimeState {
    uint64_t st = 0;
    if (_stateTok >= 0) notify_get_state(_stateTok, &st);
    return st;
}

- (uint64_t)readLastSample {
    uint64_t sp = 0;
    if (_sampleTok >= 0) notify_get_state(_sampleTok, &sp);
    return sp;
}

- (BOOL)shouldShowAttentionButtonForState:(uint64_t)st {
    return (st & FRSTATE_SB_ALIVE) &&
           (st & FRSTATE_AW_SUPPORTED) &&
           !(st & FRSTATE_ATTENTION_ON);
}

- (void)requestLiveStatusFromSB {
    notify_post(FR_NOTE_STATUS_REQ);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    _renderedLangCode = FRResolvedLangCode();
    _lastStateBits = [self readRuntimeState];
    _lastSamplePacked = [self readLastSample];
    _showingAttentionBtn = [self shouldShowAttentionButtonForState:_lastStateBits];
    [self updateLocalizedTitle];

    __weak typeof(self) weakSelf = self;
    _fgObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s requestLiveStatusFromSB];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            [s refreshLiveTelemetryIfChanged];
        });
    }];

    _langObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@FR_NOTE_LANG_CHANGED
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        FRInvalidateLangCache();
        s->_renderedLangCode = FRResolvedLangCode();
        [s updateLocalizedTitle];
        [s reloadSpecifiers];
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    FRInvalidateLangCache();
    int curLang = FRResolvedLangCode();
    if (curLang != _renderedLangCode) {
        _renderedLangCode = curLang;
        [self updateLocalizedTitle];
        [self reloadSpecifiers];
    } else {
        [self reloadSpecifierID:@"FR_SPEC_BLACKLIST" animated:NO];
    }

    [self requestLiveStatusFromSB];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf refreshLiveTelemetryIfChanged];
    });

    [_pollTimer invalidate];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(onPollTimerTick:)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)onPollTimerTick:(NSTimer *)timer {
    [self refreshLiveTelemetryIfChanged];
}

- (void)refreshLiveTelemetryIfChanged {
    uint64_t st = [self readRuntimeState];
    uint64_t sm = [self readLastSample];
    BOOL wantBtn = [self shouldShowAttentionButtonForState:st];

    BOOL stateChanged = (st != _lastStateBits);
    BOOL sampleChanged = (sm != _lastSamplePacked);
    _lastStateBits = st;
    _lastSamplePacked = sm;

    if (wantBtn != _showingAttentionBtn) {
        _showingAttentionBtn = wantBtn;
        if (wantBtn) {
            id btn = [self buildAttentionButtonSpecifier];
            if (btn) [self insertSpecifier:btn afterSpecifierID:@"FR_SPEC_STATUS" animated:YES];
        } else {
            [self removeSpecifierID:@"FR_SPEC_ATTENTION_BTN" animated:YES];
        }
    }

    if (stateChanged) {
        [self reloadSpecifierID:@"FR_SPEC_STATUS" animated:NO];
    }
    if (sampleChanged) {
        [self reloadSpecifierID:@"FR_SPEC_SAMPLE" animated:NO];
    }
}

- (NSString *)tuningFooterText {
    int enterA = FRReadPrefInt(CFSTR(FRKEY_ENTER_ANGLE), FRDEF_ENTER_ANGLE, FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE);
    int hyst = FRReadPrefInt(CFSTR(FRKEY_HYSTERESIS), FRDEF_HYSTERESIS, FRMIN_HYSTERESIS, FRMAX_HYSTERESIS);
    int exitA = FRComputeExitAngle(enterA, hyst);
    int deb = FRReadPrefInt(CFSTR(FRKEY_DEBOUNCE_MS), FRDEF_DEBOUNCE_MS, FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS);
    return [NSString stringWithFormat:FRLoc(
        @"当前生效：|roll| ≥ %d° 进入横屏，≤ %d° 退回竖屏；设备方向变化后延迟 %d ms 采样（默认即最佳，通常无需调整）。",
        @"Effective: enter landscape at |roll| ≥ %d°, return to portrait at ≤ %d°; %d ms debounce before IR poll (defaults are optimal).",
        @"Сейчас: альбом при |roll| ≥ %d°, портрет при ≤ %d°; задержка %d мс перед ИК-опросом (значения по умолчанию оптимальны)."),
        enterA, exitA, deb];
}

- (id)buildAttentionButtonSpecifier {
    id btn = FRMakeSpec(
        FRLoc(@"前往开启「注视感知功能」", @"Open Attention Aware Settings", @"Включить «Распознавание внимания»"),
        self, NULL, NULL, kFRButtonCell, @"FR_SPEC_ATTENTION_BTN");
    if (btn) {
        if ([btn respondsToSelector:@selector(setButtonAction:)]) {
            ((void (*)(id, SEL, SEL))objc_msgSend)(btn, @selector(setButtonAction:), @selector(openAttentionSettings:));
        } else {
            FRSpecSetProp(btn, NSStringFromSelector(@selector(openAttentionSettings:)), @"action");
        }
    }
    return btn;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *arr = [NSMutableArray array];

        // 1. 总开关与运行状态组
        id mainGrp = FRMakeGroupSpec(
            @"FR_GRP_MAIN",
            FRLoc(@"核心开关与状态", @"Core & Live Status", @"Основные и статус"),
            FRLoc(@"竖排方向锁定开启时本插件自动旁观；锁屏或息屏时停止感知，零待机耗电。",
                  @"Stays passive when Portrait Orientation Lock is enabled; pauses on lock/screen-off for zero standby drain.",
                  @"Не вмешивается при блокировке ориентации; отключается на экране блокировки — нулевой расход батареи."));
        if (mainGrp) [arr addObject:mainGrp];

        id enableSpec = FRMakeSpec(
            FRLoc(@"启用随脸旋转", @"Enable FaceRotate", @"Включить FaceRotate"),
            self, @selector(setEnabled:specifier:), @selector(getEnabled:),
            kFRSwitchCell, @"FR_SPEC_ENABLED");
        if (enableSpec) {
            FRSpecSetProp(enableSpec, @YES, @"default");
            [arr addObject:enableSpec];
        }

        id statusSpec = FRMakeSpec(
            FRLoc(@"运行状态", @"Status", @"Статус"),
            self, NULL, @selector(getStatusText:),
            kFRTitleValueCell, @"FR_SPEC_STATUS");
        if (statusSpec) [arr addObject:statusSpec];

        if (_showingAttentionBtn) {
            id attnBtn = [self buildAttentionButtonSpecifier];
            if (attnBtn) [arr addObject:attnBtn];
        }

        id sampleSpec = FRMakeSpec(
            FRLoc(@"最近感知", @"Last Detection", @"Последний опрос"),
            self, NULL, @selector(getLastSampleText:),
            kFRTitleValueCell, @"FR_SPEC_SAMPLE");
        if (sampleSpec) [arr addObject:sampleSpec];

        // 2. 应用黑名单组
        id blkGrp = FRMakeGroupSpec(
            @"FR_GRP_BLACKLIST",
            FRLoc(@"应用例外", @"App Exceptions", @"Исключения"),
            FRLoc(@"黑名单内的应用（如相机）将跳过人脸判断，始终使用系统原生重力旋转。",
                  @"Blacklisted apps (e.g. Camera) bypass face detection and always use native gravity rotation.",
                  @"Приложения из списка (напр. Камера) пропускают ИК-опрос и используют обычный датчик."));
        if (blkGrp) [arr addObject:blkGrp];

        id blkSpec = FRMakeSpec(
            FRLoc(@"应用黑名单", @"App Blacklist", @"Чёрный список"),
            self, NULL, @selector(getBlacklistCountText:),
            kFRTitleValueCell, @"FR_SPEC_BLACKLIST");
        if (blkSpec) [arr addObject:blkSpec];

        // 3. 检测参数组
        id tuneGrp = FRMakeGroupSpec(
            @"FR_GRP_TUNING",
            FRLoc(@"检测参数", @"Detection Tuning", @"Параметры опроса"),
            [self tuningFooterText]);
        if (tuneGrp) [arr addObject:tuneGrp];

        // 横屏触发角度
        id enterValSpec = FRMakeSpec(
            FRLoc(@"横屏触发角度", @"Landscape Trigger Angle", @"Угол входа в альбом"),
            self, NULL, @selector(getEnterAngleText:),
            kFRTitleValueCell, @"FR_SPEC_ENTER_VAL");
        if (enterValSpec) [arr addObject:enterValSpec];

        id enterSlider = FRMakeSpec(
            @"", self, @selector(setEnterAngleValue:specifier:), @selector(getEnterAngleValue:),
            kFRSliderCell, @"FR_SPEC_ENTER_SLIDER");
        if (enterSlider) {
            FRSpecSetProp(enterSlider, @(FRMIN_ENTER_ANGLE), @"min");
            FRSpecSetProp(enterSlider, @(FRMAX_ENTER_ANGLE), @"max");
            FRSpecSetProp(enterSlider, @(FRDEF_ENTER_ANGLE), @"default");
            FRSpecSetProp(enterSlider, @NO, @"showValue");
            FRSpecSetProp(enterSlider, @YES, @"isContinuous");
            [arr addObject:enterSlider];
        }

        // 退回竖屏滞回
        id hystValSpec = FRMakeSpec(
            FRLoc(@"退回竖屏滞回", @"Hysteresis Margin", @"Гистерезис возврата"),
            self, NULL, @selector(getHysteresisText:),
            kFRTitleValueCell, @"FR_SPEC_HYST_VAL");
        if (hystValSpec) [arr addObject:hystValSpec];

        id hystSlider = FRMakeSpec(
            @"", self, @selector(setHysteresisValue:specifier:), @selector(getHysteresisValue:),
            kFRSliderCell, @"FR_SPEC_HYST_SLIDER");
        if (hystSlider) {
            FRSpecSetProp(hystSlider, @(FRMIN_HYSTERESIS), @"min");
            FRSpecSetProp(hystSlider, @(FRMAX_HYSTERESIS), @"max");
            FRSpecSetProp(hystSlider, @(FRDEF_HYSTERESIS), @"default");
            FRSpecSetProp(hystSlider, @NO, @"showValue");
            FRSpecSetProp(hystSlider, @YES, @"isContinuous");
            [arr addObject:hystSlider];
        }

        // 采样防抖延迟
        id debValSpec = FRMakeSpec(
            FRLoc(@"采样防抖延迟", @"Debounce Delay", @"Задержка опроса"),
            self, NULL, @selector(getDebounceText:),
            kFRTitleValueCell, @"FR_SPEC_DEBOUNCE_VAL");
        if (debValSpec) [arr addObject:debValSpec];

        id debSlider = FRMakeSpec(
            @"", self, @selector(setDebounceValue:specifier:), @selector(getDebounceValue:),
            kFRSliderCell, @"FR_SPEC_DEBOUNCE_SLIDER");
        if (debSlider) {
            FRSpecSetProp(debSlider, @(FRMIN_DEBOUNCE_MS), @"min");
            FRSpecSetProp(debSlider, @(FRMAX_DEBOUNCE_MS), @"max");
            FRSpecSetProp(debSlider, @(FRDEF_DEBOUNCE_MS), @"default");
            FRSpecSetProp(debSlider, @NO, @"showValue");
            FRSpecSetProp(debSlider, @YES, @"isContinuous");
            [arr addObject:debSlider];
        }

        // 恢复默认参数按钮
        id resetBtn = FRMakeSpec(
            FRLoc(@"恢复默认参数", @"Reset Defaults", @"Сбросить параметры"),
            self, NULL, NULL, kFRButtonCell, @"FR_SPEC_RESET_BTN");
        if (resetBtn) {
            if ([resetBtn respondsToSelector:@selector(setButtonAction:)]) {
                ((void (*)(id, SEL, SEL))objc_msgSend)(resetBtn, @selector(setButtonAction:), @selector(confirmResetDefaults:));
            } else {
                FRSpecSetProp(resetBtn, NSStringFromSelector(@selector(confirmResetDefaults:)), @"action");
            }
            [arr addObject:resetBtn];
        }

        // 4. 更多组（调试日志 / 语言 / 关于）
        const char *logPath = jbroot("/tmp/facerotate.log");
        NSString *moreFooter = [NSString stringWithFormat:FRLoc(
            @"隐私说明：面部姿态数据仅在内存中瞬时使用，绝不落盘、不上报。调试日志默认关闭；开启后写至 %s。",
            @"Privacy: Face orientation metadata is evaluated ephemerally in memory and never saved or uploaded. Debug logging is off by default; when enabled, logs write to %s.",
            @"Приватность: данные о наклоне лица обрабатываются только в памяти, не сохраняются и не отправляются. Логирование выкл. по умолчанию; при вкл. пишется в %s."),
            logPath ?: "/tmp/facerotate.log"];
        id moreGrp = FRMakeGroupSpec(@"FR_GRP_MORE", FRLoc(@"更多", @"More", @"Дополнительно"), moreFooter);
        if (moreGrp) [arr addObject:moreGrp];

        id debugSpec = FRMakeSpec(
            FRLoc(@"调试日志", @"Debug Log", @"Журнал отладки"),
            self, @selector(setDebugLog:specifier:), @selector(getDebugLog:),
            kFRSwitchCell, @"FR_SPEC_DEBUG");
        if (debugSpec) {
            FRSpecSetProp(debugSpec, @NO, @"default");
            [arr addObject:debugSpec];
        }

        id langSpec = FRMakeSpec(
            FRLoc(@"语言", @"Language", @"Язык"),
            self, NULL, @selector(getLanguageValue:),
            kFRTitleValueCell, @"FR_SPEC_LANG");
        if (langSpec) [arr addObject:langSpec];

        id aboutSpec = FRMakeSpec(
            FRLoc(@"关于", @"About", @"О твике"),
            self, NULL, @selector(getAboutValue:),
            kFRTitleValueCell, @"FR_SPEC_ABOUT");
        if (aboutSpec) [arr addObject:aboutSpec];

        _specifiers = [arr copy];
    }
    return _specifiers;
}

#pragma mark - Specifier Getters & Setters

- (id)getEnabled:(id)spec {
    return @(FRReadPrefBool(CFSTR(FRKEY_ENABLED), FRDEF_ENABLED != 0));
}

- (void)setEnabled:(id)val specifier:(id)spec {
    BOOL en = [val boolValue];
    FRWritePrefValue(CFSTR(FRKEY_ENABLED), en ? kCFBooleanTrue : kCFBooleanFalse);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf refreshLiveTelemetryIfChanged];
    });
}

- (id)getDebugLog:(id)spec {
    return @(FRReadPrefBool(CFSTR(FRKEY_DEBUG_LOG), FRDEF_DEBUG_LOG != 0));
}

- (void)setDebugLog:(id)val specifier:(id)spec {
    BOOL on = [val boolValue];
    FRWritePrefValue(CFSTR(FRKEY_DEBUG_LOG), on ? kCFBooleanTrue : kCFBooleanFalse);
}

- (id)getStatusText:(id)spec {
    uint64_t st = _lastStateBits;
    if (!(st & FRSTATE_SB_ALIVE)) {
        return FRLoc(@"未注入 SpringBoard", @"Not Injected", @"Не в SpringBoard");
    }
    if (!(st & FRSTATE_ENABLED)) {
        return FRLoc(@"已关闭", @"Disabled", @"Выключено");
    }
    if (!(st & FRSTATE_AW_SUPPORTED)) {
        return FRLoc(@"不支持 TrueDepth 红外", @"IR Sensor Unsupported", @"Нет TrueDepth ИК");
    }
    if (!(st & FRSTATE_ATTENTION_ON)) {
        return FRLoc(@"需开启「注视感知功能」", @"Attention Aware Off", @"Внимание выкл.");
    }
    if (st & FRSTATE_PORTRAIT_LOCK) {
        return FRLoc(@"已就绪（竖排方向锁定中）", @"Ready (Portrait Locked)", @"Пауза (блок. ориент.)");
    }
    if (st & FRSTATE_SCREEN_LOCKED) {
        return FRLoc(@"已就绪（锁屏暂停）", @"Ready (Screen Locked)", @"Пауза (экран заблок.)");
    }
    if (st & FRSTATE_BLACKLISTED_FG) {
        return FRLoc(@"已就绪（前台在黑名单）", @"Ready (Blacklisted App)", @"Пауза (в чёрном списке)");
    }
    if (st & FRSTATE_IOS15_LEGACY) {
        return FRLoc(@"运行中（红外 · iOS 15 模式）", @"Active (IR · iOS 15)", @"Активно (ИК · iOS 15)");
    }
    return FRLoc(@"运行中（红外感知）", @"Active (TrueDepth IR)", @"Активно (TrueDepth ИК)");
}

- (id)getLastSampleText:(id)spec {
    FRSampleInfo info;
    if (!FRUnpackSample(_lastSamplePacked, &info)) {
        return FRLoc(@"暂无采样", @"No sample yet", @"Нет данных");
    }
    switch (info.status) {
        case FRSampleStatusValid: {
            NSString *oriStr;
            if (info.outOri == 1) oriStr = FRLoc(@"竖屏", @"Portrait", @"Портрет");
            else if (info.outOri == 3) oriStr = FRLoc(@"横屏左", @"Landscape L", @"Альбом Л");
            else if (info.outOri == 4) oriStr = FRLoc(@"横屏右", @"Landscape R", @"Альбом П");
            else oriStr = FRLoc(@"原生重力", @"Gravity", @"Датчик");
            return [NSString stringWithFormat:@"%@ · %+.1f° · %ums", oriStr, info.roll, info.latencyMs];
        }
        case FRSampleStatusNoFace:
            return [NSString stringWithFormat:FRLoc(@"无脸/超时 → 重力 (%ums)", @"No face → Gravity (%ums)", @"Нет лица → Датчик (%ums)"), info.latencyMs];
        case FRSampleStatusObstructed:
            return [NSString stringWithFormat:FRLoc(@"遮挡/无效 → 重力 (%ums)", @"Obstructed → Gravity (%ums)", @"Закрыто → Датчик (%ums)"), info.latencyMs];
        case FRSampleStatusUpsideDown:
            return [NSString stringWithFormat:FRLoc(@"倒置回退 → 重力 (%.0f°)", @"Upside-down → Gravity (%.0f°)", @"Вверх ногами → Датчик (%.0f°)"), info.roll];
        case FRSampleStatusAttentionOff:
            return FRLoc(@"注视感知关闭 → 重力", @"Attention Off → Gravity", @"Внимание выкл. → Датчик");
        default:
            return FRLoc(@"暂无采样", @"No sample yet", @"Нет данных");
    }
}

- (id)getBlacklistCountText:(id)spec {
    NSUInteger n = FRReadBlacklistCount();
    return [NSString stringWithFormat:FRLoc(@"%lu 个应用", @"%lu apps", @"%lu прил."), (unsigned long)n];
}

// 实时局部刷新数值行文字与检测参数组 Footer（避免 reloadData 打断 UISlider 拖动手势）
- (void)refreshTuningRowID:(NSString *)valSpecID text:(NSString *)text {
    UITableView *tv = [self respondsToSelector:@selector(table)] ? [self table] : nil;
    id valSpec = [self specifierForID:valSpecID];
    if (tv && valSpec) {
        NSIndexPath *ip = [self indexPathForSpecifier:valSpec];
        if (ip) {
            UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
            if (cell && cell.detailTextLabel) {
                cell.detailTextLabel.text = text;
                [cell setNeedsLayout];
            }
            UITableViewHeaderFooterView *fv = [tv footerViewForSection:ip.section];
            NSString *footer = [self tuningFooterText];
            id grpSpec = [self specifierForID:@"FR_GRP_TUNING"];
            if (grpSpec) FRSpecSetProp(grpSpec, footer, @"footerText");
            if (fv && fv.textLabel) {
                fv.textLabel.text = footer;
                [fv setNeedsLayout];
            }
        }
    }
}

- (id)getEnterAngleValue:(id)spec {
    return @(FRReadPrefInt(CFSTR(FRKEY_ENTER_ANGLE), FRDEF_ENTER_ANGLE, FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE));
}

- (id)getEnterAngleText:(id)spec {
    int v = FRReadPrefInt(CFSTR(FRKEY_ENTER_ANGLE), FRDEF_ENTER_ANGLE, FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE);
    return [NSString stringWithFormat:@"%d°", v];
}

- (void)setEnterAngleValue:(id)val specifier:(id)spec {
    int oldV = FRReadPrefInt(CFSTR(FRKEY_ENTER_ANGLE), FRDEF_ENTER_ANGLE, FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE);
    int newV = FRRoundStepInt([val doubleValue], FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE, FRSTEP_ENTER_ANGLE);
    if (newV != oldV) {
        FRWritePrefValue(CFSTR(FRKEY_ENTER_ANGLE), (__bridge CFNumberRef)@(newV));
    }
    [self refreshTuningRowID:@"FR_SPEC_ENTER_VAL" text:[NSString stringWithFormat:@"%d°", newV]];
}

- (id)getHysteresisValue:(id)spec {
    return @(FRReadPrefInt(CFSTR(FRKEY_HYSTERESIS), FRDEF_HYSTERESIS, FRMIN_HYSTERESIS, FRMAX_HYSTERESIS));
}

- (id)getHysteresisText:(id)spec {
    int v = FRReadPrefInt(CFSTR(FRKEY_HYSTERESIS), FRDEF_HYSTERESIS, FRMIN_HYSTERESIS, FRMAX_HYSTERESIS);
    return [NSString stringWithFormat:@"%d°", v];
}

- (void)setHysteresisValue:(id)val specifier:(id)spec {
    int oldV = FRReadPrefInt(CFSTR(FRKEY_HYSTERESIS), FRDEF_HYSTERESIS, FRMIN_HYSTERESIS, FRMAX_HYSTERESIS);
    int newV = FRRoundStepInt([val doubleValue], FRMIN_HYSTERESIS, FRMAX_HYSTERESIS, FRSTEP_HYSTERESIS);
    if (newV != oldV) {
        FRWritePrefValue(CFSTR(FRKEY_HYSTERESIS), (__bridge CFNumberRef)@(newV));
    }
    [self refreshTuningRowID:@"FR_SPEC_HYST_VAL" text:[NSString stringWithFormat:@"%d°", newV]];
}

- (id)getDebounceValue:(id)spec {
    return @(FRReadPrefInt(CFSTR(FRKEY_DEBOUNCE_MS), FRDEF_DEBOUNCE_MS, FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS));
}

- (id)getDebounceText:(id)spec {
    int v = FRReadPrefInt(CFSTR(FRKEY_DEBOUNCE_MS), FRDEF_DEBOUNCE_MS, FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS);
    return [NSString stringWithFormat:@"%d ms", v];
}

- (void)setDebounceValue:(id)val specifier:(id)spec {
    int oldV = FRReadPrefInt(CFSTR(FRKEY_DEBOUNCE_MS), FRDEF_DEBOUNCE_MS, FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS);
    int newV = FRRoundStepInt([val doubleValue], FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS, FRSTEP_DEBOUNCE_MS);
    if (newV != oldV) {
        FRWritePrefValue(CFSTR(FRKEY_DEBOUNCE_MS), (__bridge CFNumberRef)@(newV));
    }
    [self refreshTuningRowID:@"FR_SPEC_DEBOUNCE_VAL" text:[NSString stringWithFormat:@"%d ms", newV]];
}

- (id)getLanguageValue:(id)spec {
    return FRCurrentLangDisplayName();
}

- (id)getAboutValue:(id)spec {
    return @FR_VERSION;
}

#pragma mark - Actions

- (void)openAttentionSettings:(id)spec {
    NSArray<NSString *> *urls = @[
        @"prefs:root=ACCESSIBILITY&path=FACEID_ATTENTION",
        @"prefs:root=PASSCODE",
    ];
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    id ws = (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)])
        ? ((id (*)(Class, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace))
        : nil;
    if (ws && [ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        for (NSString *raw in urls) {
            NSURL *url = [NSURL URLWithString:raw];
            if (url && ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, @selector(openSensitiveURL:withOptions:), url, nil)) {
                return;
            }
        }
    }
    NSURL *appSettings = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    if (appSettings) {
        [[UIApplication sharedApplication] openURL:appSettings options:@{} completionHandler:nil];
    }
}

- (void)confirmResetDefaults:(id)spec {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:FRLoc(@"恢复默认参数？", @"Reset Tuning Parameters?", @"Сбросить параметры?")
                         message:FRLoc(@"将横屏触发角 (50°)、退回滞回 (15°) 与防抖延迟 (80 ms) 恢复为默认推荐值。应用黑名单与语言设置保留不变。",
                                       @"Resets Trigger Angle (50°), Hysteresis (15°), and Debounce Delay (80 ms) to recommended defaults. App blacklist and language remain unchanged.",
                                       @"Сбросит угол входа (50°), гистерезис (15°) и задержку (80 мс) к значениям по умолчанию. Чёрный список и язык сохранятся.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FRLoc(@"取消", @"Cancel", @"Отмена")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:FRLoc(@"恢复默认", @"Reset", @"Сбросить")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *act) {
        CFPreferencesSetValue(CFSTR(FRKEY_ENTER_ANGLE), (__bridge CFNumberRef)@(FRDEF_ENTER_ANGLE),
                              CFSTR(FR_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR(FRKEY_HYSTERESIS), (__bridge CFNumberRef)@(FRDEF_HYSTERESIS),
                              CFSTR(FR_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR(FRKEY_DEBOUNCE_MS), (__bridge CFNumberRef)@(FRDEF_DEBOUNCE_MS),
                              CFSTR(FR_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR(FRKEY_POLL_TIMEOUT_MS), (__bridge CFNumberRef)@(FRDEF_POLL_TIMEOUT_MS),
                              CFSTR(FR_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
        notify_post(FR_NOTE_PREFS_CHANGED);
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentAboutAlert {
    NSString *msg = FRLoc(
        @"版本：" @FR_VERSION @"\n\n基于 TrueDepth 红外注视感知的事件驱动自动旋转插件：在竖排方向锁定关闭时，按人脸垂直方向对齐屏幕朝向，侧躺也能自然横竖切换。\n\n• 零常驻摄像头 / 无隐私绿点\n• 超时、遮挡、无脸、注视感知关闭严格回退原生重力\n• 兼容 iOS 15–17（TraitsArbiter 与传统管线）",
        @"Version: " @FR_VERSION @"\n\nEvent-driven face-aware auto-rotation powered by TrueDepth infrared attention detection. Aligns screen orientation with your face upright axis while Portrait Lock is off.\n\n• No continuous camera stream / Zero green privacy dot\n• Strict fail-open to native gravity on timeout, obstruction, no face, or disabled Attention Aware\n• Supports iOS 15–17 (TraitsArbiter & legacy path)",
        @"Версия: " @FR_VERSION @"\n\nСобытийный автоповорот экрана по положению лица через ИК-датчик TrueDepth. Выравнивает экран относительно лица, когда блокировка ориентации выключена.\n\n• Без постоянного потока камеры и зелёного индикатора\n• Надёжный откат к обычному датчику при таймауте, перекрытии или отсутствии лица\n• Поддержка iOS 15–17 (TraitsArbiter и классический режим)");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:FRLoc(@"关于 FaceRotate（随脸旋转）", @"About FaceRotate", @"О FaceRotate")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FRLoc(@"好", @"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableView Customization

- (void)onSliderTouchUp:(UISlider *)slider {
    NSInteger tag = slider.tag;
    int snapped = 0;
    if (tag == 1) {
        snapped = FRRoundStepInt(slider.value, FRMIN_ENTER_ANGLE, FRMAX_ENTER_ANGLE, FRSTEP_ENTER_ANGLE);
    } else if (tag == 2) {
        snapped = FRRoundStepInt(slider.value, FRMIN_HYSTERESIS, FRMAX_HYSTERESIS, FRSTEP_HYSTERESIS);
    } else if (tag == 3) {
        snapped = FRRoundStepInt(slider.value, FRMIN_DEBOUNCE_MS, FRMAX_DEBOUNCE_MS, FRSTEP_DEBOUNCE_MS);
    } else {
        return;
    }
    [slider setValue:(float)snapped animated:YES];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    IMP superImp = FRSuperIMP([self class], _cmd);
    UITableViewCell *cell = superImp
        ? ((UITableViewCell *(*)(id, SEL, id, id))superImp)(self, _cmd, tableView, indexPath)
        : nil;
    if (!cell) return nil;

    id sp = [self specifierAtIndexPath:indexPath];
    NSString *ident = FRSpecIdent(sp);

    if ([ident isEqualToString:@"FR_SPEC_BLACKLIST"] ||
        [ident isEqualToString:@"FR_SPEC_LANG"] ||
        [ident isEqualToString:@"FR_SPEC_ABOUT"]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([ident isEqualToString:@"FR_SPEC_ATTENTION_BTN"]) {
        cell.textLabel.textColor = [UIColor systemOrangeColor];
    } else if ([ident isEqualToString:@"FR_SPEC_RESET_BTN"]) {
        cell.textLabel.textColor = [UIColor systemRedColor];
    } else if ([ident isEqualToString:@"FR_SPEC_STATUS"]) {
        uint64_t st = _lastStateBits;
        if (!(st & FRSTATE_SB_ALIVE)) {
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else if ((st & FRSTATE_ENABLED) && (st & FRSTATE_AW_SUPPORTED) && !(st & FRSTATE_ATTENTION_ON)) {
            cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
        } else if ((st & FRSTATE_ENABLED) && (st & FRSTATE_ATTENTION_ON) &&
                   !(st & (FRSTATE_PORTRAIT_LOCK | FRSTATE_SCREEN_LOCKED | FRSTATE_BLACKLISTED_FG))) {
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        } else {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    } else if ([ident isEqualToString:@"FR_SPEC_ENTER_SLIDER"] ||
               [ident isEqualToString:@"FR_SPEC_HYST_SLIDER"] ||
               [ident isEqualToString:@"FR_SPEC_DEBOUNCE_SLIDER"]) {
        if ([cell respondsToSelector:@selector(control)]) {
            id ctrl = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(control));
            if ([ctrl isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)ctrl;
                if ([ident isEqualToString:@"FR_SPEC_ENTER_SLIDER"]) slider.tag = 1;
                else if ([ident isEqualToString:@"FR_SPEC_HYST_SLIDER"]) slider.tag = 2;
                else slider.tag = 3;
                [slider removeTarget:self action:@selector(onSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
                [slider addTarget:self action:@selector(onSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            }
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id sp = [self specifierAtIndexPath:indexPath];
    NSString *ident = FRSpecIdent(sp);

    if ([ident isEqualToString:@"FR_SPEC_BLACKLIST"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        FRAppListController *vc = [[FRAppListController alloc] init];
        __weak typeof(self) weakSelf = self;
        vc.onBlacklistChanged = ^(NSUInteger count) {
            [weakSelf reloadSpecifierID:@"FR_SPEC_BLACKLIST" animated:NO];
        };
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    if ([ident isEqualToString:@"FR_SPEC_LANG"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        __weak typeof(self) weakSelf = self;
        FRPresentLanguagePicker(self, cell, ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s->_renderedLangCode = FRResolvedLangCode();
            [s updateLocalizedTitle];
            [s reloadSpecifiers];
        });
        return;
    }

    if ([ident isEqualToString:@"FR_SPEC_ABOUT"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self presentAboutAlert];
        return;
    }

    IMP superImp = FRSuperIMP([self class], _cmd);
    if (superImp) {
        ((void (*)(id, SEL, id, id))superImp)(self, _cmd, tableView, indexPath);
    }
}

@end
