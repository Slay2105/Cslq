#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

@interface ClickNode : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) NSTimeInterval delay;
@property (nonatomic, strong) UIView *marker;
@property (nonatomic, strong) UILabel *label;
@end

@implementation ClickNode
@end

@interface AutoClickManager : NSObject
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *hideButton;
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

- (UIWindow *)keyWindow {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (UIViewController *)topViewController {
    UIViewController *top = [self keyWindow].rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)setupUI {
    UIWindow *window = [self keyWindow];
    if (!window || self.panelView) return;

    // Thanh điều khiển nổi (Kéo thả được)
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(30, 60, 235, 38)];
    self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    self.panelView.layer.cornerRadius = 10;
    self.panelView.layer.borderWidth = 1.2;
    self.panelView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.4].CGColor;

    UIPanGestureRecognizer *panPanel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.panelView addGestureRecognizer:panPanel];

    // 1. Nút Bật / Tắt Auto
    self.runButton = [self createButtonWithFrame:CGRectMake(6, 4, 72, 30)
                                           title:@"CHẠY"
                                           color:[UIColor systemGreenColor]
                                          action:@selector(toggleAuto)];
    [self.panelView addSubview:self.runButton];

    // 2. Nút Thêm điểm (+)
    UIButton *addBtn = [self createButtonWithFrame:CGRectMake(82, 4, 44, 30)
                                             title:@"+Điểm"
                                             color:[UIColor systemBlueColor]
                                            action:@selector(addClickNode)];
    [self.panelView addSubview:addBtn];

    // 3. Nút Xóa điểm cuối (-)
    UIButton *delBtn = [self createButtonWithFrame:CGRectMake(130, 4, 44, 30)
                                             title:@"-Xóa"
                                             color:[UIColor systemOrangeColor]
                                            action:@selector(removeLastNode)];
    [self.panelView addSubview:delBtn];

    // 4. Nút Ẩn/Hiện tâm ngắm
    self.hideButton = [self createButtonWithFrame:CGRectMake(178, 4, 51, 30)
                                            title:@"ẨnTâm"
                                            color:[UIColor darkGrayColor]
                                           action:@selector(toggleMarkers)];
    [self.panelView addSubview:self.hideButton];

    [window addSubview:self.panelView];

    // Tạo sẵn 2 điểm mặc định khi vừa vào
    [self addClickNode];
    [self addClickNode];
}

- (UIButton *)createButtonWithFrame:(CGRect)frame title:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [color colorWithAlphaComponent:0.85];
    btn.layer.cornerRadius = 6;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)addClickNode {
    UIWindow *window = [self keyWindow];
    if (!window) return;

    NSInteger idx = self.nodes.count + 1;
    ClickNode *node = [[ClickNode alloc] init];
    node.index = idx;
    node.delay = 0.20; // Mặc định 0.20 giây (chạm vào tâm để đổi)

    CGFloat offsetX = 180 + ((idx - 1) % 5) * 42;
    CGFloat offsetY = 140 + ((idx - 1) / 5) * 42;

    UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(offsetX, offsetY, 36, 36)];
    marker.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.65];
    marker.layer.cornerRadius = 18;
    marker.layer.borderWidth = 2.0;
    marker.layer.borderColor = [UIColor whiteColor].CGColor;
    marker.tag = idx;

    UILabel *lbl = [[UILabel alloc] initWithFrame:marker.bounds];
    lbl.numberOfLines = 2;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont boldSystemFontOfSize:9];
    lbl.textColor = [UIColor whiteColor];
    lbl.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)idx, node.delay];
    [marker addSubview:lbl];

    // Kéo để di chuyển vị trí tâm
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [marker addGestureRecognizer:pan];

    // Chạm 1 lần vào tâm để chỉnh độ trễ (delay) của riêng tâm đó
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
    if (self.isRunning) return; // Đang chạy thì khóa chỉnh để tránh bấm nhầm

    NSInteger idx = recognizer.view.tag - 1;
    if (idx < 0 || idx >= self.nodes.count) return;
    ClickNode *node = self.nodes[idx];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Điểm #%ld", (long)node.index]
                                                                   message:@"Nhập độ trễ trước khi chuyển sang điểm tiếp theo (giây, VD: 0.1, 0.35, 1.5):"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"0.20";
        textField.text = [NSString stringWithFormat:@"%.2f", node.delay];
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *valStr = [alert.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [valStr doubleValue];
        if (val < 0.02) val = 0.02; // Giới hạn tối thiểu 20ms để tránh treo game
        node.delay = val;
        node.label.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)node.index, node.delay];
    }];

    UIAlertAction *applyAllAction = [UIAlertAction actionWithTitle:@"Áp dụng cho TẤT CẢ điểm" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *valStr = [alert.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [valStr doubleValue];
        if (val < 0.02) val = 0.02;
        for (ClickNode *n in self.nodes) {
            n.delay = val;
            n.label.text = [NSString stringWithFormat:@"#%ld\n%.2fs", (long)n.index, n.delay];
        }
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:saveAction];
    [alert addAction:applyAllAction];
    [alert addAction:cancelAction];

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
        self.runButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        self.currentStep = 0;
        [self executeStepWithToken:self.runToken];
    } else {
        [self.runButton setTitle:@"CHẠY" forState:UIControlStateNormal];
        self.runButton.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];
    }
}

- (void)executeStepWithToken:(NSInteger)token {
    if (!self.isRunning || token != self.runToken || self.nodes.count == 0) return;

    if (self.currentStep >= self.nodes.count) {
        self.currentStep = 0;
    }

    ClickNode *node = self.nodes[self.currentStep];
    [self triggerClickAtNode:node];

    NSTimeInterval waitTime = node.delay;
    self.currentStep = (self.currentStep + 1) % self.nodes.count;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self executeStepWithToken:token];
    });
}

- (void)triggerClickAtNode:(ClickNode *)node {
    UIWindow *window = [self keyWindow];
    if (!window) return;

    CGPoint point = node.marker.center;

    // Hiệu ứng nháy viền vàng báo hiệu điểm đang được click
    if (!self.markersHidden) {
        node.marker.layer.borderColor = [UIColor yellowColor].CGColor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            node.marker.layer.borderColor = [UIColor whiteColor].CGColor;
        });
    }

    // Tạm ẩn tất cả tâm ngắm và bảng điều khiển để hitTest xuyên thẳng xuống giao diện game
    BOOL wasPanelHidden = self.panelView.hidden;
    self.panelView.hidden = YES;
    for (ClickNode *n in self.nodes) {
        n.marker.hidden = YES;
    }

    UIView *hitView = [window hitTest:point withEvent:nil];

    self.panelView.hidden = wasPanelHidden;
    for (ClickNode *n in self.nodes) {
        n.marker.hidden = self.markersHidden;
    }

    if (!hitView) return;

    // 1. Kiểm tra nếu nằm trong WKWebView (Giao diện sự kiện Chung Sức)
    UIView *parent = hitView;
    while (parent && ![parent isKindOfClass:[WKWebView class]]) {
        parent = parent.superview;
    }
    if ([parent isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)parent;
        CGPoint webPoint = [window convertPoint:point toView:webView];
        NSString *js = [NSString stringWithFormat:
            @"(function(x, y) {"
            @"  var el = document.elementFromPoint(x, y);"
            @"  if (!el) return;"
            @"  ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend','click'].forEach(function(type) {"
            @"    var evt = new MouseEvent(type, {bubbles: true, cancelable: true, view: window, clientX: x, clientY: y});"
            @"    el.dispatchEvent(evt);"
            @"  });"
            @"  if (typeof el.click === 'function') el.click();"
            @"  if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') el.focus();"
            @"})(%f, %f);",
            webPoint.x, webPoint.y];
        [webView evaluateJavaScript:js completionHandler:nil];
        return;
    }

    // 2. Kiểm tra nếu là nút UIControl gốc của iOS / Game
    UIView *ctrlCheck = hitView;
    while (ctrlCheck && ![ctrlCheck isKindOfClass:[UIControl class]]) {
        ctrlCheck = ctrlCheck.superview;
    }
    if ([ctrlCheck isKindOfClass:[UIControl class]]) {
        [(UIControl *)ctrlCheck sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

@end

__attribute__((constructor))
static void initializeAutoClick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AutoClickManager shared] setupUI];
    });
}
