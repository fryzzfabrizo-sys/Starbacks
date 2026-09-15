#import "ModMenuViewController.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "../esp/drawing_view/menu.h"
#import "../mahoa.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const CGFloat kHeaderHeight = 62.0f;
static const CGFloat kRowHeight = 40.0f;
static const CGFloat kScrollBarWidth = 3.0f;
static const CGFloat kCheckboxSize = 18.0f;
static const CGFloat kCornerRadius = 18.0f;

static UIColor *SBColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static UIColor *SBAccent(void) { return SBColor(0.32f, 0.88f, 0.94f, 1.0f); }
static UIColor *SBAccentDim(void) { return SBColor(0.14f, 0.52f, 0.60f, 1.0f); }
static UIColor *SBText(void) { return SBColor(0.94f, 0.98f, 1.0f, 1.0f); }
static UIColor *SBMuted(void) { return SBColor(0.62f, 0.70f, 0.75f, 1.0f); }
static UIColor *SBBorder(void) { return SBColor(0.55f, 0.76f, 0.80f, 0.16f); }
static UIColor *SBPanel(void) { return SBColor(0.035f, 0.055f, 0.075f, 0.94f); }
static UIColor *SBCard(void) { return SBColor(0.075f, 0.105f, 0.13f, 0.74f); }

static const NSInteger kSegmentTrackTag = 9101;
static const NSInteger kSegmentLabelTag = 9201;

typedef NS_ENUM(NSInteger, MenuTab) {
    MenuTabESP = 0,
    MenuTabAimbot = 1,
    MenuTabMemory = 2,
    MenuTabInfo = 3
};

@interface ModMenuViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, assign) MenuTab currentTab;
@property (nonatomic, strong) UIView *floatingPanel;
@property (nonatomic, strong) UIView *panelSurface;
@property (nonatomic, assign) CGFloat panelWidth;
@property (nonatomic, assign) CGFloat panelHeight;
@property (nonatomic, assign) CGFloat sideTabWidth;
@property (nonatomic, strong) UIScrollView *contentScrollView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIButton *headerButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerSubtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, assign) NSInteger trackingPointerId;
@property (nonatomic, assign) BOOL touchOnClose;
@property (nonatomic, assign) BOOL touchOnExitHUD;
@property (nonatomic, assign) BOOL menuDragging;
@property (nonatomic, assign) CGPoint menuDragStartOrigin;
@property (nonatomic, assign) CGPoint menuDragStartTouch;
@property (nonatomic, weak) UIView *activeCheckbox;
@property (nonatomic, strong) UIView *scrollbarTrack;
@property (nonatomic, strong) UIView *scrollbarThumb;
@property (nonatomic, assign) BOOL scrollbarDragging;
@property (nonatomic, weak) UISlider *sliderTracking;
@property (nonatomic, weak) UIView *segmentedRowTracking;
@property (nonatomic, assign) CGFloat scrollbarDragStartY;
@property (nonatomic, assign) CGFloat scrollbarDragStartOffsetY;
@property (nonatomic, assign) CGFloat scrollVelocity;
@property (nonatomic, strong) CADisplayLink *scrollDisplayLink;
@property (nonatomic, assign) CGFloat scrollLastTouchY;
@property (nonatomic, assign) CFTimeInterval scrollLastTime;
@property (nonatomic, assign) BOOL isScrollingContent;
@end

@implementation ModMenuViewController

- (void)updatePanelMetrics {
    CGSize size = self.view.bounds.size;
    CGFloat availableWidth = MAX(300.0f, size.width - 16.0f);
    CGFloat availableHeight = MAX(280.0f, size.height - 24.0f);
    _panelWidth = MIN(408.0f, availableWidth);
    _panelHeight = MIN(344.0f, availableHeight);
    _sideTabWidth = _panelWidth < 360.0f ? 68.0f : 82.0f;
}

- (CGFloat)tabHeightForCurrentPanel {
    CGFloat available = _panelHeight - kHeaderHeight - 32.0f - 15.0f;
    return MIN(52.0f, MAX(40.0f, available / 4.0f));
}

- (CGFloat)tabGap {
    return 5.0f;
}

- (void)rebuildPanelForCurrentBounds {
    [_floatingPanel removeFromSuperview];
    _floatingPanel = nil;
    [_tabButtons removeAllObjects];
    [self updatePanelMetrics];
    [self setupFloatingPanel];
    [self setupHeaderBar];
    [self setupTabBar];
    [self setupContentArea];
    [self updateHeaderForTab:_currentTab];
    [self loadTabContent:_currentTab];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.multipleTouchEnabled = YES;
    _trackingPointerId = -1;
    _currentTab = MenuTabESP;
    _tabButtons = [NSMutableArray array];
    _isScrollingContent = NO;
    [self updatePanelMetrics];
    [self setupFloatingPanel];
    [self setupHeaderBar];
    [self setupTabBar];
    [self setupContentArea];
    [self updateHeaderForTab:_currentTab];
    [self loadTabContent:_currentTab];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOutsideTap:)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (!_floatingPanel) return;
    CGRect screen = self.view.bounds;
    CGRect frame = _floatingPanel.frame;
    CGFloat maxX = MAX(0.0f, screen.size.width - frame.size.width);
    CGFloat maxY = MAX(0.0f, screen.size.height - frame.size.height);
    frame.origin.x = MAX(0.0f, MIN(maxX, frame.origin.x));
    frame.origin.y = MAX(0.0f, MIN(maxY, frame.origin.y));
    _floatingPanel.frame = frame;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak ModMenuViewController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf rebuildPanelForCurrentBounds];
    }];
}

- (CGPoint)loadPanelPosition {
    CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingPanelX"];
    CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingPanelY"];
    if (x <= 10.0f && y <= 10.0f) {
        CGRect screen = self.view.bounds;
        x = MAX(8.0f, (screen.size.width - _panelWidth) / 2.0f);
        y = MAX(18.0f, (screen.size.height - _panelHeight) / 2.0f);
    }
    return CGPointMake(x, y);
}

- (void)setupFloatingPanel {
    CGPoint pos = [self loadPanelPosition];
    _floatingPanel = [[UIView alloc] initWithFrame:CGRectMake(pos.x, pos.y, _panelWidth, _panelHeight)];
    _floatingPanel.backgroundColor = [UIColor clearColor];
    _floatingPanel.layer.cornerRadius = kCornerRadius;
    _floatingPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatingPanel.layer.shadowOpacity = 0.68f;
    _floatingPanel.layer.shadowRadius = 28.0f;
    _floatingPanel.layer.shadowOffset = CGSizeMake(0, 16);
    _floatingPanel.layer.masksToBounds = NO;
    [self.view addSubview:_floatingPanel];

    UIView *clip = [[UIView alloc] initWithFrame:_floatingPanel.bounds];
    clip.backgroundColor = [UIColor clearColor];
    clip.layer.cornerRadius = kCornerRadius;
    clip.clipsToBounds = YES;
    clip.tag = 7777;
    [_floatingPanel addSubview:clip];

    if (@available(iOS 13.0, *)) {
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        blur.frame = clip.bounds;
        blur.alpha = 0.82f;
        [clip addSubview:blur];
    }

    _panelSurface = [[UIView alloc] initWithFrame:clip.bounds];
    _panelSurface.backgroundColor = SBPanel();
    _panelSurface.userInteractionEnabled = NO;
    [clip addSubview:_panelSurface];

    CAGradientLayer *wash = [CAGradientLayer layer];
    wash.frame = clip.bounds;
    wash.colors = @[
        (__bridge id)SBColor(0.10f, 0.24f, 0.27f, 0.30f).CGColor,
        (__bridge id)SBColor(0.035f, 0.055f, 0.075f, 0.04f).CGColor,
        (__bridge id)SBColor(0.01f, 0.02f, 0.03f, 0.48f).CGColor
    ];
    wash.startPoint = CGPointMake(0.0f, 0.0f);
    wash.endPoint = CGPointMake(1.0f, 1.0f);
    [clip.layer insertSublayer:wash above:_panelSurface.layer];

    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _panelWidth, 1)];
    edge.backgroundColor = SBAccent();
    edge.alpha = 0.76f;
    [clip addSubview:edge];

    _floatingPanel.layer.borderWidth = 1.0f;
    _floatingPanel.layer.borderColor = SBBorder().CGColor;
}

- (UIView *)clipContainer { return [_floatingPanel viewWithTag:7777]; }

- (void)setupHeaderBar {
    UIView *clip = [self clipContainer];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _panelWidth, kHeaderHeight)];
    header.backgroundColor = SBColor(0.02f, 0.04f, 0.055f, 0.62f);
    [clip addSubview:header];

    UIView *logo = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 34, 34)];
    logo.backgroundColor = SBAccentDim();
    logo.layer.cornerRadius = 10.0f;
    logo.layer.borderWidth = 1.0f;
    logo.layer.borderColor = SBAccent().CGColor;
    [header addSubview:logo];

    UILabel *logoLetter = [[UILabel alloc] initWithFrame:logo.bounds];
    logoLetter.text = @"S";
    logoLetter.textAlignment = NSTextAlignmentCenter;
    logoLetter.textColor = SBText();
    logoLetter.font = [UIFont systemFontOfSize:18.0f weight:UIFontWeightBlack];
    [logo addSubview:logoLetter];

    _headerButton = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat headerTextWidth = MAX(104.0f, _panelWidth - 58.0f - 140.0f);
    _headerButton.frame = CGRectMake(58, 9, headerTextWidth, 44);
    _headerButton.backgroundColor = [UIColor clearColor];
    [clip addSubview:_headerButton];

    _headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 1, headerTextWidth, 23)];
    _headerTitleLabel.textColor = SBText();
    _headerTitleLabel.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightBold];
    [_headerButton addSubview:_headerTitleLabel];

    _headerSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 23, headerTextWidth, 15)];
    _headerSubtitleLabel.text = @"STARBACKS  /  CONTROL DECK";
    _headerSubtitleLabel.textColor = SBMuted();
    _headerSubtitleLabel.font = [UIFont systemFontOfSize:8.0f weight:UIFontWeightSemibold];
    _headerSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    [_headerButton addSubview:_headerSubtitleLabel];

    CGFloat statusWidth = _panelWidth < 350.0f ? 64.0f : 72.0f;
    _statusPill = [[UIView alloc] initWithFrame:CGRectMake(_panelWidth - statusWidth - 48.0f, 18, statusWidth, 26)];
    _statusPill.backgroundColor = SBColor(0.16f, 0.50f, 0.54f, 0.18f);
    _statusPill.layer.cornerRadius = 13.0f;
    _statusPill.layer.borderWidth = 1.0f;
    _statusPill.layer.borderColor = SBAccentDim().CGColor;
    [clip addSubview:_statusPill];

    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(10, 9, 7, 7)];
    _statusDot.backgroundColor = SBAccent();
    _statusDot.layer.cornerRadius = 3.5f;
    _statusDot.layer.shadowColor = SBAccent().CGColor;
    _statusDot.layer.shadowOpacity = 0.9f;
    _statusDot.layer.shadowRadius = 4.0f;
    [ _statusPill addSubview:_statusDot];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(23, 0, statusWidth - 27.0f, 26)];
    _statusLabel.text = @"READY";
    _statusLabel.textColor = SBAccent();
    _statusLabel.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
    [_statusPill addSubview:_statusLabel];

    CGFloat btnSize = 28.0f;
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.frame = CGRectMake(_panelWidth - 39, 17, btnSize, btnSize);
    _closeButton.backgroundColor = SBColor(1.0f, 1.0f, 1.0f, 0.045f);
    _closeButton.layer.cornerRadius = 9.0f;
    _closeButton.layer.borderWidth = 1.0f;
    _closeButton.layer.borderColor = SBBorder().CGColor;
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:@"xmark"];
        image = [image imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10.0f weight:UIImageSymbolWeightBold]];
        [_closeButton setImage:image forState:UIControlStateNormal];
    }
    _closeButton.tintColor = SBMuted();
    [clip addSubview:_closeButton];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, kHeaderHeight - 1, _panelWidth - 28, 1)];
    line.backgroundColor = SBBorder();
    [clip addSubview:line];
}

- (void)setupTabBar {
    UIView *clip = [self clipContainer];
    UIView *rail = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderHeight, _sideTabWidth, _panelHeight - kHeaderHeight)];
    rail.backgroundColor = SBColor(0.025f, 0.045f, 0.06f, 0.70f);
    rail.tag = 8888;
    [clip addSubview:rail];

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(_sideTabWidth - 1, 13, 1, _panelHeight - kHeaderHeight - 26)];
    divider.backgroundColor = SBBorder();
    [rail addSubview:divider];

    NSArray *titles = @[ @"OVERVIEW", @"AIM", @"SYSTEM", @"ABOUT" ];
    NSArray *icons = @[ @"square.grid.2x2", @"scope", @"slider.horizontal.3", @"info.circle" ];
    CGFloat top = 16.0f;
    CGFloat tabH = [self tabHeightForCurrentPanel];
    CGFloat gap = [self tabGap];

    for (NSInteger i = 0; i < 4; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(7, top + i * (tabH + gap), _sideTabWidth - 14, tabH);
        button.tag = i;
        button.layer.cornerRadius = 11.0f;
        button.backgroundColor = i == _currentTab ? SBColor(0.16f, 0.48f, 0.53f, 0.34f) : [UIColor clearColor];
        button.layer.borderWidth = i == _currentTab ? 1.0f : 0.0f;
        button.layer.borderColor = SBAccentDim().CGColor;
        [button setTitle:@"" forState:UIControlStateNormal];

        UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 8.0f, 18.0f, 18.0f)];
        iconView.center = CGPointMake(CGRectGetMidX(button.bounds), 17.0f);
        iconView.tag = 3001;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        if (@available(iOS 13.0, *)) {
            iconView.image = [UIImage systemImageNamed:icons[i]];
            iconView.image = [iconView.image imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16.0f weight:UIImageSymbolWeightMedium]];
            iconView.tintColor = i == _currentTab ? SBAccent() : SBMuted();
        }
        [button addSubview:iconView];

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(3.0f, 29.0f, button.bounds.size.width - 6.0f, 15.0f)];
        titleLabel.tag = 3002;
        titleLabel.text = titles[i];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.font = [UIFont systemFontOfSize:8.0f weight:UIFontWeightBold];
        titleLabel.textColor = i == _currentTab ? SBText() : SBMuted();
        titleLabel.adjustsFontSizeToFitWidth = YES;
        titleLabel.minimumScaleFactor = 0.58f;
        [button addSubview:titleLabel];

        [button addTarget:self action:@selector(tabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [rail addSubview:button];
        [_tabButtons addObject:button];
    }
}

- (void)setupContentArea {
    UIView *clip = [self clipContainer];
    CGFloat contentTop = kHeaderHeight;
    CGFloat contentHeight = _panelHeight - contentTop;
    CGFloat contentLeft = _sideTabWidth;
    CGFloat contentWidth = _panelWidth - contentLeft;
    CGFloat scrollWidth = contentWidth - 12.0f;

    UIView *contentClip = [[UIView alloc] initWithFrame:CGRectMake(contentLeft, contentTop, contentWidth, contentHeight)];
    contentClip.backgroundColor = [UIColor clearColor];
    contentClip.clipsToBounds = YES;
    contentClip.tag = 4000;
    [clip addSubview:contentClip];

    _contentScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, scrollWidth, contentHeight)];
    _contentScrollView.backgroundColor = [UIColor clearColor];
    _contentScrollView.showsVerticalScrollIndicator = NO;
    _contentScrollView.bounces = NO;
    _contentScrollView.scrollEnabled = NO;
    [contentClip addSubview:_contentScrollView];

    _contentContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, scrollWidth, contentHeight)];
    _contentContainer.backgroundColor = [UIColor clearColor];
    [_contentScrollView addSubview:_contentContainer];

    _scrollbarTrack = [[UIView alloc] initWithFrame:CGRectMake(contentWidth - kScrollBarWidth - 5, 8, kScrollBarWidth, contentHeight - 16)];
    _scrollbarTrack.backgroundColor = SBColor(0.60f, 0.80f, 0.82f, 0.14f);
    _scrollbarTrack.layer.cornerRadius = kScrollBarWidth / 2.0f;
    _scrollbarTrack.tag = 5000;
    [contentClip addSubview:_scrollbarTrack];

    _scrollbarThumb = [[UIView alloc] initWithFrame:CGRectMake(contentWidth - kScrollBarWidth - 5, 8, kScrollBarWidth, 34.0f)];
    _scrollbarThumb.backgroundColor = SBAccent();
    _scrollbarThumb.layer.cornerRadius = kScrollBarWidth / 2.0f;
    _scrollbarThumb.tag = 5001;
    [contentClip addSubview:_scrollbarThumb];
}

- (void)updateScrollbarLayout {
    CGFloat contentH = _contentScrollView.contentSize.height;
    CGFloat viewH = _contentScrollView.bounds.size.height;
    if (contentH <= viewH || viewH <= 0) {
        _scrollbarTrack.hidden = YES;
        _scrollbarThumb.hidden = YES;
        return;
    }
    _scrollbarTrack.hidden = NO;
    _scrollbarThumb.hidden = NO;
    CGFloat maxOffset = contentH - viewH;
    CGFloat thumbH = viewH * (viewH / contentH);
    thumbH = MAX(28.0f, MIN(viewH - 4.0f, thumbH));
    CGFloat range = viewH - thumbH;
    CGFloat offset = _contentScrollView.contentOffset.y;
    CGFloat thumbY = range > 0 ? (offset / maxOffset) * range : 0.0f;
    thumbY = MAX(0, MIN(range, thumbY));
    _scrollbarThumb.frame = CGRectMake(_scrollbarThumb.frame.origin.x, thumbY + 8, kScrollBarWidth, thumbH);
}

- (void)startScrollInertia {
    [self stopScrollInertia];
    if (ABS(_scrollVelocity) < 1.0f) return;
    _scrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(scrollInertiaStep)];
    [_scrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopScrollInertia {
    [_scrollDisplayLink invalidate];
    _scrollDisplayLink = nil;
}

- (void)scrollInertiaStep {
    _scrollVelocity *= 0.92f;
    if (ABS(_scrollVelocity) < 0.5f) {
        [self stopScrollInertia];
        return;
    }
    [self applyScrollDelta:_scrollVelocity];
}

- (void)applyScrollDelta:(CGFloat)delta {
    CGFloat contentH = _contentScrollView.contentSize.height;
    CGFloat viewH = _contentScrollView.bounds.size.height;
    CGFloat maxOffset = MAX(0, contentH - viewH);
    CGFloat offset = _contentScrollView.contentOffset.y + delta;
    offset = MAX(0, MIN(maxOffset, offset));
    _contentScrollView.contentOffset = CGPointMake(0, offset);
    [self updateScrollbarLayout];
}

- (void)updateHeaderForTab:(MenuTab)tab {
    NSArray *titles = @[ @"ESP OVERVIEW", @"AIM CONTROL", @"SYSTEM MEMORY", @"BUILD PROFILE" ];
    NSArray *values = @[ @"Live visual telemetry", @"Precision targeting", @"Runtime preferences", @"Identity & version" ];
    _headerTitleLabel.text = titles[tab];
    _headerSubtitleLabel.text = [NSString stringWithFormat:@"STARBACKS  /  %@", values[tab]];
}

- (void)updateTabBarForTab:(MenuTab)tab {
    NSArray *icons = @[ @"square.grid.2x2", @"scope", @"slider.horizontal.3", @"info.circle" ];
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *button = _tabButtons[i];
        BOOL active = i == tab;
        button.backgroundColor = active ? SBColor(0.16f, 0.48f, 0.53f, 0.34f) : [UIColor clearColor];
        button.layer.borderWidth = active ? 1.0f : 0.0f;
        UILabel *titleLabel = [button viewWithTag:3002];
        UIImageView *iconView = [button viewWithTag:3001];
        if (titleLabel) titleLabel.textColor = active ? SBText() : SBMuted();
        if (iconView) iconView.tintColor = active ? SBAccent() : SBMuted();
    }
}

- (UILabel *)sectionLabel:(NSString *)text y:(CGFloat)y width:(CGFloat)width {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, y, width - 24, 17)];
    label.text = text;
    label.textColor = SBAccent();
    label.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
    label.text = [text uppercaseString];
    label.alpha = 0.9f;
    [_contentContainer addSubview:label];
    return label;
}

- (UIView *)makeCheckboxWithKey:(NSString *)key checked:(BOOL)checked x:(CGFloat)x y:(CGFloat)y {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(x, y, kCheckboxSize, kCheckboxSize)];
    box.backgroundColor = checked ? SBAccentDim() : [UIColor clearColor];
    box.layer.cornerRadius = 5.0f;
    box.layer.borderWidth = 1.0f;
    box.layer.borderColor = checked ? SBAccent().CGColor : SBColor(0.75f, 0.85f, 0.87f, 0.36f).CGColor;
    box.tag = checked ? 1 : 0;
    objc_setAssociatedObject(box, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(box, "isCheckbox", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (checked) [self addCheckmarkTo:box];
    return box;
}

- (void)addCheckmarkTo:(UIView *)box {
    if (@available(iOS 13.0, *)) {
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(2, 2, kCheckboxSize - 4, kCheckboxSize - 4)];
        imageView.image = [UIImage systemImageNamed:@"checkmark"];
        imageView.tintColor = SBText();
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.tag = 9999;
        [box addSubview:imageView];
    }
}

- (void)setCheckbox:(UIView *)box checked:(BOOL)checked {
    box.tag = checked ? 1 : 0;
    box.backgroundColor = checked ? SBAccentDim() : [UIColor clearColor];
    box.layer.borderColor = checked ? SBAccent().CGColor : SBColor(0.75f, 0.85f, 0.87f, 0.36f).CGColor;
    [[box viewWithTag:9999] removeFromSuperview];
    if (checked) [self addCheckmarkTo:box];
}

- (UIView *)buildCheckboxCellWithTitle:(NSString *)title key:(NSString *)key frame:(CGRect)frame {
    BOOL enabled = ESPPrefsBool(key, NO);
    UIView *row = [[UIView alloc] initWithFrame:frame];
    row.backgroundColor = SBCard();
    row.layer.cornerRadius = 10.0f;
    row.layer.borderWidth = 1.0f;
    row.layer.borderColor = SBColor(0.56f, 0.75f, 0.78f, 0.10f).CGColor;
    objc_setAssociatedObject(row, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 2, frame.size.height - 16)];
    accent.backgroundColor = enabled ? SBAccent() : SBColor(0.55f, 0.75f, 0.78f, 0.18f);
    accent.layer.cornerRadius = 1.0f;
    accent.tag = 9111;
    [row addSubview:accent];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, frame.size.width - kCheckboxSize - 28, frame.size.height)];
    label.text = title;
    label.textColor = enabled ? SBText() : SBMuted();
    label.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightSemibold];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72f;
    [row addSubview:label];

    CGFloat checkboxY = (frame.size.height - kCheckboxSize) / 2.0f;
    UIView *checkbox = [self makeCheckboxWithKey:key checked:enabled x:frame.size.width - kCheckboxSize - 11.0f y:checkboxY];
    [row addSubview:checkbox];
    return row;
}

- (UIView *)buildDangerCellWithTitle:(NSString *)title frame:(CGRect)frame {
    UIView *row = [[UIView alloc] initWithFrame:frame];
    row.backgroundColor = SBColor(0.35f, 0.08f, 0.10f, 0.34f);
    row.layer.cornerRadius = 10.0f;
    row.layer.borderWidth = 1.0f;
    row.layer.borderColor = SBColor(1.0f, 0.28f, 0.32f, 0.32f).CGColor;
    objc_setAssociatedObject(row, "key", @"__exit_hud__", OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(13, 0, frame.size.width - 48, frame.size.height)];
    label.text = title;
    label.textColor = SBColor(1.0f, 0.50f, 0.52f, 1.0f);
    label.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
    [row addSubview:label];

    if (@available(iOS 13.0, *)) {
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(frame.size.width - 31, 11, 18, 18)];
        icon.image = [UIImage systemImageNamed:@"power"];
        icon.tintColor = SBColor(1.0f, 0.50f, 0.52f, 1.0f);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [row addSubview:icon];
    }
    return row;
}

- (void)loadTabContent:(MenuTab)tab {
    for (UIView *view in _contentContainer.subviews) [view removeFromSuperview];
    _contentScrollView.contentOffset = CGPointZero;
    [self stopScrollInertia];
    _scrollVelocity = 0;

    CGFloat contentWidth = _contentScrollView.bounds.size.width;
    _contentContainer.frame = CGRectMake(0, 0, contentWidth, _contentScrollView.bounds.size.height);
    __block CGFloat y = 14.0f;
    CGFloat rowWidth = contentWidth - 24.0f;
    CGFloat padX = 12.0f;
    CGFloat gapX = 7.0f;
    CGFloat colWidth = (rowWidth - gapX) / 2.0f;

    if (tab == MenuTabInfo) {
        UILabel *eyebrow = [self sectionLabel:@"Starbacks identity" y:y width:contentWidth];
        y += 24.0f;
        UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(padX, y, rowWidth, 66)];
        hero.backgroundColor = SBCard();
        hero.layer.cornerRadius = 13.0f;
        hero.layer.borderWidth = 1.0f;
        hero.layer.borderColor = SBBorder().CGColor;
        [_contentContainer addSubview:hero];

        UILabel *brand = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, rowWidth - 30, 25)];
        brand.text = @"STARBACKS / ELITE BUILD";
        brand.textColor = SBText();
        brand.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightBlack];
        [hero addSubview:brand];
        UILabel *tagline = [[UILabel alloc] initWithFrame:CGRectMake(15, 37, rowWidth - 30, 16)];
        tagline.text = @"A focused control surface for a cleaner session.";
        tagline.textColor = SBMuted();
        tagline.font = [UIFont systemFontOfSize:10.0f weight:UIFontWeightMedium];
        [hero addSubview:tagline];
        y += 78.0f;

        [self sectionLabel:@"Build details" y:y width:contentWidth];
        y += 22.0f;
        NSArray *details = @[
            @[ @"GAME", @"Garena Free Fire" ],
            @[ @"GAME VERSION", @"1.126.1" ],
            @[ @"MENU BUILD", @"v2.0.2" ],
            @[ @"PROFILE", @"Premium HUD" ],
            @[ @"STATUS", @"Verified session" ],
            @[ @"CHANNEL", @"Starbacks" ]
        ];
        for (NSArray *detail in details) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(padX, y, rowWidth, 26)];
            UILabel *left = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, rowWidth * 0.42f, 26)];
            left.text = detail[0];
            left.textColor = SBMuted();
            left.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
            [row addSubview:left];
            UILabel *right = [[UILabel alloc] initWithFrame:CGRectMake(rowWidth * 0.42f, 0, rowWidth * 0.58f - 10, 26)];
            right.text = detail[1];
            right.textColor = SBText();
            right.font = [UIFont systemFontOfSize:10.0f weight:UIFontWeightSemibold];
            right.textAlignment = NSTextAlignmentRight;
            [row addSubview:right];
            [_contentContainer addSubview:row];
            y += 27.0f;
        }
        [self finalizeContentHeight:y contentWidth:contentWidth];
        return;
    }

    if (tab == MenuTabMemory) {
        [self sectionLabel:@"Runtime functions" y:y width:contentWidth];
        y += 23.0f;
        NSArray *rows = @[
            @[ @"No Reload", @"NoReload" ],
            @[ @"Fast Fire", @"FastFire" ],
            @[ @"High Camera", @"camcao" ]
        ];
        for (NSUInteger i = 0; i < rows.count; i += 2) {
            NSArray *left = rows[i];
            [_contentContainer addSubview:[self buildCheckboxCellWithTitle:left[0] key:left[1] frame:CGRectMake(padX, y, colWidth, kRowHeight)]];
            if (i + 1 < rows.count) {
                NSArray *right = rows[i + 1];
                [_contentContainer addSubview:[self buildCheckboxCellWithTitle:right[0] key:right[1] frame:CGRectMake(padX + colWidth + gapX, y, colWidth, kRowHeight)]];
            }
            y += kRowHeight + 7.0f;
        }
        y += 8.0f;
        [self sectionLabel:@"Camera calibration" y:y width:contentWidth];
        y += 23.0f;
        y = [self addSliderRow:@"Camera height" format:@"CAMERA HEIGHT  /  %.0f" key:@"Campc" def:1.0f min:1 max:100 labelTag:7001 sliderTag:7002 y:y width:rowWidth];
        [self finalizeContentHeight:y contentWidth:contentWidth];
        return;
    }

    NSArray *rows = tab == MenuTabESP ? @[
        @[ @"2D Box", @"Box" ],
        @[ @"Corner Box", @"box" ],
        @[ @"Health Bar", @"Health" ],
        @[ @"Enemy Count", @"Count" ],
        @[ @"Show Name", @"Name" ],
        @[ @"Bone Work", @"Bone" ],
        @[ @"Show Distance", @"Dis" ],
        @[ @"Radar Line", @"Line" ],
        @[ @"FOV Circle", @"ShowFov" ]
    ] : @[
        @[ @"Auto Aimbot", @"Aimbot" ],
        @[ @"Silent Aim", @"SilentAim" ],
        @[ @"Ignore Bot", @"AimIgnoreBot" ],
        @[ @"Ignore Knocked", @"AimIgnoreKnock" ],
        @[ @"Visible Check", @"AimCheckVisible" ]
    ];

    if (tab == MenuTabAimbot) {
        [self sectionLabel:@"Signature feature" y:y width:contentWidth];
        y += 23.0f;
        [_contentContainer addSubview:[self buildCheckboxCellWithTitle:@"Aim Magnet" key:@"AimMagnet" frame:CGRectMake(padX, y, rowWidth, kRowHeight)]];
        y += kRowHeight + 10.0f;
    }

    [self sectionLabel:(tab == MenuTabESP ? @"Visual telemetry" : @"Core targeting") y:y width:contentWidth];
    y += 23.0f;
    for (NSUInteger i = 0; i < rows.count; i += 2) {
        NSArray *left = rows[i];
        [_contentContainer addSubview:[self buildCheckboxCellWithTitle:left[0] key:left[1] frame:CGRectMake(padX, y, colWidth, kRowHeight)]];
        if (i + 1 < rows.count) {
            NSArray *right = rows[i + 1];
            [_contentContainer addSubview:[self buildCheckboxCellWithTitle:right[0] key:right[1] frame:CGRectMake(padX + colWidth + gapX, y, colWidth, kRowHeight)]];
        }
        y += kRowHeight + 7.0f;
    }

    y += 8.0f;
    if (tab == MenuTabESP) {
        [self sectionLabel:@"Advanced visual layer" y:y width:contentWidth];
        y += 23.0f;
        NSArray *advanced = @[
            @[ @"Real Bot Filter", (NSString *)NSSENCRYPT("EspBot") ]
        ];
        for (NSArray *item in advanced) {
            [_contentContainer addSubview:[self buildCheckboxCellWithTitle:item[0] key:item[1] frame:CGRectMake(padX, y, rowWidth, kRowHeight)]];
            y += kRowHeight + 7.0f;
        }
        [_contentContainer addSubview:[self buildDangerCellWithTitle:@"Close Starbacks HUD" frame:CGRectMake(padX, y, rowWidth, kRowHeight)]];
        y += kRowHeight + 7.0f;
    } else {
        [self sectionLabel:@"Aim behaviour" y:y width:contentWidth];
        y += 23.0f;
        y = [self addSegmentedRow:@"Trigger mode" key:@"TriggerMode" y:y width:rowWidth];
        y = [self addSegmentedRow:@"Target lock" key:@"AimPos" y:y width:rowWidth];
        y = [self addSegmentedRow:@"Target priority" key:@"AimTargetMode" y:y width:rowWidth];
        y += 6.0f;
        [self sectionLabel:@"Precision envelope" y:y width:contentWidth];
        y += 23.0f;
        y = [self addSliderRow:@"FOV radius" format:@"AIM FOV  /  %.0f PX" key:@"Fov" def:150.0f min:10 max:500 labelTag:6001 sliderTag:6002 y:y width:rowWidth];
        y = [self addSliderRow:@"Max distance" format:@"AIM DISTANCE  /  %.0f M" key:@"Distance" def:200.0f min:1 max:500 labelTag:6003 sliderTag:6004 y:y width:rowWidth];
        y = [self addSliderRow:@"Lock speed" format:@"AIM SPEED  /  %.0f%%" key:@"AimSpeed" def:100.0f min:1 max:100 labelTag:6005 sliderTag:6006 y:y width:rowWidth];
        y += 4.0f;
        [_contentContainer addSubview:[self buildCheckboxCellWithTitle:@"Floating Aim Button" key:(NSString *)NSSENCRYPT("FloatAimBtn") frame:CGRectMake(padX, y, rowWidth, kRowHeight)]];
        y += kRowHeight + 7.0f;
    }
    [self finalizeContentHeight:y contentWidth:contentWidth];
}

- (void)finalizeContentHeight:(CGFloat)y contentWidth:(CGFloat)width {
    _contentContainer.frame = CGRectMake(0, 0, width, y + 12.0f);
    _contentScrollView.contentSize = _contentContainer.frame.size;
    [self updateScrollbarLayout];
}

- (CGFloat)addSliderRow:(NSString *)name format:(NSString *)format key:(NSString *)key def:(CGFloat)def min:(float)minValue max:(float)maxValue labelTag:(NSInteger)labelTag sliderTag:(NSInteger)sliderTag y:(CGFloat)y width:(CGFloat)rowWidth {
    CGFloat value = ESPPrefsFloat(key, def);
    if (value < minValue || value > maxValue) value = def;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(10, y, rowWidth - 20, 51)];
    card.backgroundColor = SBCard();
    card.layer.cornerRadius = 10.0f;
    card.layer.borderWidth = 1.0f;
    card.layer.borderColor = SBColor(0.56f, 0.75f, 0.78f, 0.10f).CGColor;
    [_contentContainer addSubview:card];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(11, 4, rowWidth - 42, 17)];
    label.text = [NSString stringWithFormat:format, value];
    label.textColor = SBText();
    label.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
    label.tag = labelTag;
    [card addSubview:label];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(8, 22, rowWidth - 36, 24)];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = value;
    slider.minimumTrackTintColor = SBAccent();
    slider.maximumTrackTintColor = SBColor(0.65f, 0.80f, 0.82f, 0.18f);
    if (@available(iOS 13.0, *)) slider.thumbTintColor = SBText();
    else slider.thumbTintColor = SBAccent();
    slider.tag = sliderTag;
    objc_setAssociatedObject(slider, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, "label", label, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, "fmt", format, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];
    return y + 58.0f;
}

- (void)checkboxTappedWithView:(UIView *)box {
    NSString *key = objc_getAssociatedObject(box, "key");
    if (!key) return;
    BOOL enabled = box.tag == 0;
    [self setCheckbox:box checked:enabled];
    UIView *row = box.superview;
    UILabel *label = nil;
    for (UIView *subview in row.subviews) if ([subview isKindOfClass:[UILabel class]]) label = (UILabel *)subview;
    label.textColor = enabled ? SBText() : SBMuted();
    UIView *accent = [row viewWithTag:9111];
    accent.backgroundColor = enabled ? SBAccent() : SBColor(0.55f, 0.75f, 0.78f, 0.18f);
    ESPPrefsSetBool(key, enabled);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ESPSyncFromPrefs();
    [self notifyMenuView];
}

- (void)notifyMenuView {
    for (UIView *view = self.view.superview; view; view = view.superview) {
        if ([view isKindOfClass:[MenuView class]]) {
            [(MenuView *)view reloadFloatingAuxButtonsFromPrefs];
            break;
        }
    }
}

- (void)sliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, "key");
    if (!key) return;
    float value = sender.value;
    ESPPrefsSetFloat(key, value);
    [[NSUserDefaults standardUserDefaults] setFloat:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ESPSyncFromPrefs();
    UILabel *label = objc_getAssociatedObject(sender, "label");
    NSString *format = objc_getAssociatedObject(sender, "fmt");
    if (label && format) label.text = [NSString stringWithFormat:format, value];
}

- (NSArray<NSString *> *)comboOptionsForKey:(NSString *)key {
    if ([key isEqualToString:@"box"]) return @[ @"2D Box", @"Corner" ];
    if ([key isEqualToString:@"TriggerMode"]) return @[ @"Auto", @"Fire", @"Scope", @"Combo" ];
    if ([key isEqualToString:@"AimPos"]) return @[ @"Head", @"Neck", @"Chest" ];
    if ([key isEqualToString:@"AimTargetMode"]) return @[ @"Crosshair", @"Distance", @"HP" ];
    return @[];
}

- (void)updateSegmentedRowVisual:(UIView *)row selectedIndex:(int)selectedIndex {
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, "segCells");
    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        UIView *cell = cells[i];
        UILabel *label = [cell viewWithTag:kSegmentLabelTag];
        BOOL selected = i == selectedIndex;
        cell.backgroundColor = selected ? SBAccentDim() : [UIColor clearColor];
        if (label) {
            label.textColor = selected ? SBText() : SBMuted();
            label.font = [UIFont systemFontOfSize:9.0f weight:selected ? UIFontWeightBold : UIFontWeightMedium];
        }
    }
}

- (CGFloat)addSegmentedRow:(NSString *)title key:(NSString *)key y:(CGFloat)y width:(CGFloat)rowWidth {
    NSArray<NSString *> *options = [self comboOptionsForKey:key];
    if (!options.count) return y;
    const CGFloat titleHeight = 16.0f;
    const CGFloat pillHeight = 29.0f;
    const CGFloat gap = 4.0f;
    const CGFloat bottom = 6.0f;
    CGFloat rowHeight = titleHeight + gap + pillHeight + bottom;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, rowWidth - 20, rowHeight)];
    row.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(row, "segComboPrefsKey", key, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, rowWidth - 20, titleHeight)];
    titleLabel.text = title.uppercaseString;
    titleLabel.textColor = SBMuted();
    titleLabel.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
    [row addSubview:titleLabel];

    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(0, titleHeight + gap, rowWidth - 20, pillHeight)];
    track.tag = kSegmentTrackTag;
    track.backgroundColor = SBCard();
    track.layer.cornerRadius = 9.0f;
    track.layer.borderWidth = 1.0f;
    track.layer.borderColor = SBBorder().CGColor;
    track.clipsToBounds = YES;
    [row addSubview:track];

    int selected = (int)ESPPrefsFloat(key, 0.0f);
    if (selected < 0 || selected >= (int)options.count) selected = 0;
    CGFloat segmentWidth = track.bounds.size.width / (CGFloat)options.count;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(segmentWidth * i + 2, 2, segmentWidth - 4, pillHeight - 4)];
        cell.layer.cornerRadius = 7.0f;
        cell.userInteractionEnabled = NO;
        UILabel *label = [[UILabel alloc] initWithFrame:cell.bounds];
        label.tag = kSegmentLabelTag;
        label.text = options[i];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.62f;
        [cell addSubview:label];
        [track addSubview:cell];
        [cells addObject:cell];
    }
    objc_setAssociatedObject(row, "segCells", cells, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSegmentedRowVisual:row selectedIndex:selected];
    [_contentContainer addSubview:row];
    return y + rowHeight + 5.0f;
}

- (void)applySegmentedSelectionForRow:(UIView *)row touchInContent:(CGPoint)point {
    NSString *key = objc_getAssociatedObject(row, "segComboPrefsKey");
    NSArray *cells = objc_getAssociatedObject(row, "segCells");
    UIView *track = [row viewWithTag:kSegmentTrackTag];
    if (!key || !track || !cells.count) return;
    CGPoint inRow = CGPointMake(point.x - row.frame.origin.x, point.y - row.frame.origin.y);
    if (!CGRectContainsPoint(track.frame, inRow)) return;
    CGFloat relativeX = inRow.x - track.frame.origin.x;
    NSInteger count = (NSInteger)cells.count;
    NSInteger index = (NSInteger)(relativeX / (track.bounds.size.width / (CGFloat)count));
    index = MAX(0, MIN(count - 1, index));
    ESPPrefsSetFloat(key, (float)index);
    ESPSyncFromPrefs();
    [self updateSegmentedRowVisual:row selectedIndex:(int)index];
    [self notifyMenuView];
}

- (void)tabButtonTapped:(UIButton *)sender {
    MenuTab tab = (MenuTab)sender.tag;
    if (tab == _currentTab) return;
    _currentTab = tab;
    [self updateTabBarForTab:tab];
    [self updateHeaderForTab:tab];
    [self loadTabContent:tab];
}

- (void)closeTapped {
    [[NSUserDefaults standardUserDefaults] setFloat:_floatingPanel.frame.origin.x forKey:@"FloatingPanelX"];
    [[NSUserDefaults standardUserDefaults] setFloat:_floatingPanel.frame.origin.y forKey:@"FloatingPanelY"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (self.onCloseBlock) self.onCloseBlock();
}

- (void)handleOutsideTap:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self.view];
    if (!CGRectContainsPoint(_floatingPanel.frame, point)) [self closeTapped];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return !CGRectContainsPoint(_floatingPanel.frame, [touch locationInView:self.view]);
}

- (BOOL)handleTouchAtViewPoint:(CGPoint)point phase:(NSInteger)phase pointerId:(NSInteger)pointerId {
    BOOL insidePanel = CGRectContainsPoint(_floatingPanel.frame, point);
    UITouchPhase touchPhase = (UITouchPhase)phase;

    if (touchPhase == UITouchPhaseBegan) {
        if (!insidePanel) return NO;
        if (_trackingPointerId != -1 && _trackingPointerId != pointerId) return NO;
        _trackingPointerId = pointerId;
        _touchOnClose = NO;
        _touchOnExitHUD = NO;
        _menuDragging = NO;
        _activeCheckbox = nil;
        _segmentedRowTracking = nil;
        _sliderTracking = nil;
        _scrollbarDragging = NO;
        _isScrollingContent = NO;
        [self stopScrollInertia];
        _scrollVelocity = 0;

        CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
        if (inPanel.y < kHeaderHeight) {
            CGRect closeRect = CGRectMake(_panelWidth - 39, 17, 28, 28);
            if (CGRectContainsPoint(CGRectInset(closeRect, -8, -8), inPanel)) {
                _touchOnClose = YES;
            } else {
                _menuDragging = YES;
                _menuDragStartOrigin = _floatingPanel.frame.origin;
                _menuDragStartTouch = point;
            }
            return YES;
        }

        if (inPanel.x < _sideTabWidth) {
            CGFloat top = 16.0f;
            CGFloat tabH = [self tabHeightForCurrentPanel];
            CGFloat gap = [self tabGap];
            for (NSInteger i = 0; i < 4; i++) {
                CGRect tabRect = CGRectMake(7, kHeaderHeight + top + i * (tabH + gap), _sideTabWidth - 14, tabH);
                if (CGRectContainsPoint(tabRect, inPanel)) {
                    [self tabButtonTapped:_tabButtons[i]];
                    return YES;
                }
            }
            return YES;
        }

        if (inPanel.x >= _panelWidth - kScrollBarWidth - 11) {
            CGFloat trackY = inPanel.y - kHeaderHeight;
            CGFloat viewHeight = _contentScrollView.bounds.size.height;
            CGFloat contentHeight = _contentScrollView.contentSize.height;
            CGFloat maxOffset = contentHeight - viewHeight;
            if (maxOffset > 0) {
                CGFloat thumbY = _scrollbarThumb.frame.origin.y;
                CGFloat thumbHeight = _scrollbarThumb.frame.size.height;
                if (trackY >= thumbY && trackY <= thumbY + thumbHeight) {
                    _scrollbarDragging = YES;
                    _scrollbarDragStartY = point.y;
                    _scrollbarDragStartOffsetY = _contentScrollView.contentOffset.y;
                } else {
                    CGFloat trackHeight = _scrollbarTrack.frame.size.height;
                    CGFloat range = trackHeight - thumbHeight;
                    if (range > 0) {
                        CGFloat offset = (trackY / trackHeight) * maxOffset;
                        _contentScrollView.contentOffset = CGPointMake(0, MAX(0, MIN(maxOffset, offset)));
                        [self updateScrollbarLayout];
                    }
                }
            }
            return YES;
        }

        _scrollLastTouchY = point.y;
        _scrollLastTime = CACurrentMediaTime();
        CGPoint inContent = CGPointMake(inPanel.x - _sideTabWidth, inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);
        for (UIView *row in _contentContainer.subviews) {
            if ([row isKindOfClass:[UISlider class]] || [row isKindOfClass:[UILabel class]]) continue;
            if (!CGRectContainsPoint(row.frame, inContent)) continue;
            NSString *segmentKey = objc_getAssociatedObject(row, "segComboPrefsKey");
            if (segmentKey) {
                UIView *track = [row viewWithTag:kSegmentTrackTag];
                CGPoint inRow = CGPointMake(inContent.x - row.frame.origin.x, inContent.y - row.frame.origin.y);
                if (track && CGRectContainsPoint(track.frame, inRow)) _segmentedRowTracking = row;
                break;
            }
            NSString *rowKey = objc_getAssociatedObject(row, "key");
            if ([rowKey isEqualToString:@"__exit_hud__"]) {
                _touchOnExitHUD = YES;
                break;
            }
            for (UIView *subview in row.subviews) {
                if (objc_getAssociatedObject(subview, "isCheckbox")) {
                    _activeCheckbox = subview;
                    break;
                }
            }
            break;
        }
        if (!_activeCheckbox && !_touchOnExitHUD && !_segmentedRowTracking) {
            for (UIView *view in _contentContainer.subviews) {
                if ([view isKindOfClass:[UISlider class]]) {
                    if (CGRectContainsPoint(view.frame, inContent)) _sliderTracking = (UISlider *)view;
                } else {
                    for (UIView *subview in view.subviews) {
                        if ([subview isKindOfClass:[UISlider class]] && CGRectContainsPoint(view.frame, inContent)) {
                            CGPoint local = CGPointMake(inContent.x - view.frame.origin.x, inContent.y - view.frame.origin.y);
                            if (CGRectContainsPoint(subview.frame, local)) _sliderTracking = (UISlider *)subview;
                        }
                    }
                }
                if (_sliderTracking) break;
            }
        }
        return YES;
    }

    if (touchPhase == UITouchPhaseMoved) {
        if (pointerId != _trackingPointerId) return NO;
        if (_sliderTracking) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
            CGPoint inContent = CGPointMake(inPanel.x - _sideTabWidth, inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);
            UIView *card = _sliderTracking.superview;
            CGFloat relativeX = inContent.x - card.frame.origin.x - _sliderTracking.frame.origin.x;
            CGFloat ratio = relativeX / _sliderTracking.frame.size.width;
            ratio = MAX(0, MIN(1, ratio));
            _sliderTracking.value = _sliderTracking.minimumValue + ratio * (_sliderTracking.maximumValue - _sliderTracking.minimumValue);
            [self sliderChanged:_sliderTracking];
            return YES;
        }
        if (_scrollbarDragging) {
            CGFloat contentHeight = _contentScrollView.contentSize.height;
            CGFloat viewHeight = _contentScrollView.bounds.size.height;
            CGFloat maxOffset = contentHeight - viewHeight;
            if (maxOffset <= 0) {
                _scrollbarDragging = NO;
                return YES;
            }
            CGFloat trackHeight = _scrollbarTrack.frame.size.height;
            CGFloat thumbHeight = _scrollbarThumb.frame.size.height;
            CGFloat ratio = (point.y - _scrollbarDragStartY) / MAX(1.0f, trackHeight - thumbHeight);
            CGFloat offset = _scrollbarDragStartOffsetY + ratio * maxOffset;
            _contentScrollView.contentOffset = CGPointMake(0, MAX(0, MIN(maxOffset, offset)));
            [self updateScrollbarLayout];
            return YES;
        }
        if (_menuDragging) {
            CGFloat dx = point.x - _menuDragStartTouch.x;
            CGFloat dy = point.y - _menuDragStartTouch.y;
            CGRect screen = self.view.bounds;
            CGFloat newX = MAX(0, MIN(MAX(0, screen.size.width - _panelWidth), _menuDragStartOrigin.x + dx));
            CGFloat newY = MAX(0, MIN(MAX(0, screen.size.height - _panelHeight), _menuDragStartOrigin.y + dy));
            _floatingPanel.frame = CGRectMake(newX, newY, _panelWidth, _panelHeight);
            return YES;
        }
        CGFloat panelX = point.x - _floatingPanel.frame.origin.x;
        CGFloat panelY = point.y - _floatingPanel.frame.origin.y;
        if (panelY > kHeaderHeight && panelX > _sideTabWidth) {
            CFTimeInterval now = CACurrentMediaTime();
            CGFloat deltaY = point.y - _scrollLastTouchY;
            if (now - _scrollLastTime > 0.001) _scrollVelocity = -deltaY / (CGFloat)((now - _scrollLastTime) * 60.0);
            [self applyScrollDelta:-deltaY];
            if (ABS(deltaY) > 3.0f) {
                _isScrollingContent = YES;
                _activeCheckbox = nil;
                _segmentedRowTracking = nil;
                _touchOnExitHUD = NO;
            }
            _scrollLastTouchY = point.y;
            _scrollLastTime = now;
            return YES;
        }
    }

    if (touchPhase == UITouchPhaseEnded || touchPhase == UITouchPhaseCancelled) {
        if (pointerId != _trackingPointerId) return NO;
        if (_touchOnClose) {
            [self closeTapped];
        } else if (_touchOnExitHUD && !_isScrollingContent && self.onExitHUDRequested) {
            self.onExitHUDRequested();
        } else if (_activeCheckbox && !_isScrollingContent) {
            [self checkboxTappedWithView:_activeCheckbox];
        } else if (_segmentedRowTracking && !_isScrollingContent) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x, point.y - _floatingPanel.frame.origin.y);
            CGPoint inContent = CGPointMake(inPanel.x - _sideTabWidth, inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);
            [self applySegmentedSelectionForRow:_segmentedRowTracking touchInContent:inContent];
        } else if (_menuDragging) {
            [[NSUserDefaults standardUserDefaults] setFloat:_floatingPanel.frame.origin.x forKey:@"FloatingPanelX"];
            [[NSUserDefaults standardUserDefaults] setFloat:_floatingPanel.frame.origin.y forKey:@"FloatingPanelY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        } else if (_scrollbarDragging) {
            [self updateScrollbarLayout];
        } else if (_isScrollingContent) {
            [self startScrollInertia];
        }
        _trackingPointerId = -1;
        _touchOnClose = NO;
        _touchOnExitHUD = NO;
        _menuDragging = NO;
        _scrollbarDragging = NO;
        _activeCheckbox = nil;
        _segmentedRowTracking = nil;
        _sliderTracking = nil;
        _isScrollingContent = NO;
        return YES;
    }
    return insidePanel && pointerId == _trackingPointerId;
}

@end
