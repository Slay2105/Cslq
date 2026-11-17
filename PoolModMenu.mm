#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <vector>
#import <algorithm>

struct TrackByteItem {
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
@property (nonatomic, assign) int forceMode; // 0: Giữ nguyên onVal, 1: Ép = 1, 2: Ép = 2 (TrackAll)
@end

@implementation VP4NativeModView {
    std::vector<TrackByteItem> _candidates;
    std::vector<TrackByteItem> _lockedAddrs;
    std::vector<vm_address_t> _moneyAddrs;
    intptr_t _slide;
    vm_address_t _dataStart, _dataEnd;
    int _scanStep;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.lockNativeTrack = NO;
        self.forceMode = 0;
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
                    if (strcmp(seg->segname, "__DATA") == 0) {
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
        uint8_t val = item.onVal;
        if (self.forceMode == 1) val = 1;
        else if (self.forceMode == 2) val = 2;
        vm_write(task, item.addr, (vm_offset_t)&val, sizeof(uint8_t));
    }
}

#pragma mark - Quét Từng Byte Chuẩn Xác (Bắt cả Bool 1-byte và Enum TrackAll = 2, AimLine = 1, NoAim = 0)

- (void)step1ScanFullTrack {
    _candidates.clear();
    mach_port_t task = mach_task_self();

    // 1. Quét toàn bộ phân vùng __DATA + __BSS của Binary trước tiên (đưa lên đầu danh sách)
    if (_dataStart != 0 && _dataEnd > _dataStart) {
        vm_size_t dSize = _dataEnd - _dataStart;
        std::vector<uint8_t> buf(dSize);
        vm_size_t out = 0;
        if (vm_read_overwrite(task, _dataStart, dSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
            for (vm_size_t i = 0; i < out; i++) {
                uint8_t v = buf[i];
                if (v >= 1 && v <= 4) {
                    _candidates.push_back({_dataStart + i, v});
                }
            }
        }
    }

    // 2. Quét thêm vùng nhớ Heap chứa đối tượng cwTrackSettings / CareerPlay
    vm_address_t addr = 0;
    vm_size_t size = 0;
    while (_candidates.size() < 600000) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS) break;

        BOOL rw = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        if (rw && size <= 16 * 1024 * 1024 && (addr < _dataStart || addr >= _dataEnd)) {
            const vm_size_t chunk = 65536;
            std::vector<uint8_t> buf(chunk);
            for (vm_size_t off = 0; off < size; off += chunk) {
                vm_size_t rSize = MIN(chunk, size - off);
                vm_size_t out = 0;
                if (vm_read_overwrite(task, addr + off, rSize, (vm_address_t)buf.data(), &out) == KERN_SUCCESS) {
                    for (vm_size_t i = 0; i < out; i++) {
                        uint8_t v = buf[i];
                        if (v >= 1 && v <= 4) {
                            _candidates.push_back({addr + off + i, v});
                            if (_candidates.size() >= 600000) break;
                        }
                    }
                }
                if (_candidates.size() >= 600000) break;
            }
        }
        addr += size;
    }

    _scanStep = 1;
    self.statusLabel.text = [NSString stringWithFormat:@"✅ B1 XONG (%lu biến).\nGiờ vào trận mất tia (hoặc tắt Track trong Menu game) rồi bấm [B2: Lọc Mất Tia]!", (unsigned long)_candidates.size()];
}

// Bước 2: Bắt cả trường hợp về 0 (No AimAids) HOẶC giảm từ 2 xuống 1 (từ TrackAll về AimLine ngắn)
- (void)step2FilterNoTrack {
    if (_scanStep < 1 || _candidates.empty()) {
        self.statusLabel.text = @"⚠️ Hãy bấm [B1: Quét Có Tia] ở màn có đủ tia trước!";
        return;
    }

    std::vector<TrackByteItem> filtered;
    mach_port_t task = mach_task_self();
    for (const auto &item : _candidates) {
        uint8_t cur = 255;
        vm_size_t out = 0;
        if (vm_read_overwrite(task, item.addr, sizeof(uint8_t), (vm_address_t)&cur, &out) == KERN_SUCCESS) {
            // Chấp nhận cur == 0 HOẶC cur < onVal (ví dụ TrackAll=2 giảm xuống AimLine=1)
            if (cur < item.onVal) {
                filtered.push_back(item);
            }
        }
    }

    _candidates = filtered;
    _scanStep = 2;
    self.statusLabel.text = [NSString stringWithFormat:@"🎯 B2 XONG: Còn %lu biến (đã tính cả AimLine=1).\nQuay lại bàn CÓ TIA bấm [B2B] để lọc chuẩn!", (unsigned long)_candidates.size()];
}

- (void)step2BFilterTrackAgain {
    if (_candidates.empty()) return;

    std::vector<TrackByteItem> filtered;
    mach_port_t task = mach_task_self();
    for (const auto &item : _candidates) {
        uint8_t cur = 0;
        vm_size_t out = 0;
        if (vm_read_overwrite(task, item.addr, sizeof(uint8_t), (vm_address_t)&cur, &out) == KERN_SUCCESS) {
            if (cur == item.onVal) {
                filtered.push_back(item);
            }
        }
    }

    _candidates = filtered;

    // Đếm xem có bao nhiêu biến nằm thẳng trong vùng __DATA gốc của game
    int inDataSeg = 0;
    for (const auto &item : _candidates) {
        if (item.addr >= _dataStart && item.addr < _dataEnd) inDataSeg++;
    }

    self.statusLabel.text = [NSString stringWithFormat:@"🔥 B2B XONG: Còn %lu biến (Trong __DATA: %d biến)!\nBấm [BƯỚC 3: KHÓA TIA 3D] ngay!", (unsigned long)_candidates.size(), inDataSeg];
}

- (void)step3ToggleLock:(UIButton *)btn {
    if (!self.lockNativeTrack) {
        if (_scanStep < 2) {
            self.statusLabel.text = @"❌ Bạn phải lọc qua Bước 2 trước khi Khóa!";
            return;
        }
        _lockedAddrs.clear();
        size_t limit = std::min(_candidates.size(), (size_t)2500);
        for (size_t i = 0; i < limit; i++) {
            _lockedAddrs.push_back(_candidates[i]);
        }
        self.lockNativeTrack = YES;
        [btn setTitle:@"BƯỚC 3: ĐANG KHÓA BẬT TIA 3D (ON)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.35 alpha:0.95];

        uint64_t off = (_lockedAddrs.empty()) ? 0 : (uint64_t)(_lockedAddrs[0].addr - _slide);
        self.statusLabel.text = [NSString stringWithFormat:@"🔒 Đang khóa %lu biến (Offset đầu: 0x%llX).\nNếu chưa hiện tia đỏ, bấm thử nút [Ép Kiểu: Auto / 1 / 2] bên dưới!", (unsigned long)_lockedAddrs.size(), off];
    } else {
        self.lockNativeTrack = NO;
        [btn setTitle:@"BƯỚC 3: KHÓA BẬT TIA 3D (OFF)" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.95];
        self.statusLabel.text = @"Đã tắt khóa tia 3D.";
    }
}

- (void)cycleForceMode:(UIButton *)btn {
    self.forceMode = (self.forceMode + 1) % 3;
    if (self.forceMode == 0) [btn setTitle:@"Ép Kiểu: Gốc (Auto)" forState:UIControlStateNormal];
    else if (self.forceMode == 1) [btn setTitle:@"Ép Kiểu: Giá trị = 1" forState:UIControlStateNormal];
    else [btn setTitle:@"Ép Kiểu: TrackAll = 2" forState:UIControlStateNormal];
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

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(80, 20, 330, 315)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.layer.borderColor = [UIColor cyanColor].CGColor;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 330, 30)];
    title.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.70 alpha:0.35];
    title.text = @"  VP4 - MỞ KHÓA TIA 3D GỐC (TrackAll v3)";
    title.textColor = [UIColor cyanColor];
    title.font = [UIFont boldSystemFontOfSize:12];
    title.userInteractionEnabled = YES;
    UIPanGestureRecognizer *panMenu = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [self.panelView addGestureRecognizer:panMenu];
    [self.panelView addSubview:title];

    [self addBtn:@"B1: Quét Có Tia" frame:CGRectMake(10, 36, 100, 30) tag:1 action:@selector(onTrackBtn:)];
    [self addBtn:@"B2: Lọc Mất Tia" frame:CGRectMake(115, 36, 100, 30) tag:2 action:@selector(onTrackBtn:)];
    [self addBtn:@"B2B: Lọc Có Lại" frame:CGRectMake(220, 36, 100, 30) tag:3 action:@selector(onTrackBtn:)];

    [self addBtn:@"BƯỚC 3: KHÓA BẬT TIA 3D (OFF)"
           frame:CGRectMake(10, 72, 205, 32)
             tag:4
          action:@selector(step3ToggleLock:)];

    [self addBtn:@"Ép Kiểu: Gốc (Auto)"
           frame:CGRectMake(220, 72, 100, 32)
             tag:5
          action:@selector(cycleForceMode:)];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 108, 310, 56)];
    self.statusLabel.text = @"💡 MẸO QUÉT CHUẨN TRONG 1 BÀN: Vào Quick Play (đang có tia đỏ) bấm [B1] -> Vào Menu game tắt Tracking bấm [B2] -> Bật lại Tracking bấm [B2B] -> Bấm [BƯỚC 3] rồi vào Career!";
    self.statusLabel.textColor = [UIColor greenColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.numberOfLines = 4;
    [self.panelView addSubview:self.statusLabel];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, 168, 310, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [self.panelView addSubview:line];

    UILabel *mTitle = [[UILabel alloc] initWithFrame:CGRectMake(10, 174, 310, 18)];
    mTitle.text = @"💰 MOD TIỀN CAREER MODE (NHẬP TIỀN HIỆN TẠI):";
    mTitle.textColor = [UIColor yellowColor];
    mTitle.font = [UIFont boldSystemFontOfSize:11];
    [self.panelView addSubview:mTitle];

    self.moneyInput = [[UITextField alloc] initWithFrame:CGRectMake(10, 196, 120, 30)];
    self.moneyInput.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.moneyInput.textColor = [UIColor whiteColor];
    self.moneyInput.placeholder = @"VD: 1500";
    self.moneyInput.font = [UIFont boldSystemFontOfSize:12];
    self.moneyInput.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInput.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInput.delegate = self;
    [self.panelView addSubview:self.moneyInput];

    [self addBtn:@"Quét Tiền" frame:CGRectMake(138, 196, 86, 30) tag:10 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Lọc Tiền" frame:CGRectMake(232, 196, 88, 30) tag:11 action:@selector(onMoneyBtn:)];
    [self addBtn:@"Sửa Tiền Thành 9,999,999$" frame:CGRectMake(10, 232, 310, 32) tag:12 action:@selector(onMoneyBtn:)];

    self.moneyStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 268, 310, 22)];
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
