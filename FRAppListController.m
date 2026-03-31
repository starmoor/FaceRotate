#import "FRAppListController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include "FRCommon.h"
#include "FRLoc.h"

@interface FRAppEntry : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) BOOL isSystemApp;
@end

@implementation FRAppEntry
@end

@interface FRAppListController ()
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<FRAppEntry *> *allApps;
@property (nonatomic, strong) NSArray<FRAppEntry *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundleIDs;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *iconCache;
@property (nonatomic, assign) BOOL loading;
@end

static NSArray<NSString *> *FRReadBlacklistFromPrefs(void) {
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR(FRKEY_BLACKLIST), CFSTR(FR_PREFS_DOMAIN));
    if (!val) {
        return FRDefaultBlacklist();
    }
    id obj = CFBridgingRelease(val);
    if (![obj isKindOfClass:[NSArray class]]) {
        return FRDefaultBlacklist();
    }
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (id item in (NSArray *)obj) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
            [clean addObject:(NSString *)item];
        }
    }
    return clean;
}

static void FRWriteBlacklistToPrefs(NSSet<NSString *> *set) {
    NSArray<NSString *> *sorted = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
    CFPreferencesSetValue(CFSTR(FRKEY_BLACKLIST), (__bridge CFPropertyListRef)sorted,
                          CFSTR(FR_PREFS_DOMAIN),
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(CFSTR(FR_PREFS_DOMAIN));
    notify_post(FR_NOTE_PREFS_CHANGED);
}

@implementation FRAppListController

- (instancetype)init {
    if (@available(iOS 13.0, *)) {
        self = [super initWithStyle:UITableViewStyleInsetGrouped];
    } else {
        self = [super initWithStyle:UITableViewStyleGrouped];
    }
    if (self) {
        _iconCache = [[NSCache alloc] init];
        _iconCache.countLimit = 120;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = FRLoc(@"应用黑名单", @"App Blacklist", @"Чёрный список");
    self.selectedBundleIDs = [NSMutableSet setWithArray:FRReadBlacklistFromPrefs()];

    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.hidesNavigationBarDuringPresentation = NO;
    sc.searchBar.placeholder = FRLoc(@"搜索应用名称或 Bundle ID", @"Search app name or Bundle ID", @"Поиск по названию или Bundle ID");
    self.searchController = sc;
    self.navigationItem.searchController = sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.tableView.rowHeight = 52.0;

    [self loadInstalledAppsAsync];
}

- (void)loadInstalledAppsAsync {
    self.loading = YES;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];

    NSSet<NSString *> *initialSelected = [self.selectedBundleIDs copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSMutableArray<FRAppEntry *> *list = [NSMutableArray array];
            Class wsCls = objc_getClass("LSApplicationWorkspace");
            id ws = (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)])
                ? ((id (*)(Class, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace))
                : nil;

            NSArray *proxies = nil;
            if (ws) {
                if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
                    proxies = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications));
                } else if ([ws respondsToSelector:@selector(allApplications)]) {
                    proxies = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allApplications));
                }
            }

            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (id proxy in proxies) {
                if (!proxy) continue;

                NSString *bid = [proxy respondsToSelector:@selector(bundleIdentifier)]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier))
                    : nil;
                if (![bid isKindOfClass:[NSString class]] || bid.length == 0 || [seen containsObject:bid]) {
                    continue;
                }

                NSString *appType = [proxy respondsToSelector:@selector(applicationType)]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(applicationType))
                    : nil;
                BOOL isUser = [appType isKindOfClass:[NSString class]] && [appType isEqualToString:@"User"];
                BOOL isSystem = [appType isKindOfClass:[NSString class]] && [appType isEqualToString:@"System"];
                if (!isUser && !isSystem) {
                    continue;
                }

                // 过滤隐藏或禁止启动的系统组件
                if (isSystem) {
                    if ([proxy respondsToSelector:@selector(isLaunchProhibited)]) {
                        BOOL prohibited = ((BOOL (*)(id, SEL))objc_msgSend)(proxy, @selector(isLaunchProhibited));
                        if (prohibited) continue;
                    }
                    if ([proxy respondsToSelector:@selector(appTags)]) {
                        id tags = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(appTags));
                        if ([tags isKindOfClass:[NSArray class]] && [(NSArray *)tags containsObject:@"hidden"]) {
                            continue;
                        }
                    }
                }

                NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName))
                    : nil;
                if ((![name isKindOfClass:[NSString class]] || name.length == 0) &&
                    [proxy respondsToSelector:@selector(itemName)]) {
                    name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(itemName));
                }
                if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                    if (isSystem) continue; // 无显示名的系统组件大概率是无界面服务
                    name = bid;
                }

                [seen addObject:bid];
                FRAppEntry *entry = [[FRAppEntry alloc] init];
                entry.bundleID = bid;
                entry.displayName = name;
                entry.isSystemApp = isSystem;
                [list addObject:entry];
            }

            // 已勾选黑名单置顶，组内按本地化名称排序
            [list sortUsingComparator:^NSComparisonResult(FRAppEntry *a, FRAppEntry *b) {
                BOOL aSel = [initialSelected containsObject:a.bundleID];
                BOOL bSel = [initialSelected containsObject:b.bundleID];
                if (aSel != bSel) {
                    return aSel ? NSOrderedAscending : NSOrderedDescending;
                }
                NSComparisonResult cmp = [a.displayName localizedCaseInsensitiveCompare:b.displayName];
                if (cmp != NSOrderedSame) return cmp;
                return [a.bundleID compare:b.bundleID];
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.loading = NO;
                strongSelf.navigationItem.rightBarButtonItem = nil;
                strongSelf.allApps = [list copy];
                [strongSelf applySearchFilter];
            });
        }
    });
}

- (void)applySearchFilter {
    NSString *query = [self.searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredApps = self.allApps ?: @[];
    } else {
        NSMutableArray<FRAppEntry *> *matched = [NSMutableArray array];
        for (FRAppEntry *entry in self.allApps) {
            if ([entry.displayName rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [entry.bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matched addObject:entry];
            }
        }
        self.filteredApps = matched;
    }
    [self.tableView reloadData];
}

- (UIImage *)iconForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    UIImage *cached = [self.iconCache objectForKey:bundleID];
    if (cached) return cached;

    SEL sel = @selector(_applicationIconImageForBundleIdentifier:format:scale:);
    if ([UIImage respondsToSelector:sel]) {
        CGFloat scale = [UIScreen mainScreen].scale;
        UIImage *img = ((UIImage *(*)(Class, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], sel, bundleID, 0, scale);
        if (img) {
            [self.iconCache setObject:img forKey:bundleID];
            return img;
        }
    }
    return nil;
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applySearchFilter];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.loading) {
        return FRLoc(@"正在加载已安装应用...", @"Loading installed apps...", @"Загрузка приложений...");
    }
    return FRLoc(@"勾选的应用始终使用系统原生重力旋转", @"Checked apps always use native gravity rotation", @"Отмеченные приложения используют обычный поворот по датчику");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.loading) return nil;
    return [NSString stringWithFormat:FRLoc(@"共 %lu 个应用，已屏蔽 %lu 个", @"%lu apps listed, %lu blacklisted", @"Всего: %lu, в списке: %lu"),
            (unsigned long)self.filteredApps.count,
            (unsigned long)self.selectedBundleIDs.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kReuse = @"FRAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kReuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kReuse];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.imageView.layer.cornerRadius = 6.5;
        cell.imageView.layer.masksToBounds = YES;
    }

    FRAppEntry *entry = self.filteredApps[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry.displayName;
    cell.detailTextLabel.text = entry.bundleID;
    cell.imageView.image = [self iconForBundleID:entry.bundleID];
    cell.accessoryType = [self.selectedBundleIDs containsObject:entry.bundleID]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FRAppEntry *entry = self.filteredApps[(NSUInteger)indexPath.row];
    if ([self.selectedBundleIDs containsObject:entry.bundleID]) {
        [self.selectedBundleIDs removeObject:entry.bundleID];
    } else {
        [self.selectedBundleIDs addObject:entry.bundleID];
    }

    FRWriteBlacklistToPrefs(self.selectedBundleIDs);
    if (self.onBlacklistChanged) {
        self.onBlacklistChanged(self.selectedBundleIDs.count);
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell) {
        cell.accessoryType = [self.selectedBundleIDs containsObject:entry.bundleID]
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }

    UITableViewHeaderFooterView *footer = [tableView footerViewForSection:0];
    if (footer && footer.textLabel) {
        footer.textLabel.text = [NSString stringWithFormat:FRLoc(@"共 %lu 个应用，已屏蔽 %lu 个", @"%lu apps listed, %lu blacklisted", @"Всего: %lu, в списке: %lu"),
                                 (unsigned long)self.filteredApps.count,
                                 (unsigned long)self.selectedBundleIDs.count];
        [footer setNeedsLayout];
    }
}

@end
