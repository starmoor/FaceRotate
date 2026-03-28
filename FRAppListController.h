#pragma once

#import <UIKit/UIKit.h>

@interface FRAppListController : UITableViewController <UISearchResultsUpdating>

@property (nonatomic, copy, nullable) void (^onBlacklistChanged)(NSUInteger count);

@end
