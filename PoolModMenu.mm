#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <vector>
#import <cmath>

static inline vm_address_t VP4Addr(uintptr_t baseHeader, uint64_t staticVMA) {
    return (vm_address_t)(baseHeader + (staticVMA - 0x100000000ULL));
}

// 3 hàm con bật Tia 3D Vật Lý Động (Dynamic Physics Path + Ghost Ball) từ Offsets_Report_5.txt
typedef void (*VP4SubFlagFn)(int enabled);
typedef int  (*VP4GetFlagFn)(void);

#pragma mark - Giả Lập UITouch & UIEvent Đầy Đủ Cho Thanh Kéo Cơ (One Shot / Auto Play)

@interface VP4SyntheticTouch : UITouch
@property (nonatomic, assign) CGPoint synthLocation;
@property (nonatomic, assign) CGPoint synthPrevLocation;
@property (nonatomic, assign) UITouchPhase synthPhase;
@property (nonatomic, weak) UIView *synthView;
@property (nonatomic, weak) UIWindow *synthWindow;
@property (nonatomic, assign) NSTimeInterval synthTimestamp;
@end

@implementation VP4SyntheticTouch
- (CGPoint)locationInView:(UIView *)view {
    if (!view || view == self.synthWindow) return self.synthLocation;
    return [self.synthWindow convertPoint:self.synthLocation toView:view];
}
- (CGPoint)previousLocationInView:(UIView *)view {
    if (!view || view == self.synthWindow) return self.synthPrevLocation;
    return [self.synthWindow convertPoint:self.synthPrevLocation toView:view];
}
- (UITouchPhase)phase { return self.synthPhase; }
- (UIView *)view { return self.synthView; }
- (UIWindow *)window { return self.synthWindow; }
- (NSUInteger)tapCount { return 1; }
- (NSTimeInterval)timestamp { return self.synthTimestamp; }
@end

@interface VP4SyntheticEvent : UIEvent
@property (nonatomic, strong) NSSet<UITouch *> *synthTouches;
@property (nonatomic, assign) NSTimeInterval synthTimestamp;
@end

@implementation VP4SyntheticEvent
- (NSSet<UITouch *> *)allTouches { return self.synthTouches; }
- (NSSet<UITouch *> *)touchesForWindow:(UIWindow *)window { return self.synthTouches; }
- (NSSet<UITouch *> *)touchesForView:(UIView *)view { return self.synthTouches; }
- (UIEventType)type { return UIEventTypeTouches; }
- (UIEventSubtype)subtype { return UIEventSubtypeNone; }
- (NSTimeInterval)timestamp { return self.synthTimestamp; }
@end

#pragma mark - Giao Diện & Logic Chính Của Mod Menu

@interface VP4ProModMenu : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *floatingIcon;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *moneyInput;
@property (nonatomic, strong) CADisplayLink *engineTimer;

// Lớp thước kẻ 2D phụ (Tùy chọn)
@property (nonatomic, strong) CAShapeLayer *line2DAim;
@property (nonatomic, strong) CAShapeLayer *line2DTarget;
@property (nonatomic, strong) CAShapeLayer *ghost2DCircle;
@property (nonatomic, strong) UIView *handleCue;
@property (nonatomic, strong) UIView *handleObj;
@property (nonatomic, strong) UIView *handlePocket;

// Trạng thái các chức năng
@property (nonatomic, assign) BOOL native3DLineEnabled;
@property (nonatomic, assign) BOOL freeCameraEnabled;
@property (nonatomic, assign) BOOL overlay2DEnabled;
@property (nonatomic, assign) BOOL autoPlayEnabled;
@end

@implementation VP4ProModMenu {
    uintptr_t _baseHeader;
    std::vector<vm_address_t> _careerMgrInstances;
    std::vector<vm_address_t> _moneyScanList;
    int _frameCounter;
    BOOL _isStroking;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.native3DLineEnabled = NO;
        self.freeCameraEnabled = NO;
        self.overlay2DEnabled = NO;
        self.autoPlayEnabled = NO;
        _frameCounter = 0;
        _isStroking = NO;

        [self locateGameBinary];
        [self setup2DOverlayElements];
        [self setupMenuInterface];

        self.engineTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(onEngineFrame)];
        [self.engineTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

// Cho phép chạm xuyên qua vùng trống xuống màn hình game
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

- (void)locateGameBinary {
    _baseHeader = 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "VirtualPool4iPhone")) {
            _baseHeader = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    if (_baseHeader == 0 && count > 0) {
        _baseHeader = (uintptr_t)_dyld_get_image_header(0);
    }
}

// Quét tìm đối tượng cwCareerManager (VTable 0x100fb8988) để mở khóa giới hạn tia trong Career Mode
- (void)refreshCareerManagerInstances {
    if (_baseHeader == 0) return;
    _careerMgrInstances.clear();

    uint64_t targetVTable = (uint64_t)VP4Addr(_baseHeader, 0x100fb8988ULL);
    mach_port_t task = mach_task_self();
    vm_address_t addr = 0;
    vm_size_t size = 0;

    while (true) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) && size <= 32 * 1024 * 1024) {
            const vm_size_t chunk = 65536;
            std::vector<uint8_t> buf(chunk);
            for (vm_size_t off = 0; off < size; off += chunk) {
                vm_size_t rSize = MIN(chunk, size - off);
                vm_size_t out = 0;
                if (vm_read_overwrite(task, addr + off, rSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
                    for (vm_size_t i = 0; i + 8 <= out; i += 8) {
                        uint64_t vptr = *(uint64_t *)(buf.data() + i) & 0xffffffffffffULL;
                        if (vptr == (targetVTable & 0xffffffffffffULL)) {
                            _careerMgrInstances.push_back(addr + off + i);
                        }
                    }
                }
            }
        }
        addr += size;
    }
}

#pragma mark - 1. Bật Tia 3D Vật Lý Động Theo Lực Cơ & Áp-Phê (Chuẩn Offsets_Report_5.txt)

- (void)enableDynamicPhysicsTrackOnce {
    if (_baseHeader == 0) return;

    // Gọi trực tiếp 3 hàm con của nhánh w0 == 2 (100111338) mà KHÔNG ghi đè hằng số lực 96.0 vào [0x101293278]+0x8
    VP4SubFlagFn setAimLine   = (VP4SubFlagFn)VP4Addr(_baseHeader, 0x10017bdbcULL);
    VP4SubFlagFn setTruePath  = (VP4SubFlagFn)VP4Addr(_baseHeader, 0x1001968c8ULL);
    VP4SubFlagFn setGhostBall = (VP4SubFlagFn)VP4Addr(_baseHeader, 0x10017bdfcULL);

    setAimLine(1);   // Bật tia ngắm
    setTruePath(1);  // Bật tính toán vật lý động theo lực cơ kéo, áp-phê, trô, cu-lê!
    setGhostBall(1); // Bật bóng mờ Ghost Ball tại điểm chạm và điểm dừng
}

- (void)maintainDynamicTrackFlags {
    if (_baseHeader == 0) return;
    mach_port_t task = mach_task_self();
    vm_size_t outSize = 0;

    // 1. Giữ cấu hình trong PlayerProfile (0x1012924b0) ở chế độ TrackingGhostPath (3)
    vm_address_t profilePtrAddr = VP4Addr(_baseHeader, 0x1012924b0ULL);
    uint64_t profileObj = 0;
    if (vm_read_overwrite(task, profilePtrAddr, sizeof(uint64_t), (vm_address_t)&profileObj, &outSize) == KERN_SUCCESS && profileObj > 0x100000000ULL) {
        if (self.native3DLineEnabled) {
            uint32_t ghostPathMode = 3; // 3 = TrackingGhostPath_Icon.tga (Quỹ đạo động + Ghost Ball)
            uint32_t one = 1;
            vm_write(task, (vm_address_t)(profileObj + 0x88), (vm_offset_t)&ghostPathMode, sizeof(uint32_t));
            vm_write(task, (vm_address_t)(profileObj + 0x8c), (vm_offset_t)&one, sizeof(uint32_t));
            vm_write(task, (vm_address_t)(profileObj + 0xc0), (vm_offset_t)&one, sizeof(uint32_t));
        }
        if (self.freeCameraEnabled) {
            uint32_t zero = 0;
            vm_write(task, (vm_address_t)(profileObj + 0x48), (vm_offset_t)&zero, sizeof(uint32_t));
        }
    }

    if (!self.native3DLineEnabled) return;

    // 2. Chỉ giữ đúng các byte cờ hiển thị (Tuyệt đối KHÔNG ghi đè biến lực tại 0x101293278)
    uint8_t one8 = 1;
    vm_write(task, VP4Addr(_baseHeader, 0x1011bf8d0ULL), (vm_offset_t)&one8, sizeof(uint8_t));
    vm_write(task, VP4Addr(_baseHeader, 0x10120e2e0ULL), (vm_offset_t)&one8, sizeof(uint8_t));

    // 3. Giữ 2 byte cờ Render tại *(0x101293230) + 0x14 (AimLine) và + 0x15 (Dynamic Physics Path) = 1
    vm_address_t renderStatePtrAddr = VP4Addr(_baseHeader, 0x101293230ULL);
    uint64_t renderStateObj = 0;
    if (vm_read_overwrite(task, renderStatePtrAddr, sizeof(uint64_t), (vm_address_t)&renderStateObj, &outSize) == KERN_SUCCESS && renderStateObj > 0x100000000ULL) {
        vm_write(task, (vm_address_t)(renderStateObj + 0x14), (vm_offset_t)&one8, sizeof(uint8_t));
        vm_write(task, (vm_address_t)(renderStateObj + 0x15), (vm_offset_t)&one8, sizeof(uint8_t));
    }

    // 4. Giữ chế độ AimMode = 2 (Full Dynamic TrackAll) tại *(0x1012932c8) + 0x148c
    vm_address_t gamePtrAddr = VP4Addr(_baseHeader, 0x1012932c8ULL);
    uint64_t gameObj = 0;
    if (vm_read_overwrite(task, gamePtrAddr, sizeof(uint64_t), (vm_address_t)&gameObj, &outSize) == KERN_SUCCESS && gameObj > 0x100000000ULL) {
        uint32_t mode2 = 2;
        vm_write(task, (vm_address_t)(gameObj + 0x148c), (vm_offset_t)&mode2, sizeof(uint32_t));
    }

    // 5. Mở khóa giới hạn tia trong các đối tượng cwCareerManager (+0x5c = 2)
    uint32_t careerMode2 = 2;
    for (vm_address_t mgr : _careerMgrInstances) {
        vm_write(task, mgr + 0x5c, (vm_offset_t)&careerMode2, sizeof(uint32_t));
    }
}

- (void)onEngineFrame {
    _frameCounter++;
    if (self.native3DLineEnabled || self.freeCameraEnabled) {
        [self maintainDynamicTrackFlags];
        if (self.native3DLineEnabled && (_frameCounter % 90 == 1)) {
            [self enableDynamicPhysicsTrackOnce];
        }
    }

    // Nếu bật Auto Play, tự động thực hiện cú bắn mỗi 5 giây
    if (self.autoPlayEnabled && !_isStroking && (_frameCounter % 300 == 0)) {
        [self performAutoCueStroke];
    }
}

#pragma mark - 2. One Shot & Auto Play (Giả Lập Kéo Thanh Cơ Với UIEvent Thực)

- (void)sendTouchPhase:(UITouchPhase)phase
                 touch:(VP4SyntheticTouch *)touch
                 event:(VP4SyntheticEvent *)event
              location:(CGPoint)loc
            targetView:(UIView *)targetView {
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    touch.synthPrevLocation = touch.synthLocation;
    touch.synthLocation = loc;
    touch.synthPhase = phase;
    touch.synthTimestamp = now;
    event.synthTimestamp = now;

    NSSet *touches = [NSSet setWithObject:touch];
    event.synthTouches = touches;

    // Gửi tới cả targetView, gestureRecognizers và UIResponder chain của game
    for (UIGestureRecognizer *gr in targetView.gestureRecognizers) {
        if (!gr.enabled) continue;
        if (phase == UITouchPhaseBegan) [gr touchesBegan:touches withEvent:event];
        else if (phase == UITouchPhaseMoved) [gr touchesMoved:touches withEvent:event];
        else if (phase == UITouchPhaseEnded) [gr touchesEnded:touches withEvent:event];
    }

    if (phase == UITouchPhaseBegan) [targetView touchesBegan:touches withEvent:event];
    else if (phase == UITouchPhaseMoved) [targetView touchesMoved:touches withEvent:event];
    else if (phase == UITouchPhaseEnded) [targetView touchesEnded:touches withEvent:event];
}

- (void)performAutoCueStroke {
    if (_isStroking || !self.window) return;
    _isStroking = YES;

    UIWindow *win = self.window;
    CGFloat W = win.bounds.size.width;
    CGFloat H = win.bounds.size.height;

    // Vị trí tâm thanh kéo cơ bên phải màn hình
    CGFloat sliderX = W - 22.0;
    CGFloat startY  = H * 0.46;
    CGFloat pullY   = H * 0.72; // Kéo xuống vừa phải
    CGFloat hitY    = H * 0.16; // Đẩy nhanh lên để ra cơ

    // Tạm ẩn lớp Mod Menu trong tích tắc để lấy đúng UIView của game qua hitTest
    BOOL wasMenuHidden = self.hidden;
    self.hidden = YES;
    UIView *targetView = [win hitTest:CGPointMake(sliderX, startY) withEvent:nil];
    self.hidden = wasMenuHidden;
    if (!targetView) targetView = win.rootViewController.view ?: win;

    VP4SyntheticTouch *touch = [[VP4SyntheticTouch alloc] init];
    touch.synthWindow = win;
    touch.synthView = targetView;
    touch.synthLocation = CGPointMake(sliderX, startY);
    touch.synthPrevLocation = CGPointMake(sliderX, startY);

    VP4SyntheticEvent *event = [[VP4SyntheticEvent alloc] init];

    // Bắt đầu chạm vào thanh cơ
    [self sendTouchPhase:UITouchPhaseBegan touch:touch event:event location:CGPointMake(sliderX, startY) targetView:targetView];

    // Kéo cơ xuống (10 bước mượt)
    int pullSteps = 10;
    for (int i = 1; i <= pullSteps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 25 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            CGFloat y = startY + (pullY - startY) * ((CGFloat)i / pullSteps);
            [self sendTouchPhase:UITouchPhaseMoved touch:touch event:event location:CGPointMake(sliderX, y) targetView:targetView];
        });
    }

    // Giữ nhịp ngắm rồi đẩy cơ lên dứt khoát (5 bước nhanh)
    int pushStartMs = (pullSteps + 3) * 25;
    int pushSteps = 5;
    for (int j = 1; j <= pushSteps; j++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((pushStartMs + j * 10) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            CGFloat y = pullY + (hitY - pullY) * ((CGFloat)j / pushSteps);
            [self sendTouchPhase:UITouchPhaseMoved touch:touch event:event location:CGPointMake(sliderX, y) targetView:targetView];
        });
    }

    // Nhả tay kết thúc cú bắn
    int endMs = pushStartMs + (pushSteps + 1) * 10;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self sendTouchPhase:UITouchPhaseEnded touch:touch event:event location:CGPointMake(sliderX, hitY) targetView:targetView];
        _isStroking = NO;
    });

    self.statusLabel.text = [NSString stringWithFormat:@"⚡ Đã gửi thao tác kéo cơ lên [%@]!", NSStringFromClass([targetView class])];
}

#pragma mark - 3. Mod Tiền Career Mode (VTable 10CareerPlay + Quét RAM)

- (void)modCareerCashInstant9999999 {
    if (_baseHeader == 0) return;
    mach_port_t task = mach_task_self();
    uint64_t careerPlayVTable = (uint64_t)VP4Addr(_baseHeader, 0x100fba2b8ULL);
    int patchedCareerStructs = 0;

    vm_address_t addr = 0;
    vm_size_t size = 0;
    while (true) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) && size <= 32 * 1024 * 1024) {
            const vm_size_t chunk = 65536;
            std::vector<uint8_t> buf(chunk);
            for (vm_size_t off = 0; off < size; off += chunk) {
                vm_size_t rSize = MIN(chunk, size - off);
                vm_size_t out = 0;
                if (vm_read_overwrite(task, addr + off, rSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
                    for (vm_size_t i = 0; i + 8 <= out; i += 8) {
                        uint64_t vptr = *(uint64_t *)(buf.data() + i) & 0xffffffffffffULL;
                        if (vptr == (careerPlayVTable & 0xffffffffffffULL)) {
                            vm_address_t careerObj = addr + off + i;
                            uint64_t dataPtr = 0;
                            vm_size_t rOut = 0;
                            if (vm_read_overwrite(task, careerObj + 0x1a0, 8, (vm_address_t)&dataPtr, &rOut) == KERN_SUCCESS && dataPtr > 0x100000000ULL) {
                                int16_t slot = 0;
                                if (vm_read_overwrite(task, (vm_address_t)(dataPtr + 0x14a), 2, (vm_address_t)&slot, &rOut) == KERN_SUCCESS) {
                                    if (slot >= 0 && slot < 64) {
                                        int32_t rich = 9999999;
                                        vm_address_t cashAddr = (vm_address_t)(dataPtr + (slot * 0x8c) + 0xc4);
                                        if (vm_write(task, cashAddr, (vm_offset_t)&rich, 4) == KERN_SUCCESS) {
                                            patchedCareerStructs++;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        addr += size;
    }

    int manualCount = 0;
    int32_t rich = 9999999;
    for (vm_address_t a : _moneyScanList) {
        if (vm_write(task, a, (vm_offset_t)&rich, 4) == KERN_SUCCESS) manualCount++;
    }

    self.statusLabel.text = [NSString stringWithFormat:@"💰 Đã bơm 9,999,999$ (CareerPlay: %d | RAM Scan: %d)!", patchedCareerStructs, manualCount];
}

- (void)scanMoneyRAM:(int32_t)targetVal isFirst:(BOOL)first {
    mach_port_t task = mach_task_self();
    if (first) {
        _moneyScanList.clear();
        vm_address_t addr = 0;
        vm_size_t size = 0;
        while (true) {
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t obj = MACH_PORT_NULL;
            if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

            if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) && size <= 64 * 1024 * 1024) {
                const vm_size_t chunk = 65536;
                std::vector<uint8_t> buf(chunk);
                for (vm_size_t off = 0; off < size; off += chunk) {
                    vm_size_t rSize = MIN(chunk, size - off);
                    vm_size_t out = 0;
                    if (vm_read_overwrite(task, addr + off, rSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
                        for (vm_size_t i = 0; i + 4 <= out; i += 4) {
                            if (*(int32_t *)(buf.data() + i) == targetVal) {
                                _moneyScanList.push_back(addr + off + i);
                                if (_moneyScanList.size() >= 150000) break;
                            }
                        }
                    }
                    if (_moneyScanList.size() >= 150000) break;
                }
            }
            addr += size;
            if (_moneyScanList.size() >= 150000) break;
        }
    } else {
        std::vector<vm_address_t> next;
        for (vm_address_t a : _moneyScanList) {
            int32_t cur = 0;
            vm_size_t out = 0;
            if (vm_read_overwrite(task, a, 4, (vm_address_t)&cur, &out) == KERN_SUCCESS && cur == targetVal) {
                next.push_back(a);
            }
        }
        _moneyScanList = next;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"🔍 Quét số %d: Tìm thấy %lu địa chỉ khớp.", targetVal, (unsigned long)_moneyScanList.size()];
}

#pragma mark - 4. Thước Kẻ 2D Phụ (Overlay 2D)

- (UIView *)create2DHandle:(UIColor *)color center:(CGPoint)pt title:(NSString *)title {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
    h.center = pt;
    h.backgroundColor = [color colorWithAlphaComponent:0.2];
    h.layer.cornerRadius = 16;
    h.layer.borderColor = color.CGColor;
    h.layer.borderWidth = 1.5;
    h.hidden = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(-10, -13, 52, 12)];
    lbl.text = title;
    lbl.textColor = color;
    lbl.font = [UIFont boldSystemFontOfSize:9];
    lbl.textAlignment = NSTextAlignmentCenter;
    [h addSubview:lbl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHandleDrag:)];
    [h addGestureRecognizer:pan];
    [self addSubview:h];
    return h;
}

- (void)setup2DOverlayElements {
    self.line2DAim = [CAShapeLayer layer];
    self.line2DAim.strokeColor = [UIColor whiteColor].CGColor;
    self.line2DAim.lineWidth = 1.5;
    self.line2DAim.lineDashPattern = @[@6, @4];
    self.line2DAim.fillColor = [UIColor clearColor].CGColor;
    self.line2DAim.hidden = YES;
    [self.layer addSublayer:self.line2DAim];

    self.line2DTarget = [CAShapeLayer layer];
    self.line2DTarget.strokeColor = [UIColor greenColor].CGColor;
    self.line2DTarget.lineWidth = 1.8;
    self.line2DTarget.fillColor = [UIColor clearColor].CGColor;
    self.line2DTarget.hidden = YES;
    [self.layer addSublayer:self.line2DTarget];

    self.ghost2DCircle = [CAShapeLayer layer];
    self.ghost2DCircle.strokeColor = [UIColor cyanColor].CGColor;
    self.ghost2DCircle.lineWidth = 1.6;
    self.ghost2DCircle.fillColor = [UIColor clearColor].CGColor;
    self.ghost2DCircle.hidden = YES;
    [self.layer addSublayer:self.ghost2DCircle];

    CGFloat W = MAX(self.bounds.size.width, self.bounds.size.height);
    CGFloat H = MIN(self.bounds.size.width, self.bounds.size.height);
    self.handleCue    = [self create2DHandle:[UIColor whiteColor] center:CGPointMake(W * 0.35, H * 0.60) title:@"CÁI"];
    self.handleObj    = [self create2DHandle:[UIColor yellowColor] center:CGPointMake(W * 0.52, H * 0.45) title:@"MỤC TIÊU"];
    self.handlePocket = [self create2DHandle:[UIColor greenColor] center:CGPointMake(W * 0.78, H * 0.20) title:@"LỖ"];
}

- (void)update2DOverlayLines {
    if (!self.overlay2DEnabled) return;
    CGPoint pCue = self.handleCue.center;
    CGPoint pObj = self.handleObj.center;
    CGPoint pPoc = self.handlePocket.center;

    CGFloat dx = pPoc.x - pObj.x;
    CGFloat dy = pPoc.y - pObj.y;
    CGFloat len = hypot(dx, dy);
    CGFloat R = 13.0;
    CGPoint pGhost = (len > 1.0) ? CGPointMake(pObj.x - 2.0 * R * (dx / len), pObj.y - 2.0 * R * (dy / len)) : pObj;

    UIBezierPath *p1 = [UIBezierPath bezierPath];
    [p1 moveToPoint:pCue];
    [p1 addLineToPoint:pGhost];
    self.line2DAim.path = p1.CGPath;

    UIBezierPath *p2 = [UIBezierPath bezierPath];
    [p2 moveToPoint:pObj];
    [p2 addLineToPoint:pPoc];
    self.line2DTarget.path = p2.CGPath;

    self.ghost2DCircle.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(pGhost.x - R, pGhost.y - R, R * 2, R * 2)].CGPath;
}

#pragma mark - 5. Giao Diện Menu (Đã Bỏ Thanh Chỉnh Lực)

- (UIButton *)createBtn:(NSString *)title frame:(CGRect)frame action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.95];
    b.layer.cornerRadius = 7;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:b];
    return b;
}

- (void)setupMenuInterface {
    self.floatingIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingIcon.frame = CGRectMake(20, 42, 46, 46);
    self.floatingIcon.backgroundColor = [UIColor colorWithRed:0.05 green:0.10 blue:0.18 alpha:0.94];
    self.floatingIcon.layer.cornerRadius = 23;
    self.floatingIcon.layer.borderWidth = 2.0;
    self.floatingIcon.layer.borderColor = [UIColor cyanColor].CGColor;
    [self.floatingIcon setTitle:@"🎱" forState:UIControlStateNormal];
    self.floatingIcon.titleLabel.font = [UIFont systemFontOfSize:22];
    [self.floatingIcon addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *iconPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.floatingIcon addGestureRecognizer:iconPan];
    [self addSubview:self.floatingIcon];

    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake(75, 20, 340, 300)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:0.96];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor cyanColor].CGColor;
    self.menuPanel.hidden = YES;
    [self addSubview:self.menuPanel];

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 340, 30)];
    header.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.70 alpha:0.4];
    header.text = @"  🎱 VIRTUAL POOL 4 - PRO MOD MENU";
    header.textColor = [UIColor cyanColor];
    header.font = [UIFont boldSystemFontOfSize:12];
    header.userInteractionEnabled = YES;
    UIPanGestureRecognizer *menuPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.menuPanel addGestureRecognizer:menuPan];
    [self.menuPanel addSubview:header];

    // --- MỤC 1: LINE 3D GỐC THEO LỰC CƠ & ÁP-PHÊ ---
    [self createBtn:@"1. Line 3D Động (Theo Lực Cơ): OFF"
              frame:CGRectMake(10, 36, 210, 32)
             action:@selector(onToggleNative3DLine:)];

    [self createBtn:@"Mở Góc Camera: OFF"
              frame:CGRectMake(225, 36, 105, 32)
             action:@selector(onToggleFreeCam:)];

    [self createBtn:@"Làm Mới Tia 3D Trong Trận"
              frame:CGRectMake(10, 72, 210, 28)
             action:@selector(onForceRefresh3DTrack)];

    [self createBtn:@"Thước 2D: OFF"
              frame:CGRectMake(225, 72, 105, 28)
             action:@selector(onToggle2DOverlay:)];

    // --- MỤC 2: ONE SHOT & AUTO PLAY (ĐÃ BỎ THANH LỰC) ---
    UIView *div1 = [[UIView alloc] initWithFrame:CGRectMake(10, 106, 320, 1)];
    div1.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [self.menuPanel addSubview:div1];

    [self createBtn:@"🔥 BẮN NGAY 1 CƠ (ONE SHOT)"
              frame:CGRectMake(10, 112, 195, 32)
             action:@selector(performAutoCueStroke)];

    [self createBtn:@"🤖 Auto Play: OFF"
              frame:CGRectMake(210, 112, 120, 32)
             action:@selector(onToggleAutoPlay:)];

    // --- MỤC 3: MOD TIỀN CAREER MODE ---
    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(10, 150, 320, 1)];
    div2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [self.menuPanel addSubview:div2];

    UILabel *mLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 154, 320, 18)];
    mLbl.text = @"💰 MOD TIỀN CAREER (BẤM NHANH HOẶC QUÉT SỐ):";
    mLbl.textColor = [UIColor greenColor];
    mLbl.font = [UIFont boldSystemFontOfSize:10.5];
    [self.menuPanel addSubview:mLbl];

    self.moneyInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 176, 110, 28)];
    self.moneyInput.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.moneyInput.textColor = [UIColor whiteColor];
    self.moneyInput.placeholder = @"VD: 1500";
    self.moneyInput.font = [UIFont boldSystemFontOfSize:12];
    self.moneyInput.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInput.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInput.delegate = self;
    [self.menuPanel addSubview:self.moneyInput];

    [self createBtn:@"Quét Tiền" frame:CGRectMake(126, 176, 98, 28) action:@selector(onScanMoneyFirst)];
    [self createBtn:@"Lọc Tiền" frame:CGRectMake(230, 176, 100, 28) action:@selector(onScanMoneyFilter)];

    UIButton *cashBtn = [self createBtn:@"💎 BƠM TIỀN -> 9,999,999$ (AUTO + RAM)"
                                  frame:CGRectMake(10, 210, 320, 32)
                                 action:@selector(modCareerCashInstant9999999)];
    cashBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.0 alpha:0.95];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 246, 320, 48)];
    self.statusLabel.text = @"✅ Đã kích hoạt chế độ Dynamic GhostPath (0x1001968c8).\nTia 3D và bóng mờ sẽ tự co giãn theo đúng lực kéo cơ, áp-phê & trô!";
    self.statusLabel.textColor = [UIColor cyanColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.numberOfLines = 3;
    [self.menuPanel addSubview:self.statusLabel];
}

#pragma mark - Xử Lý Sự Kiện

- (void)toggleMenu {
    [self endEditing:YES];
    self.menuPanel.hidden = !self.menuPanel.hidden;
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:self];
    pan.view.center = CGPointMake(pan.view.center.x + d.x, pan.view.center.y + d.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)onHandleDrag:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:self];
    pan.view.center = CGPointMake(pan.view.center.x + d.x, pan.view.center.y + d.y);
    [pan setTranslation:CGPointZero inView:self];
    [self update2DOverlayLines];
}

- (void)onToggleNative3DLine:(UIButton *)btn {
    self.native3DLineEnabled = !self.native3DLineEnabled;
    if (self.native3DLineEnabled) {
        [btn setTitle:@"1. Line 3D Động (Theo Lực Cơ): ON" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.35 alpha:0.95];
        [self refreshCareerManagerInstances];
        [self enableDynamicPhysicsTrackOnce];
        [self maintainDynamicTrackFlags];
        self.statusLabel.text = [NSString stringWithFormat:@"🔥 Đã bật Line 3D Vật Lý Động (nhánh w0=2, khóa %lu phòng)!\nKéo nhẹ/mạnh thanh cơ hoặc chỉnh áp-phê để thấy tia thay đổi theo lực.", (unsigned long)_careerMgrInstances.size()];
    } else {
        [btn setTitle:@"1. Line 3D Động (Theo Lực Cơ): OFF" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.95];
        self.statusLabel.text = @"Đã tắt khóa Line 3D Động.";
    }
}

- (void)onForceRefresh3DTrack {
    [self refreshCareerManagerInstances];
    [self enableDynamicPhysicsTrackOnce];
    [self maintainDynamicTrackFlags];
    self.statusLabel.text = [NSString stringWithFormat:@"🔄 Đã làm mới tia 3D động & %lu phòng Career!", (unsigned long)_careerMgrInstances.size()];
}

- (void)onToggleFreeCam:(UIButton *)btn {
    self.freeCameraEnabled = !self.freeCameraEnabled;
    [btn setTitle:(self.freeCameraEnabled ? @"Mở Góc Camera: ON" : @"Mở Góc Camera: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = self.freeCameraEnabled ? [UIColor colorWithRed:0.0 green:0.55 blue:0.65 alpha:0.95] : [UIColor colorWithWhite:0.18 alpha:0.95];
    [self maintainDynamicTrackFlags];
}

- (void)onToggle2DOverlay:(UIButton *)btn {
    self.overlay2DEnabled = !self.overlay2DEnabled;
    [btn setTitle:(self.overlay2DEnabled ? @"Thước 2D: ON" : @"Thước 2D: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = self.overlay2DEnabled ? [UIColor colorWithRed:0.0 green:0.55 blue:0.65 alpha:0.95] : [UIColor colorWithWhite:0.18 alpha:0.95];
    self.line2DAim.hidden = !self.overlay2DEnabled;
    self.line2DTarget.hidden = !self.overlay2DEnabled;
    self.ghost2DCircle.hidden = !self.overlay2DEnabled;
    self.handleCue.hidden = !self.overlay2DEnabled;
    self.handleObj.hidden = !self.overlay2DEnabled;
    self.handlePocket.hidden = !self.overlay2DEnabled;
    [self update2DOverlayLines];
}

- (void)onToggleAutoPlay:(UIButton *)btn {
    self.autoPlayEnabled = !self.autoPlayEnabled;
    [btn setTitle:(self.autoPlayEnabled ? @"🤖 Auto Play: ON" : @"🤖 Auto Play: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = self.autoPlayEnabled ? [UIColor colorWithRed:0.75 green:0.25 blue:0.15 alpha:0.95] : [UIColor colorWithWhite:0.18 alpha:0.95];
    self.statusLabel.text = self.autoPlayEnabled ? @"🤖 Đang bật Auto Play: Tự động ra cơ mỗi 5 giây!" : @"Đã dừng Auto Play.";
}

- (void)onScanMoneyFirst {
    [self endEditing:YES];
    [self scanMoneyRAM:(int32_t)[self.moneyInput.text intValue] isFirst:YES];
}

- (void)onScanMoneyFilter {
    [self endEditing:YES];
    [self scanMoneyRAM:(int32_t)[self.moneyInput.text intValue] isFirst:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

__attribute__((constructor))
static void initVP4AllInOneMod() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win && [UIApplication sharedApplication].windows.count > 0) {
            win = [UIApplication sharedApplication].windows.firstObject;
        }
        if (win) {
            VP4ProModMenu *menu = [[VP4ProModMenu alloc] initWithFrame:win.bounds];
            menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [win addSubview:menu];
        }
    });
}
