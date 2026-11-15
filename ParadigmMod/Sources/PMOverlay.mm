//
//  ParadigmMod 设置页（仿游戏原生斜切风格）+ 悬浮球
//

#import "PMCommon.h"
#import <UIKit/UIKit.h>
#include <math.h>

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
    [self.on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.35] setFill];
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
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:0.9];
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
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint t = [g translationInView:nil];
    CGRect f = win.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect sb = UIScreen.mainScreen.bounds;
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
// 设置页
// ---------------------------------------------------------------------------
@interface PMSettingsController () <UITextFieldDelegate>
@end

@implementation PMSettingsController {
    UIScrollView *_scroll;
    CGFloat _y;
    NSInteger _tab;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PMBGColor();

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, self.view.bounds.size.width - 40, 30)];
    title.text = @"ParadigmMod";
    title.font = [UIFont italicSystemFontOfSize:23];
    title.textColor = UIColor.whiteColor;
    [self.view addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, self.view.bounds.size.width - 40, 18)];
    sub.text = @"范式：起源 4.13 · 注入版";
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    [self.view addSubview:sub];

    PMTabBar *tab = [[PMTabBar alloc] initWithFrame:CGRectMake(16, 76, self.view.bounds.size.width - 32, 40)];
    __weak typeof(self) weakSelf = self;
    tab.onSelect = ^(NSInteger index) { [weakSelf switchTab:index]; };
    [self.view addSubview:tab];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 124, self.view.bounds.size.width, self.view.bounds.size.height - 124)];
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

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)onKeyboard:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - kb.origin.y - 124);
    UIEdgeInsets inset = _scroll.contentInset;
    inset.bottom = (n.name == UIKeyboardWillHideNotification) ? 0 : overlap;
    _scroll.contentInset = inset;
    if (gActiveField) {
        CGRect r = [gActiveField convertRect:gActiveField.bounds toView:_scroll];
        [_scroll scrollRectToVisible:CGRectInset(r, 0, -40) animated:YES];
    }
}

- (void)switchTab:(NSInteger)index {
    if (_tab == index) return;
    _tab = index;
    [self rebuild];
}

- (void)rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    gStatusLabel = nil;
    _y = 6;

    switch (_tab) {
        case 0: [self buildGameplay]; break;
        case 1: [self buildUnlock]; break;
        case 2: [self buildProfile]; break;
        case 3: [self buildInterface]; break;
        default: [self buildDiagnostics]; break;
    }
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

    [self section:@"速度"];
    [self sliderRow:@"谱面速度倍率" value:PMSpeed min:0.5 max:2.0 action:@selector(onSpeed:)];
}

// ------------------------------ 解锁 ------------------------------
- (void)buildUnlock {
    [self section:@"本地解锁（不写存档 / 不上传）"];
    [self toggleRow:@"全曲 / 全难度" detail:@"写入 TrackUnlockStorage.UnlockAll"
                tag:PMRowUnlockAll on:PMUnlockAll];
    [self toggleRow:@"角色 / 皮肤 / 收藏 / 故事 / 称号 / 背景 / 挑战"
             detail:@"本地把各类 IsUnlocked 判为 true" tag:PMRowUnlockCollection on:PMUnlockCollection];
    [self toggleRow:@"付费曲包（本地）" detail:@"仅本地把 IsPurchased 判为 true"
                tag:PMRowPaidUnlock on:PMPaidUnlock];

    [self section:@"网络"];
    [self toggleRow:@"屏蔽成绩上传" detail:@"拦截 BackendAPI.ScoreUploadCoroutine，本地成绩仍保存"
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
    [self fieldRow:@"角色" key:@"characters" placeholder:@"例如 54/54"];
    [self fieldRow:@"皮肤" key:@"skins" placeholder:@"例如 92/92"];
    [self fieldRow:@"故事" key:@"stories" placeholder:@"例如 127/127"];
    [self fieldRow:@"称号" key:@"titles" placeholder:@"例如 853/853"];
    [self fieldRow:@"背景" key:@"backgrounds" placeholder:@"例如 232/232"];
    [self fieldRow:@"标题画面" key:@"titlescreens" placeholder:@"例如 20/20"];
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
    [self sliderRow:@"悬浮球透明度" value:PMBallAlpha min:0.2 max:1.0 action:@selector(onBallAlpha:)];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(22, _y, self.view.bounds.size.width - 44, 40)];
    tip.text = @"悬浮球可拖动；隐藏后轻触屏幕右边缘中部的小圆点即可再次打开设置。";
    tip.font = [UIFont systemFontOfSize:11];
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    tip.numberOfLines = 2;
    [_scroll addSubview:tip];
    _y += 46;
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
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(24, _y, self.view.bounds.size.width - 48, 20)];
    l.text = title;
    l.font = [UIFont boldSystemFontOfSize:12];
    l.textColor = PMAccentColor();
    [_scroll addSubview:l];
    _y += 26;
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
    PMCardView *card = [[PCardView alloc] initWithFrame:CGRectMake(14, _y, w, 78)];
    [_scroll addSubview:card];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 110, 20)];
    t.text = title;
    t.font = [UIFont systemFontOfSize:14];
    t.textColor = UIColor.whiteColor;
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
    PMCardView *card = [[PCardView alloc] initWithFrame:CGRectMake(14, _y, w, 48)];
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
        case PMRowUnlockCollection: PMUnlockCollection = on; break;
        case PMRowBlockUpload: PMBlockUpload = on; break;
        case PMRowProfileOn: PMProfileEnabled = on; break;
        case PMRowBallShow:
            PMBallVisible = on;
            PMUpdateBall();
            break;
        default: break;
    }
    [self persist];
    PMApplySettingsNow();
}

- (void)onSpeed:(UISlider *)sl {
    float v = sl.value;
    if (fabsf(v - 1.0f) < 0.04f) v = 1.0f;
    PMSpeed = v;
    UILabel *lab = [self.view viewWithTag:9001];
    lab.text = [NSString stringWithFormat:@"%.2f", v];
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
    [d setBool:PMUnlockAll forKey:@"pm.unlock"];
    [d setBool:PMPaidUnlock forKey:@"pm.paid"];
    [d setBool:PMUnlockCollection forKey:@"pm.coll"];
    [d setBool:PMBlockUpload forKey:@"pm.block"];
    [d setFloat:PMSpeed forKey:@"pm.speed"];
    [d setBool:PMProfileEnabled forKey:@"pm.profile.on"];
    [d setBool:PMBallVisible forKey:@"pm.ball.show"];
    [d setFloat:PMBallAlpha forKey:@"pm.ball.alpha"];
}

- (void)refreshStatus {
    if (!gStatusLabel) return;
    gStatusLabel.text = [NSString stringWithFormat:
        @"hook: %@   il2cpp: %@\nslots: %d   autoplay hits: %d\nunlockAll: %@   upload blocked: %d",
        PMHookReady ? @"OK" : @"FAILED",
        PMIl2CppReady ? @"OK" : @"N/A",
        PMLastSlotCount, PMAutoJudged,
        PMUnlockAllApplied ? @"on" : @"off",
        PMUploadBlocked];
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
    _text.text = PMLogTail(1000);
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
    UIActivityViewController *vc = [[UIActivityViewController alloc]
        initWithActivityItems:@[PMLogTail(0)] applicationActivities:nil];
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
        gPanelWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gPanelWindow.frame = UIScreen.mainScreen.bounds;
        gPanelWindow.windowLevel = UIWindowLevelAlert + 2;
        gPanelWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        PMSettingsController *vc = [PMSettingsController new];
        vc.onDismiss = ^{
            gPanelWindow.hidden = YES;
            gPanelWindow = nil;
        };
        gPanelWindow.rootViewController = vc;
        gPanelWindow.hidden = NO;
    });
}

void PMUpdateBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBallWindow) return;
        UIView *host = gBallWindow.rootViewController.view;
        for (UIView *v in host.subviews) [v removeFromSuperview];
        host.backgroundColor = UIColor.clearColor;

        CGRect sb = UIScreen.mainScreen.bounds;
        if (PMBallVisible) {
            CGFloat side = 56;
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            CGFloat x = [d objectForKey:@"pm.ball.x"] ? [d floatForKey:@"pm.ball.x"] : 24;
            CGFloat y = [d objectForKey:@"pm.ball.y"] ? [d floatForKey:@"pm.ball.y"] : 120;
            x = MAX(0, MIN(sb.size.width - side, x));
            y = MAX(24, MIN(sb.size.height - side - 24, y));
            gBallWindow.frame = CGRectMake(x, y, side, side);
            PMBallView *ball = [[PMBallView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            ball.alpha = MAX(0.2f, MIN(1.0f, PMBallAlpha));
            [gBallWindow.rootViewController.view addSubview:ball];
        } else {
            CGFloat side = 44;
            gBallWindow.frame = CGRectMake(sb.size.width - side, sb.size.height / 2 - side / 2, side, side);
            PMEdgeDotView *dot = [[PMEdgeDotView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
            [gBallWindow.rootViewController.view addSubview:dot];
        }
        gBallWindow.hidden = NO;
    });
}

void PMShowOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBallWindow) {
            UIWindowScene *scene = pm_active_scene();
            gBallWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                : [[UIWindow alloc] initWithFrame:CGRectMake(24, 120, 56, 56)];
            gBallWindow.windowLevel = UIWindowLevelAlert + 1;
            gBallWindow.backgroundColor = UIColor.clearColor;
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = UIColor.clearColor;
            gBallWindow.rootViewController = root;
            PMLog(@"悬浮球已创建");
        }
        PMUpdateBall();
    });
}
