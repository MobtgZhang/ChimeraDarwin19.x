/// GUI event types and event queue.
/// Bridges hardware input (keyboard, mouse) with the desktop compositor.

pub const EventType = enum {
    key_press,
    key_release,
    mouse_move,
    mouse_press,
    mouse_release,
    mouse_click,
    window_close,
    window_focus,
    timer_tick,
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

pub const Event = struct {
    kind: EventType,
    // Key fields
    scancode: u8 = 0,
    ascii: u8 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    // Mouse fields
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_dx: i16 = 0,
    mouse_dy: i16 = 0,
    button: MouseButton = .left,
    // Target
    window_id: u16 = 0,
    // Tick
    tick: u64 = 0,
};

const QUEUE_SIZE = 128;

var queue: [QUEUE_SIZE]Event = undefined;
var q_head: usize = 0;
var q_tail: usize = 0;

pub fn push(ev: Event) void {
    const next = (q_tail + 1) % QUEUE_SIZE;
    if (next == q_head) return; // full, drop event
    queue[q_tail] = ev;
    q_tail = next;
}

pub fn pop() ?Event {
    if (q_head == q_tail) return null;
    const ev = queue[q_head];
    q_head = (q_head + 1) % QUEUE_SIZE;
    return ev;
}

pub fn isEmpty() bool {
    return q_head == q_tail;
}

pub fn clear() void {
    q_head = 0;
    q_tail = 0;
}
