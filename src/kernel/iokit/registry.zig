/// IORegistry — a tree of device objects modelled after Apple's I/O Kit.
/// Each node carries a class name, a set of properties (key-value pairs),
/// and links to parent/children.  Drivers match against property predicates
/// to attach themselves to the appropriate hardware.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const MAX_NODES: usize = 256;
pub const MAX_PROPERTIES: usize = 16;
pub const MAX_KEY_LEN: usize = 32;
pub const MAX_VAL_LEN: usize = 64;
pub const MAX_PATH_LEN: usize = 256;

pub const Property = struct {
    key: [MAX_KEY_LEN]u8,
    key_len: usize,
    value: [MAX_VAL_LEN]u8,
    value_len: usize,
    int_value: u64,
    is_int: bool,
    active: bool,
};

pub const IORegNode = struct {
    id: u32,
    class_name: [64]u8,
    class_name_len: usize,
    name: [64]u8,
    name_len: usize,
    properties: [MAX_PROPERTIES]Property,
    prop_count: usize,
    parent: ?*IORegNode,
    first_child: ?*IORegNode,
    next_sibling: ?*IORegNode,
    busy_state: u32,
    active: bool,

    pub fn getClassName(self: *const IORegNode) []const u8 {
        return self.class_name[0..self.class_name_len];
    }

    pub fn getName(self: *const IORegNode) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setProperty(self: *IORegNode, key: []const u8, value: []const u8) bool {
        for (&self.properties) |*p| {
            if (!p.active) continue;
            if (strEql(p.key[0..p.key_len], key)) {
                const vlen = @min(value.len, MAX_VAL_LEN);
                @memcpy(p.value[0..vlen], value[0..vlen]);
                p.value_len = vlen;
                p.is_int = false;
                return true;
            }
        }
        if (self.prop_count >= MAX_PROPERTIES) return false;
        for (&self.properties) |*p| {
            if (p.active) continue;
            const klen = @min(key.len, MAX_KEY_LEN);
            const vlen = @min(value.len, MAX_VAL_LEN);
            @memcpy(p.key[0..klen], key[0..klen]);
            p.key_len = klen;
            @memcpy(p.value[0..vlen], value[0..vlen]);
            p.value_len = vlen;
            p.is_int = false;
            p.int_value = 0;
            p.active = true;
            self.prop_count += 1;
            return true;
        }
        return false;
    }

    pub fn setPropertyInt(self: *IORegNode, key: []const u8, value: u64) bool {
        for (&self.properties) |*p| {
            if (!p.active) continue;
            if (strEql(p.key[0..p.key_len], key)) {
                p.int_value = value;
                p.is_int = true;
                p.value_len = 0;
                return true;
            }
        }
        if (self.prop_count >= MAX_PROPERTIES) return false;
        for (&self.properties) |*p| {
            if (p.active) continue;
            const klen = @min(key.len, MAX_KEY_LEN);
            @memcpy(p.key[0..klen], key[0..klen]);
            p.key_len = klen;
            p.int_value = value;
            p.is_int = true;
            p.value_len = 0;
            p.active = true;
            self.prop_count += 1;
            return true;
        }
        return false;
    }

    pub fn getProperty(self: *const IORegNode, key: []const u8) ?*const Property {
        for (&self.properties) |*p| {
            if (!p.active) continue;
            if (strEql(p.key[0..p.key_len], key)) return p;
        }
        return null;
    }

    pub fn getPropertyInt(self: *const IORegNode, key: []const u8) ?u64 {
        const prop = self.getProperty(key) orelse return null;
        if (prop.is_int) return prop.int_value;
        return null;
    }

    pub fn addChild(self: *IORegNode, child: *IORegNode) void {
        child.parent = self;
        child.next_sibling = self.first_child;
        self.first_child = child;
    }

    pub fn getPath(self: *const IORegNode, buf: []u8) usize {
        var pos: usize = 0;
        var node: ?*const IORegNode = self;

        while (node) |n| {
            const name = n.getName();
            if (pos + name.len + 1 > buf.len) break;

            if (pos > 0 and pos < buf.len) {
                buf[pos] = ':';
                pos += 1;
            }

            @memcpy(buf[pos..][0..name.len], name);
            pos += name.len;

            node = n.parent;
        }

        return pos;
    }
};

var nodes: [MAX_NODES]IORegNode = undefined;
var node_count: usize = 0;
var root: ?*IORegNode = null;
var lock: SpinLock = .{};

pub fn init() void {
    node_count = 0;
    root = allocNode("IORegistryEntry", "Root");
    if (root) |r| {
        _ = r.setProperty("IOProviderClass", "IOResources");
    }
    log.info("IORegistry initialized (root node created)", .{});
}

pub fn getRoot() ?*IORegNode {
    return root;
}

pub fn allocNode(class_name: []const u8, name: []const u8) ?*IORegNode {
    lock.acquire();
    defer lock.release();

    if (node_count >= MAX_NODES) return null;
    var n = &nodes[node_count];
    n.* = .{
        .id = @intCast(node_count),
        .class_name = [_]u8{0} ** 64,
        .class_name_len = @min(class_name.len, 64),
        .name = [_]u8{0} ** 64,
        .name_len = @min(name.len, 64),
        .properties = undefined,
        .prop_count = 0,
        .parent = null,
        .first_child = null,
        .next_sibling = null,
        .busy_state = 0,
        .active = true,
    };
    @memcpy(n.class_name[0..n.class_name_len], class_name[0..n.class_name_len]);
    @memcpy(n.name[0..n.name_len], name[0..n.name_len]);
    for (&n.properties) |*p| p.active = false;
    node_count += 1;
    return n;
}

pub fn findByClass(class: []const u8) ?*IORegNode {
    for (0..node_count) |i| {
        if (!nodes[i].active) continue;
        if (strEql(nodes[i].class_name[0..nodes[i].class_name_len], class))
            return &nodes[i];
    }
    return null;
}

pub fn findByProperty(key: []const u8, value: []const u8) ?*IORegNode {
    for (0..node_count) |i| {
        if (!nodes[i].active) continue;
        if (nodes[i].getProperty(key)) |p| {
            if (!p.is_int and strEql(p.value[0..p.value_len], value))
                return &nodes[i];
        }
    }
    return null;
}

pub fn fromPath(path: []const u8) ?*IORegNode {
    _ = path;
    return root;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}
