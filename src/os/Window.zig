const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const linux = @cImport({
    @cInclude("linux/input-event-codes.h");
});

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
    sym: u32,
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

const Context = struct {
    compositor: ?*wl.Compositor,
    seat: ?*wl.Seat,
    wm_base: ?*xdg.WmBase,

    xkb_context: ?*xkb.xkb_context,
    xkb_keymap: ?*xkb.xkb_keymap,
    xkb_state: ?*xkb.xkb_state,

    width: i32,
    height: i32,

    open: bool,

    mouse_listener: ?MouseListener,
    key_listener: ?KeyListener,
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
        .wm_base = null,
        .xkb_context = null,
        .xkb_keymap = null,
        .xkb_state = null,
        .width = 0,
        .height = 0,
        .open = true,
        .mouse_listener = null,
        .key_listener = null,
    };

    registry.setListener(*Context, registryListener, context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    errdefer if (context.compositor) |compositor| {
        compositor.destroy();
    };
    errdefer if (context.wm_base) |wm_base| {
        wm_base.destroy();
    };

    const compositor = context.compositor orelse return error.NoCompositor;
    const seat = context.seat orelse return error.NoSeat;
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

    if (self.context.compositor) |compositor| {
        compositor.destroy();
    }
    if (self.context.wm_base) |wm_base| {
        wm_base.destroy();
    }

    self.registry.destroy();
    self.display.disconnect();

    xkb.xkb_context_unref(self.context.xkb_context);
    xkb.xkb_keymap_unref(self.context.xkb_keymap);
    xkb.xkb_state_unref(self.context.xkb_state);

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

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    context: *Context,
) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
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
    _ = pointer;
    switch (event) {
        .enter => |enter| {
            if (context.mouse_listener) |ml| {
                ml.dispatch(.{
                    .enter = .{
                        .x = enter.surface_x.toDouble(),
                        .y = enter.surface_y.toDouble(),
                    },
                });
            }
        },
        .leave => {
            if (context.mouse_listener) |ml| {
                ml.dispatch(.leave);
            }
        },
        .motion => |motion| {
            if (context.mouse_listener) |ml| {
                ml.dispatch(.{
                    .motion = .{
                        .x = motion.surface_x.toDouble(),
                        .y = motion.surface_y.toDouble(),
                    },
                });
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
