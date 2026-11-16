#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <vector>
#import <cmath>

@interface PoolModOverlay : UIView <UITextFieldDelegate>
// Layers vẽ đồ họa
@property (nonatomic, strong) CAShapeLayer *tableLayer;
@property (nonatomic, strong) CAShapeLayer *pocketsLayer;
@property (nonatomic, strong) CAShapeLayer *aimLineLayer;
@property (nonatomic, strong) CAShapeLayer *targetLineLayer;
@property (nonatomic, strong) CAShapeLayer *tangentLineLayer;
@property (nonatomic, strong) CAShapeLayer *bankLineLayer;
@property (nonatomic, strong) CAShapeLayer *ghostBallLayer;

// Các nút kéo trên bàn
@property (nonatomic, strong) UIView *cueBallHandle;
@property (nonatomic, strong) UIView *objBallHandle;
@property (nonatomic, strong) UIView *bankTargetHandle;
@property (nonatomic, strong) UIView *tableTLHandle;
@property (nonatomic, strong) UIView *tableBRHandle;

// Giao diện Menu & Icon nổi
@property (nonatomic, strong) UIButton *floatingIcon;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *angleInfoLabel;
@property (nonatomic, strong) UILabel *memStatusLabel;
@property (nonatomic, strong) UITextField *moneyInputField;

// Trạng thái tính năng
@property (nonatomic, assign) BOOL aimEnabled;
@property (nonatomic, assign) BOOL autoPocketEnabled;
@property (nonatomic, assign) BOOL bankModeEnabled;
@property (nonatomic, assign) BOOL tangentEnabled;
@property (nonatomic, assign) BOOL calibrateTableMode;
@property (nonatomic, assign) int selectedPocketIndex; // -1: Auto, 0..5: 6 lỗ
@property (nonatomic, assign) CGFloat ballRadius;
@end

@implementation PoolModOverlay {
    std::vector<vm_address_t> _scanResults;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.aimEnabled = YES;
        self.autoPocketEnabled = YES;
        self.bankModeEnabled = NO;
        self.tangentEnabled = YES;
        self.calibrateTableMode = NO;
        self.selectedPocketIndex = -1;
        self.ballRadius = 13.0;

        [self setupDrawingLayers];
        [self setupTableAndBallHandles];
        [self setupFloatingIconAndMenu];
        [self redrawAllTrajectories];
    }
    return self;
}

// Cho phép chạm xuyên qua vùng trống để vuốt cơ bình thường trong game
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        return nil;
    }
    return hit;
}

#pragma mark - Khởi tạo Lớp Vẽ (CAShapeLayer)

- (CAShapeLayer *)makeLayerWithColor:(UIColor *)color width:(CGFloat)width dashed:(BOOL)dashed {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.strokeColor = color.CGColor;
    layer.fillColor = [UIColor clearColor].CGColor;
    layer.lineWidth = width;
    if (dashed) {
        layer.lineDashPattern = @[@6, @4];
    }
    [self.layer addSublayer:layer];
    return layer;
}

- (void)setupDrawingLayers {
    self.tableLayer   = [self makeLayerWithColor:[UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:0.4] width:1.2 dashed:YES];
    self.pocketsLayer = [self makeLayerWithColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.75] width:2.0 dashed:NO];
    self.aimLineLayer = [self makeLayerWithColor:[UIColor whiteColor] width:1.6 dashed:NO];
    self.targetLineLayer  = [self makeLayerWithColor:[UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:0.95] width:2.0 dashed:NO];
    self.tangentLineLayer = [self makeLayerWithColor:[UIColor colorWithRed:1.0 green:0.9 blue:0.0 alpha:0.75] width:1.3 dashed:YES];
    self.bankLineLayer    = [self makeLayerWithColor:[UIColor colorWithRed:0.0 green:0.9 blue:1.0 alpha:0.9] width:1.6 dashed:YES];
    self.ghostBallLayer   = [self makeLayerWithColor:[UIColor colorWithRed:0.0 green:1.0 blue:0.9 alpha:0.95] width:1.8 dashed:NO];
}

#pragma mark - Nút Kéo Tâm Bi & Khung Bàn

- (UIView *)createDraggablePointWithColor:(UIColor *)color size:(CGFloat)size center:(CGPoint)center title:(NSString *)title {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    v.center = center;
    v.backgroundColor = [color colorWithAlphaComponent:0.20];
    v.layer.cornerRadius = size / 2.0;
    v.layer.borderColor = color.CGColor;
    v.layer.borderWidth = 1.6;

    // Tâm chấm nhỏ ở chính giữa để đặt chuẩn vào giữa viên bi
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake((size - 4)/2.0, (size - 4)/2.0, 4, 4)];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 2.0;
    dot.userInteractionEnabled = NO;
    [v addSubview:dot];

    if (title.length > 0) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(-10, -14, size + 20, 12)];
        lbl.text = title;
        lbl.font = [UIFont boldSystemFontOfSize:9];
        lbl.textColor = color;
        lbl.textAlignment = NSTextAlignmentCenter;
        [v addSubview:lbl];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHandlePan:)];
    [v addGestureRecognizer:pan];
    [self addSubview:v];
    return v;
}

- (void)setupTableAndBallHandles {
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < H) { CGFloat tmp = W; W = H; H = tmp; } // Ưu tiên màn ngang

    // 2 Góc khung bàn (Trái-Trên & Phải-Dưới)
    self.tableTLHandle = [self createDraggablePointWithColor:[UIColor cyanColor] size:26 center:CGPointMake(W * 0.14, H * 0.16) title:@"TL"];
    self.tableBRHandle = [self createDraggablePointWithColor:[UIColor cyanColor] size:26 center:CGPointMake(W * 0.86, H * 0.82) title:@"BR"];
    self.tableTLHandle.hidden = YES;
    self.tableBRHandle.hidden = YES;

    // Tâm Bi Cái (Trắng), Tâm Bi Mục Tiêu (Vàng), Điểm Đập Băng (Xanh)
    self.cueBallHandle    = [self createDraggablePointWithColor:[UIColor whiteColor] size:34 center:CGPointMake(W * 0.32, H * 0.52) title:@"CÁI"];
    self.objBallHandle    = [self createDraggablePointWithColor:[UIColor yellowColor] size:34 center:CGPointMake(W * 0.58, H * 0.45) title:@"MỤC TIÊU"];
    self.bankTargetHandle = [self createDraggablePointWithColor:[UIColor cyanColor] size:30 center:CGPointMake(W * 0.50, H * 0.20) title:@"BĂNG"];
    self.bankTargetHandle.hidden = YES;
}

- (void)onHandlePan:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    UIView *v = pan.view;
    v.center = CGPointMake(v.center.x + delta.x, v.center.y + delta.y);
    [pan setTranslation:CGPointZero inView:self];
    [self redrawAllTrajectories];
}

#pragma mark - Thuật Toán Hình Học (Auto Ghost Ball, 6 Lỗ, Góc Tách 90, Phản Xạ Băng)

- (CGRect)currentTableRect {
    CGFloat minX = MIN(self.tableTLHandle.center.x, self.tableBRHandle.center.x);
    CGFloat maxX = MAX(self.tableTLHandle.center.x, self.tableBRHandle.center.x);
    CGFloat minY = MIN(self.tableTLHandle.center.y, self.tableBRHandle.center.y);
    CGFloat maxY = MAX(self.tableTLHandle.center.y, self.tableBRHandle.center.y);
    return CGRectMake(minX, minY, MAX(40, maxX - minX), MAX(40, maxY - minY));
}

- (void)getSixPockets:(CGPoint *)pockets fromRect:(CGRect)r {
    pockets[0] = CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r)); // Lỗ 1: Trái Trên
    pockets[1] = CGPointMake(CGRectGetMidX(r), CGRectGetMinY(r)); // Lỗ 2: Giữa Trên
    pockets[2] = CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r)); // Lỗ 3: Phải Trên
    pockets[3] = CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r)); // Lỗ 4: Trái Dưới
    pockets[4] = CGPointMake(CGRectGetMidX(r), CGRectGetMaxY(r)); // Lỗ 5: Giữa Dưới
    pockets[5] = CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)); // Lỗ 6: Phải Dưới
}

- (void)redrawAllTrajectories {
    if (!self.aimEnabled) return;

    CGRect tableRect = [self currentTableRect];
    CGPoint pockets[6];
    [self getSixPockets:pockets fromRect:tableRect];

    // 1. Vẽ khung bàn & 6 lỗ
    UIBezierPath *tPath = [UIBezierPath bezierPathWithRect:tableRect];
    self.tableLayer.path = tPath.CGPath;
    self.tableLayer.hidden = !self.calibrateTableMode;

    UIBezierPath *pPath = [UIBezierPath bezierPath];
    for (int i = 0; i < 6; i++) {
        [pPath appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(pockets[i].x - 8, pockets[i].y - 8, 16, 16)]];
    }
    self.pocketsLayer.path = pPath.CGPath;

    CGPoint P_cue = self.cueBallHandle.center;
    CGPoint P_obj = self.objBallHandle.center;
    CGFloat R = self.ballRadius;

    // 2. Tìm lỗ tối ưu (Auto-Pocket) hoặc lỗ chỉ định
    int bestPocket = self.selectedPocketIndex;
    CGFloat bestCutDeg = 180.0;
    CGPoint bestGhost = P_obj;

    for (int i = 0; i < 6; i++) {
        if (self.selectedPocketIndex != -1 && self.selectedPocketIndex != i) continue;

        CGFloat dx = pockets[i].x - P_obj.x;
        CGFloat dy = pockets[i].y - P_obj.y;
        CGFloat len = hypot(dx, dy);
        if (len < 1.0) continue;

        CGFloat ux = dx / len;
        CGFloat uy = dy / len;

        // Tâm Ghost Ball chuẩn xác lùi 2R từ tâm Bi Mục Tiêu ngược hướng lỗ
        CGPoint ghost = CGPointMake(P_obj.x - 2.0 * R * ux, P_obj.y - 2.0 * R * uy);

        // Vector từ Bi Cái -> Ghost Ball
        CGFloat sx = ghost.x - P_cue.x;
        CGFloat sy = ghost.y - P_cue.y;
        CGFloat sLen = hypot(sx, sy);
        if (sLen < 1.0) continue;

        // Góc chẻ bi (Cut Angle)
        CGFloat dot = (sx / sLen) * ux + (sy / sLen) * uy;
        dot = fmax(-1.0, fmin(1.0, dot));
        CGFloat deg = acos(dot) * (180.0 / M_PI);

        if (deg < bestCutDeg) {
            bestCutDeg = deg;
            bestPocket = i;
            bestGhost = ghost;
        }
    }

    if (bestPocket < 0 || bestPocket > 5) bestPocket = 0;
    CGPoint P_pocket = pockets[bestPocket];

    // 3. Vẽ Tia Bi Cái -> Ghost Ball & Vòng tròn Ghost Ball
    UIBezierPath *aimPath = [UIBezierPath bezierPath];
    [aimPath moveToPoint:P_cue];
    [aimPath addLineToPoint:bestGhost];
    self.aimLineLayer.path = aimPath.CGPath;

    // Đổi màu cảnh báo nếu góc chẻ > 78 độ (quá mỏng/bị che)
    if (bestCutDeg <= 78.0) {
        self.aimLineLayer.strokeColor = [UIColor whiteColor].CGColor;
        self.targetLineLayer.strokeColor = [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:0.95].CGColor;
    } else {
        self.aimLineLayer.strokeColor = [UIColor redColor].CGColor;
        self.targetLineLayer.strokeColor = [UIColor orangeColor].CGColor;
    }

    UIBezierPath *ghostPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(bestGhost.x - R, bestGhost.y - R, R * 2.0, R * 2.0)];
    self.ghostBallLayer.path = ghostPath.CGPath;

    // 4. Vẽ Tia Ăn Bi (Bi Mục Tiêu -> Tâm Lỗ)
    UIBezierPath *targetPath = [UIBezierPath bezierPath];
    [targetPath moveToPoint:P_obj];
    [targetPath addLineToPoint:P_pocket];
    self.targetLineLayer.path = targetPath.CGPath;

    // 5. Vẽ Tia Tách Bi Cái 90 độ sau va chạm (Tránh chết cái vào lỗ)
    UIBezierPath *tanPath = [UIBezierPath bezierPath];
    if (self.tangentEnabled) {
        CGFloat ix = P_obj.x - bestGhost.x;
        CGFloat iy = P_obj.y - bestGhost.y;
        CGFloat iLen = hypot(ix, iy);
        if (iLen > 0.1) {
            ix /= iLen; iy /= iLen;
            // Vector vuông góc với phương va chạm
            CGFloat tx = -iy;
            CGFloat ty = ix;
            CGFloat sx = bestGhost.x - P_cue.x;
            CGFloat sy = bestGhost.y - P_cue.y;
            if (sx * tx + sy * ty < 0) { tx = -tx; ty = -ty; }
            [tanPath moveToPoint:bestGhost];
            [tanPath addLineToPoint:CGPointMake(bestGhost.x + tx * 220.0, bestGhost.y + ty * 220.0)];
        }
    }
    self.tangentLineLayer.path = tanPath.CGPath;

    // 6. Vẽ Tia Đập Băng Phản Xạ (2 Cushions) nếu bật chế độ Băng
    UIBezierPath *bankPath = [UIBezierPath bezierPath];
    if (self.bankModeEnabled) {
        CGPoint curPos = P_cue;
        CGFloat dx = self.bankTargetHandle.center.x - P_cue.x;
        CGFloat dy = self.bankTargetHandle.center.y - P_cue.y;
        CGFloat dLen = hypot(dx, dy);
        if (dLen > 1.0) {
            dx /= dLen; dy /= dLen;
            [bankPath moveToPoint:curPos];

            CGRect inner = CGRectInset(tableRect, R, R);
            for (int bounce = 0; bounce < 3; bounce++) {
                CGFloat tMin = 99999.0;
                int hitWall = 0; // 1:Left/Right, 2:Top/Bottom

                if (fabs(dx) > 1e-4) {
                    CGFloat tx1 = (CGRectGetMinX(inner) - curPos.x) / dx;
                    CGFloat tx2 = (CGRectGetMaxX(inner) - curPos.x) / dx;
                    if (tx1 > 1.0 && tx1 < tMin) { tMin = tx1; hitWall = 1; }
                    if (tx2 > 1.0 && tx2 < tMin) { tMin = tx2; hitWall = 1; }
                }
                if (fabs(dy) > 1e-4) {
                    CGFloat ty1 = (CGRectGetMinY(inner) - curPos.y) / dy;
                    CGFloat ty2 = (CGRectGetMaxY(inner) - curPos.y) / dy;
                    if (ty1 > 1.0 && ty1 < tMin) { tMin = ty1; hitWall = 2; }
                    if (ty2 > 1.0 && ty2 < tMin) { tMin = ty2; hitWall = 2; }
                }
                if (hitWall == 0 || tMin > 5000.0) break;

                curPos = CGPointMake(curPos.x + dx * tMin, curPos.y + dy * tMin);
                [bankPath addLineToPoint:curPos];
                if (hitWall == 1) dx = -dx;
                if (hitWall == 2) dy = -dy;
            }
        }
    }
    self.bankLineLayer.path = bankPath.CGPath;

    // Cập nhật thông số góc chẻ trên Menu
    self.angleInfoLabel.text = [NSString stringWithFormat:@"Lỗ đích: #%d | Góc chẻ: %.1f° (%@)",
                                bestPocket + 1, bestCutDeg, (bestCutDeg <= 78.0 ? @"KHẢ THI" : @"QUÁ MỎNG")];
}

#pragma mark - Công Cụ Quét & Mod Tiền Trực Tiếp Trong RAM (Mach VM + NSUserDefaults)

- (void)scanMemoryForValue:(int32_t)targetVal isFirstScan:(BOOL)firstScan {
    if (firstScan) {
        _scanResults.clear();
        vm_address_t address = 0;
        vm_size_t size = 0;
        mach_port_t task = mach_task_self();

        while (true) {
            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t object_name = MACH_PORT_NULL;

            kern_return_t kr = vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64,
                                            (vm_region_info_t)&info, &count, &object_name);
            if (kr != KERN_SUCCESS) break;

            // Chỉ quét các vùng nhớ cho phép Đọc + Ghi (RW) và không bị khóa
            BOOL isWritable = (info.protection & VM_PROT_WRITE) && (info.protection & VM_PROT_READ);
            if (isWritable && size <= 64 * 1024 * 1024) {
                const vm_size_t chunkLimit = 65536;
                std::vector<uint8_t> buffer(chunkLimit);

                for (vm_size_t offset = 0; offset < size; offset += chunkLimit) {
                    vm_size_t readSize = MIN(chunkLimit, size - offset);
                    vm_size_t outSize = 0;
                    if (vm_read_overwrite(task, address + offset, readSize, (vm_address_t)buffer.data(), &outSize) == KERN_SUCCESS) {
                        for (vm_size_t i = 0; i + sizeof(int32_t) <= outSize; i += 4) {
                            int32_t val = *(int32_t *)(buffer.data() + i);
                            if (val == targetVal) {
                                _scanResults.push_back(address + offset + i);
                                if (_scanResults.size() >= 150000) break;
                            }
                        }
                    }
                    if (_scanResults.size() >= 150000) break;
                }
            }
            address += size;
            if (_scanResults.size() >= 150000) break;
        }
    } else {
        std::vector<vm_address_t> filtered;
        mach_port_t task = mach_task_self();
        for (vm_address_t addr : _scanResults) {
            int32_t currentVal = 0;
            vm_size_t outSize = 0;
            if (vm_read_overwrite(task, addr, sizeof(int32_t), (vm_address_t)&currentVal, &outSize) == KERN_SUCCESS) {
                if (currentVal == targetVal) {
                    filtered.push_back(addr);
                }
            }
        }
        _scanResults = filtered;
    }

    self.memStatusLabel.text = [NSString stringWithFormat:@"Tìm thấy: %lu địa chỉ khớp giá trị %d", (unsigned long)_scanResults.size(), targetVal];
}

- (void)writeNewMoneyValue:(int32_t)newVal {
    mach_port_t task = mach_task_self();
    int modifiedCount = 0;
    for (vm_address_t addr : _scanResults) {
        if (vm_write(task, addr, (vm_offset_t)&newVal, sizeof(int32_t)) == KERN_SUCCESS) {
            modifiedCount++;
        }
    }

    // Đồng thời kiểm tra & cập nhật các khóa tiền phổ biến trong NSUserDefaults nếu có
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict = [defs dictionaryRepresentation];
    for (NSString *key in dict.allKeys) {
        NSString *lower = [key lowercaseString];
        if ([lower containsString:@"cash"] || [lower containsString:@"money"] ||
            [lower containsString:@"coin"] || [lower containsString:@"bankroll"] ||
            [lower containsString:@"funds"]) {
            [defs setInteger:newVal forKey:key];
        }
    }
    [defs synchronize];

    self.memStatusLabel.text = [NSString stringWithFormat:@"Đã ghi %d vào %d địa chỉ RAM & Plist!", newVal, modifiedCount];
}

#pragma mark - Giao Diện Floating Icon & Bảng Menu Điều Khiển

- (void)setupFloatingIconAndMenu {
    // 1. Nút Icon nổi (Kéo thả được)
    self.floatingIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingIcon.frame = CGRectMake(25, 45, 48, 48);
    self.floatingIcon.backgroundColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.20 alpha:0.92];
    self.floatingIcon.layer.cornerRadius = 24;
    self.floatingIcon.layer.borderWidth = 2.0;
    self.floatingIcon.layer.borderColor = [UIColor cyanColor].CGColor;
    [self.floatingIcon setTitle:@"🎱" forState:UIControlStateNormal];
    self.floatingIcon.titleLabel.font = [UIFont systemFontOfSize:24];
    [self.floatingIcon addTarget:self action:@selector(toggleMenuPanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *iconPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHandlePan:)];
    [self.floatingIcon addGestureRecognizer:iconPan];
    [self addSubview:self.floatingIcon];

    // 2. Bảng Menu chính
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake(85, 30, 320, 310)];
    self.menuPanel.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.94];
    self.menuPanel.layer.cornerRadius = 14;
    self.menuPanel.layer.borderColor = [UIColor cyanColor].CGColor;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.hidden = YES;
    [self addSubview:self.menuPanel];

    // Tiêu đề kéo thả được bảng Menu
    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 34)];
    header.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.65 alpha:0.4];
    header.text = @"  VIRTUAL POOL 4 - PRO MOD MENU";
    header.textColor = [UIColor cyanColor];
    header.font = [UIFont boldSystemFontOfSize:13];
    header.userInteractionEnabled = YES;
    UIPanGestureRecognizer *menuPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHandlePan:)];
    [self.menuPanel addGestureRecognizer:menuPan];
    [self.menuPanel addSubview:header];

    // Thông số góc chẻ tự động
    self.angleInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 38, 296, 18)];
    self.angleInfoLabel.textColor = [UIColor greenColor];
    self.angleInfoLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.menuPanel addSubview:self.angleInfoLabel];

    // Hàng nút bật/tắt nhanh
    [self createMenuButton:@"Line: BẬT" frame:CGRectMake(12, 60, 92, 30) tag:101 action:@selector(onFeatureBtn:)];
    [self createMenuButton:@"Băng: TẮT" frame:CGRectMake(114, 60, 92, 30) tag:102 action:@selector(onFeatureBtn:)];
    [self createMenuButton:@"Căn Bàn" frame:CGRectMake(216, 60, 92, 30) tag:103 action:@selector(onFeatureBtn:)];

    // Chọn lỗ đích (Auto hoặc Lỗ 1..6)
    UILabel *pLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 96, 80, 24)];
    pLbl.text = @"Khóa Lỗ:";
    pLbl.textColor = [UIColor whiteColor];
    pLbl.font = [UIFont systemFontOfSize:11];
    [self.menuPanel addSubview:pLbl];

    NSArray *pTitles = @[@"AUTO", @"1", @"2", @"3", @"4", @"5", @"6"];
    for (int i = 0; i < 7; i++) {
        UIButton *b = [self createMenuButton:pTitles[i]
                                       frame:CGRectMake(72 + i * 34, 96, 31, 24)
                                         tag:200 + i
                                      action:@selector(onPocketSelect:)];
        if (i == 0) b.backgroundColor = [UIColor colorWithRed:0.0 green:0.6 blue:0.4 alpha:0.8];
    }

    // Thanh trượt chỉnh kích thước vòng Ghost Ball khớp với độ zoom của bàn
    UILabel *rLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 126, 95, 24)];
    rLbl.text = @"Cỡ Bi (2R):";
    rLbl.textColor = [UIColor whiteColor];
    rLbl.font = [UIFont systemFontOfSize:11];
    [self.menuPanel addSubview:rLbl];

    UISlider *rSlider = [[UISlider alloc] initWithFrame:CGRectMake(95, 126, 210, 24)];
    rSlider.minimumValue = 6.0;
    rSlider.maximumValue = 28.0;
    rSlider.value = 13.0;
    [rSlider addTarget:self action:@selector(onRadiusChanged:) forControlEvents:UIControlEventValueChanged];
    [self.menuPanel addSubview:rSlider];

    // Khu vực Mod Tiền (RAM Scanner & Editor)
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(12, 158, 296, 1)];
    div.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [self.menuPanel addSubview:div];

    UILabel *mTitle = [[UILabel alloc] initWithFrame:CGRectMake(12, 164, 296, 18)];
    mTitle.text = @"💰 MOD TIỀN TRỰC TIẾP (NHẬP SỐ TIỀN HIỆN TẠI):";
    mTitle.textColor = [UIColor yellowColor];
    mTitle.font = [UIFont boldSystemFontOfSize:11];
    [self.menuPanel addSubview:mTitle];

    self.moneyInputField = [[UITextField alloc] initWithFrame:CGRectMake(12, 186, 135, 30)];
    self.moneyInputField.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    self.moneyInputField.textColor = [UIColor whiteColor];
    self.moneyInputField.font = [UIFont boldSystemFontOfSize:13];
    self.moneyInputField.placeholder = @"VD: 500";
    self.moneyInputField.keyboardType = UIKeyboardTypeNumberPad;
    self.moneyInputField.borderStyle = UITextBorderStyleRoundedRect;
    self.moneyInputField.delegate = self;
    [self.menuPanel addSubview:self.moneyInputField];

    [self createMenuButton:@"1. Quét Mới" frame:CGRectMake(155, 186, 74, 30) tag:301 action:@selector(onMoneyAction:)];
    [self createMenuButton:@"2. Lọc Lại" frame:CGRectMake(235, 186, 73, 30) tag:302 action:@selector(onMoneyAction:)];

    [self createMenuButton:@"3. Sửa Tiền -> 9,999,999$"
                     frame:CGRectMake(12, 224, 296, 32)
                       tag:303
                    action:@selector(onMoneyAction:)];

    self.memStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 262, 296, 36)];
    self.memStatusLabel.text = @"HD: Nhập tiền hiện có -> Bấm [1. Quét Mới] -> Đấu/Mua gì đó cho tiền đổi -> Nhập số mới -> [2. Lọc] -> [3. Sửa Tiền].";
    self.memStatusLabel.textColor = [UIColor lightGrayColor];
    self.memStatusLabel.font = [UIFont systemFontOfSize:10];
    self.memStatusLabel.numberOfLines = 2;
    [self.menuPanel addSubview:self.memStatusLabel];
}

- (UIButton *)createMenuButton:(NSString *)title frame:(CGRect)frame tag:(NSInteger)tag action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.tag = tag;
    btn.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.9];
    btn.layer.cornerRadius = 6;
    btn.layer.borderColor = [UIColor colorWithWhite:0.45 alpha:1.0].CGColor;
    btn.layer.borderWidth = 1.0;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:btn];
    return btn;
}

#pragma mark - Xử Lý Sự Kiện Nút Bấm

- (void)toggleMenuPanel {
    [self endEditing:YES];
    self.menuPanel.hidden = !self.menuPanel.hidden;
}

- (void)onFeatureBtn:(UIButton *)sender {
    if (sender.tag == 101) {
        self.aimEnabled = !self.aimEnabled;
        [sender setTitle:(self.aimEnabled ? @"Line: BẬT" : @"Line: TẮT") forState:UIControlStateNormal];
        self.aimLineLayer.hidden = !self.aimEnabled;
        self.targetLineLayer.hidden = !self.aimEnabled;
        self.tangentLineLayer.hidden = !self.aimEnabled;
        self.ghostBallLayer.hidden = !self.aimEnabled;
        self.pocketsLayer.hidden = !self.aimEnabled;
        self.cueBallHandle.hidden = !self.aimEnabled;
        self.objBallHandle.hidden = !self.aimEnabled;
    } else if (sender.tag == 102) {
        self.bankModeEnabled = !self.bankModeEnabled;
        [sender setTitle:(self.bankModeEnabled ? @"Băng: BẬT" : @"Băng: TẮT") forState:UIControlStateNormal];
        self.bankTargetHandle.hidden = !self.bankModeEnabled;
        self.bankLineLayer.hidden = !self.bankModeEnabled;
    } else if (sender.tag == 103) {
        self.calibrateTableMode = !self.calibrateTableMode;
        [sender setTitle:(self.calibrateTableMode ? @"Xong Bàn" : @"Căn Bàn") forState:UIControlStateNormal];
        self.tableTLHandle.hidden = !self.calibrateTableMode;
        self.tableBRHandle.hidden = !self.calibrateTableMode;
        self.tableLayer.hidden = !self.calibrateTableMode;
    }
    [self redrawAllTrajectories];
}

- (void)onPocketSelect:(UIButton *)sender {
    for (int i = 0; i < 7; i++) {
        UIButton *b = [self.menuPanel viewWithTag:200 + i];
        b.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.9];
    }
    sender.backgroundColor = [UIColor colorWithRed:0.0 green:0.6 blue:0.4 alpha:0.85];
    int idx = (int)sender.tag - 200;
    self.selectedPocketIndex = (idx == 0) ? -1 : (idx - 1);
    [self redrawAllTrajectories];
}

- (void)onRadiusChanged:(UISlider *)slider {
    self.ballRadius = slider.value;
    [self redrawAllTrajectories];
}

- (void)onMoneyAction:(UIButton *)sender {
    [self endEditing:YES];
    int32_t inputVal = (int32_t)[self.moneyInputField.text intValue];
    if (sender.tag == 301) {
        [self scanMemoryForValue:inputVal isFirstScan:YES];
    } else if (sender.tag == 302) {
        [self scanMemoryForValue:inputVal isFirstScan:NO];
    } else if (sender.tag == 303) {
        [self writeNewMoneyValue:9999999];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - Constructor Tự Động Khởi Chạy Khi Mở Game

__attribute__((constructor))
static void initializeVirtualPoolMod() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *targetWindow = nil;
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            if (win.isKeyWindow) {
                targetWindow = win;
                break;
            }
        }
        if (!targetWindow && [UIApplication sharedApplication].windows.count > 0) {
            targetWindow = [UIApplication sharedApplication].windows.firstObject;
        }
        if (targetWindow) {
            PoolModOverlay *overlay = [[PoolModOverlay alloc] initWithFrame:targetWindow.bounds];
            overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [targetWindow addSubview:overlay];
        }
    });
}
