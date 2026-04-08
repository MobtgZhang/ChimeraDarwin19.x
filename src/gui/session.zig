/// Mach IPC 桌面会话服务 - 提供窗口服务器与应用的通信机制
/// 定义桌面会话消息类型和处理函数

const std = @import("std");
const log = @import("../lib/log.zig");
const mach_port = @import("../kernel/mach/port.zig");
const mach_message = @import("../kernel/mach/message.zig");

/// 桌面会话消息类型
pub const DesktopSessionMsgType = enum(u32) {
    // 窗口管理
    window_create = 1,
    window_close = 2,
    window_minimize = 3,
    window_maximize = 4,
    window_restore = 5,
    window_move = 6,
    window_resize = 7,
    window_focus = 8,

    // 资源请求
    icon_load = 100,
    cursor_change = 101,
    wallpaper_change = 102,

    // 事件通知
    mouse_event = 200,
    keyboard_event = 201,
    window_redraw = 202,

    // 会话管理
    session_register = 300,
    session_unregister = 301,
    session_info = 302,
};

/// 窗口创建请求
pub const WindowCreateRequest = struct {
    msg_type: u32,
    title: [64]u8,
    title_len: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    content_type: u32,
};

/// 窗口事件通知
pub const WindowEventNotify = struct {
    msg_type: u32,
    window_id: u16,
    event_type: u32,
};

/// 图标加载请求
pub const IconLoadRequest = struct {
    msg_type: u32,
    icon_category: u32,  // 0=dock, 1=menu, 2=window, 3=status
    icon_name: [32]u8,
    preferred_size: u32,
};

/// 光标更改请求
pub const CursorChangeRequest = struct {
    msg_type: u32,
    cursor_type: u32,
};

/// 桌面会话信息
pub const DesktopSessionInfo = struct {
    session_id: u32,
    port_name: u32,
    window_count: u32,
    desktop_width: u32,
    desktop_height: u32,
};

/// 桌面会话状态
pub const DesktopSessionState = enum(u8) {
    unregistered = 0,
    registered = 1,
    active = 2,
    suspended = 3,
};

/// 桌面会话
pub const DesktopSession = struct {
    session_id: u32,
    port: mach_port.Port,
    state: DesktopSessionState,
    window_count: u32,
    desktop_width: u32,
    desktop_height: u32,

    pub fn init(id: u32) DesktopSession {
        return DesktopSession{
            .session_id = id,
            .port = mach_port.Port.init(0, .send),
            .state = .unregistered,
            .window_count = 0,
            .desktop_width = 800,
            .desktop_height = 600,
        };
    }
};

/// 全局桌面会话管理器
pub const SessionManager = struct {
    sessions: [16]DesktopSession,
    session_count: u32,
    next_session_id: u32,
    desktop_port: u32,
    desktop_width: u32,
    desktop_height: u32,

    pub fn init() SessionManager {
        var manager = SessionManager{
            .sessions = undefined,
            .session_count = 0,
            .next_session_id = 1,
            .desktop_port = 0,
            .desktop_width = 800,
            .desktop_height = 600,
        };
        for (&manager.sessions) |*s| {
            s.* = DesktopSession.init(0);
        }
        return manager;
    }
};

var global_session_manager: SessionManager = undefined;
var session_manager_initialized: bool = false;

/// 初始化会话管理器
pub fn init() void {
    if (!session_manager_initialized) {
        global_session_manager = SessionManager.init();
        session_manager_initialized = true;
        log.info("[SESSION] Desktop session manager initialized", .{});
    }
}

/// 注册新会话
pub fn registerSession() ?u32 {
    if (!session_manager_initialized) init();

    if (global_session_manager.session_count >= 16) {
        log.warn("[SESSION] Maximum sessions reached", .{});
        return null;
    }

    const session_id = global_session_manager.next_session_id;
    global_session_manager.next_session_id +%= 1;

    for (&global_session_manager.sessions) |*s| {
        if (s.state == .unregistered) {
            s.session_id = session_id;
            s.state = .registered;
            global_session_manager.session_count +%= 1;
            log.info("[SESSION] New session registered: {}", .{session_id});
            return session_id;
        }
    }

    return null;
}

/// 注销会话
pub fn unregisterSession(session_id: u32) bool {
    if (!session_manager_initialized) return false;

    for (&global_session_manager.sessions) |*s| {
        if (s.session_id == session_id and s.state != .unregistered) {
            s.state = .unregistered;
            global_session_manager.session_count -%= 1;
            log.info("[SESSION] Session unregistered: {}", .{session_id});
            return true;
        }
    }
    return false;
}

/// 获取会话信息
pub fn getSessionInfo(session_id: u32) ?DesktopSessionInfo {
    if (!session_manager_initialized) return null;

    for (&global_session_manager.sessions) |*s| {
        if (s.session_id == session_id and s.state != .unregistered) {
            return DesktopSessionInfo{
                .session_id = s.session_id,
                .port_name = s.port.name,
                .window_count = s.window_count,
                .desktop_width = s.desktop_width,
                .desktop_height = s.desktop_height,
            };
        }
    }
    return null;
}

/// 设置桌面尺寸
pub fn setDesktopSize(width: u32, height: u32) void {
    if (!session_manager_initialized) init();
    global_session_manager.desktop_width = width;
    global_session_manager.desktop_height = height;
    log.info("[SESSION] Desktop size set to {}x{}", .{ width, height });
}

/// 获取桌面尺寸
pub fn getDesktopSize() struct { width: u32, height: u32 } {
    if (!session_manager_initialized) init();
    return .{
        .width = global_session_manager.desktop_width,
        .height = global_session_manager.desktop_height,
    };
}

/// 处理桌面会话消息
pub fn handleSessionMessage(msg: *const mach_message.MsgHeader) bool {
    const msg_type = @as(DesktopSessionMsgType, @enumFromInt(msg.id));

    switch (msg_type) {
        .window_create => {
            // 处理窗口创建请求
            log.debug("[SESSION] Window create request", .{});
            return true;
        },
        .window_close => {
            log.debug("[SESSION] Window close request", .{});
            return true;
        },
        .window_focus => {
            log.debug("[SESSION] Window focus request", .{});
            return true;
        },
        .icon_load => {
            log.debug("[SESSION] Icon load request", .{});
            return true;
        },
        .cursor_change => {
            log.debug("[SESSION] Cursor change request", .{});
            return true;
        },
        .wallpaper_change => {
            log.debug("[SESSION] Wallpaper change request", .{});
            return true;
        },
        .session_info => {
            log.debug("[SESSION] Session info request", .{});
            return true;
        },
        else => {
            log.warn("[SESSION] Unknown message type: {}", .{@intFromEnum(msg_type)});
            return false;
        },
    }
}

/// 发送窗口创建消息
pub fn sendWindowCreate(session_id: u32, title: []const u8, x: i32, y: i32, w: u32, h: u32) bool {
    if (!session_manager_initialized) return false;

    var request = WindowCreateRequest{
        .msg_type = @intFromEnum(DesktopSessionMsgType.window_create),
        .title = undefined,
        .title_len = @intCast(@min(title.len, 63)),
        .x = x,
        .y = y,
        .width = w,
        .height = h,
        .content_type = 0,
    };
    @memcpy(request.title[0..request.title_len], title[0..request.title_len]);

    // TODO: 通过Mach消息发送
    log.debug("[SESSION] Sending window create for session {}", .{session_id});
    return true;
}

/// 获取活动会话数量
pub fn getActiveSessionCount() u32 {
    if (!session_manager_initialized) return 0;
    return global_session_manager.session_count;
}
