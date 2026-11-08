#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// --- Giả lập UITouch thật cho UnityView & UIKit ---
@interface AOVSynthTouch : UITouch
@property (nonatomic, assign) UITouchPhase synthPhase;
@property (nonatomic, assign) NSUInteger synthTapCount;
@property (nonatomic, assign) NSTimeInterval synthTimestamp;
@property (nonatomic, strong) UIWindow *synthWindow;
@property (nonatomic, strong) UIView *synthView;
@property (nonatomic, assign) CGPoint windowLocation;
- (instancetype)initWithWindow:(UIWindow *)window view:(UIView *)view locationInWindow:(CGPoint)loc;
- (void)updatePhase:(UITouchPhase)phase;
@end

@implementation AOVSynthTouch

- (instancetype)initWithWindow:(UIWindow *)window view:(UIView *)view locationInWindow:(CGPoint)loc {
    self = [super init];
    if (self) {
        _synthWindow = window;
        _synthView = view;
        _windowLocation = loc;
        _synthTapCount = 1;
        _synthPhase = UITouchPhaseBegan;
        _synthTimestamp = [[NSProcessInfo processInfo] systemUptime];
        [self syncInternalState];
    }
    return self;
}

- (void)syncInternalState {
    SEL setWin = NSSelectorFromString(@"setWindow:");
    if ([self respondsToSelector:setWin]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, setWin, _synthWindow);
    }
    SEL setV = NSSelectorFromString(@"setView:");
    if ([self respondsToSelector:setV]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, setV, _synthView);
    }
    SEL setP = NSSelectorFromString(@"setPhase:");
    if ([self respondsToSelector:setP]) {
        ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(self, setP, _synthPhase);
    }
    SEL setT = NSSelectorFromString(@"setTapCount:");
    if ([self respondsToSelector:setT]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(self, setT, _synthTapCount);
    }
    SEL setLoc = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    if ([self respondsToSelector:setLoc]) {
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(self, setLoc, _windowLocation, YES);
    }
    SEL setFirst = NSSelectorFromString(@"_setIsFirstTouchForView:");
    if ([self respondsToSelector:setFirst]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, setFirst, YES);
    }
}

- (void)updatePhase:(UITouchPhase)phase {
    _synthPhase = phase;
    _synthTimestamp = [[NSProcessInfo processInfo] systemUptime];
    [self syncInternalState];
}

- (UITouchPhase)phase { return _synthPhase; }
- (NSUInteger)tapCount { return _synthTapCount; }
- (NSTimeInterval)timestamp { return _synthTimestamp; }
- (UIWindow *)window { return _synthWindow; }
- (UIView *)view { return _synthView; }
- (UITouchType)type { return UITouchTypeDirect; }
- (CGFloat)force { return 1.0; }
- (CGFloat)maximumPossibleForce { return 1.0; }
- (CGFloat)majorRadius { return 12.0; }

- (CGPoint)locationInView:(UIView *)view {
    if (!view) return _windowLocation;
    if (_synthWindow) return [_synthWindow convertPoint:_windowLocation toView:view];
    return _windowLocation;
}

- (CGPoint)previousLocationInView:(UIView *)view {
    return [self locationInView:view];
}

@end

// --- Giả lập UIEvent chứa AOVSynthTouch cho UnityEngine ---
@interface AOVSynthEvent : UIEvent
@property (nonatomic, strong) AOVSynthTouch *synthTouch;
@end

@implementation AOVSynthEvent
- (UIEventType)type { return UIEventTypeTouches; }
- (UIEventSubtype)subtype { return UIEventSubtypeNone; }
- (NSTimeInterval)timestamp {
    return _synthTouch ? _synthTouch.timestamp : [[NSProcessInfo processInfo] systemUptime];
}
- (NSSet<UITouch *> *)allTouches {
    return _synthTouch ? [NSSet setWithObject:_synthTouch] : [NSSet set];
}
- (NSSet<UITouch *> *)touchesForWindow:(UIWindow *)window {
    return [self allTouches];
}
- (NSSet<UITouch *> *)touchesForView:(UIView *)view {
    return [self allTouches];
}
- (NSSet<UITouch *> *)touchesForGestureRecognizer:(UIGestureRecognizer *)gesture {
    return [self allTouches];
}
- (NSArray<UITouch *> *)coalescedTouchesForTouch:(UITouch *)touch {
    return _synthTouch ? @[_synthTouch] : @[];
}
- (NSArray<UITouch *> *)predictedTouchesForTouch:(UITouch *)touch {
    return @[];
}
@end

// --- Cấu trúc điểm Click ---
@interface ClickNode : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) NSTimeInterval delay;
@property (nonatomic, assign) NSTimeInterval holdTime;
@property (nonatomic, strong) UIView *marker;
@property (nonatomic, strong) UILabel *label;
@end

@implementation ClickNode
@end

@interface AutoClickManager : NSObject
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *hideButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<ClickNode *> *nodes;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL markersHidden;
@property (nonatomic, assign) NSInteger currentStep;
@property (nonatomic, assign) NSInteger runToken;
+ (instancetype)shared;
- (void)setupUI;
@end

@implementation AutoClickManager

+ (instancetype)shared {
    static AutoClickManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoClickManager alloc] init];
        instance.nodes = [NSMutableArray array];
    });
    return instance;
}

- (NSArray<UIWindow *> *)allAppWindows {
    NSMutableArray<UIWindow *> *list = [NSMutableArray array];
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in scene.windows) {
                if (!w.hidden && w.alpha > 0.01) [list addObject:w];
            }
        }
    }
    if (list.count == 0) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha > 0.01) [list addObject:w];
        }
    }
    return list;
}

- (UIWindow *)gameWindow {
    NSArray<UIWindow *> *windows = [self allAppWindows];
    // Ưu tiên cửa sổ chính chứa UnityView của game thay vì cửa sổ phụ của mod menu khác
    for (UIWindow *w in windows) {
        if ([self findUnityViewInView:w] != nil) return w;
    }
    for (UIWindow *w in windows) {
        if (w.isKeyWindow) return w;
    }
    return windows.firstObject;
}

- (UIView *)findUnityViewInView:(UIView *)root {
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"UnityView"] || [cls containsString:@"UnityRendering"]) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = [self findUnityViewInView:sub];
        if (found) return found;
    }
    return nil;
}

- (void)findWebViewsInView:(UIView *)root result:(NSMutableArray<WKWebView *> *)result {
    if (root.hidden || root.alpha < 0.01) return;
    if ([root isKindOfClass:[WKWebView class]]) {
        [result addObject:(WKWebView *)root];
        return;
    }
    for (UIView *sub in root.subviews) {
        [self findWebViewsInView:sub result:result];
    }
}

- (UIViewController *)topViewController {
    UIViewController *top = [self gameWindow].rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)setupUI {
    UIWindow *window = [self gameWindow];
    if (!window || self.panelView) return;

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(30, 52, 240, 52)];
    self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.panelView.layer.cornerRadius = 10;
    self.panelView.layer.borderWidth = 1.2;
    self.panelView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.4].CGColor;

    UIPanGestureRecognizer *panPanel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.panelView addGestureRecognizer:panPanel];

    self.runButton = [self createButtonWithFrame:CGRectMake(6, 4, 70, 28)
                                           title:@"CHẠY"
                                           color:[UIColor systemGreenColor]
                                          action:@selector(toggleAuto)];
    [self.panelView addSubview:self.runButton];

    UIButton *addBtn = [self createButtonWithFrame:CGRectMake(80, 4, 46, 28)
                                             title:@"+Điểm"
                                             color:[UIColor systemBlueColor]
                                            action:@selector(addClickNode)];
    [self.panelView addSubview:addBtn];

    UIButton *delBtn = [self createButtonWithFrame:CGRectMake(130, 4, 46, 28)
                                             title:@"-Xóa"
                                             color:[UIColor systemOrangeColor]
                                            action:@selector(removeLastNode)];
    [self.panelView addSubview:delBtn];

    self.hideButton = [self createButtonWithFrame:CGRectMake(180, 4, 54, 28)
                                            title:@"ẨnTâm"
                                            color:[UIColor darkGrayColor]
                                           action:@selector(toggleMarkers)];
    [self.panelView addSubview:self.hideButton];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 34, 224, 15)];
    self.statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    self.statusLabel.text = @"Sẵn sàng • Chạm vào tâm để chỉnh trễ/giữ";
    [self.panelView addSubview:self.statusLabel];

    [window addSubview:self.panelView];

    [self addClickNode];
}

- (UIButton *)createButtonWithFrame:(CGRect)frame title:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [color colorWithAlphaComponent:0.88];
    btn.layer.cornerRadius = 6;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)addClickNode {
    UIWindow *window = self.panelView.window ?: [self gameWindow];
    if (!window) return;

    NSInteger idx = self.nodes.count + 1;
    ClickNode *node = [[ClickNode alloc] init];
    node.index = idx;
    node.delay = 0.25;    // Khoảng nghỉ sau khi click
    node.holdTime = 0.08; // Thời gian nhấn giữ (80ms giúp ăn nút Nhảy & Unity)

    CGFloat offsetX = 240 + ((idx - 1) % 5) * 44;
    CGFloat offsetY = 160 + ((idx - 1) / 5) * 44;

    UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(offsetX, offsetY, 38, 38)];
    marker.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.68];
    marker.layer.cornerRadius = 19;
    marker.layer.borderWidth = 2.0;
    marker.layer.borderColor = [UIColor whiteColor].CGColor;
    marker.tag = idx;

    // Chấm tâm chính xác ở giữa
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(17, 17, 4, 4)];
    dot.backgroundColor = [UIColor yellowColor];
    dot.layer.cornerRadius = 2;
    dot.userInteractionEnabled = NO;
    [marker addSubview:dot];

    UILabel *lbl = [[UILabel alloc] initWithFrame:marker.bounds];
    lbl.numberOfLines = 2;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont boldSystemFontOfSize:9];
    lbl.textColor = [UIColor whiteColor];
    lbl.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)idx, node.delay];
    [marker addSubview:lbl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [marker addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMarkerTap:)];
    [marker addGestureRecognizer:tap];

    node.marker = marker;
    node.label = lbl;
    node.marker.hidden = self.markersHidden;

    [self.nodes addObject:node];
    [window insertSubview:marker belowSubview:self.panelView];
}

- (void)removeLastNode {
    if (self.nodes.count == 0) return;
    ClickNode *last = [self.nodes lastObject];
    [last.marker removeFromSuperview];
    [self.nodes removeLastObject];
}

- (void)toggleMarkers {
    self.markersHidden = !self.markersHidden;
    for (ClickNode *node in self.nodes) {
        node.marker.hidden = self.markersHidden;
    }
    [self.hideButton setTitle:(self.markersHidden ? @"Hiện" : @"ẨnTâm") forState:UIControlStateNormal];
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:recognizer.view.superview];
    recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
                                         recognizer.view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:recognizer.view.superview];
}

- (void)handleMarkerTap:(UITapGestureRecognizer *)recognizer {
    if (self.isRunning) return;

    NSInteger idx = recognizer.view.tag - 1;
    if (idx < 0 || idx >= self.nodes.count) return;
    ClickNode *node = self.nodes[idx];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Cài đặt Điểm #%ld", (long)node.index]
                                                                   message:@"Ô 1: Độ trễ chuyển bước (giây)\nÔ 2: Thời gian nhấn giữ nút (giây - để 0.5 nếu muốn giữ nhảy liên tiếp)"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Độ trễ (VD: 0.25)";
        tf.text = [NSString stringWithFormat:@"%.2f", node.delay];
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Nhấn giữ (VD: 0.08)";
        tf.text = [NSString stringWithFormat:@"%.2f", node.holdTime];
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Lưu điểm này" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *dStr = [alert.textFields[0].text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        NSString *hStr = [alert.textFields[1].text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double dVal = [dStr doubleValue];
        double hVal = [hStr doubleValue];
        if (dVal < 0.03) dVal = 0.03;
        if (hVal < 0.02) hVal = 0.02;
        node.delay = dVal;
        node.holdTime = hVal;
        node.label.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)node.index, node.delay];
    }];

    UIAlertAction *applyAllAction = [UIAlertAction actionWithTitle:@"Áp dụng cho TẤT CẢ điểm" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *dStr = [alert.textFields[0].text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        NSString *hStr = [alert.textFields[1].text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double dVal = [dStr doubleValue];
        double hVal = [hStr doubleValue];
        if (dVal < 0.03) dVal = 0.03;
        if (hVal < 0.02) hVal = 0.02;
        for (ClickNode *n in self.nodes) {
            n.delay = dVal;
            n.holdTime = hVal;
            n.label.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)n.index, n.delay];
        }
    }];

    [alert addAction:saveAction];
    [alert addAction:applyAllAction];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];

    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)toggleAuto {
    self.isRunning = !self.isRunning;
    self.runToken++;

    if (self.isRunning) {
        if (self.nodes.count == 0) {
            self.isRunning = NO;
            return;
        }
        [self.runButton setTitle:@"DỪNG" forState:UIControlStateNormal];
        self.runButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.92];
        self.currentStep = 0;
        [self executeStepWithToken:self.runToken];
    } else {
        [self.runButton setTitle:@"CHẠY" forState:UIControlStateNormal];
        self.runButton.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.88];
        self.statusLabel.text = @"Đã dừng";
    }
}

- (void)executeStepWithToken:(NSInteger)token {
    if (!self.isRunning || token != self.runToken || self.nodes.count == 0) return;

    if (self.currentStep >= self.nodes.count) {
        self.currentStep = 0;
    }

    ClickNode *node = self.nodes[self.currentStep];
    [self triggerClickAtNode:node];

    NSTimeInterval totalWait = node.holdTime + node.delay;
    self.currentStep = (self.currentStep + 1) % self.nodes.count;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(totalWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self executeStepWithToken:token];
    });
}

- (CGPoint)convertPointFromPanelWindow:(CGPoint)pt toView:(UIView *)targetView {
    UIWindow *srcWin = self.panelView.window;
    UIWindow *dstWin = targetView.window;
    CGPoint winPt = pt;
    if (srcWin && dstWin && srcWin != dstWin) {
        winPt = [srcWin convertPoint:pt toWindow:dstWin];
    }
    return [targetView convertPoint:winPt fromView:dstWin];
}

- (void)triggerClickAtNode:(ClickNode *)node {
    UIWindow *hostWin = self.panelView.window ?: [self gameWindow];
    if (!hostWin) return;

    CGPoint pointInHostWin = node.marker.center;
    NSTimeInterval holdDuration = node.holdTime;

    if (!self.markersHidden) {
        node.marker.layer.borderColor = [UIColor yellowColor].CGColor;
        node.marker.transform = CGAffineTransformMakeScale(0.88, 0.88);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            node.marker.layer.borderColor = [UIColor whiteColor].CGColor;
            node.marker.transform = CGAffineTransformIdentity;
        });
    }

    // Ẩn tạm thời bảng điều khiển và tâm ngắm để không tự chạm trúng mình
    BOOL wasPanelHidden = self.panelView.hidden;
    self.panelView.hidden = YES;
    for (ClickNode *n in self.nodes) n.marker.hidden = YES;

    // 1. Quét toàn bộ WKWebView đang hiển thị trên mọi cửa sổ
    NSMutableArray<WKWebView *> *webViews = [NSMutableArray array];
    for (UIWindow *w in [self allAppWindows]) {
        [self findWebViewsInView:w result:webViews];
    }

    WKWebView *matchedWebView = nil;
    CGPoint matchedWebPoint = CGPointZero;
    for (WKWebView *wv in webViews) {
        CGPoint localPt = [self convertPointFromPanelWindow:pointInHostWin toView:wv];
        if ([wv pointInside:localPt withEvent:nil]) {
            matchedWebView = wv;
            matchedWebPoint = localPt;
            break;
        }
    }

    // 2. Tìm view đích trên cửa sổ Game chính (UnityView / UIKit)
    UIWindow *gameWin = [self gameWindow];
    CGPoint ptInGameWin = pointInHostWin;
    if (hostWin != gameWin && gameWin != nil) {
        ptInGameWin = [hostWin convertPoint:pointInHostWin toWindow:gameWin];
    }

    UIView *hitView = [gameWin hitTest:ptInGameWin withEvent:nil];
    UIView *unityView = [self findUnityViewInView:gameWin];
    UIView *targetNativeView = hitView ?: unityView ?: gameWin;

    // Khôi phục hiển thị tâm ngắm
    self.panelView.hidden = wasPanelHidden;
    for (ClickNode *n in self.nodes) n.marker.hidden = self.markersHidden;

    // --- KÊNH A: Nếu điểm đặt nằm trên WKWebView (Mini-game / Web sự kiện) ---
    if (matchedWebView) {
        NSInteger holdMs = (NSInteger)(holdDuration * 1000);
        NSString *js = [NSString stringWithFormat:
            @"(function(x, y, holdMs) {"
            @"  var doc = document;"
            @"  var el = doc.elementFromPoint(x, y);"
            @"  if (el && el.tagName === 'IFRAME' && el.contentDocument) {"
            @"    var rect = el.getBoundingClientRect();"
            @"    doc = el.contentDocument;"
            @"    x = x - rect.left; y = y - rect.top;"
            @"    el = doc.elementFromPoint(x, y);"
            @"  }"
            @"  if (!el) return;"
            @"  var tObj = null;"
            @"  try {"
            @"    tObj = new Touch({identifier: Date.now(), target: el, clientX: x, clientY: y, pageX: x, pageY: y, screenX: x, screenY: y, radiusX: 10, radiusY: 10, force: 1});"
            @"    el.dispatchEvent(new TouchEvent('touchstart', {bubbles: true, cancelable: true, composed: true, view: window, touches: [tObj], targetTouches: [tObj], changedTouches: [tObj]}));"
            @"  } catch(e) {}"
            @"  try { el.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, cancelable: true, pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y, buttons: 1})); } catch(e) {}"
            @"  el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, buttons: 1}));"
            @"  setTimeout(function() {"
            @"    try {"
            @"      if (tObj) el.dispatchEvent(new TouchEvent('touchend', {bubbles: true, cancelable: true, composed: true, view: window, touches: [], targetTouches: [], changedTouches: [tObj]}));"
            @"    } catch(e) {}"
            @"    try { el.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, cancelable: true, pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y})); } catch(e) {}"
            @"    el.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true, view: window, clientX: x, clientY: y}));"
            @"    el.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window, clientX: x, clientY: y}));"
            @"    if (typeof el.click === 'function') el.click();"
            @"  }, holdMs);"
            @"})(%f, %f, %ld);",
            matchedWebPoint.x, matchedWebPoint.y, (long)holdMs];
        [matchedWebView evaluateJavaScript:js completionHandler:nil];
    }

    // --- KÊNH B: Phát xung UITouch thật (Began -> Giữ -> Ended) vào UnityView & hitView ---
    if (targetNativeView && gameWin) {
        UIView *dispatchView = (unityView && ![targetNativeView isDescendantOfView:matchedWebView]) ? unityView : targetNativeView;
        AOVSynthTouch *touch = [[AOVSynthTouch alloc] initWithWindow:gameWin view:dispatchView locationInWindow:ptInGameWin];

        UIEvent *eventToUse = nil;
        SEL teSel = NSSelectorFromString(@"_touchesEvent");
        SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
        if ([[UIApplication sharedApplication] respondsToSelector:teSel]) {
            UIEvent *sysEv = ((UIEvent *(*)(id, SEL))objc_msgSend)([UIApplication sharedApplication], teSel);
            if (sysEv && [sysEv respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(sysEv, addSel, touch, NO);
                eventToUse = sysEv;
            }
        }
        if (!eventToUse) {
            AOVSynthEvent *synthEv = [[AOVSynthEvent alloc] init];
            synthEv.synthTouch = touch;
            eventToUse = synthEv;
        }

        NSSet *touchSet = [NSSet setWithObject:touch];

        // 1. Nhấn xuống (Touch Began)
        [dispatchView touchesBegan:touchSet withEvent:eventToUse];
        if (hitView && hitView != dispatchView) {
            [hitView touchesBegan:touchSet withEvent:eventToUse];
        }

        // Kích hoạt UIControl nếu có
        UIView *ctrlCheck = hitView;
        while (ctrlCheck && ![ctrlCheck isKindOfClass:[UIControl class]]) {
            ctrlCheck = ctrlCheck.superview;
        }
        if ([ctrlCheck isKindOfClass:[UIControl class]]) {
            [(UIControl *)ctrlCheck sendActionsForControlEvents:UIControlEventTouchDown];
        }

        // 2. Nhả tay sau thời gian giữ (Touch Ended)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [touch updatePhase:UITouchPhaseEnded];
            [dispatchView touchesEnded:touchSet withEvent:eventToUse];
            if (hitView && hitView != dispatchView) {
                [hitView touchesEnded:touchSet withEvent:eventToUse];
            }
            if ([ctrlCheck isKindOfClass:[UIControl class]]) {
                [(UIControl *)ctrlCheck sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
    }

    NSString *hitName = matchedWebView ? @"Web+Unity" : NSStringFromClass([targetNativeView class]);
    self.statusLabel.text = [NSString stringWithFormat:@"Đang bấm #%ld (%.0f, %.0f) -> %@",
                             (long)node.index, ptInGameWin.x, ptInGameWin.y, hitName];
}

@end

__attribute__((constructor))
static void initializeAutoClick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AutoClickManager shared] setupUI];
    });
}
