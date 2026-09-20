#ifndef ESPInstallerViewController_h
#define ESPInstallerViewController_h

#import <UIKit/UIKit.h>

@interface ESPInstallerViewController : UITableViewController

- (BOOL)espEnabled;
- (BOOL)espApplied;
- (NSString *)statusTitle;
- (NSString *)statusDetail;
- (NSString *)actionTitle;
- (NSString *)actionSubtitle;
- (void)reloadState;
- (void)toggleESP;
- (void)setESPEnabledAndRun:(BOOL)run;
- (BOOL)prepareForCleanup;

@end

#endif
