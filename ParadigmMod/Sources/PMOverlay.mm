//
//  ParadigmMod 设置页（仿游戏原生斜切风格）+ 悬浮球
//

#import "PMCommon.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>

// ---------------------------------------------------------------------------
// 打歌时防止误触 iOS 边缘手势（上划回主屏 / 下拉控制中心）
// iOS 11+ 的做法：让 UIViewController 声明「边缘手势需要二次滑动」，
// 并隐藏 home indicator；这样第一次滑动只会出现小提示条，不会直接生效。
// ---------------------------------------------------------------------------
static UIRectEdge pm_vc_edges(id self, SEL _cmd) { return UIRectEdgeAll; }
static BOOL pm_vc_home_indicator(id self, SEL _cmd) { return YES; }

static void pm_install_gesture_guards(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class cls = [UIViewController class];
    Method m1 = class_getInstanceMethod(cls, NSSelectorFromString(@"preferredScreenEdgesDeferringSystemGestures"));
    if (m1) method_setImplementation(m1, (IMP)pm_vc_edges);
    Method m2 = class_getInstanceMethod(cls, NSSelectorFromString(@"prefersHomeIndicatorAutoHidden"));
    if (m2) method_setImplementation(m2, (IMP)pm_vc_home_indicator);
    PMLog(@"已启用边缘手势延迟（防划出屏幕 / 下拉控制中心）");
}

typedef NS_ENUM(NSInteger, PMRowTag) {
    PMRowAutoPlay = 100,
    PMRowAllPerfect,
    PMRowLockHP,
    PMRowUnlockAll,
    PMRowPaidUnlock,
    PMRowUnlockCollection,
    PMRowBlockUpload,
    PMRowProfileOn,
    PMRowBallShow,
    PMRowUnlockCharacter,
    PMRowUnlockSkin,
    PMRowUnlockRelic,
    PMRowUnlockStory,
    PMRowUnlockTitle,
    PMRowUnlockBg,
    PMRowUnlockChallenge,
    PMRowAutoHide,
    PMRowLifeBar,
};

@interface PMSettingsController : UIViewController
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@interface PMLogViewController : UIViewController
@end

static UIWindow *gBallWindow = nil;
static UIWindow *gPanelWindow = nil;
static UILabel *gStatusLabel = nil;
static NSTimer *gStatusTimer = nil;
static UITextField *gActiveField = nil;

static UIColor *PMBGColor(void) { return [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1]; }
static UIColor *PMAccentColor(void) { return [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1]; }

// ---------------------------------------------------------------------------
// 斜切路径（游戏 UI 的平行四边形风格）
// ---------------------------------------------------------------------------
static UIBezierPath *PMSlant(CGRect r, CGFloat ratio) {
    CGFloat cut = MIN(r.size.height * ratio, r.size.width * 0.4);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + cut, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - cut, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
    [p closePath];
    return p;
}

@interface PMCardView : UIView
@property (nonatomic, strong) UIColor *fillColor;
@end

@implementation PMCardView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.fillColor = [UIColor colorWithWhite:1 alpha:0.07];
    }
    return self;
}
- (void)setFillColor:(UIColor *)fillColor {
    _fillColor = fillColor;
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    [self.fillColor setFill];
    [PMSlant(self.bounds, 0.26) fill];
}
@end

// ---------------------------------------------------------------------------
// 斜切开关
// ---------------------------------------------------------------------------
@interface PMToggle : UIControl
@property (nonatomic, assign) BOOL on;
@end

@implementation PMToggle
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        [self addTarget:self action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)setOn:(BOOL)on {
    _on = on;
    [self setNeedsDisplay];
}
- (void)flip {
    self.on = !self.on;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)drawRect:(CGRect)rect {
    CGRect r = self.bounds;
    [PMSlant(CGRectInset(r, 0, r.size.height * 0.18), 0.26) addClip];
    [[UIColor colorWithWhite:0 alpha:0.45] setFill];
    UIRectFill(r);
    CGRect knob = CGRectMake(self.on ? r.size.width * 0.52 : 0, r.size.height * 0.18,
                             r.size.width * 0.48, r.size.height * 0.64);
    UIColor *knobColor = self.on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.35];
    [knobColor setFill];
    [PMSlant(knob, 0.26) fill];
    NSString *t = self.on ? @"ON" : @"OFF";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    UIColor *tc = self.on ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.75];
    [t drawInRect:CGRectInset(r, 0, r.size.height * 0.22)
        withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:11],
                         NSForegroundColorAttributeName:tc,
                         NSParagraphStyleAttributeName:ps}];
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}
@end

// ---------------------------------------------------------------------------
// 斜切分类栏
// ---------------------------------------------------------------------------
@interface PMTabBar : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic, assign) NSInteger selectedIndex;
@end

@implementation PMTabBar {
    NSArray<UIButton *> *_buttons;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        NSArray *names = @[@"玩法", @"解锁", @"资料", @"界面", @"诊断"];
        NSMutableArray *bs = [NSMutableArray array];
        for (NSInteger i = 0; i < names.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = i;
            b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            [b setTitle:names[i] forState:UIControlStateNormal];
            [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            [bs addObject:b];
        }
        _buttons = bs;
        self.selectedIndex = 0;
    }
    return self;
}
- (void)setSelectedIndex:(NSInteger)index {
    _selectedIndex = index;
    for (UIButton *b in _buttons) {
        BOOL sel = (b.tag == index);
        [b setTitleColor:sel ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.8]
                 forState:UIControlStateNormal];
    }
    [self setNeedsDisplay];
}
- (void)onTap:(UIButton *)sender {
    self.selectedIndex = sender.tag;
    if (self.onSelect) self.onSelect(sender.tag);
}
- (void)drawRect:(CGRect)rect {
    CGFloat cut = 40 * 0.26;
    CGFloat slot = (self.bounds.size.width - cut) / MAX(1, _buttons.count);
    [[UIColor colorWithWhite:0 alpha:0.45] setFill];
    [PMSlant(CGRectMake(0, 3, self.bounds.size.width, 34), 0.26) fill];
    [UIColor.whiteColor setFill];
    [PMSlant(CGRectMake(slot * self.selectedIndex, 0, slot + cut, 40), 0.26) fill];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cut = 40 * 0.26;
    CGFloat slot = (self.bounds.size.width - cut) / MAX(1, _buttons.count);
    for (NSInteger i = 0; i < _buttons.count; i++) {
        _buttons[i].frame = CGRectMake(i * slot + cut / 2, 0, slot, 40);
    }
}
@end

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------
static void pm_open_panel(void);

@interface PMBallView : UIView
@end

@implementation PMBallView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CGFloat side = frame.size.width;
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = side / 2;
        self.layer.masksToBounds = NO;
        self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.30;
        self.layer.shadowRadius = 7;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = self.bounds;
        g.cornerRadius = side / 2;
        g.colors = @[(id)[UIColor colorWithRed:0.42 green:0.82 blue:1.0 alpha:0.96].CGColor,
                     (id)[UIColor colorWithRed:0.13 green:0.44 blue:0.92 alpha:0.96].CGColor];
        g.startPoint = CGPointMake(0.15, 0.0);
        g.endPoint = CGPointMake(0.9, 1.0);
        [self.layer addSublayer:g];

        CAGradientLayer *shine = [CAGradientLayer layer];
        shine.frame = CGRectMake(side * 0.10, side * 0.05, side * 0.80, side * 0.42);
        shine.cornerRadius = side * 0.21;
        shine.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.35].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
        shine.startPoint = CGPointMake(0.5, 0.0);
        shine.endPoint = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:shine];

        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"M";
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:side * 0.44 weight:UIFontWeightSemibold];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.96];
        l.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
        l.layer.shadowOpacity = 1;
        l.layer.shadowRadius = 1.5;
        l.layer.shadowOffset = CGSizeZero;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    }
    return self;
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint t = [g translationInView:nil];
    CGRect f = win.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect sb = win.windowScene ? win.windowScene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(sb.size.width - f.size.width, f.origin.x));
    f.origin.y = MAX(24, MIN(sb.size.height - f.size.height - 24, f.origin.y));
    win.frame = f;
    [g setTranslation:CGPointZero inView:nil];
    if (g.state == UIGestureRecognizerStateEnded) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setFloat:f.origin.x forKey:@"pm.ball.x"];
        [d setFloat:f.origin.y forKey:@"pm.ball.y"];
    }
}
- (void)onTap { pm_open_panel(); }
@end

// 隐藏悬浮球后，屏幕右缘的小热区
@interface PMEdgeDotView : UIView
@end

@implementation PMEdgeDotView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - 14, frame.size.height / 2 - 5, 10, 10)];
        dot.backgroundColor = PMAccentColor();
        dot.alpha = 0.28;
        dot.layer.cornerRadius = 5;
        dot.userInteractionEnabled = NO;
        [self addSubview:dot];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
    }
    return self;
}
- (void)onTap { pm_open_panel(); }
@end

static UIWindowScene *pm_active_scene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// 官方设置页里的 MOD 入口（检测到设置面板时显示）
// ---------------------------------------------------------------------------
static UIWindow *gEntryWindow = nil;

@interface PMEntryButton : UIControl
@end

@implementation PMEntryButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        [self addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)onTap { pm_open_panel(); }
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}
- (void)drawRect:(CGRect)rect {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentLeft;
    NSDictionary *attrs = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:16],
                            NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:0.92],
                            NSParagraphStyleAttributeName:ps};
    [@"Mod设置" drawInRect:CGRectMake(6, (self.bounds.size.height - 22) / 2, self.bounds.size.width - 12, 22)
            withAttributes:attrs];
}
@end

@interface PMEntryHitView : UIControl
@end

@implementation PMEntryHitView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        [self addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)onTap { pm_open_panel(); }
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1.0;
}
@end

static void pm_prepare_entry_window(CGRect f) {
    UIWindowScene *scene = pm_active_scene();
    if (!gEntryWindow) {
        gEntryWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:f];
        gEntryWindow.windowLevel = UIWindowLevelAlert + 1;
        gEntryWindow.backgroundColor = UIColor.clearColor;
        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = UIColor.clearColor;
        gEntryWindow.rootViewController = root;
    }
    gEntryWindow.frame = f;
    UIView *host = gEntryWindow.rootViewController.view;
    for (UIView *v in host.subviews) [v removeFromSuperview];
    host.backgroundColor = UIColor.clearColor;
}

// 官方侧栏里的「Mod设置」已经由 Unity 克隆出来，这里只铺一层透明点击区
void PMSetModEntryRect(CGRect screenRect) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = pm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        CGFloat uy = sb.size.height - (screenRect.origin.y + screenRect.size.height);
        CGRect f = CGRectMake(screenRect.origin.x,
                              uy,
                              MAX(80, screenRect.size.width),
                              MAX(36, screenRect.size.height));
        pm_prepare_entry_window(f);
        PMEntryHitView *hit = [[PMEntryHitView alloc] initWithFrame:CGRectMake(0, 0, f.size.width, f.size.height)];
        [gEntryWindow.rootViewController.view addSubview:hit];
        gEntryWindow.hidden = NO;
    });
}

void PMSetModEntryVisible(bool visible) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!visible) {
            gEntryWindow.hidden = YES;
            return;
        }
        UIWindowScene *scene = pm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        CGFloat w = sb.size.width * 0.30;
        CGFloat h = 44;
        CGFloat x = sb.size.width * 0.115;
        CGFloat y = sb.size.height * 0.665;
        CGRect f = CGRectMake(x, y, w, h);
        pm_prepare_entry_window(f);
        PMEntryButton *b = [[PMEntryButton alloc] initWithFrame:CGRectMake(0, 0, f.size.width, f.size.height)];
        [gEntryWindow.rootViewController.view addSubview:b];
        gEntryWindow.hidden = NO;
    });
}

// ---------------------------------------------------------------------------
// 设置页
// ---------------------------------------------------------------------------
@interface PMSettingsController () <UITextFieldDelegate>
@end

@implementation PMSettingsController {
    UIScrollView *_scroll;
    UIButton *_closeButton;
    CGFloat _y;
}

- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PMBGColor();

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 14, self.view.bounds.size.width - 90, 28)];
    title.text = @"ParadigmMod";
    title.font = [UIFont italicSystemFontOfSize:22];
    title.textColor = UIColor.whiteColor;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, self.view.bounds.size.width - 90, 16)];
    sub.text = @"范式：起源 4.13 · 注入版";
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:sub];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.9] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    _closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _closeButton.layer.cornerRadius = 20;
    _closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_closeButton addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 72, self.view.bounds.size.width, self.view.bounds.size.height - 72)];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_scroll];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onKeyboard:)
                                               name:UIKeyboardWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onKeyboard:)
                                               name:UIKeyboardWillHideNotification object:nil];

    [self rebuild];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    _closeButton.frame = CGRectMake(w - 22 - 40, 14, 40, 40);
    _scroll.frame = CGRectMake(0, 72, w, h - 72);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)onKeyboard:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - kb.origin.y - 106);
    UIEdgeInsets inset = _scroll.contentInset;
    inset.bottom = (n.name == UIKeyboardWillHideNotification) ? 0 : overlap;
    _scroll.contentInset = inset;
    if (gActiveField) {
        CGRect r = [gActiveField convertRect:gActiveField.bounds toView:_scroll];
        [_scroll scrollRectToVisible:CGRectInset(r, 0, -40) animated:YES];
    }
}

- (void)rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    gStatusLabel = nil;
    _y = 6;

    [self buildGameplay];
    [self buildUnlock];
    [self buildProfile];
    [self buildInterface];
    [self buildDiagnostics];
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, _y + 24);
}

// ------------------------------ 玩法 ------------------------------
- (void)buildGameplay {
    [self section:@"判定"];
    [self toggleRow:@"AutoPlay 自动打歌" detail:@"按判定时间自动命中所有音符"
                tag:PMRowAutoPlay on:PMAutoPlay];
    [self toggleRow:@"全 Perfect" detail:@"Good / Miss 强制按 Perfect 结算"
                tag:PMRowAllPerfect on:PMAllPerfect];
    [self toggleRow:@"锁血" detail:@"Miss 不掉血" tag:PMRowLockHP on:PMLockHP];
    [self toggleRow:@"显示血条（保持满血）" detail:@"关掉则完全不显示两侧血条"
                tag:PMRowLifeBar on:PMShowLifeBar];
}

// ------------------------------ 解锁 ------------------------------
- (void)buildUnlock {
    [self section:@"本地解锁（不写存档 / 不上传）"];
    [self toggleRow:@"全部解锁" detail:@"一键开启下面所有项"
                tag:PMRowUnlockCollection on:PMUnlockCollection];
    [self toggleRow:@"全曲 / 全难度" detail:@"TrackUnlockStorage.UnlockAll"
                tag:PMRowUnlockAll on:PMUnlockAll];
    [self toggleRow:@"角色" detail:@"IsCharacterUnlocked 本地放行"
                tag:PMRowUnlockCharacter on:PMUnlockCharacters];
    [self toggleRow:@"皮肤" detail:@"SkinUnlockStorage.UnlockAll"
                tag:PMRowUnlockSkin on:PMUnlockSkins];
    [self toggleRow:@"收藏品" detail:@"IsRelicUnlocked 本地放行"
                tag:PMRowUnlockRelic on:PMUnlockRelics];
    [self toggleRow:@"故事" detail:@"StoryUnlockStorage.UnlockAll"
                tag:PMRowUnlockStory on:PMUnlockStories];
    [self toggleRow:@"称号" detail:@"IsAchievementUnlocked 本地放行"
                tag:PMRowUnlockTitle on:PMUnlockTitles];
    [self toggleRow:@"背景" detail:@"DictStorage.UnlockAll + 成就背景放行"
                tag:PMRowUnlockBg on:PMUnlockBackgrounds];
    [self toggleRow:@"挑战" detail:@"IsChallengeUnlocked 本地放行"
                tag:PMRowUnlockChallenge on:PMUnlockChallenges];

    [self section:@"网络"];
    [self toggleRow:@"屏蔽成绩上传" detail:@"本地拦截 /play/upload 请求，成绩只留本机"
                tag:PMRowBlockUpload on:PMBlockUpload];
}

// ------------------------------ 资料 ------------------------------
- (void)buildProfile {
    [self section:@"个人资料（仅本地显示）"];
    [self toggleRow:@"启用资料修改" detail:@"只改界面显示，不改存档、不上传服务器"
                tag:PMRowProfileOn on:PMProfileEnabled];

    [self section:@"数值（留空 = 游戏原值）"];
    [self fieldRow:@"ID" key:@"id" placeholder:@"原 ID"];
    [self fieldRow:@"等级" key:@"level" placeholder:@"例如 99"];
    [self fieldRow:@"Rating" key:@"rating" placeholder:@"例如 16.00"];
    [self fieldRow:@"曲目数" key:@"tracks" placeholder:@"例如 441"];
    [self fieldRow:@"谱面数" key:@"charts" placeholder:@"例如 1371"];
    [self fieldRow:@"游玩次数" key:@"playcount" placeholder:@"例如 9999"];
    [self fieldRow:@"总时长" key:@"playtime" placeholder:@"例如 999:59:59"];
    [self fieldRow:@"总分" key:@"totalscore" placeholder:@"例如 99999999"];
    [self fieldRow:@"完美解析数" key:@"note" placeholder:@"例如 999999"];
    [self fieldRow:@"各难度计数" key:@"grades" placeholder:@"例如 999"];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, self.view.bounds.size.width - 44, 34)];
    tip.text = @"仅影响本机显示；游戏内的实际成绩、排行与云端数据不会改变。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 40;
}

// ------------------------------ 界面 ------------------------------
- (void)buildInterface {
    [self section:@"悬浮球"];
    [self toggleRow:@"显示悬浮球" detail:@"关闭后隐藏，可在屏幕右缘小圆点重新呼出"
                tag:PMRowBallShow on:PMBallVisible];
    [self toggleRow:@"游玩时自动隐藏" detail:@"进入打歌界面自动收起，避免误触"
                tag:PMRowAutoHide on:PMAutoHideInGame];
    [self sliderRow:@"悬浮球透明度" value:PMBallAlpha min:0.2 max:1.0 action:@selector(onBallAlpha:)];
    [self sliderRow:[NSString stringWithFormat:@"悬浮球大小 %.0f", PMBallSize]
              value:PMBallSize min:40 max:96 action:@selector(onBallSize:)];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, self.view.bounds.size.width - 44, 40)];
    tip.text = @"悬浮球可拖动；隐藏后轻触屏幕右边缘中部的小圆点即可再次打开设置。游玩时会自动收起。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 46;

    [self section:@"声音"];
    [self sliderRow:[NSString stringWithFormat:@"打击音量 %.0f%%", PMHitVolumeBoost * 100]
              value:PMHitVolumeBoost min:1.0 max:1.5 action:@selector(onHitBoost:)];
}

// ------------------------------ 诊断 ------------------------------
- (void)buildDiagnostics {
    [self section:@"状态"];
    gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, self.view.bounds.size.width - 44, 96)];
    gStatusLabel.numberOfLines = 0;
    gStatusLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    [_scroll addSubview:gStatusLabel];
    _y += 100;

    [self buttonRow:@"查看运行日志" action:@selector(onShowLog)];
    [self buttonRow:@"关闭" action:@selector(onClose)];
}

// ------------------------------ 通用行 ------------------------------
- (void)section:(NSString *)title {
    CGFloat w = self.view.bounds.size.width - 28;
    PMCardView *board = [[PMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 30)];
    board.fillColor = [UIColor colorWithWhite:1 alpha:0.11];
    [_scroll addSubview:board];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(30, 5, w - 60, 20)];
    l.text = title;
    l.font = [UIFont boldSystemFontOfSize:13];
    l.textColor = UIColor.whiteColor;
    [board addSubview:l];
    _y += 36;
}

- (void)toggleRow:(NSString *)title detail:(NSString *)detail tag:(NSInteger)tag on:(BOOL)on {
    CGFloat w = self.view.bounds.size.width - 28;
    PMCardView *card = [[PMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 60)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 110, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14];
    t.textColor = UIColor.whiteColor;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.8;
    [card addSubview:t];

    UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(16, 29, w - 110, 20)];
    d.text = detail;
    d.font = [UIFont systemFontOfSize:10];
    d.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    d.adjustsFontSizeToFitWidth = YES;
    d.minimumScaleFactor = 0.8;
    [card addSubview:d];

    PMToggle *sw = [[PMToggle alloc] initWithFrame:CGRectMake(w - 84, 14, 70, 32)];
    sw.tag = tag;
    sw.on = on;
    [sw addTarget:self action:@selector(onToggle:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];

    _y += 66;
}

- (void)sliderRow:(NSString *)title value:(CGFloat)value min:(CGFloat)mn max:(CGFloat)mx action:(SEL)action {
    CGFloat w = self.view.bounds.size.width - 28;
    PMCardView *card = [[PMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 78)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 110, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14];
    t.textColor = UIColor.whiteColor;
    t.tag = 9102;
    [card addSubview:t];

    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(w - 96, 8, 80, 20)];
    v.text = [NSString stringWithFormat:@"%.2f", value];
    v.tag = 9001;
    v.textAlignment = NSTextAlignmentRight;
    v.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    v.textColor = PMAccentColor();
    [card addSubview:v];

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, 36, w - 32, 30)];
    sl.minimumValue = mn;
    sl.maximumValue = mx;
    sl.value = value;
    sl.continuous = YES;
    sl.minimumTrackTintColor = PMAccentColor();
    [sl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:sl];

    _y += 84;
}

- (void)fieldRow:(NSString *)title key:(NSString *)key placeholder:(NSString *)placeholder {
    CGFloat w = self.view.bounds.size.width - 28;
    PMCardView *card = [[PMCardView alloc] initWithFrame:CGRectMake(14, _y, w, 48)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 96, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:13];
    t.textColor = UIColor.whiteColor;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.75;
    [card addSubview:t];

    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(112, 9, w - 128, 30)];
    f.text = PMProfileValue(key) ?: @"";
    f.placeholder = placeholder;
    f.textAlignment = NSTextAlignmentRight;
    f.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    f.textColor = PMAccentColor();
    f.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder
            attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:0.22],
                         NSFontAttributeName:[UIFont systemFontOfSize:12]}];
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.returnKeyType = UIReturnKeyDone;
    f.accessibilityIdentifier = key;
    f.delegate = self;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    f.layer.cornerRadius = 6;
    f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 30)];
    f.leftViewMode = UITextFieldViewModeAlways;
    [f addTarget:self action:@selector(onFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [card addSubview:f];

    _y += 54;
}

- (void)buttonRow:(NSString *)title action:(SEL)action {
    CGFloat w = self.view.bounds.size.width - 28;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(14, _y, w, 44);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    _y += 50;
}

// ------------------------------ 事件 ------------------------------
- (void)onToggle:(PMToggle *)sender {
    BOOL on = sender.on;
    switch (sender.tag) {
        case PMRowAutoPlay: PMAutoPlay = on; break;
        case PMRowAllPerfect: PMAllPerfect = on; break;
        case PMRowLockHP: PMLockHP = on; break;
        case PMRowUnlockAll: PMUnlockAll = on; break;
        case PMRowPaidUnlock: PMPaidUnlock = on; break;
        case PMRowUnlockCollection:
            PMUnlockCollection = on;
            PMUnlockCharacters = on;
            PMUnlockSkins = on;
            PMUnlockRelics = on;
            PMUnlockStories = on;
            PMUnlockTitles = on;
            PMUnlockBackgrounds = on;
            PMUnlockChallenges = on;
            [self rebuild];
            break;
        case PMRowUnlockCharacter: PMUnlockCharacters = on; break;
        case PMRowUnlockSkin: PMUnlockSkins = on; break;
        case PMRowUnlockRelic: PMUnlockRelics = on; break;
        case PMRowUnlockStory: PMUnlockStories = on; break;
        case PMRowUnlockTitle: PMUnlockTitles = on; break;
        case PMRowUnlockBg: PMUnlockBackgrounds = on; break;
        case PMRowUnlockChallenge: PMUnlockChallenges = on; break;
        case PMRowBlockUpload: PMBlockUpload = on; break;
        case PMRowProfileOn: PMProfileEnabled = on; break;
        case PMRowAutoHide:
            PMAutoHideInGame = on;
            PMUpdateBall();
            break;
        case PMRowLifeBar:
            PMShowLifeBar = on;
            break;
        case PMRowBallShow:
            PMBallVisible = on;
            PMUpdateBall();
            break;
        default: break;
    }
    if (sender.tag >= PMRowUnlockCharacter && sender.tag <= PMRowUnlockChallenge) {
        PMUnlockCollection = PMUnlockCharacters && PMUnlockSkins && PMUnlockRelics &&
                             PMUnlockStories && PMUnlockTitles && PMUnlockBackgrounds &&
                             PMUnlockChallenges;
    }
    [self persist];
    PMApplySettingsNow();
}

- (void)onHitBoost:(UISlider *)sl {
    float v = sl.value;
    if (v < 1.005f) v = 1.0f;
    PMHitVolumeBoost = v;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.2f", v];
    UILabel *title = [sl.superview viewWithTag:9102];
    title.text = [NSString stringWithFormat:@"打击音量 %.0f%%", v * 100];
    [self persist];
    PMApplySettingsNow();
}

- (void)onBallAlpha:(UISlider *)sl {
    PMBallAlpha = sl.value;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.2f", sl.value];
    [self persist];
    PMUpdateBall();
}

- (void)onBallSize:(UISlider *)sl {
    PMBallSize = sl.value;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.0f", sl.value];
    UILabel *title = [sl.superview viewWithTag:9102];
    title.text = [NSString stringWithFormat:@"悬浮球大小 %.0f", sl.value];
    [self persist];
    PMUpdateBall();
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    gActiveField = textField;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    gActiveField = nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)onFieldChanged:(UITextField *)f {
    NSString *key = f.accessibilityIdentifier;
    if (!key.length) return;
    if (!PMProfileText) PMProfileText = [NSMutableDictionary dictionary];
    NSString *v = [f.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (v.length) {
        PMProfileText[key] = v;
        [NSUserDefaults.standardUserDefaults setObject:v forKey:[@"pm.profile." stringByAppendingString:key]];
    } else {
        [PMProfileText removeObjectForKey:key];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:[@"pm.profile." stringByAppendingString:key]];
    }
}

- (void)persist {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:PMAutoPlay forKey:@"pm.auto"];
    [d setBool:PMAllPerfect forKey:@"pm.ap"];
    [d setBool:PMLockHP forKey:@"pm.hp"];
    [d setBool:PMShowLifeBar forKey:@"pm.hp.bar"];
    [d setBool:PMUnlockAll forKey:@"pm.unlock"];
    [d setBool:PMPaidUnlock forKey:@"pm.paid"];
    [d setBool:PMUnlockCollection forKey:@"pm.coll"];
    [d setBool:PMUnlockCharacters forKey:@"pm.coll.char"];
    [d setBool:PMUnlockSkins forKey:@"pm.coll.skin"];
    [d setBool:PMUnlockRelics forKey:@"pm.coll.relic"];
    [d setBool:PMUnlockStories forKey:@"pm.coll.story"];
    [d setBool:PMUnlockTitles forKey:@"pm.coll.title"];
    [d setBool:PMUnlockBackgrounds forKey:@"pm.coll.bg"];
    [d setBool:PMUnlockChallenges forKey:@"pm.coll.challenge"];
    [d setBool:PMBlockUpload forKey:@"pm.block"];
    [d setBool:PMProfileEnabled forKey:@"pm.profile.on"];
    [d setBool:PMBallVisible forKey:@"pm.ball.show"];
    [d setBool:PMAutoHideInGame forKey:@"pm.ball.auto"];
    [d setFloat:PMBallAlpha forKey:@"pm.ball.alpha"];
    [d setFloat:PMBallSize forKey:@"pm.ball.size"];
    [d setFloat:PMHitVolumeBoost forKey:@"pm.hitvol"];
}

- (void)refreshStatus {
    if (!gStatusLabel) return;
    gStatusLabel.text = [NSString stringWithFormat:
        @"模式: 轮询（不改代码）   il2cpp: %@\nslots: %d   autoplay hits: %d\nunlockAll: %@",
        PMIl2CppReady ? @"OK" : @"N/A",
        PMLastSlotCount, PMAutoJudged,
        PMUnlockAllApplied ? @"on" : @"off"];
}

- (void)onShowLog {
    [self presentViewController:[PMLogViewController new] animated:YES completion:nil];
}

- (void)onClose {
    [gStatusTimer invalidate];
    gStatusTimer = nil;
    if (self.onDismiss) self.onDismiss();
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [gStatusTimer invalidate];
    gStatusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                  selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

@end

// ---------------------------------------------------------------------------
// 日志查看页
// ---------------------------------------------------------------------------
@implementation PMLogViewController {
    UITextView *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, w - 40, 28)];
    title.text = @"运行日志";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = UIColor.whiteColor;
    [self.view addSubview:title];

    _text = [[UITextView alloc] initWithFrame:CGRectMake(12, 84, w - 24, h - 200)];
    _text.editable = NO;
    _text.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    _text.layer.cornerRadius = 10;
    _text.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    _text.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _text.text = PMLogTail(400);
    [self.view addSubview:_text];

    CGFloat by = h - 104;
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(12, by, (w - 36) / 3, 42);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    clear.layer.cornerRadius = 10;
    [clear addTarget:self action:@selector(onClear) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    share.frame = CGRectMake(24 + (w - 36) / 3, by, (w - 36) / 3, 42);
    [share setTitle:@"分享" forState:UIControlStateNormal];
    share.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    share.layer.cornerRadius = 10;
    [share addTarget:self action:@selector(onShare:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:share];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(36 + 2 * (w - 36) / 3, by, (w - 36) / 3, 42);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    close.layer.cornerRadius = 10;
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}

- (void)onClear {
    PMLogClear();
    _text.text = @"(已清空)";
}

- (void)onShare:(UIButton *)sender {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [dirs.firstObject stringByAppendingPathComponent:@"ParadigmMod.log"];
    id item = [NSFileManager.defaultManager fileExistsAtPath:path]
                  ? [NSURL fileURLWithPath:path]
                  : (id)PMLogTail(0);
    UIActivityViewController *vc = [[UIActivityViewController alloc]
        initWithActivityItems:@[item] applicationActivities:nil];
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = sender;
        vc.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
static void pm_open_panel(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanelWindow) return;
        UIWindowScene *scene = pm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        gPanelWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:sb];
        gPanelWindow.frame = sb;
        gPanelWindow.windowLevel = UIWindowLevelAlert + 2;
        gPanelWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        PMSettingsController *vc = [PMSettingsController new];
        vc.onDismiss = ^{
            gPanelWindow.hidden = YES;
            gPanelWindow = nil;
            PMUpdateBall();
        };
        gPanelWindow.rootViewController = vc;
        gPanelWindow.hidden = NO;
        [UIViewController attemptRotationToDeviceOrientation];
    });
}

static int gBallMode = -1;   // -1 未渲染, 0 隐藏, 1 悬浮球, 2 边缘小点

@interface PMBallTicker : NSObject
+ (instancetype)shared;
@end

static BOOL pm_in_gameplay(void) {
    return (CFAbsoluteTimeGetCurrent() - PMLastGameplayTick) < 2.0;
}

static int pm_desired_ball_mode(void) {
    if (PMBallHidden) return 0;
    BOOL autoHide = PMAutoHideInGame && pm_in_gameplay();
    if (autoHide) return 0;
    return PMBallVisible ? 1 : 2;
}

void PMUpdateBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBallWindow) return;
        UIView *host = gBallWindow.rootViewController.view;
        for (UIView *v in host.subviews) [v removeFromSuperview];
        host.backgroundColor = UIColor.clearColor;

        int mode = pm_desired_ball_mode();
        gBallMode = mode;
        if (mode == 0) {
            gBallWindow.hidden = YES;
            return;
        }

        UIWindowScene *scene = pm_active_scene();
        CGRect sb = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
        if (mode == 1) {
            CGFloat side = MAX(40.0f, MIN(96.0f, PMBallSize));
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            CGFloat x = [d objectForKey:@"pm.ball.x"] ? [d floatForKey:@"pm.ball.x"] : 24;
            CGFloat y = [d objectForKey:@"pm.ball.y"] ? [d floatForKey:@"pm.ball.y"] : 64;
            x = MAX(0, MIN(sb.size.width - side, x));
            y = MAX(24, MIN(sb.size.height - side - 24, y));
            gBallWindow.frame = CGRectMake(x, y, side, side);
            PMBallView *ball = [[PMBallView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            ball.alpha = MAX(0.2f, MIN(1.0f, PMBallAlpha));
            [host addSubview:ball];
        } else {
            CGFloat side = 32;
            gBallWindow.frame = CGRectMake(sb.size.width - side, sb.size.height / 2 - side / 2, side, side);
            PMEdgeDotView *dot = [[PMEdgeDotView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            [host addSubview:dot];
        }
        gBallWindow.hidden = NO;
    });
}

// 游玩时自动收起悬浮球 / 小点，避免误触
static void pm_ball_tick(void) {
    if (!gBallWindow) return;
    if (gBallMode != pm_desired_ball_mode()) PMUpdateBall();
}

void PMShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static BOOL timerStarted = NO;
        if (!gBallWindow) {
            UIWindowScene *scene = pm_active_scene();
            gBallWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                : [[UIWindow alloc] initWithFrame:CGRectMake(24, 64, 56, 56)];
            gBallWindow.windowLevel = UIWindowLevelAlert + 1;
            gBallWindow.backgroundColor = UIColor.clearColor;
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = UIColor.clearColor;
            gBallWindow.rootViewController = root;
            PMLog(@"悬浮球已创建");
        }
        pm_install_gesture_guards();
        PMUpdateBall();
        if (!timerStarted) {
            timerStarted = YES;
            [NSTimer scheduledTimerWithTimeInterval:1.0 target:[PMBallTicker shared]
                                           selector:@selector(tick) userInfo:nil repeats:YES];
        }
    });
}

@implementation PMBallTicker
+ (instancetype)shared {
    static PMBallTicker *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [PMBallTicker new]; });
    return t;
}
- (void)tick { pm_ball_tick(); }
@end

#pragma mark - 官方「Mod设置」里的修改行

static UIViewController *pm_top_vc(void) {
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

void PMPromptForModValue(NSString *key) {
    if (!key.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *title = nil, *cur = @"", *hint = @"";
        BOOL isProfile = YES;
        if ([key isEqualToString:@"level"]) {
            title = @"等级"; cur = PMProfileValue(@"level") ?: @""; hint = @"主界面显示为 Lv.，建议 1-999";
        } else if ([key isEqualToString:@"rating"]) {
            title = @"Rating"; cur = PMProfileValue(@"rating") ?: @""; hint = @"例如 900 或 900.50，范围 0-9999";
        } else if ([key isEqualToString:@"playcount"]) {
            title = @"游玩次数"; cur = PMProfileValue(@"playcount") ?: @""; hint = @"0-999999";
        } else if ([key isEqualToString:@"playtime"]) {
            title = @"总游玩时间（小时）"; cur = PMProfileValue(@"playtime") ?: @""; hint = @"例如 120";
        } else if ([key isEqualToString:@"totalscore"]) {
            title = @"总分数"; cur = PMProfileValue(@"totalscore") ?: @""; hint = @"0-999999999";
        } else if ([key isEqualToString:@"ballsize"]) {
            title = @"悬浮球大小"; cur = [NSString stringWithFormat:@"%.0f", PMBallSize]; hint = @"24-96"; isProfile = NO;
        } else if ([key isEqualToString:@"ballalpha"]) {
            title = @"悬浮球透明度"; cur = [NSString stringWithFormat:@"%.2f", PMBallAlpha]; hint = @"0.2-1.0"; isProfile = NO;
        }
        if (!title) return;
        UIViewController *vc = pm_top_vc();
        if (!vc) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:hint
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.keyboardType = UIKeyboardTypeDecimalPad;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *t = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceCharacterSet];
            if (!t.length) return;
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            if (isProfile) {
                if (!PMProfileText) PMProfileText = [NSMutableDictionary dictionary];
                PMProfileText[key] = t;
                PMProfileEnabled = YES;
                [d setObject:t forKey:[@"pm.profile." stringByAppendingString:key]];
                [d setBool:YES forKey:@"pm.profile.on"];
            } else if ([key isEqualToString:@"ballsize"]) {
                float v = MAX(24.0f, MIN(96.0f, t.floatValue));
                PMBallSize = v;
                [d setFloat:v forKey:@"pm.ball.size"];
                PMUpdateBall();
            } else {
                float v = MAX(0.2f, MIN(1.0f, t.floatValue));
                PMBallAlpha = v;
                [d setFloat:v forKey:@"pm.ball.alpha"];
                PMUpdateBall();
            }
            PMLog(@"Mod设置: %@ = %@", key, t);
        }]];
        [vc presentViewController:ac animated:YES completion:nil];
    });
}
