// FaceRotate UI 本地化（仅 Preferences bundle 使用；简体中文 / English，默认跟随系统）

#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "FRCommon.h"

static int sFRResolvedLang = -1; // -1=未初始化, 0=en, 1=zh

static inline NSString *FRReadLangPref(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR(FRKEY_LANG), CFSTR(FR_PREFS_DOMAIN));
    if (!v) return @"system";
    id obj = CFBridgingRelease(v);
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if ([s isEqualToString:@"zh"] || [s isEqualToString:@"en"]) {
            return s;
        }
    }
    return @"system";
}

static inline void FRInvalidateLangCache(void) {
    sFRResolvedLang = -1;
}

static inline int FRResolvedLangCode(void) {
    if (sFRResolvedLang >= 0) return sFRResolvedLang;
    NSString *pref = FRReadLangPref();
    if ([pref isEqualToString:@"zh"]) {
        sFRResolvedLang = 1;
    } else if ([pref isEqualToString:@"en"]) {
        sFRResolvedLang = 0;
    } else {
        NSString *sys = [NSLocale preferredLanguages].firstObject;
        sFRResolvedLang = [sys hasPrefix:@"zh"] ? 1 : 0;
    }
    return sFRResolvedLang;
}

static inline void FRWriteLangPref(NSString *code) {
    NSString *val = ([code isEqualToString:@"zh"] || [code isEqualToString:@"en"]) ? code : @"system";
    CFPreferencesSetValue(CFSTR(FRKEY_LANG), (__bridge CFPropertyListRef)val,
                          CFSTR(FR_PREFS_DOMAIN),
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    FRInvalidateLangCache();
    CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                                         CFSTR(FR_NOTE_LANG_CHANGED),
                                         NULL, NULL, TRUE);
}

static inline NSString *FRLoc(NSString *zh, NSString *en) {
    return (FRResolvedLangCode() == 1) ? zh : en;
}

static inline NSString *FRCurrentLangDisplayName(void) {
    NSString *pref = FRReadLangPref();
    if ([pref isEqualToString:@"zh"]) return @"简体中文";
    if ([pref isEqualToString:@"en"]) return @"English";
    return FRLoc(@"跟随系统", @"Follow System");
}

static inline void FRPresentLanguagePicker(UIViewController *vc, UIView *sourceView, void (^onChanged)(void)) {
    if (!vc) return;
    NSString *cur = FRReadLangPref();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:FRLoc(@"语言", @"Language")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"system", FRLoc(@"跟随系统", @"Follow System")],
        @[@"zh",     @"简体中文"],
        @[@"en",     @"English"],
    ];

    for (NSArray<NSString *> *it in items) {
        NSString *code = it[0];
        NSString *title = [cur isEqualToString:code]
            ? [NSString stringWithFormat:@"✓ %@", it[1]]
            : it[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            if (![cur isEqualToString:code]) {
                FRWriteLangPref(code);
                if (onChanged) onChanged();
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:FRLoc(@"取消", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = sourceView ?: vc.view;
        pop.sourceRect = sourceView ? sourceView.bounds : CGRectMake(vc.view.bounds.size.width * 0.5, vc.view.bounds.size.height * 0.5, 1, 1);
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}
