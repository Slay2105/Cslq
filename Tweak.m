#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

@interface AutoClickManager : NSObject
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *targetPoint;
@property (nonatomic, strong) NSTimer *clickTimer;
@property (nonatomic, assign) BOOL isRunning;
+ (instancetype)shared;
- (void)setupUI;
@end

@implementation AutoClickManager

+ (instancetype)shared {
    static AutoClickManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoClickManager alloc] init];
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

- (void)setupUI {
    UIWindow *window = [self keyWindow];
    if (!window || self.toggleButton) return;

    self.targetPoint = [[UIView alloc] initWithFrame:CGRectMake(250, 180, 28, 28)];
    self.targetPoint.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.5];
    self.targetPoint.layer.cornerRadius = 14;
    self.targetPoint.layer.borderWidth = 2.0;
    self.targetPoint.layer.borderColor = [UIColor whiteColor].CGColor;
    UIPanGestureRecognizer *panTarget = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.targetPoint addGestureRecognizer:panTarget];
    [window addSubview:self.targetPoint];

    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(40, 100, 95, 36);
    self.toggleButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    self.toggleButton.layer.cornerRadius = 8;
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [self.toggleButton setTitle:@"AUTO: OFF" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(toggleAutoClick) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *panBtn = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleButton addGestureRecognizer:panBtn];
    [window addSubview:self.toggleButton];
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:recognizer.view.superview];
    recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
                                         recognizer.view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:recognizer.view.superview];
}

- (void)toggleAutoClick {
    self.isRunning = !self.isRunning;
    if (self.isRunning) {
        [self.toggleButton setTitle:@"AUTO: ON" forState:UIControlStateNormal];
        [self.toggleButton setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        self.clickTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                           target:self
                                                         selector:@selector(performClick)
                                                         userInfo:nil
                                                          repeats:YES];
    } else {
        [self.toggleButton setTitle:@"AUTO: OFF" forState:UIControlStateNormal];
        [self.toggleButton setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        [self.clickTimer invalidate];
        self.clickTimer = nil;
    }
}

- (void)performClick {
    UIWindow *window = [self keyWindow];
    if (!window) return;

    CGPoint point = self.targetPoint.center;

    self.targetPoint.hidden = YES;
    UIView *hitView = [window hitTest:point withEvent:nil];
    self.targetPoint.hidden = NO;

    if (!hitView) return;

    if ([hitView isKindOfClass:[UIControl class]]) {
        [(UIControl *)hitView sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    UIView *parent = hitView;
    while (parent && ![parent isKindOfClass:[WKWebView class]]) {
        parent = parent.superview;
    }
    if ([parent isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)parent;
        CGPoint webPoint = [window convertPoint:point toView:webView];
        NSString *js = [NSString stringWithFormat:
            @"var el = document.elementFromPoint(%f, %f);"
            @"if (el) { el.click(); }",
            webPoint.x, webPoint.y];
        [webView evaluateJavaScript:js completionHandler:nil];
    }
}

@end

__attribute__((constructor))
static void initializeAutoClick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AutoClickManager shared] setupUI];
    });
}
