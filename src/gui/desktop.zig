/// 桌面合成器 - GUI系统的核心入口
/// 协调壁纸、窗口管理器、菜单栏、Dock和输入路由
/// 集成了增强的光标系统、壁纸加载、状态栏图标和Mach IPC会话

const std = @import("std");
const builtin = @import("builtin");
const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const pixel_format = @import("../lib/pixel_format.zig");
const menubar = @import("menubar.zig");
const dock = @import("dock.zig");
const window = @import("window.zig");
const cursor = @import("cursor.zig");
const event_mod = @import("event.zig");
const widgets = @import("widgets.zig");
const font = @import("font.zig");
const status_icons = @import("status_icons.zig");
const wallpaper_loader = @import("resources/wallpaper_loader.zig");
const session = @import("session.zig");
const resources = @import("resources/mod.zig");
const Color = color_mod.Color;
const theme = color_mod.theme;

const KERNEL_VERSION = "0.3.0";

var initialized: bool = false;
var frame_count: u64 = 0;
var needs_redraw: bool = true;
var current_arch_label: []const u8 = "unknown";

/// 快速轮询鼠标位置
var fast_mouse_x: i32 = 400;
var fast_mouse_y: i32 = 300;
var fast_mouse_dirty: bool = false;

/// 壁纸设置
var wallpaper_name: [32]u8 = undefined;
var wallpaper_name_len: usize = 0;

/// 启用双缓冲
pub fn enableDoubleBuffer(back_buf: [*]u32) void {
    graphics.enableDoubleBuffer(back_buf);
}

/// 桌面初始化
pub fn init(fb_base: [*]volatile u32, w: u32, h: u32, stride: u32, fmt: pixel_format.FramebufferPixelFormat, arch_label: []const u8) void {
    current_arch_label = arch_label;
    graphics.init(fb_base, w, h, stride, fmt);

    // 初始化各个子系统
    cursor.init();
    wallpaper_loader.init();
    session.init();

    menubar.init();
    dock.init();
    window.init();
    widgets.init();

    // 设置壁纸
    const default_wallpaper = "cyberpunk";
    wallpaper_name_len = default_wallpaper.len;
    @memcpy(wallpaper_name[0..wallpaper_name_len], default_wallpaper[0..wallpaper_name_len]);
    _ = wallpaper_loader.loadWallpaper(default_wallpaper);

    // 创建默认窗口
    if (window.createWindow("About ChimeraOS", @intCast(w / 2 - 200), @intCast(h / 2 - 140), 400, 280, .about_dialog)) |_| {}

    if (window.createWindow("System Info", 60, 80, 380, 260, .text_view)) |id| {
        var sys_buf: [1900]u8 = undefined;
        const sys_text = std.fmt.bufPrint(&sys_buf,
            \\ChimeraOS Z-Kernel v{s}
            \\
            \\Architecture: {s}
            \\Kernel: XNU-style Hybrid
            \\  - Mach IPC subsystem
            \\  - BSD POSIX layer
            \\  - IOKit driver framework
            \\
            \\{s}
        , .{ KERNEL_VERSION, arch_label, driversListForArch() }) catch "ChimeraOS Z-Kernel";
        window.setWindowText(id, sys_text);
    }

    initialized = true;
    needs_redraw = true;

    // 注册桌面会话
    _ = session.registerSession();
    session.setDesktopSize(w, h);
}

// ── 主渲染循环 ─────────────────────────────────────

/// 渲染桌面
pub fn render() void {
    if (!initialized) return;

    // 渲染壁纸
    wallpaper_loader.render();

    // 渲染窗口
    window.renderAll();

    // 渲染菜单栏
    menubar.render();

    // 渲染Dock
    dock.render();
}

/// 绘制光标
pub fn drawCursor(mx: i32, my: i32) void {
    if (!initialized) return;
    cursor.draw(mx, my);
}

/// 交换缓冲区
pub fn presentFrame() void {
    if (!initialized) return;
    graphics.swapBuffers();
}

/// 快速更新鼠标位置
pub fn updateFastMousePosition(x: i32, y: i32) void {
    fast_mouse_x = x;
    fast_mouse_y = y;
    fast_mouse_dirty = true;

    // 更新Dock鼠标位置
    dock.updateMousePosition(x, y);

    // 更新窗口按钮悬停状态
    window.updateButtonHover(x, y);
}

/// 获取快速鼠标位置
pub fn getFastMousePosition() struct { x: i32, y: i32 } {
    return .{ .x = fast_mouse_x, .y = fast_mouse_y };
}

/// 检查鼠标位置是否有更新
pub fn isMouseDirty() bool {
    return fast_mouse_dirty;
}

/// 清除鼠标脏标记
pub fn clearMouseDirty() void {
    fast_mouse_dirty = false;
}

// ── 输入处理 ───────────────────────────────────────

/// 鼠标移动处理
pub fn handleMouseMove(mx: i32, my: i32) void {
    // 更新Dock悬停
    dock.updateHover(mx, my);

    // 更新窗口按钮悬停
    window.updateButtonHover(mx, my);

    // 窗口拖拽
    if (window.isDragging()) {
        window.updateDrag(mx, my);
        needs_redraw = true;
    }

    // 更新光标类型
    updateCursorForContext(mx, my);

    // 鼠标移动总是标记需要重绘
    needs_redraw = true;
}

/// 根据悬停上下文更新光标类型
fn updateCursorForContext(mx: i32, my: i32) void {
    // 检查菜单栏
    if (menubar.isInMenuBar(my)) {
        cursor.setCursorType(.arrow);
        return;
    }

    // 检查Dock
    if (dock.isInDock(my)) {
        if (dock.hitTest(mx, my)) |_| {
            cursor.setCursorType(.hand);
        } else {
            cursor.setCursorType(.arrow);
        }
        return;
    }

    // 检查窗口
    if (window.hitTest(mx, my)) |hit| {
        switch (hit.hit) {
            .close_btn => cursor.setCursorType(.hand),
            .minimize_btn => cursor.setCursorType(.hand),
            .maximize_btn => cursor.setCursorType(.hand),
            .title_bar => cursor.setCursorType(.resize_ns),
            .content => cursor.setCursorType(.arrow),
            .none => cursor.setCursorType(.arrow),
        }
        return;
    }

    cursor.setCursorType(.arrow);
}

/// 鼠标按下处理
pub fn handleMouseDown(mx: i32, my: i32) void {
    // 检查菜单栏
    if (menubar.isInMenuBar(my)) {
        return;
    }

    // 检查Dock
    if (dock.hitTest(mx, my)) |idx| {
        handleDockClick(idx);
        return;
    }

    // 检查窗口
    if (window.hitTest(mx, my)) |hit| {
        switch (hit.hit) {
            .close_btn => {
                window.closeWindow(hit.id);
                needs_redraw = true;
            },
            .minimize_btn => {
                window.minimizeWindow(hit.id);
                needs_redraw = true;
            },
            .maximize_btn => {},
            .title_bar => {
                window.focusWindow(hit.id);
                window.beginDrag(hit.id, mx, my);
                needs_redraw = true;
            },
            .content => {
                window.focusWindow(hit.id);
                needs_redraw = true;
            },
            .none => {},
        }
        return;
    }
}

/// 鼠标释放处理
pub fn handleMouseUp(_: i32, _: i32) void {
    if (window.isDragging()) {
        window.endDrag();
        needs_redraw = true;
    }
}

/// 键盘按下处理
pub fn handleKeyPress(ascii: u8) void {
    _ = ascii;
    needs_redraw = true;
}

/// 处理Dock点击
fn handleDockClick(idx: usize) void {
    const label = dock.getItemLabel(idx) orelse return;
    dock.setRunning(idx, true);
    dock.bounceItem(idx);

    if (strEql(label, "Finder")) {
        if (window.createWindow("Finder", 120, 100, 440, 320, .file_manager)) |_| {}
        menubar.setActiveApp("Finder");
    } else if (strEql(label, "Terminal")) {
        if (window.createWindow("Terminal", 200, 140, 500, 320, .terminal)) |id| {
            var term_buf: [512]u8 = undefined;
            const term_text = std.fmt.bufPrint(&term_buf,
                \\ChimeraOS Terminal
                \\$ uname -a
                \\ChimeraOS {s} {s} Z-Kernel
                \\$ whoami
                \\root
                \\$ ls /dev
                \\null  zero  console
                \\$ 
            , .{ KERNEL_VERSION, current_arch_label }) catch "ChimeraOS Terminal\n$ uname -a\nChimeraOS Z-Kernel\n$ ";
            window.setWindowText(id, term_text);
        }
        menubar.setActiveApp("Terminal");
    } else if (strEql(label, "Settings")) {
        if (window.createWindow("System Preferences", 180, 100, 460, 340, .text_view)) |id| {
            var pref_buf: [900]u8 = undefined;
            const pref_text = std.fmt.bufPrint(&pref_buf,
                \\General
                \\  Appearance: Dark
                \\  Accent Color: Blue
                \\
                \\Display
                \\  Resolution: auto
                \\  Refresh: 60 Hz
                \\
                \\Sound
                \\  {s}
                \\
                \\Network
                \\  Status: Not Connected
                \\
                \\Storage
                \\  {s}
                \\
                \\About
                \\  ChimeraOS v{s}
                \\  {s}
                \\  Zig Z-Kernel
            , .{
                settingsSoundLine(),
                settingsStorageLine(),
                KERNEL_VERSION,
                current_arch_label,
            }) catch "System Preferences";
            window.setWindowText(id, pref_text);
        }
        menubar.setActiveApp("System Preferences");
    } else if (strEql(label, "TextEdit")) {
        if (window.createWindow("Untitled - TextEdit", 240, 120, 420, 300, .text_view)) |id| {
            window.setWindowText(id, "Welcome to ChimeraOS!\n\nThis is a simple desktop OS\nwritten entirely in Zig.\n\nIt features:\n- XNU-style hybrid kernel\n- Mach IPC messaging\n- BSD POSIX syscalls\n- IOKit driver framework\n- macOS-like desktop UI");
        }
        menubar.setActiveApp("TextEdit");
    } else if (strEql(label, "About")) {
        if (window.createWindow("About ChimeraOS", @intCast(graphics.screenWidth() / 2 - 200), @intCast(graphics.screenHeight() / 2 - 140), 400, 280, .about_dialog)) |_| {}
    }

    needs_redraw = true;
}

/// 更新时钟
pub fn updateClock(hour: u8, minute: u8) void {
    menubar.updateClock(hour, minute);
}

/// 每帧更新（用于动画）
pub fn tick() void {
    frame_count +%= 1;

    // 更新动画
    window.updateAnimations();
    dock.updateAnimations();
    menubar.updateAnimation();
    status_icons.updateAnimation();
}

/// 检查是否需要重绘
pub fn needsRedraw() bool {
    if (!initialized) return false;
    return needs_redraw;
}

/// 清除重绘标记
pub fn clearRedrawFlag() void {
    needs_redraw = false;
}

/// 请求重绘
pub fn requestRedraw() void {
    needs_redraw = true;
}

fn driversListForArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 =>
        \\Drivers loaded:
        \\  PS/2 Keyboard, PS/2 Mouse
        \\  PIT Timer, CMOS RTC
        \\  GOP Framebuffer
        \\  ATA/IDE, AC97 Audio
        \\  PCIe Bus Scanner
        ,
        .aarch64 =>
        \\Drivers loaded:
        \\  PL011 UART (early console)
        \\  GICv2, ARM Generic Timer (stub)
        \\  GOP Framebuffer
        \\  Virtio input / USB HID (stub)
        ,
        .riscv64 =>
        \\Drivers loaded:
        \\  16550 UART (early console)
        \\  PLIC, SBI timer (stub)
        \\  GOP Framebuffer
        \\  Virtio input (stub)
        ,
        .loongarch64 =>
        \\Drivers loaded:
        \\  UART (early console)
        \\  CPU interrupt / timer (stub)
        \\  GOP Framebuffer (UEFI)
        \\  USB HID via Virtio (stub)
        ,
        else =>
        \\Drivers loaded:
        \\  (platform drivers in development)
        ,
    };
}

fn settingsSoundLine() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "Output: AC97  Volume: 80%",
        else => "Output: (not available on this architecture)",
    };
}

fn settingsStorageLine() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "Primary: ATA/IDE (PIO)",
        else => "Primary: (platform storage TBD)",
    };
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}

/// 设置壁纸
pub fn setWallpaper(name: []const u8) void {
    if (wallpaper_loader.loadWallpaper(name)) {
        wallpaper_name_len = @min(name.len, 31);
        @memcpy(wallpaper_name[0..wallpaper_name_len], name[0..wallpaper_name_len]);
        needs_redraw = true;
    }
}

/// 获取当前壁纸名称
pub fn getWallpaperName() []const u8 {
    return wallpaper_name[0..wallpaper_name_len];
}
