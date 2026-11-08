#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <stdlib.h>

// =======================================================
// 0. HÀM SINH HỌC NGÓN TAY & CẤU TRÚC DỮ LIỆU ESP HOA
// =======================================================
static inline CGFloat randRange(CGFloat minVal, CGFloat maxVal) {
    return minVal + ((CGFloat)arc4random() / (CGFloat)UINT32_MAX) * (maxVal - minVal);
}

static inline CGPoint humanizePoint(CGPoint center, CGFloat maxRadius) {
    CGFloat u1 = fmax(0.0001, randRange(0.0, 1.0));
    CGFloat u2 = randRange(0.0, 1.0);
    CGFloat z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
    CGFloat z1 = sqrt(-2.0 * log(u1)) * sin(2.0 * M_PI * u2);
    CGFloat dx = fmax(-maxRadius, fmin(maxRadius, z0 * (maxRadius * 0.42)));
    CGFloat dy = fmax(-maxRadius, fmin(maxRadius, z1 * (maxRadius * 0.42)));
    return CGPointMake(center.x + dx, center.y + dy);
}

typedef struct {
    CGPoint screenPt;
    CGFloat score;
    CGFloat distToSelf;
    BOOL isWallClumped;
} FlowerSpot;

// =======================================================
// 1. UITOUCH NGỤY TRANG HỆ THỐNG (STEALTH BIOMETRICS)
// =======================================================
@interface AOVTouch : UITouch
@property (nonatomic, assign) UITouchPhase sPhase;
@property (nonatomic, assign) NSUInteger sTapCount;
@property (nonatomic, assign) NSTimeInterval sTime;
@property (nonatomic, strong) UIWindow *sWin;
@property (nonatomic, strong) UIView *sView;
@property (nonatomic, assign) CGPoint winLoc;
@property (nonatomic, assign) CGPoint prevWinLoc;
@property (nonatomic, assign) CGFloat sRadius;
@property (nonatomic, assign) CGFloat sForce;
- (instancetype)initWithWindow:(UIWindow *)win view:(UIView *)view loc:(CGPoint)loc;
- (void)moveToLocation:(CGPoint)newLoc;
- (void)setTouchPhase:(UITouchPhase)phase;
@end

@implementation AOVTouch
- (Class)class { return [UITouch class]; }
- (BOOL)isMemberOfClass:(Class)aClass { return aClass == [UITouch class]; }

- (instancetype)initWithWindow:(UIWindow *)win view:(UIView *)view loc:(CGPoint)loc {
    self = [super init];
    if (self) {
        _sWin = win;
        _sView = view;
        _winLoc = loc;
        _prevWinLoc = loc;
        _sTapCount = 1;
        _sPhase = UITouchPhaseBegan;
        _sTime = [[NSProcessInfo processInfo] systemUptime];
        _sRadius = randRange(11.4, 15.6);
        _sForce  = randRange(0.72, 1.28);
        [self syncPrivateFields:YES];
    }
    return self;
}

- (void)syncPrivateFields:(BOOL)resetPrev {
    SEL sW = NSSelectorFromString(@"setWindow:");
    if ([self respondsToSelector:sW]) ((void (*)(id, SEL, id))objc_msgSend)(self, sW, _sWin);
    SEL sV = NSSelectorFromString(@"setView:");
    if ([self respondsToSelector:sV]) ((void (*)(id, SEL, id))objc_msgSend)(self, sV, _sView);
    SEL sP = NSSelectorFromString(@"setPhase:");
    if ([self respondsToSelector:sP]) ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(self, sP, _sPhase);
    SEL sT = NSSelectorFromString(@"setTapCount:");
    if ([self respondsToSelector:sT]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(self, sT, _sTapCount);
    SEL sL = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    if ([self respondsToSelector:sL]) ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(self, sL, _winLoc, resetPrev);
    SEL sF = NSSelectorFromString(@"_setIsFirstTouchForView:");
    if ([self respondsToSelector:sF]) ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sF, YES);
    SEL sH = NSSelectorFromString(@"_setHidEvent:");
    if ([self respondsToSelector:sH]) ((void (*)(id, SEL, void *))objc_msgSend)(self, sH, NULL);
}

- (void)moveToLocation:(CGPoint)newLoc {
    _prevWinLoc = _winLoc;
    _winLoc = newLoc;
    _sPhase = UITouchPhaseMoved;
    _sTime = [[NSProcessInfo processInfo] systemUptime];
    _sRadius = fmax(9.5, fmin(17.5, _sRadius + randRange(-0.6, 0.6)));
    _sForce  = fmax(0.55, fmin(1.65, _sForce + randRange(-0.08, 0.08)));
    [self syncPrivateFields:NO];
}

- (void)setTouchPhase:(UITouchPhase)phase {
    _sPhase = phase;
    _sTime = [[NSProcessInfo processInfo] systemUptime];
    if (phase == UITouchPhaseEnded) {
        _sForce = randRange(0.10, 0.30);
        _sRadius = randRange(8.0, 10.5);
    }
    [self syncPrivateFields:NO];
}

- (UITouchPhase)phase { return _sPhase; }
- (NSUInteger)tapCount { return _sTapCount; }
- (NSTimeInterval)timestamp { return _sTime; }
- (UIWindow *)window { return _sWin; }
- (UIView *)view { return _sView; }
- (UITouchType)type { return UITouchTypeDirect; }
- (CGFloat)force { return _sForce; }
- (CGFloat)maximumPossibleForce { return 6.666667; }
- (CGFloat)majorRadius { return _sRadius; }
- (CGFloat)majorRadiusTolerance { return 3.55; }

- (CGPoint)locationInView:(UIView *)view {
    if (!view) return _winLoc;
    return _sWin ? [_sWin convertPoint:_winLoc toView:view] : _winLoc;
}

- (CGPoint)previousLocationInView:(UIView *)view {
    if (!view) return _prevWinLoc;
    return _sWin ? [_sWin convertPoint:_prevWinLoc toView:view] : _prevWinLoc;
}
@end

@interface AOVMultiEvent : UIEvent
@property (nonatomic, strong) NSMutableSet<UITouch *> *activeTouches;
@end

@implementation AOVMultiEvent
- (Class)class { return [UIEvent class]; }
- (instancetype)init {
    self = [super init];
    if (self) { _activeTouches = [NSMutableSet set]; }
    return self;
}
- (UIEventType)type { return UIEventTypeTouches; }
- (UIEventSubtype)subtype { return UIEventSubtypeNone; }
- (NSTimeInterval)timestamp { return [[NSProcessInfo processInfo] systemUptime]; }
- (NSSet<UITouch *> *)allTouches { return [_activeTouches copy]; }
- (NSSet<UITouch *> *)touchesForWindow:(UIWindow *)w { return [self allTouches]; }
- (NSSet<UITouch *> *)touchesForView:(UIView *)v { return [self allTouches]; }
- (NSSet<UITouch *> *)touchesForGestureRecognizer:(UIGestureRecognizer *)g { return [self allTouches]; }
@end

// =======================================================
// 2. LỚP VẼ ESP HOA RƠI & TIA SNAPLINE (FLOWER ESP OVERLAY)
// =======================================================
@interface FlowerESPOverlayView : UIView
@property (nonatomic, strong) CAShapeLayer *primaryLineLayer;
@property (nonatomic, strong) CAShapeLayer *secondaryLineLayer;
@property (nonatomic, strong) CAShapeLayer *enemyLineLayer;
@property (nonatomic, strong) NSMutableArray<UIView *> *flowerBoxes;
@property (nonatomic, strong) NSMutableArray<UILabel *> *flowerLabels;
@property (nonatomic, strong) UIView *enemyBox;
@property (nonatomic, strong) UILabel *enemyLabel;
- (void)renderWithSelfPos:(CGPoint)selfPos
                  flowers:(FlowerSpot *)flowers
              flowerCount:(int)count
                 hasEnemy:(BOOL)hasEnemy
                 enemyPos:(CGPoint)enemyPos;
- (void)clearESP;
@end

@implementation FlowerESPOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _secondaryLineLayer = [CAShapeLayer layer];
        _secondaryLineLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.75].CGColor;
        _secondaryLineLayer.fillColor = [UIColor clearColor].CGColor;
        _secondaryLineLayer.lineWidth = 1.6;
        _secondaryLineLayer.lineDashPattern = @[@4, @3];
        [self.layer addSublayer:_secondaryLineLayer];

        _primaryLineLayer = [CAShapeLayer layer];
        _primaryLineLayer.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.55 alpha:0.95].CGColor;
        _primaryLineLayer.fillColor = [UIColor clearColor].CGColor;
        _primaryLineLayer.lineWidth = 2.4;
        [self.layer addSublayer:_primaryLineLayer];

        _enemyLineLayer = [CAShapeLayer layer];
        _enemyLineLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.3 alpha:0.85].CGColor;
        _enemyLineLayer.fillColor = [UIColor clearColor].CGColor;
        _enemyLineLayer.lineWidth = 1.8;
        [self.layer addSublayer:_enemyLineLayer];

        _flowerBoxes = [NSMutableArray array];
        _flowerLabels = [NSMutableArray array];

        for (int i = 0; i < 3; i++) {
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
            box.backgroundColor = [UIColor clearColor];
            box.layer.cornerRadius = 16;
            box.layer.borderWidth = (i == 0) ? 2.4 : 1.8;
            box.hidden = YES;
            [self addSubview:box];
            [_flowerBoxes addObject:box];

            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(-28, -16, 88, 14)];
            lbl.font = [UIFont boldSystemFontOfSize:9];
            lbl.textAlignment = NSTextAlignmentCenter;
            lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
            lbl.layer.cornerRadius = 4;
            lbl.clipsToBounds = YES;
            [box addSubview:lbl];
            [_flowerLabels addObject:lbl];
        }

        _enemyBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
        _enemyBox.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.15];
        _enemyBox.layer.cornerRadius = 6;
        _enemyBox.layer.borderWidth = 2.0;
        _enemyBox.layer.borderColor = [UIColor systemRedColor].CGColor;
        _enemyBox.hidden = YES;
        [self addSubview:_enemyBox];

        _enemyLabel = [[UILabel alloc] initWithFrame:CGRectMake(-16, -15, 70, 13)];
        _enemyLabel.font = [UIFont boldSystemFontOfSize:9];
        _enemyLabel.textColor = [UIColor whiteColor];
        _enemyLabel.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.8];
        _enemyLabel.textAlignment = NSTextAlignmentCenter;
        _enemyLabel.text = @"MỤC TIÊU";
        _enemyLabel.layer.cornerRadius = 3;
        _enemyLabel.clipsToBounds = YES;
        [_enemyBox addSubview:_enemyLabel];
    }
    return self;
}

- (void)renderWithSelfPos:(CGPoint)selfPos
                  flowers:(FlowerSpot *)flowers
              flowerCount:(int)count
                 hasEnemy:(BOOL)hasEnemy
                 enemyPos:(CGPoint)enemyPos {
    UIBezierPath *priPath = [UIBezierPath bezierPath];
    UIBezierPath *secPath = [UIBezierPath bezierPath];
    UIBezierPath *enePath = [UIBezierPath bezierPath];

    for (int i = 0; i < 3; i++) {
        UIView *box = self.flowerBoxes[i];
        UILabel *lbl = self.flowerLabels[i];
        if (i < count) {
            FlowerSpot f = flowers[i];
            box.center = f.screenPt;
            box.hidden = NO;

            if (i == 0) {
                // Hoa ưu tiên #1 (Xanh Lục Neon hoặc Đỏ Tím nếu chụm tường)
                UIColor *c = f.isWallClumped ? [UIColor colorWithRed:0.0 green:1.0 blue:0.9 alpha:1.0]
                                             : [UIColor colorWithRed:0.1 green:1.0 blue:0.45 alpha:1.0];
                box.layer.borderColor = c.CGColor;
                box.backgroundColor = [c colorWithAlphaComponent:0.18];
                lbl.textColor = c;
                lbl.text = f.isWallClumped ? [NSString stringWithFormat:@"🌸F1•TƯỜNG (%.0fm)", f.distToSelf/25.0]
                                           : [NSString stringWithFormat:@"🌸F1•NHẶT (%.0fm)", f.distToSelf/25.0];

                [priPath moveToPoint:selfPos];
                [priPath addLineToPoint:f.screenPt];
            } else {
                // Hoa phụ #2, #3 (Vàng Cam)
                UIColor *c = [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:0.95];
                box.layer.borderColor = c.CGColor;
                box.backgroundColor = [c colorWithAlphaComponent:0.10];
                lbl.textColor = c;
                lbl.text = f.isWallClumped ? [NSString stringWithFormat:@"F%d•CHỤM", i + 1]
                                           : [NSString stringWithFormat:@"🌸F%d (%.0fm)", i + 1, f.distToSelf/25.0];

                // Vẽ đường nối chuỗi từ F1 -> F2 -> F3
                CGPoint prevPt = flowers[i - 1].screenPt;
                [secPath moveToPoint:prevPt];
                [secPath addLineToPoint:f.screenPt];
            }
        } else {
            box.hidden = YES;
        }
    }

    if (hasEnemy) {
        self.enemyBox.center = enemyPos;
        self.enemyBox.hidden = NO;
        [enePath moveToPoint:selfPos];
        [enePath addLineToPoint:enemyPos];
    } else {
        self.enemyBox.hidden = YES;
    }

    self.primaryLineLayer.path = priPath.CGPath;
    self.secondaryLineLayer.path = secPath.CGPath;
    self.enemyLineLayer.path = enePath.CGPath;
}

- (void)clearESP {
    self.primaryLineLayer.path = nil;
    self.secondaryLineLayer.path = nil;
    self.enemyLineLayer.path = nil;
    for (UIView *b in self.flowerBoxes) b.hidden = YES;
    self.enemyBox.hidden = YES;
}

@end

// =======================================================
// 3. CONTAINER CHỐNG CHỤP MÀN HÌNH (STREAMPROOF)
// =======================================================
@interface PassthroughContainerView : UIView
@end

@implementation PassthroughContainerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface SecureHostTextField : UITextField
@end

@implementation SecureHostTextField
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in [self.subviews reverseObjectEnumerator]) {
        CGPoint converted = [self convertPoint:point toView:sub];
        UIView *hit = [sub hitTest:converted withEvent:event];
        if (hit) return hit;
    }
    return nil;
}
- (BOOL)canBecomeFirstResponder { return NO; }
@end

// =======================================================
// 4. FLOBOT MAGIC V6 - MULTI-FLOWER ESP + WALL DE-CLUMPING
// =======================================================
@interface FloMagicManager : NSObject
@property (nonatomic, strong) SecureHostTextField *secureField;
@property (nonatomic, strong) PassthroughContainerView *rootContainer;
@property (nonatomic, strong) FlowerESPOverlayView *espOverlay;

// Giao diện
@property (nonatomic, strong) UIButton *floatingIcon;
@property (nonatomic, strong) UIButton *externalToggleBtn;
@property (nonatomic, strong) UIView *magicMenuCard;
@property (nonatomic, strong) UILabel *statusLabel;

// Các nút gạt
@property (nonatomic, strong) UISwitch *swMasterMua;
@property (nonatomic, strong) UISwitch *swDrawESP;
@property (nonatomic, strong) UISwitch *swUltFirst;
@property (nonatomic, strong) UISwitch *swChaseEnemy;
@property (nonatomic, strong) UISwitch *swAntiScreen;
@property (nonatomic, strong) UISwitch *swShowExtBtn;
@property (nonatomic, strong) UISwitch *swEditNodes;

// Mốc tọa độ
@property (nonatomic, strong) UIView *nodeJoy;
@property (nonatomic, strong) UIView *nodeAA;
@property (nonatomic, strong) UIView *nodeS1;
@property (nonatomic, strong) UIView *nodeS2;
@property (nonatomic, strong) UIView *nodeS3;

// Điều khiển cảm ứng & ESP Timer
@property (nonatomic, strong) AOVMultiEvent *fallbackEvent;
@property (nonatomic, strong) AOVTouch *joyTouch;
@property (nonatomic, strong) NSTimer *espPassiveTimer;
@property (nonatomic, assign) CGPoint currentJoyPos;

@property (nonatomic, assign) BOOL isMua;
@property (nonatomic, assign) BOOL isESPOn;
@property (nonatomic, assign) BOOL isMenuOpen;
@property (nonatomic, assign) BOOL prioUltFirst;
@property (nonatomic, assign) BOOL prioChaseEnemy;
@property (nonatomic, assign) NSInteger comboStep;
@property (nonatomic, assign) NSInteger triAngleIdx;
@property (nonatomic, assign) NSInteger sessionToken;
@property (nonatomic, assign) CGPoint lastEnemyVec;

+ (instancetype)shared;
- (void)setupAll;
@end

@implementation FloMagicManager

+ (instancetype)shared {
    static FloMagicManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[FloMagicManager alloc] init];
        inst.fallbackEvent = [[AOVMultiEvent alloc] init];
        inst.isESPOn = YES;
        inst.prioUltFirst = YES;
        inst.prioChaseEnemy = YES;
        inst.lastEnemyVec = CGPointMake(1.0, -0.4);
    });
    return inst;
}

- (UIWindow *)gameWindow {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in scene.windows) {
                if (!w.hidden && [self findUnityView:w]) return w;
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (UIView *)findUnityView:(UIView *)root {
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"UnityView"] || [cls containsString:@"UnityRendering"]) return root;
    for (UIView *sub in root.subviews) {
        UIView *v = [self findUnityView:sub];
        if (v) return v;
    }
    return nil;
}

- (void)setupAll {
    UIWindow *win = [self gameWindow];
    if (!win || self.rootContainer) return;

    CGSize sz = win.bounds.size;
    CGFloat W = MAX(sz.width, sz.height);
    CGFloat H = MIN(sz.width, sz.height);
    CGRect fullRect = CGRectMake(0, 0, W, H);

    // 1. Lớp bảo mật chống chụp/quay màn hình
    self.secureField = [[SecureHostTextField alloc] initWithFrame:fullRect];
    self.secureField.secureTextEntry = YES;
    self.secureField.userInteractionEnabled = YES;
    self.secureField.backgroundColor = [UIColor clearColor];
    [win addSubview:self.secureField];

    UIView *secureCanvas = self.secureField.subviews.firstObject ?: self.secureField;
    secureCanvas.frame = fullRect;
    secureCanvas.userInteractionEnabled = YES;

    self.rootContainer = [[PassthroughContainerView alloc] initWithFrame:fullRect];
    self.rootContainer.backgroundColor = [UIColor clearColor];
    self.rootContainer.userInteractionEnabled = YES;
    [secureCanvas addSubview:self.rootContainer];

    // 2. Lớp vẽ ESP Hoa Rơi & Đường Dẫn Tia Laser
    self.espOverlay = [[FlowerESPOverlayView alloc] initWithFrame:fullRect];
    [self.rootContainer addSubview:self.espOverlay];

    // 3. Mốc tọa độ 5 nút
    self.nodeJoy = [self createSkillNode:@"JOY" pt:CGPointMake(W * 0.16, H * 0.77) color:[UIColor systemBlueColor]];
    self.nodeAA  = [self createSkillNode:@"ĐÁNH" pt:CGPointMake(W * 0.89, H * 0.81) color:[UIColor systemRedColor]];
    self.nodeS1  = [self createSkillNode:@"S1" pt:CGPointMake(W * 0.72, H * 0.84) color:[UIColor systemOrangeColor]];
    self.nodeS2  = [self createSkillNode:@"S2" pt:CGPointMake(W * 0.77, H * 0.63) color:[UIColor systemPurpleColor]];
    self.nodeS3  = [self createSkillNode:@"ULTI" pt:CGPointMake(W * 0.86, H * 0.49) color:[UIColor systemYellowColor]];

    [self.rootContainer addSubview:self.nodeJoy];
    [self.rootContainer addSubview:self.nodeAA];
    [self.rootContainer addSubview:self.nodeS1];
    [self.rootContainer addSubview:self.nodeS2];
    [self.rootContainer addSubview:self.nodeS3];

    // 4. Nút ON/OFF Nhanh Bên Ngoài
    self.externalToggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.externalToggleBtn.frame = CGRectMake(W * 0.62, H * 0.78, 92, 36);
    self.externalToggleBtn.backgroundColor = [[UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0] colorWithAlphaComponent:0.88];
    self.externalToggleBtn.layer.cornerRadius = 18;
    self.externalToggleBtn.layer.borderWidth = 1.8;
    self.externalToggleBtn.layer.borderColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.65 alpha:1.0].CGColor;
    self.externalToggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.externalToggleBtn setTitle:@"🌸 MÚA: OFF" forState:UIControlStateNormal];
    [self.externalToggleBtn setTitleColor:[UIColor colorWithRed:0.3 green:1.0 blue:0.7 alpha:1.0] forState:UIControlStateNormal];
    [self.externalToggleBtn addTarget:self action:@selector(onTapExternalToggle) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *panExt = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    [self.externalToggleBtn addGestureRecognizer:panExt];
    [self.rootContainer addSubview:self.externalToggleBtn];

    // 5. Icon Menu Nổi (Magic Orb)
    self.floatingIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingIcon.frame = CGRectMake(W * 0.12, 32, 46, 46);
    self.floatingIcon.backgroundColor = [UIColor colorWithRed:0.14 green:0.06 blue:0.28 alpha:0.92];
    self.floatingIcon.layer.cornerRadius = 23;
    self.floatingIcon.layer.borderWidth = 2.2;
    self.floatingIcon.layer.borderColor = [UIColor colorWithRed:0.75 green:0.35 blue:1.0 alpha:1.0].CGColor;
    self.floatingIcon.layer.shadowColor = [UIColor colorWithRed:0.7 green:0.2 blue:1.0 alpha:1.0].CGColor;
    self.floatingIcon.layer.shadowRadius = 8;
    self.floatingIcon.layer.shadowOpacity = 0.9;
    self.floatingIcon.layer.shadowOffset = CGSizeZero;
    self.floatingIcon.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.floatingIcon setTitle:@"⚜️" forState:UIControlStateNormal];
    [self.floatingIcon addTarget:self action:@selector(toggleMagicMenu) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *panIcon = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    [self.floatingIcon addGestureRecognizer:panIcon];
    [self.rootContainer addSubview:self.floatingIcon];

    // 6. Bảng Menu Magic
    [self buildMagicMenuCardWithScreenSize:CGSizeMake(W, H)];

    // 7. Chạy radar ESP quét hoa nền (ngay cả khi chưa bấm Múa vẫn thấy ESP hoa rơi)
    self.espPassiveTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                            target:self
                                                          selector:@selector(passiveESPTick)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (UIView *)createSkillNode:(NSString *)title pt:(CGPoint)pt color:(UIColor *)color {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 42, 42)];
    v.center = pt;
    v.backgroundColor = [color colorWithAlphaComponent:0.6];
    v.layer.cornerRadius = 21;
    v.layer.borderWidth = 2.0;
    v.layer.borderColor = [UIColor whiteColor].CGColor;
    v.hidden = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:v.bounds];
    lbl.text = title;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont boldSystemFontOfSize:10];
    lbl.textColor = [UIColor whiteColor];
    [v addSubview:lbl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    [v addGestureRecognizer:pan];
    return v;
}

- (void)buildMagicMenuCardWithScreenSize:(CGSize)scr {
    CGFloat cardW = 310;
    CGFloat cardH = 296;
    self.magicMenuCard = [[UIView alloc] initWithFrame:CGRectMake((scr.width - cardW)/2.0, (scr.height - cardH)/2.0, cardW, cardH)];
    self.magicMenuCard.layer.cornerRadius = 18;
    self.magicMenuCard.clipsToBounds = YES;
    self.magicMenuCard.layer.borderWidth = 1.6;
    self.magicMenuCard.layer.borderColor = [UIColor colorWithRed:0.65 green:0.35 blue:1.0 alpha:0.85].CGColor;
    self.magicMenuCard.hidden = YES;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.magicMenuCard.bounds;
    [self.magicMenuCard addSubview:blurView];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, 38)];
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = header.bounds;
    grad.colors = @[
        (id)[UIColor colorWithRed:0.45 green:0.12 blue:0.85 alpha:0.85].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.55 blue:0.85 alpha:0.85].CGColor
    ];
    grad.startPoint = CGPointMake(0, 0.5);
    grad.endPoint = CGPointMake(1, 0.5);
    [header.layer insertSublayer:grad atIndex:0];
    [self.magicMenuCard addSubview:header];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 245, 38)];
    titleLbl.text = @"⚜️ FLOBOT v6 • ESP & TÁCH HOA TƯỜNG";
    titleLbl.font = [UIFont boldSystemFontOfSize:11.5];
    titleLbl.textColor = [UIColor whiteColor];
    [header addSubview:titleLbl];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(cardW - 36, 5, 28, 28);
    closeBtn.layer.cornerRadius = 14;
    closeBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [closeBtn addTarget:self action:@selector(toggleMagicMenu) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    UIPanGestureRecognizer *panMenu = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    [header addGestureRecognizer:panMenu];

    self.swMasterMua  = [self addSwitchRowAtY:42  title:@"Kích hoạt Auto Múa (Stealth)" defaultOn:NO sel:@selector(onSwitchMaster:)];
    self.swDrawESP    = [self addSwitchRowAtY:74  title:@"Vẽ ESP Hoa Rơi + Tách Hoa Chụm" defaultOn:YES sel:@selector(onSwitchESP:)];
    self.swUltFirst   = [self addSwitchRowAtY:106 title:@"Ưu tiên Ulti (S3) trước S1" defaultOn:YES sel:@selector(onSwitchUltFirst:)];
    self.swChaseEnemy = [self addSwitchRowAtY:138 title:@"Ưu tiên Hoa gần Địch + Truy đuổi" defaultOn:YES sel:@selector(onSwitchChase:)];
    self.swAntiScreen = [self addSwitchRowAtY:170 title:@"Ẩn khi Chụp / Quay màn hình" defaultOn:YES sel:@selector(onSwitchAntiScreen:)];
    self.swShowExtBtn = [self addSwitchRowAtY:202 title:@"Hiện nút ON/OFF nhanh ở ngoài" defaultOn:YES sel:@selector(onSwitchShowExt:)];
    self.swEditNodes  = [self addSwitchRowAtY:234 title:@"Hiện & Gán vị trí Nút Kỹ Năng" defaultOn:NO sel:@selector(onSwitchEditNodes:)];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 270, cardW - 20, 18)];
    self.statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor cyanColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"ESP Hoa Rơi: Đang bật • Tự động tách hoa chụm tường";
    [self.magicMenuCard addSubview:self.statusLabel];

    [self.rootContainer addSubview:self.magicMenuCard];
}

- (UISwitch *)addSwitchRowAtY:(CGFloat)y title:(NSString *)title defaultOn:(BOOL)defOn sel:(SEL)action {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 225, 28)];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    [self.magicMenuCard addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(244, y - 2, 51, 31)];
    sw.on = defOn;
    sw.onTintColor = [UIColor colorWithRed:0.65 green:0.25 blue:1.0 alpha:1.0];
    sw.transform = CGAffineTransformMakeScale(0.76, 0.76);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.magicMenuCard addSubview:sw];
    return sw;
}

- (void)handleDrag:(UIPanGestureRecognizer *)g {
    CGPoint tr = [g translationInView:self.rootContainer];
    UIView *target = (g.view.superview == self.magicMenuCard) ? self.magicMenuCard : g.view;
    target.center = CGPointMake(target.center.x + tr.x, target.center.y + tr.y);
    [g setTranslation:CGPointZero inView:self.rootContainer];
}

- (void)toggleMagicMenu {
    self.isMenuOpen = !self.isMenuOpen;
    if (self.isMenuOpen) {
        self.magicMenuCard.hidden = NO;
        self.magicMenuCard.alpha = 0.0;
        self.magicMenuCard.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.18 animations:^{
            self.magicMenuCard.alpha = 1.0;
            self.magicMenuCard.transform = CGAffineTransformIdentity;
        }];
    } else {
        [UIView animateWithDuration:0.15 animations:^{
            self.magicMenuCard.alpha = 0.0;
            self.magicMenuCard.transform = CGAffineTransformMakeScale(0.85, 0.85);
        } completion:^(BOOL finished) {
            self.magicMenuCard.hidden = YES;
        }];
    }
}

- (void)onTapExternalToggle { [self setMuaActive:!self.isMua]; }
- (void)onSwitchMaster:(UISwitch *)sw { [self setMuaActive:sw.isOn]; }
- (void)onSwitchESP:(UISwitch *)sw {
    self.isESPOn = sw.isOn;
    self.espOverlay.hidden = !sw.isOn;
    if (!sw.isOn) [self.espOverlay clearESP];
}
- (void)onSwitchUltFirst:(UISwitch *)sw { self.prioUltFirst = sw.isOn; }
- (void)onSwitchChase:(UISwitch *)sw { self.prioChaseEnemy = sw.isOn; }
- (void)onSwitchAntiScreen:(UISwitch *)sw {
    self.secureField.secureTextEntry = sw.isOn;
    self.statusLabel.text = sw.isOn ? @"Đã BẬT ẩn chụp/quay màn hình" : @"Đã TẮT ẩn chụp màn hình";
}
- (void)onSwitchShowExt:(UISwitch *)sw { self.externalToggleBtn.hidden = !sw.isOn; }
- (void)onSwitchEditNodes:(UISwitch *)sw {
    BOOL hide = !sw.isOn;
    self.nodeJoy.hidden = hide;
    self.nodeAA.hidden  = hide;
    self.nodeS1.hidden  = hide;
    self.nodeS2.hidden  = hide;
    self.nodeS3.hidden  = hide;
}

- (void)setMuaActive:(BOOL)active {
    self.isMua = active;
    self.swMasterMua.on = active;
    self.sessionToken++;

    if (active) {
        [self.externalToggleBtn setTitle:@"⚡ MÚA: ON" forState:UIControlStateNormal];
        [self.externalToggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.externalToggleBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.35 alpha:0.92];
        self.externalToggleBtn.layer.borderColor = [UIColor yellowColor].CGColor;

        self.comboStep = 0;
        [self scheduleNextHumanizedTickWithToken:self.sessionToken];
    } else {
        [self.externalToggleBtn setTitle:@"🌸 MÚA: OFF" forState:UIControlStateNormal];
        [self.externalToggleBtn setTitleColor:[UIColor colorWithRed:0.3 green:1.0 blue:0.7 alpha:1.0] forState:UIControlStateNormal];
        self.externalToggleBtn.backgroundColor = [[UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0] colorWithAlphaComponent:0.88];
        self.externalToggleBtn.layer.borderColor = [UIColor colorWithRed:0.0 green:0.95 blue:0.65 alpha:1.0].CGColor;

        [self releaseJoystick];
        self.statusLabel.text = @"Trạng thái: Đã dừng múa (ESP vẫn quét)";
    }
}

// =======================================================
// 5. THUẬT TOÁN ESP TÁCH HOA CHỤM GẦN TƯỜNG (LOCAL MAXIMA PEAK DETECTOR)
// =======================================================
- (int)detectMultiFlowersInWindow:(UIWindow *)win
                       outFlowers:(FlowerSpot *)outFlowers
                      hasEnemyOut:(BOOL *)hasEnemy
                         enemyPos:(CGPoint *)enemyPt {
    *hasEnemy = NO;
    int foundCount = 0;

    CGSize sz = win.bounds.size;
    CGPoint selfPos = CGPointMake(sz.width * 0.50, sz.height * 0.50);

    CGFloat scanBox = 420.0;
    CGRect scanRect = CGRectMake(selfPos.x - scanBox/2.0, selfPos.y - scanBox/2.0, scanBox, scanBox);

    // Lưới phân giải cao 120x120 (mỗi ô tương đương ~3.5pt màn hình, đủ tách 2 bông hoa nằm sát mép tường)
    const int G = 120;
    uint8_t pixels[120 * 120 * 4];
    float heat[120 * 120];
    memset(pixels, 0, sizeof(pixels));
    memset(heat, 0, sizeof(heat));

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(G, G), NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return 0;
    }

    CGContextScaleCTM(ctx, (CGFloat)G / scanBox, (CGFloat)G / scanBox);
    CGContextTranslateCTM(ctx, -scanRect.origin.x, -scanRect.origin.y);

    UIView *uView = [self findUnityView:win] ?: win;
    [uView drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];

    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    UIGraphicsEndImageContext();
    if (!cgImg) return 0;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef rawCtx = CGBitmapContextCreate(pixels, G, G, 8, G * 4, cs,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (rawCtx) {
        CGContextDrawImage(rawCtx, CGRectMake(0, 0, G, G), cgImg);
        CGContextRelease(rawCtx);
    }
    CGImageRelease(cgImg);

    double enemySumX = 0, enemySumY = 0, enemyWeight = 0;

    // Bước 1: Lọc hạt màu Hoa & Thanh máu địch
    for (int y = 2; y < G - 2; y++) {
        for (int x = 2; x < G - 2; x++) {
            int dx = x - G / 2;
            int dy = y - G / 2;
            int distSq = dx * dx + dy * dy;
            // Loại trừ tâm chân tướng mình (distSq < 130) và rìa ngoài
            if (distSq < 130 || distSq > 3400) continue;

            int idx = (y * G + x) * 4;
            uint8_t r = pixels[idx];
            uint8_t g = pixels[idx + 1];
            uint8_t b = pixels[idx + 2];

            // Thanh máu đỏ của địch
            if (r > 210 && g < 55 && b < 55 && (r - g) > 160) {
                enemySumX += x;
                enemySumY += (y + 15);
                enemyWeight += 1.0;
                continue;
            }

            // Nhận diện tâm sáng và cánh hoa Florentino (hỗ trợ cả khi hoa bị chìm một nửa vào vách tường tối)
            BOOL isGoldFlower = (r > 230 && g > 185 && b < 135 && (r - b) > 110);
            BOOL isRoseFlower = (r > 220 && g < 130 && b > 170 && (r - g) > 100);
            BOOL isAstralCyan = (b > 230 && g > 200 && r < 120 && (b - r) > 115);

            if (isGoldFlower || isRoseFlower || isAstralCyan) {
                heat[y * G + x] = isGoldFlower ? 2.5f : 2.0f;
            }
        }
    }

    if (enemyWeight >= 6.0) {
        CGFloat ex = scanRect.origin.x + ((enemySumX / enemyWeight) / (CGFloat)G) * scanBox;
        CGFloat ey = scanRect.origin.y + ((enemySumY / enemyWeight) / (CGFloat)G) * scanBox;
        *enemyPt = CGPointMake(ex, ey);
        *hasEnemy = YES;

        CGFloat vx = ex - selfPos.x;
        CGFloat vy = ey - selfPos.y;
        CGFloat len = hypot(vx, vy);
        if (len > 5.0) self.lastEnemyVec = CGPointMake(vx / len, vy / len);
    }

    // Bước 2: Tích chập mật độ 5x5 để tìm đỉnh từng bông hoa (giúp tách 2-3 hoa nằm sát nhau ở rìa tường)
    float density[120 * 120];
    memset(density, 0, sizeof(density));

    for (int y = 3; y < G - 3; y++) {
        for (int x = 3; x < G - 3; x++) {
            float sum = 0;
            for (int ky = -2; ky <= 2; ky++) {
                for (int kx = -2; kx <= 2; kx++) {
                    sum += heat[(y + ky) * G + (x + kx)];
                }
            }
            density[y * G + x] = sum;
        }
    }

    // Bước 3: Non-Maximum Suppression (NMS) với bán kính tách cụm nhỏ (R = 7 ô ~ 24pt)
    // Nhờ bán kính NMS nhỏ, 2 bông hoa bị ép sát tường cách nhau chỉ 28pt vẫn được tách thành 2 tâm F1, F2 riêng biệt!
    for (int k = 0; k < 3; k++) {
        float maxD = 0;
        int bestX = -1, bestY = -1;

        for (int y = 4; y < G - 4; y++) {
            for (int x = 4; x < G - 4; x++) {
                if (density[y * G + x] > maxD) {
                    maxD = density[y * G + x];
                    bestX = x;
                    bestY = y;
                }
            }
        }

        if (maxD < 11.0f || bestX < 0) break; // Ngưỡng tối thiểu để xác nhận 1 bông hoa

        // Tính trọng tâm chính xác sub-pixel quanh đỉnh vừa tìm được
        float sumWX = 0, sumWY = 0, sumW = 0;
        for (int ky = -4; ky <= 4; ky++) {
            for (int kx = -4; kx <= 4; kx++) {
                int nx = bestX + kx;
                int ny = bestY + ky;
                if (nx >= 0 && nx < G && ny >= 0 && ny < G) {
                    float w = density[ny * G + nx];
                    sumWX += nx * w;
                    sumWY += ny * w;
                    sumW  += w;
                    // Xóa vùng đỉnh này (bán kính 7 ô) để vòng lặp sau tìm bông hoa kế bên
                    if (kx * kx + ky * ky <= 49) {
                        density[ny * G + nx] = 0;
                    }
                }
            }
        }

        CGFloat cx = (sumW > 0) ? (sumWX / sumW) : bestX;
        CGFloat cy = (sumW > 0) ? (sumWY / sumW) : bestY;

        CGFloat screenX = scanRect.origin.x + (cx / (CGFloat)G) * scanBox;
        CGFloat screenY = scanRect.origin.y + (cy / (CGFloat)G) * scanBox;
        CGPoint fPt = CGPointMake(screenX, screenY);

        CGFloat distSelf = hypot(fPt.x - selfPos.x, fPt.y - selfPos.y);
        CGFloat distEnemy = 0;
        if (*hasEnemy && self.prioChaseEnemy) {
            distEnemy = hypot(fPt.x - (*enemyPt).x, fPt.y - (*enemyPt).y);
        } else {
            CGPoint chasePt = CGPointMake(selfPos.x + self.lastEnemyVec.x * 125.0,
                                          selfPos.y + self.lastEnemyVec.y * 125.0);
            distEnemy = hypot(fPt.x - chasePt.x, fPt.y - chasePt.y);
        }

        outFlowers[foundCount].screenPt = fPt;
        outFlowers[foundCount].distToSelf = distSelf;
        outFlowers[foundCount].score = (distSelf * 0.55) + (distEnemy * 0.45);
        outFlowers[foundCount].isWallClumped = NO;
        foundCount++;
    }

    // Bước 4: Kiểm tra hiện tượng "Hoa chụm gần tường" (Khoảng cách giữa 2 bông hoa < 62pt)
    for (int i = 0; i < foundCount; i++) {
        for (int j = i + 1; j < foundCount; j++) {
            CGFloat d = hypot(outFlowers[i].screenPt.x - outFlowers[j].screenPt.x,
                              outFlowers[i].screenPt.y - outFlowers[j].screenPt.y);
            if (d < 62.0) {
                outFlowers[i].isWallClumped = YES;
                outFlowers[j].isWallClumped = YES;
            }
        }
    }

    // Bước 5: Sắp xếp thứ tự ưu tiên F1 -> F2 -> F3 (Hoa gần mình + gần địch nhất lên đầu)
    for (int i = 0; i < foundCount - 1; i++) {
        for (int j = i + 1; j < foundCount; j++) {
            if (outFlowers[j].score < outFlowers[i].score) {
                FlowerSpot tmp = outFlowers[i];
                outFlowers[i] = outFlowers[j];
                outFlowers[j] = tmp;
            }
        }
    }

    // Cập nhật vẽ ESP lên màn hình
    if (self.isESPOn) {
        [self.espOverlay renderWithSelfPos:selfPos
                                   flowers:outFlowers
                               flowerCount:foundCount
                                  hasEnemy:*hasEnemy
                                  enemyPos:*enemyPt];
    }

    return foundCount;
}

- (void)passiveESPTick {
    if (self.isMua || !self.isESPOn) return;
    UIWindow *win = [self gameWindow];
    if (!win) return;

    FlowerSpot flowers[3];
    BOOL hasEnemy = NO;
    CGPoint enemyPt = CGPointZero;
    [self detectMultiFlowersInWindow:win outFlowers:flowers hasEnemyOut:&hasEnemy enemyPos:&enemyPt];
}

// =======================================================
// 6. BƠM TOUCH HỆ THỐNG & BẺ GÓC NHẶT HOA CHỤM TƯỜNG
// =======================================================
- (UIEvent *)systemOrFallbackTouchesEventWithTouch:(AOVTouch *)touch {
    SEL teSel = NSSelectorFromString(@"_touchesEvent");
    SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    if ([[UIApplication sharedApplication] respondsToSelector:teSel]) {
        UIEvent *sysEv = ((UIEvent *(*)(id, SEL))objc_msgSend)([UIApplication sharedApplication], teSel);
        if (sysEv && [sysEv respondsToSelector:addSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(sysEv, addSel, touch, NO);
            return sysEv;
        }
    }
    return self.fallbackEvent;
}

- (void)dispatchTouch:(AOVTouch *)touch phase:(UITouchPhase)phase {
    UIWindow *win = [self gameWindow];
    UIView *uView = [self findUnityView:win] ?: win;
    if (!uView) return;

    [touch setTouchPhase:phase];
    if (phase == UITouchPhaseBegan) {
        [self.fallbackEvent.activeTouches addObject:touch];
    }

    UIEvent *ev = [self systemOrFallbackTouchesEventWithTouch:touch];
    NSSet *set = [NSSet setWithObject:touch];

    if (phase == UITouchPhaseBegan) {
        [uView touchesBegan:set withEvent:ev];
    } else if (phase == UITouchPhaseMoved) {
        [uView touchesMoved:set withEvent:ev];
    } else if (phase == UITouchPhaseEnded) {
        [uView touchesEnded:set withEvent:ev];
        [self.fallbackEvent.activeTouches removeObject:touch];
    }
}

- (void)humanTapSkillAt:(CGPoint)baseCenter {
    UIWindow *win = [self gameWindow];
    UIView *uView = [self findUnityView:win] ?: win;
    if (!uView) return;

    CGPoint startPt = humanizePoint(baseCenter, 4.8);
    NSTimeInterval holdTime = randRange(0.034, 0.062);

    AOVTouch *t = [[AOVTouch alloc] initWithWindow:win view:uView loc:startPt];
    [self dispatchTouch:t phase:UITouchPhaseBegan];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((holdTime * 0.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGPoint microSlide = CGPointMake(startPt.x + randRange(-1.6, 1.6),
                                         startPt.y + randRange(-1.6, 1.6));
        [t moveToLocation:microSlide];
        [self dispatchTouch:t phase:UITouchPhaseMoved];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dispatchTouch:t phase:UITouchPhaseEnded];
    });
}

// Kéo cần Joystick: Nếu phát hiện hoa bị chụm gần tường (isWallClumped), tự động bẻ góc tiếp tuyến 18 độ để lướt dọc mép tường nhặt từng bông mà không bị kẹt vách đá
- (void)smoothPullJoystickToward:(CGPoint)worldTarget isWallClumped:(BOOL)clumped {
    UIWindow *win = [self gameWindow];
    UIView *uView = [self findUnityView:win] ?: win;
    if (!win || !uView) return;

    CGPoint selfPos = CGPointMake(win.bounds.size.width * 0.50, win.bounds.size.height * 0.50);
    CGFloat baseAngle = atan2(worldTarget.y - selfPos.y, worldTarget.x - selfPos.x);

    // Nếu hoa chụm tường, lắc nhẹ góc tiếp tuyến theo nhịp bước để không ủi thẳng mặt vào tường
    CGFloat wallTangentOffset = 0.0;
    if (clumped) {
        wallTangentOffset = ((self.comboStep % 2) == 0) ? 0.28 : -0.28;
    }

    CGFloat angle = baseAngle + wallTangentOffset + randRange(-0.04, 0.04);

    CGPoint joyOrigin = self.nodeJoy.center;
    CGFloat radius = randRange(54.0, 64.0);
    CGPoint desiredPt = CGPointMake(joyOrigin.x + cos(angle) * radius,
                                    joyOrigin.y + sin(angle) * radius);

    if (!self.joyTouch) {
        CGPoint startOrigin = humanizePoint(joyOrigin, 3.5);
        self.currentJoyPos = startOrigin;
        self.joyTouch = [[AOVTouch alloc] initWithWindow:win view:uView loc:startOrigin];
        [self dispatchTouch:self.joyTouch phase:UITouchPhaseBegan];
    }

    CGPoint midPt = CGPointMake(self.currentJoyPos.x + (desiredPt.x - self.currentJoyPos.x) * 0.55 + randRange(-1.2, 1.2),
                                self.currentJoyPos.y + (desiredPt.y - self.currentJoyPos.y) * 0.55 + randRange(-1.2, 1.2));

    [self.joyTouch moveToLocation:midPt];
    [self dispatchTouch:self.joyTouch phase:UITouchPhaseMoved];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(randRange(0.018, 0.028) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.isMua && self.joyTouch) {
            self.currentJoyPos = desiredPt;
            [self.joyTouch moveToLocation:desiredPt];
            [self dispatchTouch:self.joyTouch phase:UITouchPhaseMoved];
        }
    });
}

- (void)releaseJoystick {
    if (self.joyTouch) {
        [self dispatchTouch:self.joyTouch phase:UITouchPhaseEnded];
        self.joyTouch = nil;
    }
}

// =======================================================
// 7. VÒNG LẶP COMBO KẾT HỢP ESP ĐA HOA
// =======================================================
- (void)scheduleNextHumanizedTickWithToken:(NSInteger)token {
    if (!self.isMua || token != self.sessionToken) return;

    [self executeComboStep];

    NSTimeInterval nextInterval = randRange(0.068, 0.106);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self scheduleNextHumanizedTickWithToken:token];
    });
}

- (void)executeComboStep {
    UIWindow *win = [self gameWindow];
    if (!win) return;

    CGPoint selfPos = CGPointMake(win.bounds.size.width * 0.50, win.bounds.size.height * 0.50);
    FlowerSpot flowers[3];
    CGPoint enemyPt = CGPointZero;
    BOOL hasEnemy = NO;

    int flowerCount = [self detectMultiFlowersInWindow:win
                                            outFlowers:flowers
                                           hasEnemyOut:&hasEnemy
                                              enemyPos:&enemyPt];

    if (!hasEnemy) {
        enemyPt = CGPointMake(selfPos.x + self.lastEnemyVec.x * 130.0,
                              selfPos.y + self.lastEnemyVec.y * 130.0);
    }

    CGPoint targetFlowerPt = CGPointZero;
    BOOL isWallClumped = NO;

    if (flowerCount > 0) {
        targetFlowerPt = flowers[0].screenPt;
        isWallClumped  = flowers[0].isWallClumped;
    } else {
        CGFloat baseAngle = atan2(enemyPt.y - selfPos.y, enemyPt.x - selfPos.x);
        CGFloat offsets[3] = { -0.55, 0.55, 0.0 };
        CGFloat a = baseAngle + offsets[self.triAngleIdx % 3];
        targetFlowerPt = CGPointMake(selfPos.x + cos(a) * 115.0, selfPos.y + sin(a) * 115.0);
    }

    switch (self.comboStep) {
        case 0:
            if (self.prioUltFirst) {
                [self humanTapSkillAt:self.nodeS3.center];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(randRange(0.025, 0.045) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (self.isMua) [self humanTapSkillAt:self.nodeS1.center];
                });
            } else {
                [self humanTapSkillAt:self.nodeS1.center];
            }
            [self smoothPullJoystickToward:(flowerCount > 0 ? targetFlowerPt : enemyPt) isWallClumped:isWallClumped];
            break;

        case 1:
        case 5:
        case 9:
            [self humanTapSkillAt:self.nodeAA.center];
            [self smoothPullJoystickToward:targetFlowerPt isWallClumped:isWallClumped];
            self.statusLabel.text = isWallClumped
                ? [NSString stringWithFormat:@"ESP: Tách %d hoa chụm tường -> Lướt F1", flowerCount]
                : [NSString stringWithFormat:@"ESP: Phát hiện %d hoa -> Nhặt F1", flowerCount];
            break;

        case 2:
        case 6:
        case 10:
            [self smoothPullJoystickToward:targetFlowerPt isWallClumped:isWallClumped];
            [self humanTapSkillAt:self.nodeS2.center];
            self.triAngleIdx++;
            break;

        case 3:
        case 7:
        case 11:
            // Nếu có bông hoa thứ 2 (F2) trong cụm tường, bẻ lái sớm sang F2 ngay sau khi chạm F1
            if (flowerCount >= 2 && isWallClumped) {
                [self smoothPullJoystickToward:flowers[1].screenPt isWallClumped:YES];
            } else {
                [self smoothPullJoystickToward:(self.prioChaseEnemy ? enemyPt : targetFlowerPt) isWallClumped:NO];
            }
            break;

        case 4:
        case 8:
            [self humanTapSkillAt:self.nodeS1.center];
            [self smoothPullJoystickToward:targetFlowerPt isWallClumped:isWallClumped];
            break;

        default:
            [self smoothPullJoystickToward:targetFlowerPt isWallClumped:isWallClumped];
            break;
    }

    self.comboStep = (self.comboStep + 1) % 12;
}

@end

__attribute__((constructor))
static void initializeFloMagicV6(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[FloMagicManager shared] setupAll];
    });
}
