#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <vector>
#import <algorithm>
#import <cmath>

// Hàm tính địa chỉ thực tế trong RAM từ địa chỉ tĩnh trong Offsets_Report_4.txt
static inline vm_address_t VP4Addr(uintptr_t baseHeader, uint64_t staticVMA) {
    return (vm_address_t)(baseHeader + (staticVMA - 0x100000000ULL));
}

// Kiểu hàm gốc SetAimAids(int mode) tại 0x1001112b8 (0: No AimAids, 1: AimLine, 3: TrackAll)
typedef void (*VP4SetAimAidsFn)(int mode);

struct DiscoveredGlobal {
    vm_address_t addr;
    bool isByte;
    bool isPtrDeref;
    uint32_t fieldOffset;
};

#pragma mark - Lớp Giả Lập Thao Tác Vuốt Thanh Cơ (Dùng Cho Auto Shoot / Auto Play)

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

#pragma mark - Giao Diện & Logic Chính Của Mod Menu

@interface VP4ProModMenu : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *floatingIcon;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *powerLabel;
@property (nonatomic, strong) UISlider *powerSlider;
@property (nonatomic, strong) UITextField *moneyInput;
@property (nonatomic, strong) CADisplayLink *engineTimer;

// Lớp thước kẻ 2D phụ (Overlay 2D)
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
@property (nonatomic, assign) float shotPower; // 0.15 -> 1.0
@end

@implementation VP4ProModMenu {
    uintptr_t _baseHeader;
    std::vector<DiscoveredGlobal> _funcGlobals;
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
        self.shotPower = 0.65f;
        _frameCounter = 0;
        _isStroking = NO;

        [self locateGameBinaryAndDecodeAimFunction];
        [self setup2DOverlayElements];
        [self setupMenuInterface];

        self.engineTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(onEngineFrame)];
        [self.engineTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

// Cho phép chạm xuyên qua vùng trống để xoay cơ trong game bình thường
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

#pragma mark - 1. Định Vị Binary & Giải Mã Hàm SetAimAids (0x1001112b8)

- (void)locateGameBinaryAndDecodeAimFunction {
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
    if (_baseHeader == 0) return;

    // Tự động giải mã thân hàm SetAimAids (0x1001112b8) và GetAimFlag (0x10017bdc8) trong RAM
    uint64_t targetFuncs[] = { 0x1001112b8ULL, 0x10017bdc8ULL };
    for (uint64_t fnVMA : targetFuncs) {
        vm_address_t fnStart = VP4Addr(_baseHeader, fnVMA);
        uint64_t regBase[32] = {0};
        bool regDeref[32] = {false};

        for (int idx = 0; idx < 80; idx++) {
            uint32_t insn = *(const uint32_t *)(fnStart + idx * 4);
            if (insn == 0xd65f03c0) break; // RET

            if ((insn & 0x9f000000) == 0x90000000) { // ADRP Xd, page
                uint32_t rd = insn & 0x1f;
                int64_t immlo = (insn >> 29) & 0x3;
                int64_t immhi = (insn >> 5) & 0x7ffff;
                int64_t imm = (immhi << 2) | immlo;
                if (imm & (1LL << 20)) imm -= (1LL << 21);
                uint64_t pcPage = ((uint64_t)(fnStart + idx * 4)) & ~0xfffULL;
                regBase[rd] = pcPage + (imm << 12);
                regDeref[rd] = false;
            } else if ((insn & 0xff800000) == 0x91000000) { // ADD Xd, Xn, #imm12
                uint32_t rd = insn & 0x1f;
                uint32_t rn = (insn >> 5) & 0x1f;
                uint64_t imm12 = (insn >> 10) & 0xfff;
                if ((insn >> 22) & 1) imm12 <<= 12;
                if (regBase[rn] != 0) {
                    regBase[rd] = regBase[rn] + imm12;
                    regDeref[rd] = regDeref[rn];
                }
            } else if ((insn & 0xffc00000) == 0xf9400000) { // LDR Xd, [Xn, #imm12*8]
                uint32_t rd = insn & 0x1f;
                uint32_t rn = (insn >> 5) & 0x1f;
                uint64_t imm12 = ((insn >> 10) & 0xfff) * 8;
                if (regBase[rn] != 0 && !regDeref[rn]) {
                    regBase[rd] = regBase[rn] + imm12;
                    regDeref[rd] = true;
                }
            } else if ((insn & 0xffc00000) == 0xb9000000 || (insn & 0xffc00000) == 0xb9400000) { // STR/LDR Wd, [Xn, #imm12*4]
                uint32_t rn = (insn >> 5) & 0x1f;
                uint32_t imm12 = ((insn >> 10) & 0xfff) * 4;
                if (regBase[rn] != 0) {
                    if (!regDeref[rn]) {
                        _funcGlobals.push_back({(vm_address_t)(regBase[rn] + imm12), false, false, 0});
                    } else {
                        _funcGlobals.push_back({(vm_address_t)regBase[rn], false, true, imm12});
                    }
                }
            } else if ((insn & 0xffc00000) == 0x39000000 || (insn & 0xffc00000) == 0x39400000) { // STRB/LDRB Wd, [Xn, #imm12]
                uint32_t rn = (insn >> 5) & 0x1f;
                uint32_t imm12 = (insn >> 10) & 0xfff;
                if (regBase[rn] != 0) {
                    if (!regDeref[rn]) {
                        _funcGlobals.push_back({(vm_address_t)(regBase[rn] + imm12), true, false, 0});
                    } else {
                        _funcGlobals.push_back({(vm_address_t)regBase[rn], true, true, imm12});
                    }
                }
            }
        }
    }
}

// Quét tìm đối tượng cwCareerManager (VTable 0x100fb8988) trong Heap để mở khóa +0x5c = 3 (TrackAll)
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

#pragma mark - 2. Vòng Lặp 60FPS Khóa Cứng Line 3D Gốc (TrackAll) & Camera

- (void)applyNativeTrackAllNow {
    if (_baseHeader == 0) return;
    mach_port_t task = mach_task_self();

    // A. Khóa cấu trúc PlayerProfile / cwTrackSettings tại con trỏ toàn cục 0x1012924b0
    vm_address_t profilePtrAddr = VP4Addr(_baseHeader, 0x1012924b0ULL);
    uint64_t profileObj = 0;
    vm_size_t outSize = 0;
    if (vm_read_overwrite(task, profilePtrAddr, sizeof(uint64_t), (vm_address_t)&profileObj, &outSize) == KERN_SUCCESS && profileObj > 0x100000000ULL) {
        if (self.native3DLineEnabled) {
            uint32_t trackTypeGhostPath = 3; // 3 = TrackingGhostPath (Đủ đường đi + Ghost Ball)
            uint32_t one = 1;
            vm_write(task, (vm_address_t)(profileObj + 0x88), (vm_offset_t)&trackTypeGhostPath, sizeof(uint32_t));
            vm_write(task, (vm_address_t)(profileObj + 0x8c), (vm_offset_t)&one, sizeof(uint32_t)); // Track AimLine = ON
            vm_write(task, (vm_address_t)(profileObj + 0xc0), (vm_offset_t)&one, sizeof(uint32_t)); // Track CueBall = ON
        }
        if (self.freeCameraEnabled) {
            uint32_t zero = 0;
            vm_write(task, (vm_address_t)(profileObj + 0x48), (vm_offset_t)&zero, sizeof(uint32_t)); // Restrict Aim Eyepoint = OFF
        }
    }

    if (!self.native3DLineEnabled) return;

    // B. Khóa các biến toàn cục tìm thấy trong thân hàm 0x1001112b8 & 0x10017bdc8
    for (const auto &g : _funcGlobals) {
        vm_address_t writeAddr = g.addr;
        if (g.isPtrDeref) {
            uint64_t baseObj = 0;
            if (vm_read_overwrite(task, g.addr, sizeof(uint64_t), (vm_address_t)&baseObj, &outSize) == KERN_SUCCESS && baseObj > 0x100000000ULL) {
                writeAddr = (vm_address_t)(baseObj + g.fieldOffset);
            } else {
                continue;
            }
        }
        if (g.isByte) {
            uint8_t val8 = 1;
            vm_write(task, writeAddr, (vm_offset_t)&val8, sizeof(uint8_t));
        } else {
            uint32_t val32 = 3; // 3 = TrackAll
            vm_write(task, writeAddr, (vm_offset_t)&val32, sizeof(uint32_t));
        }
    }

    // C. Khóa offset +0x5c = 3 (TrackAll) trong mọi đối tượng cwCareerManager đang sống
    uint32_t modeTrackAll = 3;
    for (vm_address_t mgr : _careerMgrInstances) {
        vm_write(task, mgr + 0x5c, (vm_offset_t)&modeTrackAll, sizeof(uint32_t));
    }
}

- (void)onEngineFrame {
    _frameCounter++;
    if (self.native3DLineEnabled || self.freeCameraEnabled) {
        [self applyNativeTrackAllNow];
        // Mỗi 2 giây gọi lại hàm gốc SetAimAids(3) của game để đồng bộ engine vẽ 3D
        if (self.native3DLineEnabled && (_frameCounter % 120 == 1) && _baseHeader != 0) {
            VP4SetAimAidsFn setAimFn = (VP4SetAimAidsFn)VP4Addr(_baseHeader, 0x1001112b8ULL);
            setAimFn(3);
        }
    }

    // Nếu bật Auto Play, tự động thực hiện cú kéo cơ mỗi 5.5 giây
    if (self.autoPlayEnabled && !_isStroking && (_frameCounter % 330 == 0)) {
        [self performAutoCueStroke];
    }
}

#pragma mark - 3. Chức Năng Auto Play / Auto Cue Stroke (Tự Động Kéo Cơ Bắn Bi)

- (UIView *)findGameRenderView:(UIView *)root {
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[VP4ProModMenu class]]) continue;
        NSString *clsName = NSStringFromClass([sub class]);
        if ([clsName containsString:@"GL"] || [clsName containsString:@"EAGL"] || sub.subviews.count == 0) {
            if (sub.bounds.size.width > 200 && sub.bounds.size.height > 200) {
                return sub;
            }
        }
        UIView *found = [self findGameRenderView:sub];
        if (found) return found;
    }
    return root;
}

- (void)performAutoCueStroke {
    if (_isStroking || !self.window) return;
    _isStroking = YES;

    UIWindow *win = self.window;
    UIView *gameView = [self findGameRenderView:win];
    CGFloat W = win.bounds.size.width;
    CGFloat H = win.bounds.size.height;

    // Tọa độ thanh kéo cơ (Cue Stick Slider) nằm dọc bên mép phải màn hình
    CGFloat sliderX = W - 26.0;
    CGFloat startY  = H * 0.44;
    CGFloat pullY   = startY + (H * 0.36) * self.shotPower; // Kéo xuống theo % lực
    CGFloat hitY    = H * 0.18;                             // Đẩy mạnh lên để chạm bi

    VP4SyntheticTouch *touch = [[VP4SyntheticTouch alloc] init];
    touch.synthWindow = win;
    touch.synthView = gameView;
    touch.synthLocation = CGPointMake(sliderX, startY);
    touch.synthPrevLocation = CGPointMake(sliderX, startY);
    touch.synthPhase = UITouchPhaseBegan;
    touch.synthTimestamp = [[NSProcessInfo processInfo] systemUptime];

    NSSet *touchSet = [NSSet setWithObject:touch];
    [gameView touchesBegan:touchSet withEvent:nil];

    // Giai đoạn 1: Kéo cơ lùi về sau (8 bước)
    int pullSteps = 8;
    for (int i = 1; i <= pullSteps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 22 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            touch.synthPrevLocation = touch.synthLocation;
            CGFloat curY = startY + (pullY - startY) * ((CGFloat)i / pullSteps);
            touch.synthLocation = CGPointMake(sliderX, curY);
            touch.synthPhase = UITouchPhaseMoved;
            touch.synthTimestamp = [[NSProcessInfo processInfo] systemUptime];
            [gameView touchesMoved:touchSet withEvent:nil];
        });
    }

    // Giai đoạn 2: Đẩy cơ tới trước dứt khoát để bắn bi
    int pushStartMs = (pullSteps + 2) * 22;
    int pushSteps = 4;
    for (int j = 1; j <= pushSteps; j++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((pushStartMs + j * 12) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            touch.synthPrevLocation = touch.synthLocation;
            CGFloat curY = pullY + (hitY - pullY) * ((CGFloat)j / pushSteps);
            touch.synthLocation = CGPointMake(sliderX, curY);
            touch.synthPhase = UITouchPhaseMoved;
            touch.synthTimestamp = [[NSProcessInfo processInfo] systemUptime];
            [gameView touchesMoved:touchSet withEvent:nil];
        });
    }

    // Giai đoạn 3: Nhả tay kết thúc cú đánh
    int endMs = pushStartMs + (pushSteps + 1) * 12;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        touch.synthPrevLocation = touch.synthLocation;
        touch.synthPhase = UITouchPhaseEnded;
        touch.synthTimestamp = [[NSProcessInfo processInfo] systemUptime];
        [gameView touchesEnded:touchSet withEvent:nil];
        _isStroking = NO;
    });

    self.statusLabel.text = [NSString stringWithFormat:@"⚡ Đã thực hiện cú bắn tự động (Lực: %.0f%%)!", self.shotPower * 100.0f];
}

#pragma mark - 4. Chức Năng Mod Tiền (VTable 10CareerPlay 0x100fba2b8 + Quét RAM)

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

    // Đồng thời nếu đã quét RAM thủ công thì ghi đè luôn
    int manualCount = 0;
    int32_t rich = 9999999;
    for (vm_address_t a : _moneyScanList) {
        if (vm_write(task, a, (vm_offset_t)&rich, 4) == KERN_SUCCESS) manualCount++;
    }

    self.statusLabel.text = [NSString stringWithFormat:@"💰 Đã bơm 9,999,999$ (CareerPlay Struct: %d | RAM Scan: %d)!", patchedCareerStructs, manualCount];
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

#pragma mark - 5. Thước Kẻ 2D Phụ (Overlay 2D Tùy Chọn)

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

#pragma mark - 6. Khởi Tạo Giao Diện Menu Đầy Đủ Chức Năng

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
    // Nút Icon nổi 🎱
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

    // Bảng Menu chính
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake(75, 15, 340, 330)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:0.96];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor cyanColor].CGColor;
    self.menuPanel.hidden = YES;
    [self addSubview:self.menuPanel];

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 340, 30)];
    header.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.70 alpha:0.4];
    header.text = @"  🎱 VIRTUAL POOL 4 - ALL-IN-ONE MOD MENU";
    header.textColor = [UIColor cyanColor];
    header.font = [UIFont boldSystemFontOfSize:12];
    header.userInteractionEnabled = YES;
    UIPanGestureRecognizer *menuPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.menuPanel addGestureRecognizer:menuPan];
    [self.menuPanel addSubview:header];

    // --- MỤC 1: LINE 3D GỐC & CAMERA ---
    [self createBtn:@"1. Line 3D Gốc (TrackAll): OFF"
              frame:CGRectMake(10, 36, 210, 32)
             action:@selector(onToggleNative3DLine:)];

    [self createBtn:@"Mở Góc Camera: OFF"
              frame:CGRectMake(225, 36, 105, 32)
             action:@selector(onToggleFreeCam:)];

    [self createBtn:@"Kích Hoạt Lại Tia 3D Trong Trận"
              frame:CGRectMake(10, 72, 210, 28)
             action:@selector(onForceRefresh3DTrack)];

    [self createBtn:@"Thước 2D: OFF"
              frame:CGRectMake(225, 72, 105, 28)
             action:@selector(onToggle2DOverlay:)];

    // --- MỤC 2: AUTO PLAY / TỰ BẮN BI ---
    UIView *div1 = [[UIView alloc] initWithFrame:CGRectMake(10, 106, 320, 1)];
    div1.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [self.menuPanel addSubview:div1];

    self.powerLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 110, 140, 20)];
    self.powerLabel.text = @"⚡ Lực Bắn Auto: 65%";
    self.powerLabel.textColor = [UIColor yellowColor];
    self.powerLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.menuPanel addSubview:self.powerLabel];

    self.powerSlider = [[UISlider alloc] initWithFrame:CGRectMake(145, 108, 185, 24)];
    self.powerSlider.minimumValue = 0.15f;
    self.powerSlider.maximumValue = 1.00f;
    self.powerSlider.value = 0.65f;
    [self.powerSlider addTarget:self action:@selector(onPowerChanged:) forControlEvents:UIControlEventValueChanged];
    [self.menuPanel addSubview:self.powerSlider];

    [self createBtn:@"🔥 BẮN NGAY 1 CƠ (AUTO SHOT)"
              frame:CGRectMake(10, 136, 195, 32)
             action:@selector(performAutoCueStroke)];

    [self createBtn:@"🤖 Auto Play: OFF"
              frame:CGRectMake(210, 136, 120, 32)
             action:@selector(onToggleAutoPlay:)];

    // --- MỤC 3: MOD TIỀN CAREER MODE ---
    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(10, 174, 320, 1)];
    div2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [self.menuPanel addSubview:div2];

    UILabel *mLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 178, 320, 18)];
    mLbl.text = @"💰 MOD TIỀN CAREER (BẤM NHANH HOẶC QUÉT SỐ):";
    mLbl.textColor = [UIColor greenColor];
    mLbl.font = [UIFont boldSystemFontOfSize:10.5];
    [self.menuPanel addSubview:mLbl];

    self.moneyInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 200, 110, 28)];
    self.moneyInput.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.moneyInput.textColor = [UIColor whiteColor];
    self.moneyInput.placeholder = @"VD: 1500";
    self.moneyInput.font = [UIFont boldSystemFontOfSize:12];
    self.moneyInput.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInput.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInput.delegate = self;
    [self.menuPanel addSubview:self.moneyInput];

    [self createBtn:@"Quét Tiền" frame:CGRectMake(126, 200, 98, 28) action:@selector(onScanMoneyFirst)];
    [self createBtn:@"Lọc Tiền" frame:CGRectMake(230, 200, 100, 28) action:@selector(onScanMoneyFilter)];

    UIButton *cashBtn = [self createBtn:@"💎 BƠM TIỀN -> 9,999,999$ (AUTO + RAM)"
                                  frame:CGRectMake(10, 234, 320, 32)
                                 action:@selector(modCareerCashInstant9999999)];
    cashBtn.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.0 alpha:0.95];

    // Thanh trạng thái
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 272, 320, 50)];
    self.statusLabel.text = [NSString stringWithFormat:@"✅ Đã nạp %lu biến gốc từ hàm SetAimAids (0x1001112b8).\nBấm [1. Line 3D Gốc] để mở toàn bộ tia ngắm 3D & bóng mờ!", (unsigned long)_funcGlobals.size()];
    self.statusLabel.textColor = [UIColor cyanColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.numberOfLines = 3;
    [self.menuPanel addSubview:self.statusLabel];
}

#pragma mark - Sự Kiện Nút Bấm

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
        [btn setTitle:@"1. Line 3D Gốc (TrackAll): ON" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.35 alpha:0.95];
        [self refreshCareerManagerInstances];
        [self applyNativeTrackAllNow];
        if (_baseHeader != 0) {
            VP4SetAimAidsFn setAimFn = (VP4SetAimAidsFn)VP4Addr(_baseHeader, 0x1001112b8ULL);
            setAimFn(3); // Gọi thẳng hàm gốc của game: 3 = TrackAll
        }
        self.statusLabel.text = [NSString stringWithFormat:@"🔥 Đã bật TrackAll (0x1001112b8) + khóa %lu phòng Career!\nHãy nhích nhẹ cơ để tia 3D & bóng mờ hiện lên.", (unsigned long)_careerMgrInstances.size()];
    } else {
        [btn setTitle:@"1. Line 3D Gốc (TrackAll): OFF" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.95];
        self.statusLabel.text = @"Đã tắt khóa Line 3D Gốc.";
    }
}

- (void)onForceRefresh3DTrack {
    [self refreshCareerManagerInstances];
    [self applyNativeTrackAllNow];
    if (_baseHeader != 0) {
        VP4SetAimAidsFn setAimFn = (VP4SetAimAidsFn)VP4Addr(_baseHeader, 0x1001112b8ULL);
        setAimFn(3);
    }
    self.statusLabel.text = [NSString stringWithFormat:@"🔄 Đã làm mới hàm SetAimAids(3) & %lu đối tượng Career!", (unsigned long)_careerMgrInstances.size()];
}

- (void)onToggleFreeCam:(UIButton *)btn {
    self.freeCameraEnabled = !self.freeCameraEnabled;
    [btn setTitle:(self.freeCameraEnabled ? @"Mở Góc Camera: ON" : @"Mở Góc Camera: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = self.freeCameraEnabled ? [UIColor colorWithRed:0.0 green:0.55 blue:0.65 alpha:0.95] : [UIColor colorWithWhite:0.18 alpha:0.95];
    [self applyNativeTrackAllNow];
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

- (void)onPowerChanged:(UISlider *)slider {
    self.shotPower = slider.value;
    self.powerLabel.text = [NSString stringWithFormat:@"⚡ Lực Bắn Auto: %.0f%%", self.shotPower * 100.0f];
}

- (void)onToggleAutoPlay:(UIButton *)btn {
    self.autoPlayEnabled = !self.autoPlayEnabled;
    [btn setTitle:(self.autoPlayEnabled ? @"🤖 Auto Play: ON" : @"🤖 Auto Play: OFF") forState:UIControlStateNormal];
    btn.backgroundColor = self.autoPlayEnabled ? [UIColor colorWithRed:0.75 green:0.25 blue:0.15 alpha:0.95] : [UIColor colorWithWhite:0.18 alpha:0.95];
    self.statusLabel.text = self.autoPlayEnabled ? @"🤖 Đang bật Auto Play: Tự động kéo cơ bắn mỗi 5.5 giây!" : @"Đã dừng Auto Play.";
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
