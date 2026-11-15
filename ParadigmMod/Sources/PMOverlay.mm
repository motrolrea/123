//
//  ParadigmMod 设置页（UIKit）+ 悬浮球入口
//

#import "PMCommon.h"
#import <UIKit/UIKit.h>
#include <math.h>

typedef NS_ENUM(NSInteger, PMRowTag) {
    PMRowAutoPlay = 100,
    PMRowAllPerfect,
    PMRowLockHP,
    PMRowUnlockAll,
    PMRowBlockUpload,
};

@interface PMSettingsController : UIViewController
@end

static UIWindow *gWindow = nil;
static UILabel *gStatusLabel = nil;
static NSTimer *gStatusTimer = nil;

// ---------------------------------------------------------------------------
// 透传容器：除悬浮球外不拦截触摸
// ---------------------------------------------------------------------------
@interface PMPassthroughView : UIView
@end

@implementation PMPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v == self ? nil : v;
}
@end

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------
@interface PMBallView : UIView
@end

@implementation PMBallView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:0.85];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 4;
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"M";
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont boldSystemFontOfSize:24];
        l.textColor = UIColor.whiteColor;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    }
    return self;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:self.superview];
}

- (void)onTap {
    UIViewController *root = gWindow.rootViewController;
    if (root.presentedViewController) {
        [root dismissViewControllerAnimated:YES completion:nil];
    } else {
        [root presentViewController:[PMSettingsController new] animated:YES completion:nil];
    }
}
@end

// ---------------------------------------------------------------------------
// 设置页
// ---------------------------------------------------------------------------
@implementation PMSettingsController {
    UIScrollView *_scroll;
    CGFloat _y;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _y = 24;
    [self addHeader];
    [self addSection:@"玩法"];
    [self addSwitch:@"AutoPlay 自动打歌" detail:@"按判定时间自动命中所有音符" tag:PMRowAutoPlay on:PMAutoPlay];
    [self addSwitch:@"全 Perfect" detail:@"把 Good / Miss 强制改成 Perfect（不影响判定窗口）" tag:PMRowAllPerfect on:PMAllPerfect];
    [self addSwitch:@"锁血" detail:@"Miss 按 Perfect 结算，不掉血" tag:PMRowLockHP on:PMLockHP];
    [self addSpeedRow];

    [self addSection:@"解锁"];
    [self addSwitch:@"全曲 / 全难度解锁" detail:@"写入 TrackUnlockStorage.UnlockAll" tag:PMRowUnlockAll on:PMUnlockAll];

    [self addSection:@"网络"];
    [self addSwitch:@"屏蔽成绩上传" detail:@"拦截 BackendAPI.ScoreUploadCoroutine，本地成绩仍保存" tag:PMRowBlockUpload on:PMBlockUpload];

    [self addSection:@"诊断"];
    gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, _y, self.view.bounds.size.width - 40, 96)];
    gStatusLabel.numberOfLines = 0;
    gStatusLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    [_scroll addSubview:gStatusLabel];
    _y += 100;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(20, _y, self.view.bounds.size.width - 40, 44);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    close.layer.cornerRadius = 12;
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:close];
    _y += 60;
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, _y);

    [self refreshStatus];
    gStatusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _scroll.frame = self.view.bounds;
}

- (void)onClose {
    [gStatusTimer invalidate];
    gStatusTimer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addHeader {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(20, 16, self.view.bounds.size.width - 40, 30)];
    t.text = @"ParadigmMod";
    t.font = [UIFont boldSystemFontOfSize:22];
    t.textColor = UIColor.whiteColor;
    [_scroll addSubview:t];
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(20, 46, self.view.bounds.size.width - 40, 20)];
    s.text = @"范式：起源 4.13 · 注入版";
    s.font = [UIFont systemFontOfSize:12];
    s.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    [_scroll addSubview:s];
    _y = 78;
}

- (void)addSection:(NSString *)title {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, _y, self.view.bounds.size.width - 40, 22)];
    l.text = title;
    l.font = [UIFont boldSystemFontOfSize:13];
    l.textColor = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1];
    [_scroll addSubview:l];
    _y += 26;
}

- (void)addSwitch:(NSString *)title detail:(NSString *)detail tag:(NSInteger)tag on:(BOOL)on {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(14, _y, self.view.bounds.size.width - 28, 62)];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    card.layer.cornerRadius = 12;
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, card.bounds.size.width - 80, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:15];
    t.textColor = UIColor.whiteColor;
    [card addSubview:t];

    UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(14, 30, card.bounds.size.width - 80, 22)];
    d.text = detail;
    d.font = [UIFont systemFontOfSize:11];
    d.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    d.numberOfLines = 2;
    [card addSubview:d];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(card.bounds.size.width - 66, 15, 51, 31)];
    sw.tag = tag;
    sw.on = on;
    [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];

    _y += 68;
}

- (void)addSpeedRow {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(14, _y, self.view.bounds.size.width - 28, 84)];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    card.layer.cornerRadius = 12;
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 200, 20)];
    t.text = @"谱面速度倍率";
    t.font = [UIFont systemFontOfSize:15];
    t.textColor = UIColor.whiteColor;
    [card addSubview:t];

    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(card.bounds.size.width - 80, 8, 60, 20)];
    v.text = [NSString stringWithFormat:@"%.2fx", PMSpeed];
    v.tag = 9001;
    v.textAlignment = NSTextAlignmentRight;
    v.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    v.textColor = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1];
    [card addSubview:v];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(14, 40, card.bounds.size.width - 28, 30)];
    sl.minimumValue = 0.5f;
    sl.maximumValue = 2.0f;
    sl.value = PMSpeed;
    sl.continuous = YES;
    [sl addTarget:self action:@selector(onSpeed:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:sl];

    _y += 90;
}

- (void)onSwitch:(UISwitch *)sw {
    BOOL v = sw.on;
    switch (sw.tag) {
        case PMRowAutoPlay:     PMAutoPlay = v;    break;
        case PMRowAllPerfect:   PMAllPerfect = v;  break;
        case PMRowLockHP:       PMLockHP = v;      break;
        case PMRowUnlockAll:    PMUnlockAll = v;   break;
        case PMRowBlockUpload:  PMBlockUpload = v; break;
    }
    [self persist];
    PMApplySettingsNow();
}

- (void)onSpeed:(UISlider *)sl {
    // 0.5x ~ 2.0x，1.0x 附近吸附
    float v = sl.value;
    if (fabsf(v - 1.0f) < 0.04f) v = 1.0f;
    PMSpeed = v;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.2fx", v];
    [self persist];
    PMApplySettingsNow();
}

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:PMAutoPlay forKey:@"pm.auto"];
    [d setBool:PMAllPerfect forKey:@"pm.ap"];
    [d setBool:PMLockHP forKey:@"pm.hp"];
    [d setBool:PMUnlockAll forKey:@"pm.unlock"];
    [d setBool:PMBlockUpload forKey:@"pm.block"];
    [d setFloat:PMSpeed forKey:@"pm.speed"];
}

- (void)refreshStatus {
    gStatusLabel.text = [NSString stringWithFormat:
        @"hook: %@   il2cpp: %@\nslots: %d   autoplay hits: %d\nunlockAll: %@   upload blocked: %d",
        PMHookReady ? @"OK" : @"FAILED",
        PMIl2CppReady ? @"OK" : @"N/A",
        PMLastSlotCount, PMAutoJudged,
        PMUnlockAllApplied ? @"on" : @"off",
        PMUploadBlocked];
}

@end

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
void PMShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
        }
        gWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gWindow.windowLevel = UIWindowLevelAlert + 1;
        gWindow.backgroundColor = UIColor.clearColor;

        UIViewController *root = [UIViewController new];
        root.view = [[PMPassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
        root.view.backgroundColor = UIColor.clearColor;
        gWindow.rootViewController = root;
        gWindow.hidden = NO;   // 不 makeKeyAndVisible

        PMBallView *ball = [[PMBallView alloc] initWithFrame:CGRectMake(24, 120, 52, 52)];
        [root.view addSubview:ball];
        PMLog(@"悬浮球已创建");
    });
}

void PMUpdateOverlay(void) {}
