const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwp = wayland.client.zwp;

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const linux = @cImport({
    @cInclude("linux/input-event-codes.h");
});

pub const MouseEvent = union(enum) {
    enter: struct {
        x: f64,
        y: f64,
    },
    leave: void,
    motion: struct {
        x: f64,
        y: f64,
    },
    button: struct {
        button: Button,
        state: wl.Pointer.ButtonState,
    },
};

pub const KeyEvent = struct {
    state: enum { pressed, released },
    key: Key,
    sym: u32,
};

pub const CursorMode = enum {
    normal,
    captured,
};

const MouseListener = struct {
    data: ?*anyopaque,
    callback: *const fn (?*anyopaque, MouseEvent) void,

    pub fn dispatch(self: MouseListener, event: MouseEvent) void {
        self.callback(self.data, event);
    }
};

const KeyListener = struct {
    data: ?*anyopaque,
    callback: *const fn (?*anyopaque, KeyEvent) void,

    pub fn dispatch(self: KeyListener, event: KeyEvent) void {
        self.callback(self.data, event);
    }
};

const Cursor = struct {
    surface: *wl.Surface,
    theme: *wl.CursorTheme,
    buffer: *wl.Buffer,
    size: [2]u32,
    hotspot: [2]u32,

    fn load(compositor: *wl.Compositor, shm: *wl.Shm) !Cursor {
        const surface = try compositor.createSurface();
        errdefer surface.destroy();

        const theme: *wl.CursorTheme = try .load(null, 24, shm);
        errdefer theme.destroy();

        const cursor = wl.CursorTheme.getCursor(theme, "left_ptr") orelse
            return error.CursorNotFound;

        if (cursor.image_count == 0) {
            return error.CursorNoImages;
        }

        const image = cursor.images[0];
        const buffer = try image.getBuffer();

        return .{
            .surface = surface,
            .theme = theme,
            .buffer = buffer,
            .size = .{
                image.width,
                image.height,
            },
            .hotspot = .{
                image.hotspot_x,
                image.hotspot_y,
            },
        };
    }
    fn unload(self: Cursor) void {
        self.surface.destroy();
        self.theme.destroy();
    }

    fn show(self: *const Cursor, pointer: *wl.Pointer, serial: u32) void {
        self.surface.attach(self.buffer, 0, 0);
        self.surface.damage(0, 0, @intCast(self.size[0]), @intCast(self.size[1]));
        self.surface.commit();

        pointer.setCursor(
            serial,
            self.surface,
            @intCast(self.hotspot[0]),
            @intCast(self.hotspot[1]),
        );
    }
    fn hide(self: *const Cursor, pointer: *wl.Pointer, serial: u32) void {
        _ = self;
        pointer.setCursor(serial, null, 0, 0);
    }
};

const Context = struct {
    compositor: ?*wl.Compositor,
    seat: ?*wl.Seat,
    shm: ?*wl.Shm,
    wm_base: ?*xdg.WmBase,
    pointer_constraints: ?*zwp.PointerConstraintsV1,
    relative_pointer_manager: ?*zwp.RelativePointerManagerV1,

    locked_pointer: ?*zwp.LockedPointerV1,
    relative_pointer: ?*zwp.RelativePointerV1,

    cursor: ?Cursor,

    xkb_context: ?*xkb.xkb_context,
    xkb_keymap: ?*xkb.xkb_keymap,
    xkb_state: ?*xkb.xkb_state,

    width: i32,
    height: i32,

    open: bool,

    cursor_pos: ?[2]f64,
    cursor_mode: CursorMode,
    cursor_serial: ?u32,

    mouse_listener: ?MouseListener,
    key_listener: ?KeyListener,

    fn deinit(self: *Context) void {
        if (self.compositor) |compositor| {
            compositor.destroy();
            self.compositor = null;
        }
        if (self.seat) |seat| {
            seat.destroy();
            self.seat = null;
        }
        if (self.shm) |shm| {
            shm.destroy();
            self.shm = null;
        }
        if (self.wm_base) |wm_base| {
            wm_base.destroy();
            self.wm_base = null;
        }
        if (self.pointer_constraints) |pointer_constraints| {
            pointer_constraints.destroy();
            self.pointer_constraints = null;
        }
        if (self.relative_pointer_manager) |relative_pointer_manager| {
            relative_pointer_manager.destroy();
            self.relative_pointer_manager = null;
        }
        if (self.locked_pointer) |locked| {
            locked.destroy();
            self.locked_pointer = null;
        }
        if (self.relative_pointer) |relative| {
            relative.destroy();
            self.relative_pointer = null;
        }
        if (self.cursor) |cursor| {
            cursor.unload();
            self.cursor = null;
        }

        xkb.xkb_context_unref(self.xkb_context);
        xkb.xkb_keymap_unref(self.xkb_keymap);
        xkb.xkb_state_unref(self.xkb_state);
    }
};

const Window = @This();

display: *wl.Display,
registry: *wl.Registry,

surface: *wl.Surface,
xdg_surface: *xdg.Surface,
xdg_toplevel: *xdg.Toplevel,

keyboard: *wl.Keyboard,
pointer: *wl.Pointer,

context: *Context,

pub fn init(gpa: Allocator, title: [:0]const u8) !Window {
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();
    const registry = try display.getRegistry();
    errdefer registry.destroy();

    const context = try gpa.create(Context);
    errdefer gpa.destroy(context);

    context.* = .{
        .compositor = null,
        .seat = null,
        .shm = null,
        .wm_base = null,
        .pointer_constraints = null,
        .relative_pointer_manager = null,
        .cursor = null,
        .xkb_context = null,
        .xkb_keymap = null,
        .xkb_state = null,
        .width = 0,
        .height = 0,
        .open = true,
        .cursor_pos = null,
        .cursor_mode = .normal,
        .cursor_serial = null,
        .locked_pointer = null,
        .relative_pointer = null,
        .mouse_listener = null,
        .key_listener = null,
    };
    errdefer context.deinit();

    registry.setListener(*Context, registryListener, context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = context.compositor orelse return error.NoCompositor;
    const seat = context.seat orelse return error.NoSeat;
    const shm = context.shm orelse return error.NoShm;
    const wm_base = context.wm_base orelse return error.NoWmBase;

    const surface = try compositor.createSurface();
    errdefer surface.destroy();

    const xdg_surface = try wm_base.getXdgSurface(surface);
    errdefer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    errdefer xdg_toplevel.destroy();

    wm_base.setListener(*Context, wmBaseListener, context);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);
    xdg_toplevel.setListener(*Context, xdgToplevelListener, context);

    xdg_toplevel.setTitle(title);

    const keyboard = try seat.getKeyboard();
    errdefer keyboard.destroy();

    const pointer = try seat.getPointer();
    errdefer pointer.destroy();

    keyboard.setListener(*Context, keyboardListener, context);
    pointer.setListener(*Context, pointerListener, context);

    const cursor: Cursor = try .load(compositor, shm);
    errdefer cursor.unload();

    context.cursor = cursor;

    context.xkb_context = xkb.xkb_context_new(0);
    errdefer xkb.xkb_context_unref(context.xkb_context);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    return .{
        .display = display,
        .registry = registry,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .keyboard = keyboard,
        .pointer = pointer,
        .context = context,
    };
}
pub fn deinit(self: *Window, gpa: Allocator) void {
    self.pointer.destroy();
    self.keyboard.destroy();
    self.xdg_toplevel.destroy();
    self.xdg_surface.destroy();
    self.surface.destroy();

    self.context.deinit();

    self.registry.destroy();
    self.display.disconnect();

    gpa.destroy(self.context);
}

pub fn poll(self: *Window) void {
    _ = self.display.dispatchPending();
    _ = self.display.flush();
}
pub fn isOpen(self: *const Window) bool {
    return self.context.open;
}
pub fn getSize(self: *const Window) [2]i32 {
    return .{ self.context.width, self.context.height };
}
pub fn getCursorPos(self: *const Window) ?[2]f64 {
    return self.context.cursor_pos;
}

pub fn setCursorMode(self: *Window, mode: CursorMode) !void {
    if (self.context.cursor_mode == mode) return;

    switch (mode) {
        .normal => {
            if (self.context.locked_pointer) |locked| {
                locked.destroy();
                self.context.locked_pointer = null;
            }
            if (self.context.relative_pointer) |relative| {
                relative.destroy();
                self.context.relative_pointer = null;
            }
            if (self.context.cursor) |cursor| {
                if (self.context.cursor_serial) |serial| {
                    cursor.show(self.pointer, serial);
                }
            }
            self.context.cursor_mode = .normal;
        },
        .captured => {
            const constraints = self.context.pointer_constraints orelse
                return error.MissingPointerConstraints;
            const manager = self.context.relative_pointer_manager orelse
                return error.MissingRelativePointer;

            if (self.context.locked_pointer == null) {
                self.context.locked_pointer = constraints.lockPointer(
                    self.surface,
                    self.pointer,
                    null,
                    .persistent,
                ) catch return error.LockPointerFailed;
            }
            errdefer if (self.context.locked_pointer) |locked| {
                locked.destroy();
                self.context.locked_pointer = null;
            };

            if (self.context.relative_pointer == null) {
                const relative = manager.getRelativePointer(self.pointer) catch
                    return error.GetRelativePointerFailed;
                relative.setListener(*Context, relativePointerListener, self.context);
                self.context.relative_pointer = relative;
            }
            errdefer if (self.context.relative_pointer) |relative| {
                relative.destroy();
                self.context.relative_pointer = null;
            };

            if (self.context.cursor) |cursor| {
                if (self.context.cursor_serial) |serial| {
                    cursor.hide(self.pointer, serial);
                }
            }
            self.context.cursor_mode = .captured;
        },
    }
}

pub fn setMouseListener(
    self: *Window,
    comptime T: type,
    callback: *const fn (T, MouseEvent) void,
    data: T,
) void {
    self.context.mouse_listener = .{
        .data = @ptrCast(data),
        .callback = @ptrCast(callback),
    };
}
pub fn unsetMouseListener(self: *Window) void {
    self.context.mouse_listener = null;
}

pub fn setKeyListener(
    self: *Window,
    comptime T: type,
    callback: *const fn (T, KeyEvent) void,
    data: T,
) void {
    self.context.key_listener = .{
        .data = @ptrCast(data),
        .callback = @ptrCast(callback),
    };
}

pub fn unsetKeyListener(self: *Window) void {
    self.context.key_listener = null;
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    context: *Context,
) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, wl.Compositor.generated_version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, wl.Seat.generated_version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, wl.Shm.generated_version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, xdg.WmBase.generated_version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwp.PointerConstraintsV1.interface.name) == .eq) {
                context.pointer_constraints = registry.bind(
                    global.name,
                    zwp.PointerConstraintsV1,
                    zwp.PointerConstraintsV1.generated_version,
                ) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwp.RelativePointerManagerV1.interface.name) == .eq) {
                context.relative_pointer_manager = registry.bind(
                    global.name,
                    zwp.RelativePointerManagerV1,
                    zwp.RelativePointerManagerV1.generated_version,
                ) catch return;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(
    wm_base: *xdg.WmBase,
    event: xdg.WmBase.Event,
    context: *Context,
) void {
    _ = context;
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

fn xdgSurfaceListener(
    xdg_surface: *xdg.Surface,
    event: xdg.Surface.Event,
    surface: *wl.Surface,
) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
        },
    }
}

fn xdgToplevelListener(
    _: *xdg.Toplevel,
    event: xdg.Toplevel.Event,
    context: *Context,
) void {
    switch (event) {
        .configure => |configure| {
            context.width = configure.width;
            context.height = configure.height;
        },
        .close => context.open = false,
    }
}

fn keyboardListener(
    keyboard: *wl.Keyboard,
    event: wl.Keyboard.Event,
    context: *Context,
) void {
    _ = keyboard;

    switch (event) {
        .keymap => |keymap| {
            defer std.posix.close(keymap.fd);

            // No idea how to deal with anything else
            assert(keymap.format == .xkb_v1);

            const mapped = std.posix.mmap(
                null,
                keymap.size,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                keymap.fd,
                0,
            ) catch @panic("mmap failed");
            defer std.posix.munmap(mapped);

            const xkb_keymap = xkb.xkb_keymap_new_from_string(
                context.xkb_context,
                @ptrCast(mapped),
                xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
                0,
            );
            if (xkb_keymap == null) {
                @panic("noo");
            }

            const xkb_state = xkb.xkb_state_new(xkb_keymap);

            context.xkb_keymap = xkb_keymap;
            context.xkb_state = xkb_state;
        },
        .enter => {},
        .leave => {},
        .key => |key| {
            if (context.key_listener) |kl| {
                if (context.xkb_state) |state| {
                    // https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_keyboard
                    const keycode = key.key + 8; // to xkb keycode (xkb_v1)
                    const sym = xkb.xkb_state_key_get_one_sym(state, keycode);
                    kl.dispatch(.{
                        .state = switch (key.state) {
                            .pressed => .pressed,
                            .released => .released,
                            else => @panic("unknown"),
                        },
                        .sym = sym,
                        .key = keycodeToKey(key.key),
                    });
                }
            }
        },
        .modifiers => |mod| {
            if (context.xkb_state) |state| {
                _ = xkb.xkb_state_update_mask(
                    state,
                    mod.mods_depressed,
                    mod.mods_latched,
                    mod.mods_locked,
                    0,
                    0,
                    mod.group,
                );
            }
        },
    }
}

fn pointerListener(
    pointer: *wl.Pointer,
    event: wl.Pointer.Event,
    context: *Context,
) void {
    switch (event) {
        .enter => |enter| {
            context.cursor_serial = enter.serial;
            context.cursor_pos = .{
                enter.surface_x.toDouble(),
                enter.surface_y.toDouble(),
            };
            if (context.mouse_listener) |ml| {
                ml.dispatch(.{
                    .enter = .{
                        .x = enter.surface_x.toDouble(),
                        .y = enter.surface_y.toDouble(),
                    },
                });
            }

            if (context.cursor) |cursor| {
                cursor.show(pointer, enter.serial);
            }
        },
        .leave => {
            context.cursor_serial = null;
            if (context.mouse_listener) |ml| {
                ml.dispatch(.leave);
            }
        },
        .motion => |motion| {
            context.cursor_pos = .{
                motion.surface_x.toDouble(),
                motion.surface_y.toDouble(),
            };

            if (context.cursor_mode == .normal) {
                if (context.mouse_listener) |ml| {
                    ml.dispatch(.{
                        .motion = .{
                            .x = motion.surface_x.toDouble(),
                            .y = motion.surface_y.toDouble(),
                        },
                    });
                }
            }
        },
        .button => |button| {
            if (context.mouse_listener) |ml| {
                const button_code: i32 = std.math.clamp(
                    @as(i32, @intCast(button.button)) - linux.BTN_LEFT,
                    0,
                    @intFromEnum(Button.unknown),
                );
                const logical_button: Button = @enumFromInt(button_code);

                ml.dispatch(.{
                    .button = .{
                        .button = logical_button,
                        .state = button.state,
                    },
                });
            }
        },
        .axis => {},
    }
}

fn relativePointerListener(
    relative_pointer: *zwp.RelativePointerV1,
    event: zwp.RelativePointerV1.Event,
    context: *Context,
) void {
    _ = relative_pointer;
    switch (event) {
        .relative_motion => |motion| {
            if (context.cursor_mode != .captured) return;

            if (context.mouse_listener) |ml| {
                ml.dispatch(.{
                    .motion = .{
                        .x = motion.dx.toDouble(),
                        .y = motion.dy.toDouble(),
                    },
                });
            }
        },
    }
}

fn keycodeToKey(code: u32) Key {
    return switch (code) {
        linux.KEY_SPACE => .space,
        linux.KEY_APOSTROPHE => .apostrophe,
        linux.KEY_COMMA => .comma,
        linux.KEY_MINUS => .minus,
        linux.KEY_DOT => .period,
        linux.KEY_SLASH => .slash,
        linux.KEY_0 => .n0,
        linux.KEY_1 => .n1,
        linux.KEY_2 => .n2,
        linux.KEY_3 => .n3,
        linux.KEY_4 => .n4,
        linux.KEY_5 => .n5,
        linux.KEY_6 => .n6,
        linux.KEY_7 => .n7,
        linux.KEY_8 => .n8,
        linux.KEY_9 => .n9,
        linux.KEY_SEMICOLON => .semicolon,
        linux.KEY_EQUAL => .equal,
        linux.KEY_A => .a,
        linux.KEY_B => .b,
        linux.KEY_C => .c,
        linux.KEY_D => .d,
        linux.KEY_E => .e,
        linux.KEY_F => .f,
        linux.KEY_G => .g,
        linux.KEY_H => .h,
        linux.KEY_I => .i,
        linux.KEY_J => .j,
        linux.KEY_K => .k,
        linux.KEY_L => .l,
        linux.KEY_M => .m,
        linux.KEY_N => .n,
        linux.KEY_O => .o,
        linux.KEY_P => .p,
        linux.KEY_Q => .q,
        linux.KEY_R => .r,
        linux.KEY_S => .s,
        linux.KEY_T => .t,
        linux.KEY_U => .u,
        linux.KEY_V => .v,
        linux.KEY_W => .w,
        linux.KEY_X => .x,
        linux.KEY_Y => .y,
        linux.KEY_Z => .z,
        linux.KEY_LEFTBRACE => .left_bracket,
        linux.KEY_BACKSLASH => .backslash,
        linux.KEY_RIGHTBRACE => .right_bracket,
        linux.KEY_GRAVE => .grave_accent,
        linux.KEY_ESC => .escape,
        linux.KEY_ENTER => .enter,
        linux.KEY_TAB => .tab,
        linux.KEY_BACKSPACE => .backspace,
        linux.KEY_INSERT => .insert,
        linux.KEY_DELETE => .delete,
        linux.KEY_RIGHT => .right,
        linux.KEY_LEFT => .left,
        linux.KEY_DOWN => .down,
        linux.KEY_UP => .up,
        linux.KEY_PAGEUP => .page_up,
        linux.KEY_PAGEDOWN => .page_down,
        linux.KEY_HOME => .home,
        linux.KEY_END => .end,
        linux.KEY_CAPSLOCK => .caps_lock,
        linux.KEY_SCROLLLOCK => .scroll_lock,
        linux.KEY_NUMLOCK => .num_lock,
        linux.KEY_SYSRQ, linux.KEY_PRINT => .print_screen,
        linux.KEY_PAUSE => .pause,
        linux.KEY_F1 => .f1,
        linux.KEY_F2 => .f2,
        linux.KEY_F3 => .f3,
        linux.KEY_F4 => .f4,
        linux.KEY_F5 => .f5,
        linux.KEY_F6 => .f6,
        linux.KEY_F7 => .f7,
        linux.KEY_F8 => .f8,
        linux.KEY_F9 => .f9,
        linux.KEY_F10 => .f10,
        linux.KEY_F11 => .f11,
        linux.KEY_F12 => .f12,
        linux.KEY_F13 => .f13,
        linux.KEY_F14 => .f14,
        linux.KEY_F15 => .f15,
        linux.KEY_F16 => .f16,
        linux.KEY_F17 => .f17,
        linux.KEY_F18 => .f18,
        linux.KEY_F19 => .f19,
        linux.KEY_F20 => .f20,
        linux.KEY_F21 => .f21,
        linux.KEY_F22 => .f22,
        linux.KEY_F23 => .f23,
        linux.KEY_F24 => .f24,
        linux.KEY_KP0 => .kp_0,
        linux.KEY_KP1 => .kp_1,
        linux.KEY_KP2 => .kp_2,
        linux.KEY_KP3 => .kp_3,
        linux.KEY_KP4 => .kp_4,
        linux.KEY_KP5 => .kp_5,
        linux.KEY_KP6 => .kp_6,
        linux.KEY_KP7 => .kp_7,
        linux.KEY_KP8 => .kp_8,
        linux.KEY_KP9 => .kp_9,
        linux.KEY_KPDOT => .kp_decimal,
        linux.KEY_KPSLASH => .kp_divide,
        linux.KEY_KPASTERISK => .kp_multiply,
        linux.KEY_KPMINUS => .kp_subtract,
        linux.KEY_KPPLUS => .kp_add,
        linux.KEY_KPENTER => .kp_enter,
        linux.KEY_KPEQUAL => .kp_equal,
        linux.KEY_LEFTSHIFT => .left_shift,
        linux.KEY_LEFTCTRL => .left_control,
        linux.KEY_LEFTALT => .left_alt,
        linux.KEY_LEFTMETA => .left_super,
        linux.KEY_RIGHTSHIFT => .right_shift,
        linux.KEY_RIGHTCTRL => .right_control,
        linux.KEY_RIGHTALT => .right_alt,
        linux.KEY_RIGHTMETA => .right_super,
        linux.KEY_MENU => .menu,
        else => .unknown,
    };
}

pub const Button = enum {
    left,
    right,
    middle,
    b4,
    b5,
    b6,
    b7,
    b8,
    unknown,
};

pub const Key = enum(i32) {
    unknown = -1,
    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    n0 = 48,
    n1 = 49,
    n2 = 50,
    n3 = 51,
    n4 = 52,
    n5 = 53,
    n6 = 54,
    n7 = 55,
    n8 = 56,
    n9 = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    f13 = 302,
    f14 = 303,
    f15 = 304,
    f16 = 305,
    f17 = 306,
    f18 = 307,
    f19 = 308,
    f20 = 309,
    f21 = 310,
    f22 = 311,
    f23 = 312,
    f24 = 313,
    f25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
};
