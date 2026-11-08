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
    marker.layer.borderColor = [UIColor whiteColor].
