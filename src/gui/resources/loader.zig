/// ChimeraDarwin19.x icon and resource loader.
/// Provides path resolution and runtime loading for PNG/SVG assets.

const std = @import("std");
const mod = @import("mod.zig");
const Color = mod.Color;

pub const ResourceLoader = struct {
    /// Get the path to an icon file (SVG or PNG).
    pub fn getIconPath(icon_type: []const u8, name: []const u8) []const u8 {
        return std.fmt.comptimePrint("assets/icons/{s}/{s}.svg", .{ icon_type, name });
    }

    /// Get the path to a cursor file.
    pub fn getCursorPath(name: []const u8) []const u8 {
        return std.fmt.comptimePrint("assets/cursors/{s}.svg", .{name});
    }

    /// Get the path to a wallpaper file.
    pub fn getWallpaperPath(name: []const u8) []const u8 {
        return std.fmt.comptimePrint("assets/wallpapers/{s}.png", .{name});
    }

    /// Resolve an icon entry to a PNG file path (with size suffix).
    /// Returns the path in the provided buffer, or null if not found.
    pub fn resolveIconPath(buf: []u8, entry: *const mod.IconEntry, preferred_size: u32) ?[]const u8 {
        if (buf.len < MAX_PATH_LEN) return null;

        const sizes = [_]u32{ 256, 128, 64, 48, 32 };

        for (sizes) |size| {
            if (size <= preferred_size) {
                const path = std.fmt.bufPrint(buf, "assets/icons/{s}/{s}_{d}.png", .{
                    entry.name, entry.name, size,
                }) catch return null;
                return path;
            }
        }

        return std.fmt.bufPrint(buf, "assets/icons/{s}/{s}.png", .{ entry.name, entry.name }) catch null;
    }
};

/// Predefined size preference list for icons (largest to smallest).
pub const icon_sizes = [_]u32{ 256, 128, 64, 48, 32 };

const MAX_PATH_LEN = 128;

/// Built-in icon resources (palette-indexed bitmaps).
pub const BuiltinResources = struct {
    /// Get a built-in icon bitmap by name. Returns null if not found.
    pub fn getIconBitmap(name: []const u8) ?[]const u8 {
        inline for (comptime std.meta.declarations(BuiltinIcons)) |decl| {
            if (std.mem.eql(u8, decl.name, name)) {
                return @field(BuiltinIcons, decl.name);
            }
        }
        return null;
    }

    /// Get a built-in wallpaper gradient by name.
    pub fn getWallpaperGradient(name: []const u8) ?WallpaperGradient {
        inline for (comptime std.meta.declarations(BuiltinWallpapers)) |decl| {
            if (std.mem.eql(u8, decl.name, name)) {
                return @field(BuiltinWallpapers, decl.name);
            }
        }
        return null;
    }
};

/// Built-in icon bitmaps (16x16 palette-indexed).
pub const BuiltinIcons = struct {
    /// Finder icon: 0=transparent, 1=primary, 2=secondary, 3=accent, 4=highlight
    pub const finder = [256]u8{
        0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0, 0,
        0, 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0,
        0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0,
        1, 3, 3, 3, 1, 1, 3, 3, 3, 1, 1, 3, 3, 3, 3, 1,
        1, 3, 3, 3, 1, 1, 3, 3, 3, 1, 1, 3, 3, 3, 3, 1,
        1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1,
        1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1,
        1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1,
        1, 3, 3, 1, 3, 3, 3, 3, 3, 3, 3, 3, 1, 3, 3, 1,
        1, 3, 3, 3, 1, 3, 3, 3, 3, 3, 3, 1, 3, 3, 3, 1,
        0, 1, 3, 3, 3, 1, 1, 1, 1, 1, 1, 3, 3, 3, 1, 0,
        0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0,
        0, 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
};

/// Wallpaper gradient descriptor.
pub const WallpaperGradient = struct {
    top: Color,
    mid: Color,
    bottom: Color,
};

/// Built-in wallpaper gradients.
pub const BuiltinWallpapers = struct {
    pub const cyberpunk = WallpaperGradient{
        .top = 0x001E0533,
        .mid = 0x003A1B6C,
        .bottom = 0x00643C96,
    };

    pub const nature = WallpaperGradient{
        .top = 0x00228B22,
        .mid = 0x004682B4,
        .bottom = 0x0087CEEB,
    };

    pub const minimal = WallpaperGradient{
        .top = 0x002D2D30,
        .mid = 0x002D2D30,
        .bottom = 0x002D2D30,
    };

    pub const abstract_wallpaper = WallpaperGradient{
        .top = 0x00FF5757,
        .mid = 0x00FFBD2E,
        .bottom = 0x0028C840,
    };
};
