//
//  LogViewController.m
//  Cofi
//

#import "LogViewController.h"
#import "LogTextView.h"
#import <sys/utsname.h>

@interface LogViewController ()
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, strong) LogTextView *logView;
@end

@implementation LogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Log";
    self.view.backgroundColor = UIColor.whiteColor;
    // Force Light trait on this VC so the banner / log surface stays white
    // even when iOS is in dark mode.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(copyAllLog)];
    copyBtn.tintColor = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f];

    UIBarButtonItem *shareBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(shareLogFile)];
    shareBtn.tintColor = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f];

    self.navigationItem.rightBarButtonItems = @[shareBtn, copyBtn];

    _bannerLabel = [[UILabel alloc] init];
    _bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bannerLabel.numberOfLines = 0;
    _bannerLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    _bannerLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1.0f];
    // Classic white surface: banner sits on a 2% graphite plate with a
    // hairline border, no shadow — keeps the log header calm and quiet.
    _bannerLabel.backgroundColor = [UIColor colorWithWhite:0.96f alpha:1.0f];
    _bannerLabel.textAlignment = NSTextAlignmentLeft;
    _bannerLabel.attributedText = [self buildBannerText];
    _bannerLabel.layer.cornerRadius = 10;
    _bannerLabel.layer.borderWidth = 0.5f;
    _bannerLabel.layer.borderColor = [UIColor colorWithWhite:0.0f alpha:0.10f].CGColor;
    _bannerLabel.clipsToBounds = YES;
    [self.view addSubview:_bannerLabel];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.10f];
    [self.view addSubview:separator];

    _logView = [[LogTextView alloc] initWithFrame:CGRectZero];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logView];

    [NSLayoutConstraint activateConstraints:@[
        [_bannerLabel.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_bannerLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_bannerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [separator.topAnchor      constraintEqualToAnchor:_bannerLabel.bottomAnchor constant:12],
        [separator.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [separator.heightAnchor   constraintEqualToConstant:0.5],

        [_logView.topAnchor      constraintEqualToAnchor:separator.bottomAnchor],
        [_logView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
        [_logView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)copyAllLog {
    NSString *snapshot = log_inapp_buffer_snapshot();
    if (snapshot.length == 0) snapshot = @"(empty)";
    [UIPasteboard generalPasteboard].string = snapshot;

    UILabel *toast = [[UILabel alloc] init];
    toast.text = @"Log copied";
    toast.font = [UIFont boldSystemFontOfSize:13];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:0.95f];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 8;
    toast.clipsToBounds = YES;
    [toast sizeToFit];
    CGFloat w = toast.bounds.size.width + 32;
    toast.frame = CGRectMake((self.view.bounds.size.width - w) / 2, self.view.safeAreaInsets.top + 60, w, 32);
    [self.view addSubview:toast];
    [UIView animateWithDuration:0.3 delay:1.0 options:0 animations:^{
        toast.alpha = 0;
    } completion:^(BOOL finished) {
        [toast removeFromSuperview];
    }];
}

- (void)shareLogFile {
    NSString *sessionPath = log_most_recent_session_path();
    NSMutableArray *items = [NSMutableArray array];

    if (sessionPath && [[NSFileManager defaultManager] fileExistsAtPath:sessionPath]) {
        [items addObject:[NSURL fileURLWithPath:sessionPath]];
    } else {
        NSString *snapshot = log_inapp_buffer_snapshot();
        if (snapshot.length == 0) snapshot = @"(empty)";
        [items addObject:snapshot];
    }

    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                      applicationActivities:nil];
    avc.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:avc animated:YES completion:nil];
}

- (NSAttributedString *)buildBannerText {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";

    struct utsname u = {0};
    const char *machine = "device";
    if (uname(&u) == 0 && u.machine[0])
        machine = u.machine;
    NSString *ios = UIDevice.currentDevice.systemVersion ?: @"?";

    NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
    center.alignment = NSTextAlignmentCenter;
    center.lineSpacing = 4.0;

    UIColor *teal = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f];
    UIFont *detailFont = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];

    NSString *line2 = [NSString stringWithFormat:@"External for Free Fire | Version: %@ (%@)\n%s • iOS %@",
                       shortVer, build, machine, ios];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:line2 attributes:@{
        NSFontAttributeName: detailFont,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.35 alpha:1.0],
        NSParagraphStyleAttributeName: center,
    }]];

    return attr;
}

@end
