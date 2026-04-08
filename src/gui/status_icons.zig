/// 状态栏图标系统 - 渲染WiFi、电池、音量等状态图标
/// 支持动态更新和动画效果

const std = @import("std");
const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const resources = @import("resources/mod.zig");
const texture_cache = resources.texture_cache;
const log = @import("../lib/log.zig");
const Color = color_mod.Color;
const theme = color_mod.theme;

/// 状态图标类型
pub const StatusIconType = enum(u8) {
    wifi = 0,
    battery = 1,
    volume = 2,
    clock = 3,
    notification = 4,
};

/// WiFi信号强度
pub const WifiStrength = enum(u8) {
    none = 0,
    weak = 1,
    medium = 2,
    full = 3,
};

/// 电池状态
pub const BatteryState = enum(u8) {
    full = 0,
    half = 1,
    low = 2,
    critical = 3,
    charging = 4,
};

/// 音量状态
pub const VolumeState = enum(u8) {
    muted = 0,
    low = 1,
    medium = 2,
    high = 3,
};

/// 状态图标渲染器
pub const StatusIconRenderer = struct {
    wifi_icon: ?texture_cache.Texture,
    battery_icon: ?texture_cache.Texture,
    volume_icon: ?texture_cache.Texture,
    clock_icon: ?texture_cache.Texture,

    // 状态
    wifi_strength: WifiStrength,
    battery_state: BatteryState,
    battery_percent: u8,
    volume_state: VolumeState,

    // 动画
    notification_pulse: u8,
    charging_blink: bool,

    pub fn init() StatusIconRenderer {
        return StatusIconRenderer{
            .wifi_icon = null,
            .battery_icon = null,
            .volume_icon = null,
            .clock_icon = null,
            .wifi_strength = .full,
            .battery_state = .full,
            .battery_percent = 100,
            .volume_state = .medium,
            .notification_pulse = 0,
            .charging_blink = false,
        };
    }

    /// 加载所有状态图标
    pub fn loadIcons(self: *StatusIconRenderer) void {
        self.wifi_icon = texture_cache.loadStatusIcon("wifi");
        self.battery_icon = texture_cache.loadStatusIcon("battery");
        self.volume_icon = texture_cache.loadStatusIcon("volume");
        self.clock_icon = texture_cache.loadStatusIcon("clock");

        log.info("[STATUS] Loading status icons from assets", .{});
    }

    /// 渲染所有状态图标
    pub fn render(self: *StatusIconRenderer, start_x: i32, y: i32) i32 {
        var x = start_x;

        // WiFi
        x = renderWifi(self, x, y);

        // 间距
        x += 8;

        // 电池
        x = renderBattery(self, x, y);

        // 间距
        x += 8;

        // 音量
        x = renderVolume(self, x, y);

        // 间距
        x += 8;

        // 时钟（右侧）
        _ = renderClock(self, x, y);

        return x;
    }

    /// 渲染WiFi图标
    fn renderWifi(self: *StatusIconRenderer, x: i32, y: i32) i32 {
        // 绘制WiFi弧形
        const icon_color: Color = switch (self.wifi_strength) {
            .none => theme.text_secondary,
            .weak => theme.btn_minimize,
            .medium => theme.btn_minimize,
            .full => theme.text_primary,
        };

        const cx = x + 12;
        const base_y = y + 16;

        // 绘制3个弧形
        if (@intFromEnum(self.wifi_strength) >= 1) {
            graphics.drawArc(cx, base_y, 8, icon_color, 45);
        }
        if (@intFromEnum(self.wifi_strength) >= 2) {
            graphics.drawArc(cx, base_y, 6, icon_color, 45);
        }
        if (@intFromEnum(self.wifi_strength) >= 3) {
            graphics.drawArc(cx, base_y, 4, icon_color, 45);
        }

        return x + 24;
    }

    /// 渲染电池图标
    fn renderBattery(self: *StatusIconRenderer, x: i32, y: i32) i32 {
        const icon_color: Color = switch (self.battery_state) {
            .full, .charging => theme.btn_maximize,
            .half => theme.btn_minimize,
            .low => theme.btn_minimize,
            .critical => color_mod.rgb(255, 80, 80),
        };

        // 电池外壳
        const bx = x + 4;
        const by = y + 6;
        const bw: u32 = 20;
        const bh: u32 = 10;

        graphics.drawRect(bx, by, bw, bh, icon_color);

        // 电池尖
        graphics.fillRect(bx + @as(i32, @intCast(bw)), by + 3, 2, 4, icon_color);

        // 电量填充
        const fill_width: u32 = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.battery_percent)) * 0.18));
        if (fill_width > 0) {
            graphics.fillRect(bx + 1, by + 1, fill_width, bh - 2, icon_color);
        }

        // 充电指示（闪烁效果）
        if (self.battery_state == .charging and self.charging_blink) {
            graphics.fillRect(bx + 1, by + 1, 4, bh - 2, theme.white);
        }

        return x + 28;
    }

    /// 渲染音量图标
    fn renderVolume(self: *StatusIconRenderer, x: i32, y: i32) i32 {
        const icon_color: Color = switch (self.volume_state) {
            .muted => theme.text_secondary,
            else => theme.text_primary,
        };

        const cx = x + 12;
        const cy = y + 12;

        // 绘制扬声器形状
        graphics.drawVLine(cx, cy - 4, 8, icon_color);
        graphics.drawVLine(cx + 1, cy - 3, 6, icon_color);
        graphics.drawVLine(cx + 2, cy - 2, 4, icon_color);

        // 声音波浪（根据音量状态）
        if (self.volume_state != .muted) {
            if (@as(u8, @intFromEnum(self.volume_state)) >= 1) {
                graphics.drawArc(cx + 6, cy, 2, icon_color, 45);
            }
            if (@as(u8, @intFromEnum(self.volume_state)) >= 2) {
                graphics.drawArc(cx + 8, cy, 3, icon_color, 45);
            }
            if (@as(u8, @intFromEnum(self.volume_state)) >= 3) {
                graphics.drawArc(cx + 10, cy, 4, icon_color, 45);
            }
        }

        return x + 24;
    }

    /// 渲染时钟
    fn renderClock(self: *StatusIconRenderer, x: i32, y: i32) i32 {
        // 绘制简单的时钟图标
        const cx = x + 8;
        const cy = y + 8;
        const r: u32 = 6;

        // 圆圈
        graphics.fillCircle(cx, cy, r, theme.text_primary);

        // 时针和分针（简化绘制）
        graphics.drawVLine(cx, cy, 2, theme.menubar_bg);
        graphics.drawVLine(cx, cy, 3, theme.menubar_bg);

        _ = self;
        return x + 16;
    }

    /// 更新动画状态
    pub fn updateAnimation(self: *StatusIconRenderer) void {
        // 通知脉冲
        if (self.notification_pulse > 0) {
            self.notification_pulse -|= 1;
        }

        // 充电闪烁（每30帧切换）
        self.charging_blink = !self.charging_blink;
    }

    /// 设置WiFi信号强度
    pub fn setWifiStrength(self: *StatusIconRenderer, strength: WifiStrength) void {
        self.wifi_strength = strength;
    }

    /// 设置电池状态
    pub fn setBatteryState(self: *StatusIconRenderer, state: BatteryState, percent: u8) void {
        self.battery_state = state;
        self.battery_percent = percent;
    }

    /// 设置音量状态
    pub fn setVolumeState(self: *StatusIconRenderer, state: VolumeState) void {
        self.volume_state = state;
    }
};

/// 全局状态图标渲染器
var global_renderer: StatusIconRenderer = undefined;
var status_initialized: bool = false;

/// 初始化状态图标系统
pub fn init() void {
    if (!status_initialized) {
        global_renderer = StatusIconRenderer.init();
        global_renderer.loadIcons();
        status_initialized = true;
        log.info("[STATUS] Status icons system initialized", .{});
    }
}

/// 渲染状态图标到指定位置
pub fn renderStatusIcons(start_x: i32, y: i32) void {
    if (!status_initialized) {
        init();
    }
    _ = global_renderer.render(start_x, y);
}

/// 更新WiFi信号
pub fn setWifiStrength(strength: WifiStrength) void {
    if (!status_initialized) init();
    global_renderer.setWifiStrength(strength);
}

/// 更新电池状态
pub fn setBattery(state: BatteryState, percent: u8) void {
    if (!status_initialized) init();
    global_renderer.setBatteryState(state, percent);
}

/// 更新音量状态
pub fn setVolume(state: VolumeState) void {
    if (!status_initialized) init();
    global_renderer.setVolumeState(state);
}

/// 更新动画
pub fn updateAnimation() void {
    if (!status_initialized) return;
    global_renderer.updateAnimation();
}

/// 触发通知动画
pub fn triggerNotification() void {
    if (!status_initialized) init();
    global_renderer.notification_pulse = 60;
}

/// 获取渲染器
pub fn getRenderer() *StatusIconRenderer {
    if (!status_initialized) init();
    return &global_renderer;
}
