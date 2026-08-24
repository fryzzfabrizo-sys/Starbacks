// ModMenuViewController.mm
#import "ModMenuViewController.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "../esp/drawing_view/menu.h"
#import "../mahoa.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ===== KÍCH THƯỚC - GIỮ NGUYÊN =====
static const CGFloat kPanelWidth = 370.0f;  
static const CGFloat kPanelHeight = 300.0f; 
static const CGFloat kHeaderHeight = 44.0f;
static const CGFloat kSideTabWidth = 90.0f;
static const CGFloat kRowHeight = 38.0f;
static const CGFloat kScrollBarWidth = 3.0f;
static const CGFloat kCheckboxSize = 20.0f;

// ========== MÀU SẮC MỚI - BẾ NGUYÊN TỪ IMGUI ==========
// Màu nền chính: Xanh than nhạt trong suốt (WindowBg ImGui)
#define kColorMenuBG [UIColor colorWithRed:0.12f green:0.22f blue:0.32f alpha:0.55f] 

// Màu chủ đạo cho nút, tab, checkbox (Thay vì màu xanh nước biển đậm, lấy màu chủ đạo của ImGui)
#define kColorAccent [UIColor colorWithRed:0.18f green:0.32f blue:0.48f alpha:0.85f] 
#define kColorAccentBorder [UIColor colorWithRed:0.18f green:0.32f blue:0.48f alpha:0.55f]

// Màu Header & Tab background
#define kColorHeaderBG [UIColor colorWithRed:0.12f green:0.25f blue:0.38f alpha:0.50f] 
#define kColorTabInactive [UIColor colorWithRed:0.12f green:0.22f blue:0.32f alpha:0.35f]

// Màu viền & phân cách
#define kColorBorder [UIColor colorWithRed:0.80f green:0.85f blue:0.90f alpha:0.15f]
#define kColorSeparator [UIColor colorWithRed:0.80f green:0.85f blue:0.90f alpha:0.10f]

// Màu chữ: Trắng tinh
#define kColorText [UIColor colorWithWhite:1.0f alpha:1.0f]
#define kColorMuted [UIColor colorWithWhite:0.85f alpha:0.70f]

// Checkbox & Slider màu
#define kColorCheckOn kColorAccent
#define kColorCheckBorder [UIColor colorWithWhite:1.0f alpha:0.40f]

// Màu nút Exit HUD (Giữ nguyên đỏ nhạt cho nổi bật)
#define kColorDangerBG [UIColor colorWithRed:1.00f green:0.23f blue:0.19f alpha:0.20f]
#define kColorDanger [UIColor colorWithRed:1.00f green:0.26f blue:0.26f alpha:1.0f]

// Slider & Segmented
#define kColorSliderTrack [UIColor colorWithWhite:1.0f alpha:0.20f]
#define kColorSliderFill kColorAccent
#define kColorSegActive [UIColor colorWithWhite:1.0f alpha:0.15f]
#define kColorSegBG [UIColor colorWithRed:0.00f green:0.00f blue:0.00f alpha:0.35f]
// ==========================================================

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
@property (nonatomic, strong) UIScrollView *contentScrollView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIButton *headerButton;
@property (nonatomic, strong) UIButton *closeButton;

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

// ... (Tất cả các hàm setup bên dưới giữ nguyên y hệt, không cần thay đổi gì nữa) ...
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.multipleTouchEnabled = YES;

    _trackingPointerId = -1;
    _currentTab = MenuTabESP;
    _tabButtons = [NSMutableArray array];
    _isScrollingContent = NO;

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

- (void)iPadLayoutCheck {}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (_floatingPanel) {
        CGRect screen = self.view.bounds;
        CGRect frame = _floatingPanel.frame;
        if (frame.origin.x < 0) frame.origin.x = 0;
        if (frame.origin.y < 0) frame.origin.y = 0;
        if (CGRectGetMaxX(frame) > screen.size.width)
            frame.origin.x = screen.size.width - frame.size.width;
        if (CGRectGetMaxY(frame) > screen.size.height)
            frame.origin.y = screen.size.height - frame.size.height;
        _floatingPanel.frame = frame;
    }
}

- (CGPoint)loadPanelPosition {
    CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingPanelX"];
    CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingPanelY"];
    if (x <= 10.0f && y <= 10.0f) {
        CGRect screen = [UIScreen mainScreen].bounds;
        x = MAX(0, (screen.size.width - kPanelWidth) / 2.0f);
        y = 80.0f;
    }
    return CGPointMake(x, y);
}

- (void)setupFloatingPanel {
    CGPoint pos = [self loadPanelPosition];
    _floatingPanel = [[UIView alloc] initWithFrame:CGRectMake(pos.x, pos.y, kPanelWidth, kPanelHeight)];
    _floatingPanel.backgroundColor = [UIColor clearColor];
    _floatingPanel.layer.cornerRadius = 12.0f;
    
    _floatingPanel.layer.borderWidth = 1.0f;
    _floatingPanel.layer.borderColor = kColorBorder.CGColor;
    
    _floatingPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    _floatingPanel.layer.shadowOpacity = 0.5f;
    _floatingPanel.layer.shadowRadius = 30.0f;
    _floatingPanel.layer.shadowOffset = CGSizeMake(0, 10);
    
    _floatingPanel.layer.masksToBounds = NO;
    _floatingPanel.clipsToBounds = NO;
    [self.view addSubview:_floatingPanel];

    UIView *clip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, kPanelHeight)];
    clip.backgroundColor = [UIColor clearColor];
    clip.layer.cornerRadius = 12.0f;
    clip.clipsToBounds = YES;
    clip.userInteractionEnabled = NO;
    clip.tag = 7777;
    [_floatingPanel addSubview:clip];

    if (@available(iOS 13.0, *)) {
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.frame = clip.bounds;
        blurView.alpha = 0.80f;
        [clip addSubview:blurView];
    }

    UIView *bg = [[UIView alloc] initWithFrame:clip.bounds];
    bg.backgroundColor = kColorMenuBG; 
    [clip addSubview:bg];
}

- (UIView *)clipContainer { return [_floatingPanel viewWithTag:7777]; }

- (void)setupHeaderBar {
    UIView *clip = [self clipContainer];

    UIView *headerBG = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, kHeaderHeight)];
    headerBG.backgroundColor = kColorHeaderBG;
    [clip addSubview:headerBG];

    UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderHeight - 1, kPanelWidth, 1)];
    hLine.backgroundColor = kColorBorder;
    [headerBG addSubview:hLine];

    _headerButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _headerButton.frame = CGRectMake(0, 0, kPanelWidth - 44, kHeaderHeight);
    _headerButton.backgroundColor = [UIColor clearColor];
    [clip addSubview:_headerButton];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, kPanelWidth - 95, kHeaderHeight)];
    titleLabel.tag = 2002;
    titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    titleLabel.textColor = kColorText;
    titleLabel.textAlignment = NSTextAlignmentLeft;
    [_headerButton addSubview:titleLabel];

    CGFloat btnSize = 26.0f;
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.frame = CGRectMake(kPanelWidth - 36, (kHeaderHeight - btnSize) / 2.0f, btnSize, btnSize);
    _closeButton.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.05f];
    _closeButton.layer.cornerRadius = 6.0f;
    _closeButton.layer.borderWidth = 1.0f;
    _closeButton.layer.borderColor = kColorBorder.CGColor;
    UIImage *closeImg = [UIImage systemImageNamed:@"xmark"];
    if (@available(iOS 13.0, *))
        closeImg = [closeImg imageByApplyingSymbolConfiguration:
                    [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]];
    [_closeButton setImage:closeImg forState:UIControlStateNormal];
    _closeButton.tintColor = kColorMuted;
    [clip addSubview:_closeButton];
}

- (void)setupTabBar {
    UIView *clip = [self clipContainer];

    CGFloat tabAreaY = kHeaderHeight;
    CGFloat tabAreaH = kPanelHeight - kHeaderHeight;

    UIView *tabBarBG = [[UIView alloc] initWithFrame:CGRectMake(0, tabAreaY, kSideTabWidth, tabAreaH)];
    tabBarBG.backgroundColor = kColorTabInactive;
    tabBarBG.tag = 8888;
    [clip addSubview:tabBarBG];

    UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(kSideTabWidth - 1, 8, 1, tabAreaH - 16)];
    vLine.backgroundColor = kColorBorder;
    [tabBarBG addSubview:vLine];

    CGFloat topPad = 18.0f, gap = 10.0f;
    CGFloat tabW = kSideTabWidth - 10.0f;
    CGFloat tabH = 34.0f;

    NSArray *tabTitles = @[ @"ESP", @"AIMBOT", @"MEMORY", @"INFO" ];

    for (NSInteger i = 0; i < 4; i++) {
        CGFloat ty = topPad + (CGFloat)i * (tabH + gap);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(5, ty, tabW, tabH);
        btn.layer.cornerRadius = 6.0f;
        btn.tag = i;
        
        BOOL active = (i == _currentTab);
        btn.backgroundColor = active ? kColorAccent : [UIColor clearColor];
        btn.layer.borderWidth = active ? 0 : 1;
        btn.layer.borderColor = kColorBorder.CGColor;
        
        [btn setTitle:tabTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [btn setTitleColor:active ? [UIColor whiteColor] : kColorMuted forState:UIControlStateNormal];
        
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        
        [btn addTarget:self action:@selector(tabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [tabBarBG addSubview:btn];
        [_tabButtons addObject:btn];
    }
}

- (void)setupContentArea {
    UIView *clip = [self clipContainer];

    CGFloat contentTop = kHeaderHeight;
    CGFloat contentHeight = kPanelHeight - contentTop;
    CGFloat contentLeft = kSideTabWidth;
    CGFloat contentWidth = kPanelWidth - contentLeft;
    CGFloat scrollWidth = contentWidth - 10.0f;

    UIView *contentClipView = [[UIView alloc] initWithFrame:CGRectMake(contentLeft, contentTop,
                                                                        contentWidth, contentHeight)];
    contentClipView.backgroundColor = [UIColor clearColor];
    contentClipView.clipsToBounds = YES;
    contentClipView.tag = 4000;
    [clip addSubview:contentClipView];

    _contentScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, scrollWidth, contentHeight)];
    _contentScrollView.backgroundColor = [UIColor clearColor];
    _contentScrollView.showsVerticalScrollIndicator = NO;
    _contentScrollView.bounces = NO;
    _contentScrollView.scrollEnabled = NO;
    [contentClipView addSubview:_contentScrollView];

    _contentContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, scrollWidth, contentHeight)];
    _contentContainer.backgroundColor = [UIColor clearColor];
    [_contentScrollView addSubview:_contentContainer];

    _scrollbarTrack = [[UIView alloc] initWithFrame:CGRectMake(contentWidth - kScrollBarWidth - 4, 6,
                                                                kScrollBarWidth, contentHeight - 12)];
    _scrollbarTrack.backgroundColor = kColorSliderTrack;
    _scrollbarTrack.layer.cornerRadius = kScrollBarWidth / 2.0f;
    _scrollbarTrack.tag = 5000;
    [contentClipView addSubview:_scrollbarTrack];

    _scrollbarThumb = [[UIView alloc] initWithFrame:CGRectMake(contentWidth - kScrollBarWidth - 4, 6,
                                                                kScrollBarWidth, 36.0f)];
    _scrollbarThumb.backgroundColor = kColorSliderFill;
    _scrollbarThumb.layer.cornerRadius = kScrollBarWidth / 2.0f;
    _scrollbarThumb.tag = 5001;
    [contentClipView addSubview:_scrollbarThumb];
}

// ... (Các hàm updateScrollbarLayout, updateHeaderForTab, logic check box, loadTabContent giữ nguyên 100% so với code cũ bạn đã gửi) ...
// Lưu ý: Hàm makeCheckbox và buildCheckboxCell dùng kColorCheckOn, kColorText đã được định nghĩa ở trên.

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
    if (thumbH < 28.0f) thumbH = 28.0f;
    if (thumbH > viewH - 4.0f) thumbH = viewH - 4.0f;

    CGFloat range = viewH - thumbH;
    CGFloat offset = _contentScrollView.contentOffset.y;
    CGFloat thumbY = (range > 0) ? (offset / maxOffset) * range : 0.0f;
    thumbY = MAX(0, MIN(range, thumbY));
    _scrollbarThumb.frame = CGRectMake(_scrollbarThumb.frame.origin.x, thumbY + 6, kScrollBarWidth, thumbH);
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
    if (ABS(_scrollVelocity) < 0.5f) { [self stopScrollInertia]; return; }
    [self applyScrollDelta:_scrollVelocity];
}

- (void)applyScrollDelta:(CGFloat)delta {
    CGFloat contentH = _contentScrollView.contentSize.height;
    CGFloat viewH = _contentScrollView.bounds.size.height;
    CGFloat maxOff = MAX(0, contentH - viewH);
    CGFloat newOff = _contentScrollView.contentOffset.y + delta;
    newOff = MAX(0, MIN(maxOff, newOff));
    _contentScrollView.contentOffset = CGPointMake(0, newOff);
    [self updateScrollbarLayout];
}

- (void)updateHeaderForTab:(MenuTab)tab {
    UILabel *lbl = (UILabel *)[_headerButton viewWithTag:2002];
    switch (tab) {
        case MenuTabESP: lbl.text = @"ESP Settings"; break;
        case MenuTabAimbot: lbl.text = @"Aimbot Settings"; break;
        case MenuTabMemory: lbl.text = @"Memory Functions"; break;
        case MenuTabInfo: lbl.text = @"KTIEN IOS"; break;
    }
}

- (void)updateTabBarForTab:(MenuTab)tab {
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *btn = _tabButtons[i];
        BOOL active = (i == tab);
        btn.backgroundColor = active ? kColorAccent : [UIColor clearColor];
        [btn setTitleColor:active ? [UIColor whiteColor] : kColorMuted forState:UIControlStateNormal];
        btn.layer.borderWidth = active ? 0 : 1;
    }
}

- (UIView *)makeCheckboxWithKey:(NSString *)key checked:(BOOL)checked x:(CGFloat)x y:(CGFloat)y {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(x, y, kCheckboxSize, kCheckboxSize)];
    box.backgroundColor = checked ? kColorCheckOn : [UIColor clearColor];
    box.layer.cornerRadius = 4.0f;
    box.layer.borderWidth = 1.5f;
    box.layer.borderColor = checked ? kColorCheckOn.CGColor : kColorCheckBorder.CGColor;
    box.tag = checked ? 1 : 0;
    objc_setAssociatedObject(box, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(box, "isCheckbox", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (checked) [self addCheckmarkTo:box];
    return box;
}

- (void)addCheckmarkTo:(UIView *)box {
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, kCheckboxSize-6, kCheckboxSize-6)];
    UIImage *img = [UIImage systemImageNamed:@"checkmark"];
    if (@available(iOS 13.0, *))
        img = [img imageByApplyingSymbolConfiguration:
               [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]];
    iv.image = img; iv.tintColor = [UIColor whiteColor];
    iv.contentMode = UIViewContentModeScaleAspectFit; iv.tag = 9999;
    [box addSubview:iv];
}

- (void)setCheckbox:(UIView *)box checked:(BOOL)checked {
    box.tag = checked ? 1 : 0;
    box.backgroundColor = checked ? kColorCheckOn : [UIColor clearColor];
    box.layer.borderColor = checked ? kColorCheckOn.CGColor : kColorCheckBorder.CGColor;
    [[box viewWithTag:9999] removeFromSuperview];
    if (checked) [self addCheckmarkTo:box];
}

- (UIView *)buildCheckboxCellWithTitle:(NSString *)title key:(NSString *)key frame:(CGRect)frame {
    BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:key];

    UIView *rv = [[UIView alloc] initWithFrame:frame];
    rv.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.03f];
    rv.layer.cornerRadius = 4.0f;
    objc_setAssociatedObject(rv, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height - 1, frame.size.width, 1)];
    sep.backgroundColor = kColorSeparator;
    [rv addSubview:sep];

    CGFloat cbY = (frame.size.height - kCheckboxSize) / 2.0f;
    CGFloat cbX = frame.size.width - kCheckboxSize - 2.0f;
    UIView *cb = [self makeCheckboxWithKey:key checked:on x:cbX y:cbY];
    [rv addSubview:cb];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, frame.size.width - kCheckboxSize - 16, frame.size.height)];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    lbl.textColor = kColorText;
    lbl.adjustsFontSizeToFitWidth = YES;
    lbl.minimumScaleFactor = 0.75f;
    [rv addSubview:lbl];
    return rv;
}

- (void)loadTabContent:(MenuTab)tab {
    for (UIView *v in _contentContainer.subviews) {
        [v removeFromSuperview];
    }
    
    _contentScrollView.contentOffset = CGPointZero;
    [self stopScrollInertia];
    _scrollVelocity = 0;

    CGFloat contentWidth = _contentScrollView.bounds.size.width;
    _contentContainer.frame = CGRectMake(0, 0, contentWidth, _contentScrollView.bounds.size.height);
    
    __block CGFloat y = 8.0f;

    // ===== TAB INFO =====
    if (tab == MenuTabInfo) {
        CGFloat rowW = contentWidth - 14.0f;
        CGFloat startX = 8.0f;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(startX, y, rowW, 26)];
        title.text = @"FFExt Developer Information";
        title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        title.textColor = kColorText;
        [_contentContainer addSubview:title];
        y += 34;

        auto createRow = ^(NSString *label, NSString *value, CGFloat currentY) {
            UIView *row = [[UIView alloc] initWithFrame:CGRectMake(startX, currentY, rowW, 24)];
            row.backgroundColor = [UIColor clearColor];
            
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, rowW * 0.40, 24)];
            lbl.text = [NSString stringWithFormat:@"%@:", label];
            lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            lbl.textColor = kColorMuted;
            [row addSubview:lbl];
            
            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(rowW * 0.40, 0, rowW * 0.60, 24)];
            val.text = value;
            val.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            val.textColor = kColorText;
            val.textAlignment = NSTextAlignmentRight;
            val.adjustsFontSizeToFitWidth = YES;
            val.minimumScaleFactor = 0.75f;
            [row addSubview:val];
            
            [_contentContainer addSubview:row];
            return currentY + 28;
        };
        
        y = createRow(@"Tên Game", @"Garena Free Fire", y);
        y = createRow(@"Vison Game", @"1.126.1", y);
        y = createRow(@"Vison FFExt", @"v2.0.2", y);
        
        y += 8;
        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(startX, y, rowW, 1)];
        sep.backgroundColor = kColorSeparator;
        [_contentContainer addSubview:sep];
        y += 14;
        
        UILabel *devTitle = [[UILabel alloc] initWithFrame:CGRectMake(startX, y, rowW, 20)];
        devTitle.text = @"DEVELOPER INFO";
        devTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        devTitle.textColor = kColorAccent;
        [_contentContainer addSubview:devTitle];
        y += 24;

        y = createRow(@"Admin Support", @"Telegram : @ktienxios", y);
        y = createRow(@"Product", @"TIPA FFExternal KTIEN IOS", y);
        
        UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(startX, y + 12, rowW, 16)];
        foot.text = @"Build v2.0.2 — Dedicated for FreeFire";
        foot.font = [UIFont italicSystemFontOfSize:10];
        foot.textColor = kColorMuted;
        foot.textAlignment = NSTextAlignmentCenter;
        [_contentContainer addSubview:foot];
        y += 32;

        [self finalizeContentHeight:y contentWidth:contentWidth];
        return;
    }

    // ===== TAB MEMORY =====
    if (tab == MenuTabMemory) {
        NSArray *rows = @[
            @[ @"MEMORY FUNCTIONS", @"__section__" ],
            @[ @"No ReLoad", @"NoReLoad" ],
            @[ @"Vô Hạn Đạn", @"VohaDan" ],
            @[ @"Cam Cao", @"camcao" ], 
        ];

        CGFloat padX = 10.0f, gapX = 6.0f;
        CGFloat colW = (contentWidth - padX * 2.0f - gapX) / 2.0f;

        NSMutableArray *pending = [NSMutableArray array];

        auto flushPending = ^{
            for (NSUInteger i = 0; i < pending.count; i += 2) {
                NSArray *L = pending[i];
                NSArray *R = (i + 1 < pending.count) ? pending[i + 1] : nil;
                CGRect lf = CGRectMake(padX, y, colW, kRowHeight);
                [_contentContainer addSubview:[self buildCheckboxCellWithTitle:L[0] key:L[1] frame:lf]];
                if (R) {
                    CGRect rf = CGRectMake(padX + colW + gapX, y, colW, kRowHeight);
                    [_contentContainer addSubview:[self buildCheckboxCellWithTitle:R[0] key:R[1] frame:rf]];
                }
                y += kRowHeight;
            }
            [pending removeAllObjects];
        };

        for (NSArray *row in rows) {
            NSString *title = row[0];
            NSString *key = row[1];

            if ([key isEqualToString:@"__section__"]) {
                flushPending();
                UILabel *sec = [[UILabel alloc] initWithFrame:CGRectMake(10, y + 6, contentWidth - 20, 16)];
                sec.text = title;
                sec.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
                sec.textColor = kColorMuted;
                [_contentContainer addSubview:sec];
                y += 26.0f;
                continue;
            }
            [pending addObject:row];
        }
        flushPending();

        y += 4;
        CGFloat rowW = contentWidth - 20.0f;
        y = [self addSliderRow:@"Tỷ lệ Cam Cao"
                        format:@"Cam Cao  —  %.0f"
                           key:@"Campc" def:1.0f min:1 max:100
                      labelTag:7001 sliderTag:7002 y:y width:rowW];

        [self finalizeContentHeight:y contentWidth:contentWidth];
        return;
    }

    // ===== TAB ESP & AIMBOT =====
    NSArray *rows = nil;
    if (tab == MenuTabESP) {
        rows = @[
            @[ @"ESP FUNCTION", @"__section__" ],
            @[ @"2D Box", @"Box" ],
            @[ @"Corner Box", @"box" ],
            @[ @"Health Bar", @"Health" ],
            @[ @"Enemy Count", @"Count" ],
            @[ @"Show Name", @"Name" ],
            @[ @"Bone Work", @"Bone" ],
            @[ @"Show Distance", @"Dis" ], 
            @[ @"Radar Line", @"Line" ],
            @[ @"Show FOV Circle", @"ShowFov" ],
            @[ @"OTHER PREFS", @"__section__" ],
            @[ @"ESP Real Bot", (NSString *)NSSENCRYPT("EspBot") ],
            @[ @"Exit HUD", @"__exit_hud__" ],
        ];
    } else {
        rows = @[
            @[ @"AIMBOT SETTINGS", @"__section__" ],
            @[ @"Auto Aimbot", @"Aimbot" ],
            @[ @"Silent Aim", @"SilentAim" ],
            @[ @"Ignore Bot", @"AimIgnoreBot" ],
            @[ @"Ignore Knocked", @"AimIgnoreKnock" ],
            @[ @"Aim Line Speed", @"AimCheckVisible" ],
            @[ @"HUD AUX BUTTON", @"__section__" ],
            @[ @"Float AIM Btn", (NSString *)NSSENCRYPT("FloatAimBtn") ],
        ];
    }

    CGFloat padX = 10.0f, gapX = 6.0f;
    CGFloat colW = (contentWidth - padX * 2.0f - gapX) / 2.0f;

    NSMutableArray *pending = [NSMutableArray array];

    auto flushPending = ^{
        for (NSUInteger i = 0; i < pending.count; i += 2) {
            NSArray *L = pending[i];
            NSArray *R = (i + 1 < pending.count) ? pending[i + 1] : nil;
            CGRect lf = CGRectMake(padX, y, colW, kRowHeight);
            [_contentContainer addSubview:[self buildCheckboxCellWithTitle:L[0] key:L[1] frame:lf]];
            if (R) {
                CGRect rf = CGRectMake(padX + colW + gapX, y, colW, kRowHeight);
                [_contentContainer addSubview:[self buildCheckboxCellWithTitle:R[0] key:R[1] frame:rf]];
            }
            y += kRowHeight;
        }
        [pending removeAllObjects];
    };

    for (NSArray *row in rows) {
        NSString *title = row[0];
        NSString *key = row[1];

        if ([key isEqualToString:@"__section__"]) {
            flushPending();
            UILabel *sec = [[UILabel alloc] initWithFrame:CGRectMake(10, y + 6, contentWidth - 20, 16)];
            sec.text = title;
            sec.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
            sec.textColor = kColorMuted;
            [_contentContainer addSubview:sec];
            y += 26.0f;
            continue;
        }

        if ([key isEqualToString:@"__exit_hud__"]) {
            flushPending();
            CGFloat rowW = contentWidth - 20.0f;

            UIView *rv = [[UIView alloc] initWithFrame:CGRectMake(10, y, rowW, kRowHeight)];
            rv.backgroundColor = kColorDangerBG;
            rv.layer.cornerRadius = 6.0f;
            rv.layer.borderWidth = 1.0f;
            rv.layer.borderColor = [UIColor colorWithRed:1.0f green:0.3f blue:0.3f alpha:0.4f].CGColor;

            objc_setAssociatedObject(rv, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, rowW - 12, kRowHeight)];
            lbl.text = title;
            lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            lbl.textColor = kColorDanger;

            [rv addSubview:lbl];
            [_contentContainer addSubview:rv];

            y += kRowHeight + 4.0f;
            continue;
        }

        [pending addObject:row];
    }
    flushPending();

    if (tab == MenuTabAimbot) {
        y += 6;
        CGFloat rowW = contentWidth - 20.0f;

        UILabel *sec1 = [[UILabel alloc] initWithFrame:CGRectMake(10, y + 3, rowW, 16)];
        sec1.text = @"CRITICAL CONFIGS";
        sec1.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        sec1.textColor = kColorMuted;
        [_contentContainer addSubview:sec1]; y += 24;

        y = [self addSegmentedRow:@"Trigger Mode" key:@"TriggerMode" y:y width:rowW];
        y = [self addSegmentedRow:@"Aim Target Lock" key:@"AimPos" y:y width:rowW];
        y += 6;

        UILabel *sec2 = [[UILabel alloc] initWithFrame:CGRectMake(10, y + 3, rowW, 16)];
        sec2.text = @"GEOMETRIC PARAMETERS";
        sec2.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        sec2.textColor = kColorMuted;
        [_contentContainer addSubview:sec2]; y += 24;

        y = [self addSliderRow:@"Aim FOV Radius"
                        format:@"Aim FOV  —  %.0f px"
                           key:@"Fov" def:150.0f min:10 max:500
                      labelTag:6001 sliderTag:6002 y:y width:rowW];
        y = [self addSliderRow:@"Aim Max Distance"
                        format:@"Aim Distance  —  %.0f m"
                           key:@"Distance" def:200.0f min:1 max:400
                      labelTag:6003 sliderTag:6004 y:y width:rowW];
        y = [self addSliderRow:@"Aim Lock Speed"
                        format:@"Aim Speed  —  %.0f%%"
                           key:@"AimSpeed" def:100.0f min:1 max:100
                      labelTag:6005 sliderTag:6006 y:y width:rowW];
    }

    [self finalizeContentHeight:y contentWidth:contentWidth];
}

- (void)finalizeContentHeight:(CGFloat)y contentWidth:(CGFloat)cw {
    _contentContainer.frame = CGRectMake(0, 0, cw, y + 8);
    _contentScrollView.contentSize = _contentContainer.frame.size;
    [self updateScrollbarLayout];
}

- (CGFloat)addSliderRow:(NSString *)name format:(NSString *)fmt key:(NSString *)key
                    def:(CGFloat)def min:(float)minV max:(float)maxV
               labelTag:(NSInteger)ltag sliderTag:(NSInteger)stag
                      y:(CGFloat)y width:(CGFloat)rowW {
    CGFloat val = ESPPrefsFloat(key, def);
    if (val < minV || val > maxV) val = def;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, rowW, 16)];
    lbl.text = [NSString stringWithFormat:fmt, val];
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    lbl.textColor = kColorText; lbl.tag = ltag;
    [_contentContainer addSubview:lbl]; y += 18;

    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(10, y, rowW, 24)];
    sl.minimumValue = minV; sl.maximumValue = maxV; sl.value = (float)val;
    sl.minimumTrackTintColor = kColorSliderFill;
    sl.maximumTrackTintColor = kColorSliderTrack;
    if (@available(iOS 13.0, *)) {
        sl.thumbTintColor = [UIColor whiteColor];
    } else {
        sl.thumbTintColor = kColorSliderFill;
    }
    sl.tag = stag;
    objc_setAssociatedObject(sl, "key", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sl, "label", lbl, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(sl, "fmt", fmt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_contentContainer addSubview:sl]; y += 28;
    return y;
}

- (void)checkboxTappedWithView:(UIView *)box {
    NSString *key = objc_getAssociatedObject(box, "key");
    if (!key) return;
    BOOL newVal = (box.tag == 0);
    [self setCheckbox:box checked:newVal];
    ESPPrefsSetBool(key, newVal);
    [[NSUserDefaults standardUserDefaults] setBool:newVal forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ESPSyncFromPrefs();
    [self notifyMenuView];
}

- (void)notifyMenuView {
    for (UIView *v = self.view.superview; v; v = v.superview) {
        if ([v isKindOfClass:[MenuView class]]) {
            [(MenuView *)v reloadFloatingAuxButtonsFromPrefs]; break;
        }
    }
}

- (void)sliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, "key");
    if (!key) return;
    float val = sender.value;
    ESPPrefsSetFloat(key, val);
    [[NSUserDefaults standardUserDefaults] setFloat:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ESPSyncFromPrefs();
    UILabel *lbl = objc_getAssociatedObject(sender, "label");
    NSString *fmt = objc_getAssociatedObject(sender, "fmt");
    if (lbl && fmt) lbl.text = [NSString stringWithFormat:fmt, val];
}

- (NSArray<NSString *> *)comboOptionsForKey:(NSString *)key {
    if ([key isEqualToString:@"box"]) return @[ @"2D Box", @"Corner" ];
    if ([key isEqualToString:@"TriggerMode"]) return @[ @"Auto", @"Fire", @"Scope", @"Combo" ];
    if ([key isEqualToString:@"AimPos"]) return @[ @"Head", @"Neck", @"Chest" ];
    return @[];
}

- (void)updateSegmentedRowVisual:(UIView *)row selectedIndex:(int)sel {
    NSArray<UIView *> *cells = objc_getAssociatedObject(row, "segCells");
    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        UIView *cell = cells[i];
        UILabel *lab = [cell viewWithTag:kSegmentLabelTag];
        if (i == sel) {
            cell.backgroundColor = kColorSegActive;
            if (lab) {
                lab.textColor = [UIColor whiteColor];
                lab.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
            }
        } else {
            cell.backgroundColor = [UIColor clearColor];
            if (lab) {
                lab.textColor = kColorMuted;
                lab.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            }
        }
    }
}

- (CGFloat)addSegmentedRow:(NSString *)title key:(NSString *)key y:(CGFloat)y width:(CGFloat)rowW {
    NSArray<NSString *> *opts = [self comboOptionsForKey:key];
    if (!opts.count) return y;

    const CGFloat titleH = 16, pillH = 26, vGap = 4, botPad = 5;
    CGFloat rowH = titleH + vGap + pillH + botPad;

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, rowW, rowH)];
    row.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(row, "segComboPrefsKey", key, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, rowW, titleH)];
    tl.text = title;
    tl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    tl.textColor = kColorMuted;
    [row addSubview:tl];

    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(0, titleH + vGap, rowW, pillH)];
    track.tag = kSegmentTrackTag;
    track.backgroundColor = kColorSegBG;
    track.layer.cornerRadius = 6;
    track.layer.borderWidth = 1;
    track.layer.borderColor = kColorBorder.CGColor;
    track.clipsToBounds = YES;
    [row addSubview:track];

    int sel = (int)ESPPrefsFloat(key, 0);
    if (sel < 0 || sel >= (int)opts.count) sel = 0;

    CGFloat segW = rowW / (CGFloat)opts.count;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)opts.count; i++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(segW*i+2, 2, segW-4, pillH-4)];
        cell.layer.cornerRadius = 4;
        cell.userInteractionEnabled = NO;
        UILabel *lab = [[UILabel alloc] initWithFrame:cell.bounds];
        lab.tag = kSegmentLabelTag; lab.text = opts[i];
        lab.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.textColor = kColorMuted;
        lab.adjustsFontSizeToFitWidth = YES;
        lab.minimumScaleFactor = 0.65;
        [cell addSubview:lab]; [track addSubview:cell]; [cells addObject:cell];
    }
    objc_setAssociatedObject(row, "segCells", cells, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSegmentedRowVisual:row selectedIndex:sel];
    [_contentContainer addSubview:row];
    return y + rowH + 4;
}

- (void)applySegmentedSelectionForRow:(UIView *)row touchInContent:(CGPoint)pt {
    NSString *key = objc_getAssociatedObject(row, "segComboPrefsKey");
    NSArray *cells = objc_getAssociatedObject(row, "segCells");
    UIView *track = [row viewWithTag:kSegmentTrackTag];
    if (!key || !track || !cells.count) return;

    CGPoint inRow = CGPointMake(pt.x - row.frame.origin.x, pt.y - row.frame.origin.y);
    if (!CGRectContainsPoint(track.frame, inRow)) return;

    CGFloat relX = inRow.x - track.frame.origin.x;
    NSInteger n = (NSInteger)cells.count;
    CGFloat w = track.bounds.size.width;
    NSInteger idx = (NSInteger)(relX / (w / (CGFloat)n));
    idx = MAX(0, MIN(n - 1, idx));

    ESPPrefsSetFloat(key, (float)idx);
    ESPSyncFromPrefs();
    [self updateSegmentedRowVisual:row selectedIndex:(int)idx];
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
    CGPoint p = [tap locationInView:self.view];
    if (!CGRectContainsPoint(_floatingPanel.frame, p)) [self closeTapped];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    return !CGRectContainsPoint(_floatingPanel.frame, [touch locationInView:self.view]);
}

- (BOOL)handleTouchAtViewPoint:(CGPoint)point phase:(NSInteger)phase pointerId:(NSInteger)pointerId {
    BOOL insidePanel = CGRectContainsPoint(_floatingPanel.frame, point);
    UITouchPhase ph = (UITouchPhase)phase;

    if (ph == UITouchPhaseBegan) {
        if (!insidePanel) return NO;
        if (_trackingPointerId != -1 && _trackingPointerId != pointerId) return NO;

        _trackingPointerId = pointerId;
        _touchOnClose = _touchOnExitHUD = _menuDragging = NO;
        _activeCheckbox = nil; _segmentedRowTracking = nil; _sliderTracking = nil;
        _isScrollingContent = NO;
        [self stopScrollInertia];
        _scrollVelocity = 0;

        CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x,
                                      point.y - _floatingPanel.frame.origin.y);

        if (inPanel.y < kHeaderHeight) {
            CGRect closeRect = CGRectMake(kPanelWidth - 36, (kHeaderHeight - 26) / 2.0f, 26, 26);
            if (CGRectContainsPoint(CGRectInset(closeRect, -8, -8), inPanel)) {
                _touchOnClose = YES;
            } else {
                _menuDragging = YES;
                _menuDragStartOrigin = _floatingPanel.frame.origin;
                _menuDragStartTouch = point;
            }
            return YES;
        }

        if (inPanel.x < kSideTabWidth) {
            CGFloat topPad = 18.0f, gap = 10.0f;
            CGFloat tabH = 34.0f;
            for (NSInteger i = 0; i < 4; i++) {
                CGFloat ty = topPad + (CGFloat)i * (tabH + gap);
                CGRect tabRect = CGRectMake(5, ty + kHeaderHeight, kSideTabWidth - 10.0f, tabH);
                if (CGRectContainsPoint(tabRect, inPanel)) {
                    if (i != (NSInteger)_currentTab) [self tabButtonTapped:_tabButtons[i]];
                    return YES;
                }
            }
            return YES;
        }

        CGFloat contentLeft = kSideTabWidth;
        if (inPanel.x >= (kPanelWidth - kScrollBarWidth - 4)) {
            CGFloat trackY = inPanel.y - kHeaderHeight;
            CGFloat viewH = _contentScrollView.bounds.size.height;
            CGFloat contentH = _contentScrollView.contentSize.height;
            CGFloat maxOff = contentH - viewH;
            if (maxOff > 0) {
                CGFloat tY = _scrollbarThumb.frame.origin.y;
                CGFloat tH = _scrollbarThumb.frame.size.height;
                if (trackY >= tY && trackY <= tY + tH) {
                    _scrollbarDragging = YES;
                    _scrollbarDragStartY = point.y;
                    _scrollbarDragStartOffsetY = _contentScrollView.contentOffset.y;
                } else {
                    CGFloat trackH = _scrollbarTrack.frame.size.height;
                    CGFloat range = trackH - tH;
                    if (range > 0) {
                        CGFloat no = (trackY / trackH) * maxOff;
                        _contentScrollView.contentOffset = CGPointMake(0, MAX(0, MIN(maxOff, no)));
                        [self updateScrollbarLayout];
                    }
                }
            }
            return YES;
        }

        _scrollLastTouchY = point.y;
        _scrollLastTime = CACurrentMediaTime();

        CGPoint inContent = CGPointMake(inPanel.x - contentLeft - 5,
                                        inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);

        for (UIView *rv in _contentContainer.subviews) {
            if ([rv isKindOfClass:[UISlider class]] || [rv isKindOfClass:[UILabel class]]) continue;
            if (!CGRectContainsPoint(rv.frame, inContent)) continue;

            NSString *segKey = objc_getAssociatedObject(rv, "segComboPrefsKey");
            if (segKey) {
                UIView *track = [rv viewWithTag:kSegmentTrackTag];
                CGPoint inRow = CGPointMake(inContent.x - rv.frame.origin.x,
                                            inContent.y - rv.frame.origin.y);
                if (track && CGRectContainsPoint(track.frame, inRow))
                    _segmentedRowTracking = rv;
                break;
            }

            NSString *rk = objc_getAssociatedObject(rv, "key");
            if ([rk isEqualToString:@"__exit_hud__"]) { _touchOnExitHUD = YES; break; }

            for (UIView *sub in rv.subviews) {
                if (objc_getAssociatedObject(sub, "isCheckbox")) { _activeCheckbox = sub; break; }
            }
            break;
        }

        if (!_activeCheckbox && !_touchOnExitHUD && !_segmentedRowTracking) {
            for (UIView *v in _contentContainer.subviews) {
                if ([v isKindOfClass:[UISlider class]] && CGRectContainsPoint(v.frame, inContent)) {
                    _sliderTracking = (UISlider *)v; break;
                }
            }
        }
        return YES;
    }

    if (ph == UITouchPhaseMoved) {
        if (pointerId != _trackingPointerId) return NO;

        if (_sliderTracking) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x,
                                          point.y - _floatingPanel.frame.origin.y);
            CGPoint inContent = CGPointMake(inPanel.x - kSideTabWidth - 5,
                                            inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);
            UISlider *sl = _sliderTracking;
            CGFloat ratio = (inContent.x - sl.frame.origin.x) / sl.frame.size.width;
            ratio = MAX(0, MIN(1, ratio));
            sl.value = sl.minimumValue + (float)ratio * (sl.maximumValue - sl.minimumValue);
            [self sliderChanged:sl];
            return YES;
        }

        if (_scrollbarDragging) {
            CGFloat contentH = _contentScrollView.contentSize.height;
            CGFloat viewH = _contentScrollView.bounds.size.height;
            CGFloat maxOff = contentH - viewH;
            if (maxOff <= 0) { _scrollbarDragging = NO; return YES; }
            CGFloat newOff = _scrollbarDragStartOffsetY + (point.y - _scrollbarDragStartY);
            _contentScrollView.contentOffset = CGPointMake(0, MAX(0, MIN(maxOff, newOff)));
            [self updateScrollbarLayout];
            return YES;
        }

        if (_menuDragging) {
            CGFloat dx = point.x - _menuDragStartTouch.x;
            CGFloat dy = point.y - _menuDragStartTouch.y;
            CGRect screen = self.view.bounds;
            CGFloat newX = MAX(0, MIN(screen.size.width - kPanelWidth, _menuDragStartOrigin.x + dx));
            CGFloat newY = MAX(0, MIN(screen.size.height - kPanelHeight, _menuDragStartOrigin.y + dy));
            _floatingPanel.frame = CGRectMake(newX, newY, kPanelWidth, kPanelHeight);
            return YES;
        }

        CGFloat inPanelX = point.x - _floatingPanel.frame.origin.x;
        CGFloat inPanelY = point.y - _floatingPanel.frame.origin.y;
        if (inPanelY > kHeaderHeight && inPanelX > kSideTabWidth) {
            CFTimeInterval now = CACurrentMediaTime();
            CGFloat dy = point.y - _scrollLastTouchY;
            if (now - _scrollLastTime > 0.001) _scrollVelocity = -dy / (CGFloat)((now - _scrollLastTime) * 60.0);
            [self applyScrollDelta:-dy];
            if (ABS(dy) > 3) { _isScrollingContent = YES; _activeCheckbox = nil; _segmentedRowTracking = nil; _touchOnExitHUD = NO; }
            _scrollLastTouchY = point.y;
            _scrollLastTime = now;
            return YES;
        }
    }

    if (ph == UITouchPhaseEnded || ph == UITouchPhaseCancelled) {
        if (pointerId != _trackingPointerId) return NO;

        if (_touchOnClose) {
            [self closeTapped];
        } else if (_touchOnExitHUD && !_isScrollingContent && self.onExitHUDRequested) {
            self.onExitHUDRequested();
        } else if (_activeCheckbox && !_isScrollingContent) {
            [self checkboxTappedWithView:_activeCheckbox];
        } else if (_segmentedRowTracking && !_isScrollingContent) {
            CGPoint inPanel = CGPointMake(point.x - _floatingPanel.frame.origin.x,
                                          point.y - _floatingPanel.frame.origin.y);
            CGPoint inContent = CGPointMake(inPanel.x - kSideTabWidth - 5,
                                            inPanel.y - kHeaderHeight + _contentScrollView.contentOffset.y);
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
        _touchOnClose = _touchOnExitHUD = _menuDragging = _scrollbarDragging = NO;
        _activeCheckbox = nil; _segmentedRowTracking = nil; _sliderTracking = nil;
        _isScrollingContent = NO;
        return YES;
    }

    return (insidePanel && pointerId == _trackingPointerId) || _scrollbarDragging;
}

@end