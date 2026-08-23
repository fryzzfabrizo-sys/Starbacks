#import "InfoViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "API/APIClient.h"

@interface InfoRowView : UIView
@property (nonatomic, strong) UILabel *leftLabel;
@property (nonatomic, strong) UILabel *rightLabel;
@end

@implementation InfoRowView

- (instancetype)initWithLeft:(NSString *)left right:(NSString *)right {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];

    _leftLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _leftLabel.text = left ?: @"";
    _leftLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _leftLabel.textColor = [UIColor whiteColor];
    [self addSubview:_leftLabel];

    _rightLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _rightLabel.text = right ?: @"—";
    _rightLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _rightLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _rightLabel.textAlignment = NSTextAlignmentRight;
    _rightLabel.adjustsFontSizeToFitWidth = YES;
    _rightLabel.minimumScaleFactor = 0.75;
    [self addSubview:_rightLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    
    _leftLabel.frame = CGRectMake(18, 0, w * 0.40f - 18, h);
    _rightLabel.frame = CGRectMake(w * 0.40f, 0, w * 0.60f - 18, h);
}
@end

// ============================================================
// CARD KEY INFO - GIỐNG HỆT BUILD INFO (ĐÃ GỌN LẠI)
// ============================================================
@interface KeyInfoCardView : UIView
@property (nonatomic, strong) NSArray<InfoRowView *> *rows;
@end

@implementation KeyInfoCardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        self.layer.cornerRadius = 24;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.2;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
        
        // Gradient nền giống BUILD INFO
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[
            (__bridge id)[UIColor colorWithWhite:0.12 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithWhite:0.10 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithWhite:0.08 alpha:1.0].CGColor
        ];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
        gradient.frame = self.bounds;
        [self.layer insertSublayer:gradient atIndex:0];
        
        // Các dòng thông tin key - KHÔNG CÓ TIÊU ĐỀ RIÊNG
        NSMutableArray *rowItems = [NSMutableArray array];
        
        // Key
        const char* key = apiclient_get_key();
        NSString *keyString = key ? [NSString stringWithUTF8String:key] : @"Đang tải...";
        InfoRowView *r1 = [[InfoRowView alloc] initWithLeft:@"Key" right:keyString];
        [self addSubview:r1];
        [rowItems addObject:r1];
        
        // Hết hạn
        const char* expired = apiclient_get_expired_at_local();
        NSString *expiredString = expired ? [NSString stringWithUTF8String:expired] : @"Vĩnh viễn";
        InfoRowView *r2 = [[InfoRowView alloc] initWithLeft:@"Hết hạn" right:expiredString];
        [self addSubview:r2];
        [rowItems addObject:r2];
        
        // Device
        const char* device = apiclient_get_device_model();
        NSString *deviceString = device ? [NSString stringWithUTF8String:device] : @"Unknown";
        InfoRowView *r3 = [[InfoRowView alloc] initWithLeft:@"Device" right:deviceString];
        [self addSubview:r3];
        [rowItems addObject:r3];
        
        // Version Game
        InfoRowView *r4 = [[InfoRowView alloc] initWithLeft:@"Version Game" right:@"1.126.1"];
        [self addSubview:r4];
        [rowItems addObject:r4];
        
        // Build Menu
        InfoRowView *r5 = [[InfoRowView alloc] initWithLeft:@"Build Menu" right:@"2.0.2"];
        [self addSubview:r5];
        [rowItems addObject:r5];
        
        // Owner
        InfoRowView *r6 = [[InfoRowView alloc] initWithLeft:@"Owner" right:@"@ktienxios"];
        [self addSubview:r6];
        [rowItems addObject:r6];
        
        _rows = rowItems;
        
        // Divider giữa các dòng
        for (NSUInteger i = 0; i < _rows.count; i++) {
            if (i != _rows.count - 1) {
                UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(18, 0, frame.size.width - 36, 0.5)];
                sep.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
                sep.tag = 8000 + (int)i;
                [self addSubview:sep];
            }
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat rowH = 44;
    CGFloat startY = 8; // Giảm padding trên xuống
    
    for (NSUInteger i = 0; i < _rows.count; i++) {
        InfoRowView *rv = _rows[i];
        rv.frame = CGRectMake(0, startY + (CGFloat)i * rowH, w, rowH);
        
        UIView *sep = [self viewWithTag:8000 + (int)i];
        if (sep) {
            sep.frame = CGRectMake(18, startY + (CGFloat)(i + 1) * rowH - 0.5, w - 36, 0.5);
        }
    }
}

- (void)updateKeyInfo {
    // Cập nhật lại thông tin từ server
    const char* key = apiclient_get_key();
    NSString *keyString = key ? [NSString stringWithUTF8String:key] : @"Đang tải...";
    ((InfoRowView *)_rows[0]).rightLabel.text = keyString;
    
    const char* expired = apiclient_get_expired_at_local();
    NSString *expiredString = expired ? [NSString stringWithUTF8String:expired] : @"Vĩnh viễn";
    ((InfoRowView *)_rows[1]).rightLabel.text = expiredString;
    
    const char* device = apiclient_get_device_model();
    NSString *deviceString = device ? [NSString stringWithUTF8String:device] : @"Unknown";
    ((InfoRowView *)_rows[2]).rightLabel.text = deviceString;
}
@end
// ============================================================

@interface InfoViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subTitleLabel;
@property (nonatomic, strong) UIView *buildInfoCard;
@property (nonatomic, strong) UIView *keyInfoCard;
@property (nonatomic, strong) CAGradientLayer *cardGradient;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) NSArray<InfoRowView *> *rows;
@property (nonatomic, strong) KeyInfoCardView *keyInfoView;
@end

@implementation InfoViewController

- (UIColor *)accent { return [UIColor whiteColor]; }

- (void)viewDidLoad {
    [super viewDidLoad];

    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.frame = self.view.bounds;
    bg.colors = @[
        (__bridge id)[UIColor blackColor].CGColor,
        (__bridge id)[UIColor blackColor].CGColor
    ];
    bg.locations = @[@0.0, @0.5, @1.0];
    [self.view.layer insertSublayer:bg atIndex:0];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"BUILD INFO";
    _titleLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightBlack];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.layer.shadowColor = [UIColor whiteColor].CGColor;
    _titleLabel.layer.shadowRadius = 16;
    _titleLabel.layer.shadowOpacity = 0.15;
    _titleLabel.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:_titleLabel];

    _subTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subTitleLabel.text = @"APPLICATION METADATA & SPECS";
    _subTitleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _subTitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [self.view addSubview:_subTitleLabel];

    // Card BUILD INFO (giữ nguyên)
    _buildInfoCard = [[UIView alloc] initWithFrame:CGRectZero];
    _buildInfoCard.layer.cornerRadius = 24;
    _buildInfoCard.clipsToBounds = YES;
    _buildInfoCard.layer.borderWidth = 1.2;
    _buildInfoCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
    [self.view addSubview:_buildInfoCard];

    _cardGradient = [CAGradientLayer layer];
    _cardGradient.colors = @[
        (__bridge id)[UIColor colorWithWhite:0.12 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:0.10 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithWhite:0.08 alpha:1.0].CGColor
    ];
    _cardGradient.startPoint = CGPointMake(0, 0);
    _cardGradient.endPoint = CGPointMake(1, 1);
    [_buildInfoCard.layer insertSublayer:_cardGradient atIndex:0];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _blurView.alpha = 0.98;
    [_buildInfoCard addSubview:_blurView];

    // Đọc dữ liệu từ Info.plist cho BUILD INFO
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    NSString *bundleName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"—";
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: @"—";
    NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"—";
    NSString *buildVer = info[@"CFBundleVersion"] ?: @"—";

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *created = [df stringFromDate:[NSDate date]];

    InfoRowView *r1 = [[InfoRowView alloc] initWithLeft:@"Build Name" right:bundleName];
    InfoRowView *r2 = [[InfoRowView alloc] initWithLeft:@"Build Number" right:buildVer];
    InfoRowView *r3 = [[InfoRowView alloc] initWithLeft:@"Product ID" right:bundleID];
    InfoRowView *r4 = [[InfoRowView alloc] initWithLeft:@"Version" right:shortVer];
    InfoRowView *r5 = [[InfoRowView alloc] initWithLeft:@"Compiled At" right:created];
    _rows = @[ r1, r2, r3, r4, r5 ];

    for (NSUInteger i = 0; i < _rows.count; i++) {
        [_buildInfoCard addSubview:_rows[i]];
        if (i != _rows.count - 1) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectZero];
            sep.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
            sep.tag = 9000 + (int)i;
            [_buildInfoCard addSubview:sep];
        }
    }
    
    // ============================================================
    // THÊM: CARD KEY INFO BÊN DƯỚI (GIỐNG HỆT BUILD INFO - GỌN)
    // ============================================================
    _keyInfoCard = [[KeyInfoCardView alloc] initWithFrame:CGRectZero];
    _keyInfoCard.tag = 9999;
    [self.view addSubview:_keyInfoCard];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width;

    _titleLabel.frame = CGRectMake(24, insets.top + 24, w - 48, 44);
    _subTitleLabel.frame = CGRectMake(26, CGRectGetMaxY(_titleLabel.frame) + 2, w - 52, 18);

    // Card BUILD INFO
    CGFloat cardX = 16;
    CGFloat cardW = w - 32;
    CGFloat cardY = CGRectGetMaxY(_subTitleLabel.frame) + 24;
    CGFloat rowH = 44;
    CGFloat cardH = rowH * _rows.count;
    _buildInfoCard.frame = CGRectMake(cardX, cardY, cardW, cardH);

    _blurView.frame = _buildInfoCard.bounds;
    _cardGradient.frame = _buildInfoCard.bounds;

    for (NSUInteger i = 0; i < _rows.count; i++) {
        InfoRowView *rv = _rows[i];
        rv.frame = CGRectMake(0, (CGFloat)i * rowH, cardW, rowH);
        
        UIView *sep = [_buildInfoCard viewWithTag:9000 + (int)i];
        if (sep) {
            sep.frame = CGRectMake(16, CGRectGetMaxY(rv.frame) - 0.5f, cardW - 32, 0.5f);
        }
    }
    
    // Card KEY INFO bên dưới - GỌN HƠN
    CGFloat keyY = CGRectGetMaxY(_buildInfoCard.frame) + 20;
    CGFloat keyH = 44 * 6 + 16; // 6 rows + padding nhỏ
    _keyInfoCard.frame = CGRectMake(cardX, keyY, cardW, keyH);
    [_keyInfoCard setNeedsLayout];
}

@end