#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <vector>
#import <algorithm>

struct TrackMemItem {
    vm_address_t addr;
    uint32_t onVal;
};

@interface VP4NativeModView : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *moneyStatusLabel;
@property (nonatomic, strong) UITextField *moneyInput;
@property (nonatomic, strong) CADisplayLink *freezeTimer;
@property (nonatomic, assign) BOOL lockNativeTrack;
@end

@implementation VP4NativeModView {
    std::vector<TrackMemItem> _candidates;
    std::vector<TrackMemItem> _lockedAddrs;
    std::vector<vm_address_t> _moneyAddrs;
    intptr_t _slide;
    vm_address_t _textStart, _textEnd;
    vm_address_t _dataStart, _dataEnd;
    int _scanStep;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.lockNativeTrack = NO;
        _scanStep = 0;
        [self parseBinarySegments];
        [self setupMenuUI];

        self.freezeTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick)];
        [self.freezeTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

- (void)parseBinarySegments {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "VirtualPool") || i == 0)) {
            _slide = _dyld_get_image_vmaddr_slide(i);
            const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            const uint8_t *p = (const uint8_t *)(hdr + 1);
            for (uint32_t c = 0; c < hdr->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)p;
                if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
                    if (strcmp(seg->segname, "__TEXT") == 0) {
                        _textStart = (vm_address_t)(seg->vmaddr + _slide);
                        _textEnd   = _textStart + (vm_size_t)seg->vmsize;
                    } else if (strcmp(seg->segname, "__DATA") == 0) {
                        _dataStart = (vm_address_t)(seg->vmaddr + _slide);
                        _dataEnd   = _dataStart + (vm_size_t)seg->vmsize;
                    }
                }
                p += lc->cmdsize;
            }
            if (_dataStart != 0) break;
        }
    }
}

- (void)onTick {
    if (!self.lockNativeTrack || _lockedAddrs.empty()) return;
    mach_port_t task = mach_task_self();
    for (const auto &item : _lockedAddrs) {
        uint32_t val = item.onVal;
        vm_write(task, item.addr, (vm_offset_t)&val, sizeof(uint32_t));
    }
}

#pragma mark - Quét 32-bit Int Chuẩn C++ (Track Type / Track AimLine / Track CueBall)

// Bước 1: Quét khi đang ở bàn Practice / Quick Play CÓ ĐỦ TIA 3D ĐỎ/TRẮNG
- (void)step1ScanFullTrack {
    _candidates.clear();
    mach_port_t task = mach_task_self();

    vm_address_t addr = 0;
    vm_size_t size = 0;
    while (true) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

        BOOL rw = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        // Quét vùng __DATA và các vùng Heap chứa cấu hình ván đấu
        if (rw && size <= 32 * 1024 * 1024) {
            const vm_size_t chunk = 65536;
            std::vector<uint8_t> buf(chunk);
            for (vm_size_t off = 0; off < size; off += chunk) {
                vm_size_t rSize = MIN(chunk, size - off);
                vm_size_t out = 0;
                if (vm_read_overwrite(task, addr + off, rSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
                    for (vm_size_t i = 0; i + 4 <= out; i += 4) {
                        uint32_t v = *(uint32_t *)(buf.data() + i);
                        // Trong Virtual Pool 4: TrackAll / Track AimLine / Track CueBall là int32 từ 1 đến 4
                        if (v >= 1 && v <= 4) {
                            _candidates.push_back({addr + off + i, v});
                            if (_candidates.size() >= 350000) break;
                        }
                    }
                }
                if (_candidates.size() >= 350000) break;
            }
        }
        addr += size;
        if (_candidates.size() >= 350000) break;
    }

    _scanStep = 1;
    self.statusLabel.text = [NSString stringWithFormat:@"✅ BƯỚC 1 XONG (%lu biến).\nBây giờ hãy vào trận Career (bị mất tia) rồi bấm [BƯỚC 2: Lọc Khi Mất Tia]!", (unsigned long)_candidates.size()];
}

// Bước 2: Lọc khi ở trong Career Mode (Mất tia -> Giá trị giảm về 0)
- (void)step2FilterNoTrack {
    if (_scanStep < 1 || _candidates.empty()) {
        self.statusLabel.text = @"⚠️ Bạn phải vào màn CÓ TIA bấm [BƯỚC 1] trước, rồi mới sang màn mất tia bấm [BƯỚC 2]!";
        return;
    }

    std::vector<TrackMemItem> filtered;
    mach_port_t task = mach_task_self();
    for (const auto &item : _candidates) {
        uint32_t cur = 999;
        vm_size_t out = 0;
        if (vm_read_overwrite(task, item.addr, sizeof(uint32_t), (vm_address_t)&cur, &out) == KERN_SUCCESS) {
            // Khi mất tia (No AimAids hoặc chỉ còn AimLine ngắn), giá trị về 0 hoặc nhỏ hơn lúc TrackAll
            if (cur == 0) {
                filtered.push_back(item);
            }
        }
    }

    _candidates = filtered;
    _scanStep = 2;
    self.statusLabel.text = [NSString stringWithFormat:@"🎯 BƯỚC 2 XONG: Đã lọc còn %lu biến.\nNếu số này > 100, hãy quay lại bàn CÓ TIA bấm [BƯỚC 2B] rồi quay lại Career bấm [BƯỚC 2] lần nữa!", (unsigned long)_candidates.size()];
}

// Bước 2B: Lọc lặp lại khi bật lại Tia
- (void)step2BFilterTrackAgain {
    if (_candidates.empty()) return;

    std::vector<TrackMemItem> filtered;
    mach_port_t task = mach_task_self();
    for (const auto &item : _candidates) {
        uint32_t cur = 0;
        vm_size_t out = 0;
        if (vm_read_overwrite(task, item.addr, sizeof(uint32_t), (vm_address_t)&cur, &out) == KERN_SUCCESS) {
            if (cur == item.onVal && cur >= 1 && cur <= 4) {
                filtered.push_back(item);
            }
        }
    }

    _candidates = filtered;
    self.statusLabel.text = [NSString stringWithFormat:@"🔥 BƯỚC 2B XONG: Chỉ còn %lu biến chuẩn xác!\nBấm [BƯỚC 3: BẬT KHÓA TIA 3D] ngay!", (unsigned long)_candidates.size()];
}

- (void)step3ToggleLock:(UIButton *)btn {
    if (!self.lockNativeTrack) {
        if (_scanStep < 2) {
            self.statusLabel.text = @"❌ Chưa lọc Bước 2! Bạn đang có quá nhiều biến, phải bấm [BƯỚC 2: Lọc Khi Mất Tia] trước khi Khóa!";
            return;
        }
        _lockedAddrs.clear();
        size_t limit = std::min(_candidates.size(), (size_t)200);
        for (size_t i = 0; i < limit; i++) {
            _lockedAddrs.push_back(_candidates[i]);
        }
        self.lockNativeTrack = YES;
        [btn setTitle:@"BƯỚC 3: ĐANG KHÓA BẬT TIA 3D (ON)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.35 alpha:0.95];

        uint64_t off = (_lockedAddrs.empty()) ? 0 : (uint64_t)(_lockedAddrs[0].addr - _slide);
        self.statusLabel.text = [NSString stringWithFormat:@"🔒 Đang khóa cứng %lu biến TrackAll (Offset: 0x%llX).\nHãy xoay nhẹ cơ để game vẽ lại tia 3D!", (unsigned long)_lockedAddrs.size(), off];
    } else {
        self.lockNativeTrack = NO;
        [btn setTitle:@"BƯỚC 3: KHÓA BẬT TIA 3D (OFF)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.95];
        self.statusLabel.text = @"Đã tắt khóa tia 3D.";
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

#pragma mark - Giao Diện Menu

- (UIButton *)addBtn:(NSString *)title frame:(CGRect)frame tag:(NSInteger)tag action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.tag = tag;
    b.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.95];
    b.layer.cornerRadius = 7;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.6].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:10.5];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:b];
    return b;
}

- (void)setupMenuUI {
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

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(80, 25, 330, 305)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.layer.borderColor = [UIColor cyanColor].CGColor;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 330, 32)];
    title.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.70 alpha:0.35];
    title.text = @"  VP4 - MỞ KHÓA TIA 3D GỐC (TrackAll)";
    title.textColor = [UIColor cyanColor];
    title.font = [UIFont boldSystemFontOfSize:12];
    title.userInteractionEnabled = YES;
    UIPanGestureRecognizer *panMenu = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.panelView addGestureRecognizer:panMenu];
    [self.panelView addSubview:title];

    [self addBtn:@"B1: Quét Có Tia" frame:CGRectMake(10, 40, 100, 32) tag:1 action:@selector(onTrackBtn:)];
    [self addBtn:@"B2: Lọc Mất Tia" frame:CGRectMake(115, 40, 100, 32) tag:2 action:@selector(onTrackBtn:)];
    [self addBtn:@"B2B: Lọc Có Lại" frame:CGRectMake(220, 40, 100, 32) tag:3 action:@selector(onTrackBtn:)];

    [self addBtn:@"BƯỚC 3: KHÓA BẬT TIA 3D (OFF)"
           frame:CGRectMake(10, 78, 310, 34)
             tag:4
          action:@selector(step3ToggleLock:)];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 116, 310, 52)];
    self.statusLabel.text = @"⚠️ BẮT BUỘC LÀM ĐỦ BƯỚC:\n1) Vào Practice (có đủ tia đỏ/trắng) bấm [B1]\n2) Sang Career (mất tia) bấm [B2]\n3) Quay lại Practice bấm [B2B] -> rồi mới bấm [BƯỚC 3]!";
    self.statusLabel.textColor = [UIColor greenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.numberOfLines = 4;
    [self.panelView addSubview:self.statusLabel];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, 172, 310, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [self.panelView addSubview:line];

    UILabel *mTitle = [[UILabel alloc] initWithFrame:CGRectMake(10, 178, 310, 18)];
    mTitle.text = @"💰 MOD TIỀN CAREER MODE (NHẬP TIỀN HIỆN TẠI):";
    mTitle.textColor = [UIColor yellowColor];
    mTitle.font = [UIFont boldSystemFontOfSize:11];
    [self.panelView addSubview:mTitle];

    self.moneyInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 200, 120, 30)];
    self.moneyInput.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.moneyInput.textColor = [UIColor whiteColor];
    self.moneyInput.placeholder = @"VD: 1500";
    self.moneyInput.font = [UIFont boldSystemFontOfSize:12];
    self.moneyInput.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInput.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInput.delegate = self;
    [self.panelView addSubview:self.moneyInput];

    [self addBtn:@"Quét Tiền" frame:CGRectMake(138, 200, 86, 30) tag:10 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Lọc Tiền" frame:CGRectMake(232, 200, 88, 30) tag:11 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Sửa Tiền Thành 9,999,999$" frame:CGRectMake(10, 236, 310, 32) tag:12 action:@selector(onMoneyBtn:)];

    self.moneyStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 272, 310, 22)];
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
    if (sender.tag == 1) [self step1ScanFullTrack];
    else if (sender.tag == 2) [self step2FilterNoTrack];
    else if (sender.tag == 3) [self step2BFilterTrackAgain];
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
