/// Intrusive red-black tree keyed on u64.
/// Embed a `Node` in your struct and use `@fieldParentPtr` to recover the container.

pub const Color = enum(u1) { red = 0, black = 1 };

pub const Node = struct {
    key: u64 = 0,
    left: ?*Node = null,
    right: ?*Node = null,
    parent: ?*Node = null,
    color: Color = .red,
};

pub const Tree = struct {
    root: ?*Node = null,
    count: usize = 0,

    // ── Lookup ────────────────────────────────────────────────

    pub fn search(self: *const Tree, key: u64) ?*Node {
        var cur = self.root;
        while (cur) |n| {
            if (key == n.key) return n;
            cur = if (key < n.key) n.left else n.right;
        }
        return null;
    }

    /// Return the node with the largest key <= `key`.
    pub fn floorEntry(self: *const Tree, key: u64) ?*Node {
        var best: ?*Node = null;
        var cur = self.root;
        while (cur) |n| {
            if (key == n.key) return n;
            if (key > n.key) {
                best = n;
                cur = n.right;
            } else {
                cur = n.left;
            }
        }
        return best;
    }

    pub fn minimum(self: *const Tree) ?*Node {
        var n = self.root orelse return null;
        while (n.left) |l| n = l;
        return n;
    }

    pub fn maximum(self: *const Tree) ?*Node {
        var n = self.root orelse return null;
        while (n.right) |r| n = r;
        return n;
    }

    pub fn successor(node: *Node) ?*Node {
        if (node.right) |r| {
            var n = r;
            while (n.left) |l| n = l;
            return n;
        }
        var n = node;
        var p = n.parent;
        while (p) |pp| {
            if (n != pp.right) return pp;
            n = pp;
            p = pp.parent;
        }
        return null;
    }

    // ── Insertion ─────────────────────────────────────────────

    pub fn insert(self: *Tree, z: *Node) void {
        z.left = null;
        z.right = null;
        z.color = .red;

        var y: ?*Node = null;
        var x = self.root;
        while (x) |n| {
            y = n;
            x = if (z.key < n.key) n.left else n.right;
        }
        z.parent = y;

        if (y) |p| {
            if (z.key < p.key) {
                p.left = z;
            } else {
                p.right = z;
            }
        } else {
            self.root = z;
        }

        self.count += 1;
        self.insertFixup(z);
    }

    fn insertFixup(self: *Tree, node: *Node) void {
        var z = node;
        while (true) {
            const p = z.parent orelse break;
            if (p.color == .black) break;

            const gp = p.parent orelse break;
            if (p == gp.left) {
                const uncle = gp.right;
                if (uncle != null and uncle.?.color == .red) {
                    p.color = .black;
                    uncle.?.color = .black;
                    gp.color = .red;
                    z = gp;
                } else {
                    if (z == p.right) {
                        z = p;
                        self.rotateLeft(z);
                    }
                    const pp = z.parent.?;
                    pp.color = .black;
                    pp.parent.?.color = .red;
                    self.rotateRight(pp.parent.?);
                }
            } else {
                const uncle = gp.left;
                if (uncle != null and uncle.?.color == .red) {
                    p.color = .black;
                    uncle.?.color = .black;
                    gp.color = .red;
                    z = gp;
                } else {
                    if (z == p.left) {
                        z = p;
                        self.rotateRight(z);
                    }
                    const pp = z.parent.?;
                    pp.color = .black;
                    pp.parent.?.color = .red;
                    self.rotateLeft(pp.parent.?);
                }
            }
        }
        self.root.?.color = .black;
    }

    // ── Removal ───────────────────────────────────────────────

    pub fn remove(self: *Tree, z: *Node) void {
        var y = z;
        var y_orig_color = y.color;
        var x: ?*Node = null;
        var x_parent: ?*Node = null;

        if (z.left == null) {
            x = z.right;
            x_parent = z.parent;
            self.transplant(z, z.right);
        } else if (z.right == null) {
            x = z.left;
            x_parent = z.parent;
            self.transplant(z, z.left);
        } else {
            y = z.right.?;
            while (y.left) |l| y = l;
            y_orig_color = y.color;
            x = y.right;

            if (y.parent == z) {
                x_parent = y;
            } else {
                x_parent = y.parent;
                self.transplant(y, y.right);
                y.right = z.right;
                if (y.right) |r| r.parent = y;
            }
            self.transplant(z, y);
            y.left = z.left;
            if (y.left) |l| l.parent = y;
            y.color = z.color;
        }

        self.count -= 1;

        if (y_orig_color == .black) {
            self.removeFixup(x, x_parent);
        }

        z.left = null;
        z.right = null;
        z.parent = null;
    }

    fn removeFixup(self: *Tree, node: ?*Node, parent: ?*Node) void {
        var x = node;
        var p = parent;
        while (x != self.root and (x == null or x.?.color == .black)) {
            const pp = p orelse break;
            if (x == pp.left) {
                var w = pp.right orelse break;
                if (w.color == .red) {
                    w.color = .black;
                    pp.color = .red;
                    self.rotateLeft(pp);
                    w = pp.right orelse break;
                }
                const wl_black = (w.left == null or w.left.?.color == .black);
                const wr_black = (w.right == null or w.right.?.color == .black);
                if (wl_black and wr_black) {
                    w.color = .red;
                    x = pp;
                    p = pp.parent;
                } else {
                    if (wr_black) {
                        if (w.left) |wl| wl.color = .black;
                        w.color = .red;
                        self.rotateRight(w);
                        w = pp.right orelse break;
                    }
                    w.color = pp.color;
                    pp.color = .black;
                    if (w.right) |wr| wr.color = .black;
                    self.rotateLeft(pp);
                    x = self.root;
                    p = null;
                }
            } else {
                var w = pp.left orelse break;
                if (w.color == .red) {
                    w.color = .black;
                    pp.color = .red;
                    self.rotateRight(pp);
                    w = pp.left orelse break;
                }
                const wl_black = (w.left == null or w.left.?.color == .black);
                const wr_black = (w.right == null or w.right.?.color == .black);
                if (wl_black and wr_black) {
                    w.color = .red;
                    x = pp;
                    p = pp.parent;
                } else {
                    if (wl_black) {
                        if (w.right) |wr| wr.color = .black;
                        w.color = .red;
                        self.rotateLeft(w);
                        w = pp.left orelse break;
                    }
                    w.color = pp.color;
                    pp.color = .black;
                    if (w.left) |wl| wl.color = .black;
                    self.rotateRight(pp);
                    x = self.root;
                    p = null;
                }
            }
        }
        if (x) |n| n.color = .black;
    }

    // ── Rotations & helpers ───────────────────────────────────

    fn rotateLeft(self: *Tree, x: *Node) void {
        const y = x.right orelse return;
        x.right = y.left;
        if (y.left) |yl| yl.parent = x;
        y.parent = x.parent;
        if (x.parent) |p| {
            if (x == p.left) p.left = y else p.right = y;
        } else {
            self.root = y;
        }
        y.left = x;
        x.parent = y;
    }

    fn rotateRight(self: *Tree, x: *Node) void {
        const y = x.left orelse return;
        x.left = y.right;
        if (y.right) |yr| yr.parent = x;
        y.parent = x.parent;
        if (x.parent) |p| {
            if (x == p.left) p.left = y else p.right = y;
        } else {
            self.root = y;
        }
        y.right = x;
        x.parent = y;
    }

    fn transplant(self: *Tree, u: *Node, v: ?*Node) void {
        if (u.parent) |p| {
            if (u == p.left) p.left = v else p.right = v;
        } else {
            self.root = v;
        }
        if (v) |n| n.parent = u.parent;
    }
};
