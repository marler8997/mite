const GlyphIndexCache = @This();
const std = @import("std");

pub const Half = enum(u2) { single, wide_left, wide_right };

pub const Key = packed struct(u23) {
    codepoint: u21,
    half: Half,
};

const Node = struct {
    prev: ?u32,
    next: ?u32,
    key: ?Key,
};

map: std.AutoHashMapUnmanaged(Key, u32) = .{},
nodes: []Node,
front: u32,
back: u32,

pub fn init(allocator: std.mem.Allocator, capacity: u32) error{OutOfMemory}!GlyphIndexCache {
    var result: GlyphIndexCache = .{
        .map = .{},
        .nodes = try allocator.alloc(Node, capacity),
        .front = undefined,
        .back = undefined,
    };
    result.clearRetainingCapacity();
    return result;
}

pub fn clearRetainingCapacity(self: *GlyphIndexCache) void {
    self.map.clearRetainingCapacity();
    self.nodes[0] = .{ .prev = null, .next = 1, .key = null };
    self.nodes[self.nodes.len - 1] = .{ .prev = @intCast(self.nodes.len - 2), .next = null, .key = null };
    for (self.nodes[1 .. self.nodes.len - 1], 1..) |*node, index| {
        node.* = .{
            .prev = @intCast(index - 1),
            .next = @intCast(index + 1),
            .key = null,
        };
    }
    self.front = 0;
    self.back = @intCast(self.nodes.len - 1);
}

pub fn deinit(self: *GlyphIndexCache, allocator: std.mem.Allocator) void {
    allocator.free(self.nodes);
    self.map.deinit(allocator);
}

const Reserved = struct {
    index: u32,
    replaced: ?Key,
};
pub fn reserve(self: *GlyphIndexCache, allocator: std.mem.Allocator, key: Key) error{OutOfMemory}!union(enum) {
    newly_reserved: Reserved,
    already_reserved: u32,
} {
    {
        const entry = try self.map.getOrPut(allocator, key);
        if (entry.found_existing) {
            self.moveToBack(entry.value_ptr.*);
            return .{ .already_reserved = entry.value_ptr.* };
        }
        entry.value_ptr.* = self.front;
    }

    std.debug.assert(self.nodes[self.front].prev == null);
    std.debug.assert(self.nodes[self.front].next != null);
    const replaced = self.nodes[self.front].key;
    self.nodes[self.front].key = key;
    if (replaced) |r| {
        const removed = self.map.remove(r);
        std.debug.assert(removed);
    }
    const save_front = self.front;
    self.moveToBack(self.front);
    return .{ .newly_reserved = .{ .index = save_front, .replaced = replaced } };
}

fn moveToBack(self: *GlyphIndexCache, index: u32) void {
    if (index == self.back) return;

    const node = &self.nodes[index];
    if (node.prev) |prev| {
        self.nodes[prev].next = node.next;
    } else {
        self.front = node.next.?;
    }

    if (node.next) |next| {
        self.nodes[next].prev = node.prev;
    }

    self.nodes[self.back].next = index;
    node.prev = self.back;
    node.next = null;
    self.back = index;
}
