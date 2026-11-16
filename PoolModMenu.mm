#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <vector>
#import <algorithm>

#if __has_include("GeneratedOffsets.h")
#import "GeneratedOffsets.h"
#else
static const uint64_t kAutoTrackOffsets[] = {};
static const size_t kAutoTrackOffsetsCount = 0;
#endif

struct TrackCandidate {
    vm_address_t addr;
    uint8_t onVal;
};

@interface VP4NativeModView : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *moneyStatusLabel;
@property (nonatomic, strong) UITextField *moneyInput;
@property (nonatomic, strong) CADisplayLink *freezeTimer;

@property (nonatomic, assign) BOOL lockNativeTrack;
@property (nonatomic, assign) BOOL lockPushOutAndRule;
@end

@implementation VP4NativeModView {
    std::vector<TrackCandidate> _trackCandidates;
    std::vector<TrackCandidate> _lockedTrackAddrs;
    std::vector<vm_address_t> _moneyAddrs;
    intptr_t _mainSlide;
    vm_address_t _dataStart;
    vm_size_t _dataSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.lockNativeTrack = NO;
        [self locateMainBinaryDataSegment];
        [self setupUI];

        // Vòng lặp 60FPS giữ cờ Tia 3D Gốc của game luôn = BẬT
        self.freezeTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrameTick)];
        [self.freezeTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

// Cho phép chạm xuyên qua vùng trống để xoay cơ, chỉnh áp-phê và kéo lực bình thường
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}

#pragma mark - Định vị vùng nhớ __DATA của VirtualPool4iPhone

- (void)locateMainBinaryDataSegment {
    _mainSlide = 0;
    _dataStart = 0;
    _dataSize = 0;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "VirtualPool") || i == 0)) {
            _mainSlide = _dyld_get_image_vmaddr_slide(i);
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            const uint8_t *ptr = (const uint8_t *)(header + 1);

            for (uint32_t c = 0; c < header->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)ptr;
                if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
                    if (strcmp(seg->segname, "__DATA") == 0) {
                        _dataStart = (vm_address_t)(seg->vmaddr + _mainSlide);
                        _dataSize  = (vm_size_t)seg->vmsize;
                        break;
                    }
                }
                ptr += lc->cmdsize;
            }
            if (_dataStart != 0) break;
        }
    }

    // Nạp sẵn các Offset tự động trích xuất từ GitHub Actions (nếu có)
    for (size_t i = 0; i < kAutoTrackOffsetsCount; i++) {
        vm_address_t target = (vm_address_t)(_mainSlide + kAutoTrackOffsets[i]);
        _lockedTrackAddrs.push_back({target, 1});
    }
}

#pragma mark - Vòng lặp Khóa Tia 3D Gốc (60Hz)

- (void)onFrameTick {
    if (!self.lockNativeTrack) return;

    mach_port_t task = mach_task_self();
    for (const auto &item : _lockedTrackAddrs) {
        uint8_t val = item.onVal ? item.onVal : 1;
        vm_write(task, item.addr, (vm_offset_t)&val, sizeof(uint8_t));
    }
}

#pragma mark - Quét & Tìm Cờ Tia 3D Gốc (Native 3D Trajectory Flag)

// Bước 1: Quét khi đang ở màn chơi CÓ TIA 3D GỐC (như trong video: Practice hoặc Amateur)
- (void)scanWhenTrackIsVisible {
    _trackCandidates.clear();
    mach_port_t task = mach_task_self();

    // Ưu tiên quét phân vùng __DATA của Binary chính (nơi lưu toàn bộ biến trạng thái C++ của Virtual Pool)
    if (_dataStart != 0 && _dataSize != 0) {
        std::vector<uint8_t> buf(_dataSize);
        vm_size_t outSize = 0;
        if (vm_read_overwrite(task, _dataStart, _dataSize, (vm_address_t)buf.data(), &outSize) == KERN_SUCCESS) {
            for (vm_size_t i = 0; i < outSize; i++) {
                uint8_t v = buf[i];
                // Các cờ bật tia (bool = 1, hoặc mode = 1, 2, 3)
                if (v >= 1 && v <= 3) {
                    _trackCandidates.push_back({_dataStart + i, v});
                }
            }
        }
    }

    // Quét thêm các vùng nhớ Heap nhỏ chứa cấu hình Match
    vm_address_t addr = 0;
    vm_size_t size = 0;
    while (_trackCandidates.size() < 250000) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

        BOOL rw = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        if (rw && size <= 8 * 1024 * 1024 && addr != _dataStart) {
            std::vector<uint8_t> buf(size);
            vm_size_t outSize = 0;
            if (vm_read_overwrite(task, addr, size, (vm_address_t)buf.data(), &outSize) == KERN_SUCCESS) {
                for (vm_size_t i = 0; i < outSize; i += 4) {
                    uint8_t v = buf[i];
                    if (v == 1 && (i + 3 < outSize) && buf[i+1] == 0 && buf[i+2] == 0 && buf[i+3] == 0) {
                        _trackCandidates.push_back({addr + i, 1});
                        if (_trackCandidates.size() >= 250000) break;
                    }
                }
            }
        }
        addr += size;
    }

    self.statusLabel.text = [NSString stringWithFormat:@"✅ Đã chụp %lu biến khi CÓ TIA.\nGiờ hãy tắt tia (hoặc vào trận mất tia) rồi bấm [2. Lọc Khi Mất Tia]!", (unsigned long)_trackCandidates.size()];
}

// Bước 2: Lọc khi vào chế độ MẤT TIA (giá trị chuyển về 0)
- (void)filterWhenTrackIsHidden {
    if (_trackCandidates.empty()) {
        self.statusLabel.text = @"⚠️ Bạn cần bấm [1. Quét Khi Có Tia] trước!";
        return;
    }

    std::vector<TrackCandidate> nextList;
    mach_port_t task = mach_task_self();

    for (const auto &c : _trackCandidates) {
        uint8_t cur = 255;
        vm_size_t outSize = 0;
        if (vm_read_overwrite(task, c.addr, sizeof(uint8_t), (vm_address_t)&cur, &outSize) == KERN_SUCCESS) {
            if (cur == 0) {
                nextList.push_back(c);
            }
        }
    }

    _trackCandidates = nextList;
    self.statusLabel.text = [NSString stringWithFormat:@"🎯 Còn lại: %lu địa chỉ nghi vấn.\n(Nếu > 50, hãy bật lại tia rồi bấm [2B. Lọc Khi Có Lại] để chuẩn 100%%).", (unsigned long)_trackCandidates.size()];
}

// Bước 2B: Lọc lại một lần nữa khi BẬT LẠI TIA (giá trị quay về > 0) để chính xác tuyệt đối
- (void)filterWhenTrackIsVisibleAgain {
    if (_trackCandidates.empty()) return;

    std::vector<TrackCandidate> nextList;
    mach_port_t task = mach_task_self();

    for (const auto &c : _trackCandidates) {
        uint8_t cur = 0;
        vm_size_t outSize = 0;
        if (vm_read_overwrite(task, c.addr, sizeof(uint8_t), (vm_address_t)&cur, &outSize) == KERN_SUCCESS) {
            if (cur == c.onVal || (cur >= 1 && cur <= 3)) {
                nextList.push_back({c.addr, cur});
            }
        }
    }

    _trackCandidates = nextList;
    self.statusLabel.text = [NSString stringWithFormat:@"🔥 Đã lọc chuẩn xác còn: %lu địa chỉ Tia 3D Gốc!\nBấm [3. KHÓA BẬT TIA 3D: ON] ngay!", (unsigned long)_trackCandidates.size()];
}

- (void)toggleLockNative3DTrack:(UIButton *)btn {
    self.lockNativeTrack = !self.lockNativeTrack;
    if (self.lockNativeTrack) {
        if (!_trackCandidates.empty()) {
            _lockedTrackAddrs.clear();
            // Khóa tối đa 60 địa chỉ sát nhất để tránh ghi nhầm biến khác
            size_t limit = std::min(_trackCandidates.size(), (size_t)60);
            for (size_t i = 0; i < limit; i++) {
                _lockedTrackAddrs.push_back(_trackCandidates[i]);
            }
        }
        [btn setTitle:@"3. KHÓA BẬT TIA 3D GỐC: ĐANG BẬT (ON)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.35 alpha:0.95];

        // Hiển thị luôn Offset thực tế để bạn có thể lưu cố định
        if (!_lockedTrackAddrs.empty() && _mainSlide != 0) {
            uint64_t firstOffset = (uint64_t)(_lockedTrackAddrs[0].addr - _mainSlide);
            self.statusLabel.text = [NSString stringWithFormat:@"🔒 Đang ép bật %lu địa chỉ Tia 3D Gốc (Offset đầu: 0x%llX)",
                                     (unsigned long)_lockedTrackAddrs.size(), firstOffset];
        } else {
            self.statusLabel.text = [NSString stringWithFormat:@"🔒 Đang khóa %lu địa chỉ Tia 3D Gốc!", (unsigned long)_lockedTrackAddrs.size()];
        }
    } else {
        [btn setTitle:@"3. KHÓA BẬT TIA 3D GỐC: ĐANG TẮT (OFF)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.95];
        self.statusLabel.text = @"Đã tạm dừng khóa Tia 3D Gốc.";
    }
}

#pragma mark - Quét & Mod Tiền Career Mode

- (void)scanMoney:(int32_t)val firstScan:(BOOL)first {
    mach_port_t task = mach_task_self();
    if (first) {
        _moneyAddrs.clear();
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
                            if (*(int32_t *)(buf.data() + i) == val) {
                                _moneyAddrs.push_back(addr + off + i);
                                if (_moneyAddrs.size() >= 150000) break;
                            }
                        }
                    }
                    if (_moneyAddrs.size() >= 150000) break;
                }
            }
            addr += size;
            if (_moneyAddrs.size() >= 150000) break;
        }
    } else {
        std::vector<vm_address_t> next;
        for (vm_address_t a : _moneyAddrs) {
            int32_t cur = 0;
            vm_size_t out = 0;
            if (vm_read_overwrite(task, a, 4, (vm_address_t)&cur, &out) == KERN_SUCCESS && cur == val) {
                next.push_back(a);
            }
        }
        _moneyAddrs = next;
    }
    self.moneyStatusLabel.text = [NSString stringWithFormat:@"Tìm thấy %lu địa chỉ khớp số tiền %d", (unsigned long)_moneyAddrs.size(), val];
}

- (void)writeMoney:(int32_t)newVal {
    mach_port_t task = mach_task_self();
    int count = 0;
    for (vm_address_t a : _moneyAddrs) {
        if (vm_write(task, a, (vm_offset_t)&newVal, 4) == KERN_SUCCESS) count++;
    }
    self.moneyStatusLabel.text = [NSString stringWithFormat:@"💰 Đã ghi 9,999,999$ vào %d địa chỉ!", count];
}

#pragma mark - Giao Diện Menu Điều Khiển

- (UIButton *)addBtn:(NSString *)title frame:(CGRect)frame tag:(NSInteger)tag action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.tag = tag;
    b.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.95];
    b.layer.cornerRadius = 7;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:b];
    return b;
}

- (void)setupUI {
    // Icon nổi 🎱
    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(25, 45, 46, 46);
    self.floatingBtn.backgroundColor = [UIColor colorWithRed:0.06 green:0.10 blue:0.18 alpha:0.92];
    self.floatingBtn.layer.cornerRadius = 23;
    self.floatingBtn.layer.borderWidth = 2.0;
    self.floatingBtn.layer.borderColor = [UIColor cyanColor].CGColor;
    [self.floatingBtn setTitle:@"🎱" forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont systemFontOfSize:22];
    [self.floatingBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *panIcon = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.floatingBtn addGestureRecognizer:panIcon];
    [self addSubview:self.floatingBtn];

    // Bảng Menu chính
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(80, 25, 330, 300)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.layer.borderColor = [UIColor cyanColor].CGColor;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 330, 32)];
    title.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.70 alpha:0.35];
    title.text = @"  VP4 - MỞ KHÓA TIA 3D GỐC (NATIVE TRACK)";
    title.textColor = [UIColor cyanColor];
    title.font = [UIFont boldSystemFontOfSize:12];
    title.userInteractionEnabled = YES;
    UIPanGestureRecognizer *panMenu = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.panelView addGestureRecognizer:panMenu];
    [self.panelView addSubview:title];

    // Nhóm 1: Mở khóa Tia 3D Gốc của Game
    [self addBtn:@"1. Quét Khi CÓ TIA" frame:CGRectMake(10, 40, 100, 32) tag:1 action:@selector(onTrackBtn:)];
    [self addBtn:@"2. Lọc Khi MẤT TIA" frame:CGRectMake(115, 40, 100, 32) tag:2 action:@selector(onTrackBtn:)];
    [self addBtn:@"2B. Lọc CÓ LẠI" frame:CGRectMake(220, 40, 100, 32) tag:3 action:@selector(onTrackBtn:)];

    [self addBtn:@"3. KHÓA BẬT TIA 3D GỐC: ĐANG TẮT (OFF)"
           frame:CGRectMake(10, 78, 310, 34)
             tag:4
          action:@selector(toggleLockNative3DTrack:)];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 116, 310, 48)];
    self.statusLabel.text = @"HƯỚNG DẪN: Vào bàn đang hiện tia gốc (như video) -> bấm [1] -> Tắt tia hoặc vào Career mất tia -> bấm [2] -> Bật lại tia bấm [2B] -> Bấm [3] để khóa tia 3D gốc luôn hiện!";
    self.statusLabel.textColor = [UIColor greenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.numberOfLines = 3;
    [self.panelView addSubview:self.statusLabel];

    // Nhóm 2: Mod Tiền
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, 170, 310, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [self.panelView addSubview:line];

    UILabel *mTitle = [[UILabel alloc] initWithFrame:CGRectMake(10, 176, 310, 18)];
    mTitle.text = @"💰 MOD TIỀN CAREER MODE (NHẬP TIỀN HIỆN TẠI):";
    mTitle.textColor = [UIColor yellowColor];
    mTitle.font = [UIFont boldSystemFontOfSize:11];
    [self.panelView addSubview:mTitle];

    self.moneyInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 198, 120, 30)];
    self.moneyInput.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.moneyInput.textColor = [UIColor whiteColor];
    self.moneyInput.placeholder = @"Nhập số tiền...";
    self.moneyInput.font = [UIFont boldSystemFontOfSize:12];
    self.moneyInput.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInput.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInput.delegate = self;
    [self.panelView addSubview:self.moneyInput];

    [self addBtn:@"Quét Tiền" frame:CGRectMake(138, 198, 86, 30) tag:10 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Lọc Tiền" frame:CGRectMake(232, 198, 88, 30) tag:11 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Sửa Tiền Thành 9,999,999$" frame:CGRectMake(10, 234, 310, 32) tag:12 action:@selector(onMoneyBtn:)];

    self.moneyStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 270, 310, 22)];
    self.moneyStatusLabel.text = @"Sẵn sàng quét bộ nhớ.";
    self.moneyStatusLabel.textColor = [UIColor lightGrayColor];
    self.moneyStatusLabel.font = [UIFont systemFontOfSize:10];
    [self.panelView addSubview:self.moneyStatusLabel];
}

- (void)togglePanel {
    [self endEditing:YES];
    self.panelView.hidden = !self.panelView.hidden;
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:self];
    pan.view.center = CGPointMake(pan.view.center.x + d.x, pan.view.center.y + d.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)onTrackBtn:(UIButton *)sender {
    if (sender.tag == 1) [self scanWhenTrackIsVisible];
    else if (sender.tag == 2) [self filterWhenTrackIsHidden];
    else if (sender.tag == 3) [self filterWhenTrackIsVisibleAgain];
}

- (void)onMoneyBtn:(UIButton *)sender {
    [self endEditing:YES];
    int32_t v = (int32_t)[self.moneyInput.text intValue];
    if (sender.tag == 10) [self scanMoney:v firstScan:YES];
    else if (sender.tag == 11) [self scanMoney:v firstScan:NO];
    else if (sender.tag == 12) [self writeMoney:9999999];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

__attribute__((constructor))
static void initVP4NativeMod() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win && [UIApplication sharedApplication].windows.count > 0) {
            win = [UIApplication sharedApplication].windows.firstObject;
        }
        if (win) {
            VP4NativeModView *modView = [[VP4NativeModView alloc] initWithFrame:win.bounds];
            modView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [win addSubview:modView];
        }
    });
}
