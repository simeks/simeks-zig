const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const math = @import("math");

const gui = @import("root.zig");
const Atlas = @import("Atlas.zig");
const DrawList = @import("DrawList.zig");

const Color = gui.Color;
const DrawData = gui.DrawData;
const DrawVertex = gui.DrawVertex;
const Rect = gui.Rect;
const Style = gui.Style;
const TextOptions = gui.TextOptions;

const max_stack_depth = 32;

pub const InputState = struct {
    mouse_position: math.Vec2 = .{ 0, 0 },
    mouse_left_down: bool = false,
};

pub const LayoutDirection = enum {
    vertical,
    horizontal,
};

pub const PanelOptions = struct {
    origin: math.Vec2 = .{ 0, 0 },
    size: ?math.Vec2 = null,

    color: ?Color = null,
    direction: LayoutDirection = .vertical,
    spacing: ?f32 = null,
    padding: ?math.Vec2 = null,
};

pub const ButtonOptions = struct {
    text: TextOptions = .{},
    min_width: ?f32 = null,
    text_offset: f32 = 0.0,
};

pub const DropdownOptions = struct {
    text: TextOptions = .{},
    min_width: ?f32 = null,
};

pub const SliderOptions = struct {
    width: f32 = 200.0,
};

pub const KnobOptions = struct {
    radius: f32 = 36.0,
};

const ClickInteraction = enum {
    none,
    active,
    clicked,
    hover,
};

const DragInteraction = enum {
    none,
    active,
    hover,
};

const Action = union(enum) {
    none: void,
    knob: struct {
        pointer_y: f32,
    },
};

const DrawCommand = union(enum) {
    rect: struct {
        rect: Rect,
        color: Color,
    },
    text: struct {
        position: math.Vec2,
        text: []const u8,
        size: f32,
        color: Color,
    },
    filled_circle: struct {
        center: math.Vec2,
        radius: f32,
        color: Color,
    },
};

const PanelStack = struct {
    const Layout = struct {
        direction: LayoutDirection,
        spacing: f32,
        padding: math.Vec2,
    };

    const Frame = struct {
        cmd_index: usize,
        position: math.Vec2,
        min_size: math.Vec2,
        layout: Layout,
        cursor: f32 = 0.0,
        cross_extent: f32 = 0.0,
        item_count: usize = 0,

        fn place(self: *Frame, size: math.Vec2) math.Vec2 {
            if (self.item_count > 0) {
                self.cursor += self.layout.spacing;
            }
            const origin: math.Vec2 = .{
                self.position[0] + self.layout.padding[0],
                self.position[1] + self.layout.padding[1],
            };
            const position = switch (self.layout.direction) {
                .vertical => .{ origin[0], origin[1] + self.cursor },
                .horizontal => .{ origin[0] + self.cursor, origin[1] },
            };
            self.expand(size);
            return position;
        }

        fn nextPosition(self: *const Frame) math.Vec2 {
            var cursor_value = self.cursor;
            if (self.item_count > 0) {
                cursor_value += self.layout.spacing;
            }
            const origin: math.Vec2 = .{
                self.position[0] + self.layout.padding[0],
                self.position[1] + self.layout.padding[1],
            };
            return switch (self.layout.direction) {
                .vertical => .{ origin[0], origin[1] + cursor_value },
                .horizontal => .{ origin[0] + cursor_value, origin[1] },
            };
        }

        fn contentSize(self: Frame) math.Vec2 {
            return switch (self.layout.direction) {
                .vertical => .{ self.cross_extent, self.cursor },
                .horizontal => .{ self.cursor, self.cross_extent },
            };
        }

        fn expand(self: *Frame, size: math.Vec2) void {
            switch (self.layout.direction) {
                .vertical => {
                    self.cursor += size[1];
                    self.cross_extent = @max(self.cross_extent, size[0]);
                },
                .horizontal => {
                    self.cursor += size[0];
                    self.cross_extent = @max(self.cross_extent, size[1]);
                },
            }
            self.item_count += 1;
        }
    };

    frames: [max_stack_depth]Frame = undefined,
    next: usize = 0,

    pub fn push(self: *PanelStack, frame: Frame) void {
        assert(self.next < max_stack_depth);
        self.frames[self.next] = frame;
        self.next += 1;
    }

    pub fn pop(self: *PanelStack) ?Frame {
        if (self.next == 0) return null;
        self.next -= 1;
        return self.frames[self.next];
    }

    pub fn top(self: *PanelStack) ?*Frame {
        if (self.next == 0) return null;
        return &self.frames[self.next - 1];
    }
};

const IdStack = struct {
    const initial_seed = 0x25eefffd6ec7461c;

    ids: [max_stack_depth]u64 = undefined,
    next: usize = 0,

    pub fn push(self: *IdStack, name: []const u8) void {
        assert(self.next < max_stack_depth);
        self.ids[self.next] = hashFn(self.top(), name);
        self.next += 1;
    }

    pub fn pop(self: *IdStack) void {
        assert(self.next > 0);
        self.next -= 1;
    }

    pub fn getHash(self: *const IdStack, name: []const u8) u64 {
        return hashFn(self.top(), name);
    }

    fn top(self: *const IdStack) u64 {
        if (self.next == 0) return initial_seed;
        return self.ids[self.next - 1];
    }

    fn hashFn(seed: u64, name: []const u8) u64 {
        var hasher: std.hash.Wyhash = .init(seed);
        hasher.update(name);
        return hasher.final();
    }
};

const Gui = @This();

gpa: Allocator,
style: Style = .{},
atlas: *Atlas,
display_size: math.Vec2,
input: InputState = .{},
prev_input: InputState = .{},

active_id: ?u64,
open_popup_id: ?u64 = null,
action: Action,

main_commands: std.ArrayList(DrawCommand),
overlay_commands: std.ArrayList(DrawCommand),
panel_stack: PanelStack,
id_stack: IdStack,

string_arena: std.heap.ArenaAllocator,

draw_list: DrawList,

pub fn create(gpa: Allocator) !*Gui {
    const self = try gpa.create(Gui);
    errdefer gpa.destroy(self);

    const atlas = try Atlas.create(gpa);
    errdefer atlas.destroy(gpa);

    self.* = .{
        .gpa = gpa,
        .atlas = atlas,
        .display_size = .{ 0, 0 },
        .input = .{},
        .prev_input = .{},
        .active_id = null,
        .open_popup_id = null,
        .action = .{ .none = {} },
        .main_commands = .empty,
        .overlay_commands = .empty,
        .panel_stack = .{},
        .id_stack = .{},
        .string_arena = .init(gpa),
        .draw_list = .init(gpa, atlas),
    };

    return self;
}

pub fn destroy(self: *Gui) void {
    self.main_commands.deinit(self.gpa);
    self.overlay_commands.deinit(self.gpa);
    self.draw_list.deinit();
    self.atlas.destroy(self.gpa);
    self.string_arena.deinit();
    self.gpa.destroy(self);
}

pub fn beginFrame(self: *Gui, display_size: math.Vec2, input: InputState) void {
    self.prev_input = self.input;
    self.input = input;
    self.display_size = display_size;
    self.main_commands.clearRetainingCapacity();
    self.overlay_commands.clearRetainingCapacity();
    self.draw_list.reset();
    _ = self.string_arena.reset(.retain_capacity);

    if (!input.mouse_left_down) {
        if (!self.prev_input.mouse_left_down) {
            self.active_id = null;
        }
        self.action = .{ .none = {} };
    }
}

pub fn endFrame(self: *Gui) void {
    assert(self.panel_stack.top() == null); // unclosed panel

    const command_sets = [_][]const DrawCommand{
        self.main_commands.items,
        self.overlay_commands.items,
    };

    for (command_sets) |commands| {
        for (commands) |cmd| {
            switch (cmd) {
                .rect => |rect| {
                    self.draw_list.drawRect(
                        rect.rect,
                        rect.color,
                        .{ 0, 0 },
                        .{ 0, 0 },
                    );
                },
                .text => |text| {
                    self.draw_list.drawText(
                        text.position,
                        text.text,
                        text.color,
                        text.size,
                    );
                },
                .filled_circle => |circle| {
                    self.draw_list.drawCircleFilled(circle.center, circle.radius, circle.color);
                },
            }
        }
    }
}

pub fn beginPanel(self: *Gui, name: []const u8, options: PanelOptions) void {
    var position = options.origin;
    var size = options.size orelse .{ 0, 0 };

    // Place in parent
    if (self.panel_stack.top()) |parent| {
        // Actual size will be filled in later
        position += parent.place(.{ 0, 0 });
    }

    // If no parent, fill all screen
    if (self.panel_stack.top() == null and options.size == null) {
        size = .{
            @max(self.display_size[0] - position[0], 0.0),
            @max(self.display_size[1] - position[1], 0.0),
        };
    }

    const cmd_index = self.main_commands.items.len;
    self.main_commands.append(self.gpa, .{
        .rect = .{
            .rect = .{
                .x = position[0],
                .y = position[1],
                // Filled in later (endPanel)
                .width = 0,
                .height = 0,
            },
            .color = options.color orelse self.style.panel_background_color,
        },
    }) catch @panic("oom");

    self.panel_stack.push(.{
        .cmd_index = cmd_index,
        .position = position,
        .min_size = size,
        .layout = .{
            .direction = options.direction,
            .spacing = options.spacing orelse self.style.panel_item_spacing,
            .padding = options.padding orelse self.style.panel_padding,
        },
    });
    self.id_stack.push(name);
}

pub fn endPanel(self: *Gui) void {
    assert(self.panel_stack.top() != null);
    if (self.panel_stack.pop()) |frame| {
        const content_size = frame.contentSize();
        const panel_size: math.Vec2 = .{
            @max(content_size[0] + frame.layout.padding[0] * 2.0, frame.min_size[0]),
            @max(content_size[1] + frame.layout.padding[1] * 2.0, frame.min_size[1]),
        };

        var rect_cmd = &self.main_commands.items[frame.cmd_index].rect;
        rect_cmd.rect.width = panel_size[0];
        rect_cmd.rect.height = panel_size[1];

        if (self.panel_stack.top()) |parent| {
            parent.expand(panel_size);
        }

        self.id_stack.pop();
    }
}

pub fn spacer(self: *Gui, size: math.Vec2) void {
    assert(size[0] >= 0);
    assert(size[1] >= 0);
    const parent = self.panel_stack.top() orelse @panic("no parent");
    _ = parent.place(size);
}

/// Reserve space of the given size, returns a rect of the reserved area
pub fn reserveRect(self: *Gui, size: math.Vec2) Rect {
    assert(size[0] >= 0);
    assert(size[1] >= 0);
    const parent = self.panel_stack.top() orelse @panic("no parent");
    const position = parent.place(size);
    return .{
        .x = position[0],
        .y = position[1],
        .width = size[0],
        .height = size[1],
    };
}

/// Get the position that the next element will be placed
pub fn nextPosition(self: *Gui) math.Vec2 {
    const parent = self.panel_stack.top() orelse @panic("no parent");
    return parent.nextPosition();
}

pub fn label(self: *Gui, text: []const u8, options: TextOptions) void {
    const arena_text = self.string_arena.allocator().dupe(u8, text) catch @panic("oom");

    const size = measureText(self, arena_text, options);

    const parent = self.panel_stack.top() orelse @panic("no parent");
    const position = parent.place(size);

    self.main_commands.append(self.gpa, .{
        .text = .{
            .position = position,
            .text = arena_text,
            .color = options.color orelse .white,
            .size = options.size,
        },
    }) catch @panic("oom");
}

pub fn labelFmt(self: *Gui, comptime fmt: []const u8, args: anytype, options: TextOptions) void {
    const text = std.fmt.allocPrint(
        self.string_arena.allocator(),
        fmt,
        args,
    ) catch @panic("oom");

    const size = measureText(self, text, options);

    const parent = self.panel_stack.top() orelse @panic("no parent");
    const position = parent.place(size);

    self.main_commands.append(self.gpa, .{
        .text = .{
            .position = position,
            .text = text,
            .color = options.color orelse .white,
            .size = options.size,
        },
    }) catch @panic("oom");
}

pub fn button(self: *Gui, text: []const u8, options: ButtonOptions) bool {
    const arena_text = self.string_arena.allocator().dupe(u8, text) catch @panic("oom");

    // Layout

    const padding: math.Vec2 = .{
        self.style.button_padding[0] * 2.0,
        self.style.button_padding[1] * 2.0,
    };
    const text_size = measureText(self, arena_text, options.text) + padding;
    const layout_size: math.Vec2 = .{
        @max(text_size[0], options.min_width orelse 0.0),
        text_size[1],
    };

    const parent = self.panel_stack.top() orelse @panic("no parent");
    const position = parent.place(layout_size);
    const rect: Rect = .{
        .x = position[0],
        .y = position[1],
        .width = layout_size[0],
        .height = layout_size[1],
    };

    // Input

    const id = self.id_stack.getHash(arena_text);
    const clickable = self.interactClickable(id, rect);

    // Drawing

    self.main_commands.appendSlice(self.gpa, &.{
        .{
            .rect = .{
                .rect = rect,
                .color = switch (clickable) {
                    .active => self.style.button_hold_background,
                    .hover => self.style.button_hover_background,
                    else => self.style.button_background,
                },
            },
        },
        .{
            .text = .{
                .position = .{
                    rect.x + self.style.button_padding[0] + options.text_offset,
                    rect.y + self.style.button_padding[1],
                },
                .text = arena_text,
                .color = options.text.color orelse self.style.button_text_color,
                .size = options.text.size,
            },
        },
    }) catch @panic("oom");

    return clickable == .clicked;
}

pub fn dropdown(
    self: *Gui,
    name: []const u8,
    items: []const []const u8,
    selected_index: *usize,
    options: DropdownOptions,
) bool {
    assert(items.len > 0);
    assert(selected_index.* < items.len);

    const arrow_size = 8.0;
    const arrow_spacing = 8.0;

    const selected = self.string_arena.allocator().dupe(u8, items[selected_index.*]) catch @panic("oom");

    const padding: math.Vec2 = .{
        self.style.button_padding[0] * 2.0,
        self.style.button_padding[1] * 2.0,
    };

    // Fit the largest string
    var text_size: math.Vec2 = .{ options.min_width orelse 0.0, options.text.size };
    for (items) |entry| {
        const entry_size = self.measureText(entry, options.text);
        text_size = .{
            @max(text_size[0], entry_size[0]),
            @max(text_size[1], entry_size[1]),
        };
    }
    const layout_size = text_size + padding + math.Vec2{ arrow_size + arrow_spacing, 0 };

    const parent = self.panel_stack.top() orelse @panic("no parent");
    const position = parent.place(layout_size);
    const button_rect: Rect = .{
        .x = position[0],
        .y = position[1],
        .width = layout_size[0],
        .height = layout_size[1],
    };

    const menu_id = self.id_stack.getHash(name);

    const clickable = self.interactClickable(menu_id, button_rect);

    self.main_commands.appendSlice(self.gpa, &.{
        .{
            .rect = .{
                .rect = button_rect,
                .color = switch (clickable) {
                    .active => self.style.button_hold_background,
                    .hover => self.style.button_hover_background,
                    else => self.style.button_background,
                },
            },
        },
        .{
            .text = .{
                .position = .{
                    button_rect.x + self.style.button_padding[0],
                    button_rect.y + self.style.button_padding[1],
                },
                .text = selected,
                .color = options.text.color orelse self.style.button_text_color,
                .size = options.text.size,
            },
        },
        // "Arrow"
        .{
            .rect = .{
                .rect = .{
                    .x = button_rect.x + text_size[0] + padding[0],
                    .y = button_rect.y + button_rect.height * 0.5 - arrow_size * 0.5,
                    .width = arrow_size,
                    .height = arrow_size,
                },
                .color = if (self.open_popup_id == menu_id or clickable == .active)
                    self.style.accent_color
                else
                    self.style.button_text_color,
            },
        },
    }) catch @panic("oom");

    if (clickable == .clicked) {
        if (self.open_popup_id == menu_id) {
            self.open_popup_id = null;
        } else {
            self.open_popup_id = menu_id;
        }
    }

    if (self.open_popup_id != menu_id) {
        return false;
    }

    // Dropdown popup

    const popup_rect: Rect = .{
        .x = button_rect.x,
        .y = button_rect.y + button_rect.height,
        .width = button_rect.width,
        .height = button_rect.height * @as(f32, @floatFromInt(items.len)),
    };

    const just_pressed = self.input.mouse_left_down and !self.prev_input.mouse_left_down;
    if (just_pressed and
        !popup_rect.containsPoint(self.input.mouse_position) and
        !button_rect.containsPoint(self.input.mouse_position))
    {
        self.open_popup_id = null;
        self.active_id = null;
        return false;
    }

    self.overlay_commands.append(
        self.gpa,
        .{
            .rect = .{
                .rect = popup_rect,
                .color = self.style.panel_background_color,
            },
        },
    ) catch @panic("oom");

    for (0.., items) |idx, entry| {
        const item_rect: Rect = .{
            .x = popup_rect.x,
            .y = popup_rect.y + button_rect.height * @as(f32, @floatFromInt(idx)),
            .width = button_rect.width,
            .height = button_rect.height,
        };

        const item_clickable = self.interactClickable(self.id_stack.getHash(items[idx]), item_rect);
        if (item_clickable == .clicked) {
            self.open_popup_id = null;
            if (selected_index.* != idx) {
                selected_index.* = idx;
                return true;
            }
        }

        self.overlay_commands.appendSlice(self.gpa, &.{
            .{
                .rect = .{
                    .rect = item_rect,
                    .color = if (selected_index.* == idx)
                        self.style.button_hold_background
                    else switch (item_clickable) {
                        .hover => self.style.button_hover_background,
                        .active => self.style.button_hold_background,
                        else => self.style.button_background,
                    },
                },
            },
            .{
                .text = .{
                    .position = .{
                        item_rect.x + self.style.button_padding[0],
                        item_rect.y + self.style.button_padding[1],
                    },
                    .text = entry,
                    .color = options.text.color orelse .white,
                    .size = options.text.size,
                },
            },
        }) catch @panic("oom");
    }

    return false;
}

pub fn slider(self: *Gui, name: []const u8, value: *f32, min: f32, max: f32, options: SliderOptions) bool {
    assert(min < max);
    assert(value.* >= min);
    assert(value.* <= max);

    // Layout
    const parent = self.panel_stack.top() orelse @panic("no parent");

    const slider_width = @max(options.width, 0.0);
    const layout_size: math.Vec2 = .{ slider_width, self.style.slider_height };
    const position = parent.place(layout_size);
    const rect: Rect = .{
        .x = position[0],
        .y = position[1],
        .width = slider_width,
        .height = self.style.slider_height,
    };

    // Input

    var interact: DragInteraction = .none;
    var new_value: ?f32 = null;

    switch (self.interactClickable(self.id_stack.getHash(name), rect)) {
        .none => {},
        .hover => interact = .hover,
        .active, .clicked => {
            const mouse_x = std.math.clamp(
                self.input.mouse_position[0],
                rect.x,
                rect.x + rect.width,
            );

            const slider_x: f32 = if (rect.width > 0.0)
                (mouse_x - rect.x) / rect.width
            else
                0.0;

            const mouse_value = min + slider_x * (max - min);
            interact = .active;
            if (mouse_value != value.*) {
                new_value = mouse_value;
            }
        },
    }
    if (new_value) |v| {
        value.* = v;
    }

    // Drawing

    const track_rect: Rect = .{
        .x = rect.x,
        .y = rect.y + (self.style.slider_height - self.style.slider_track_height) * 0.5,
        .width = rect.width,
        .height = self.style.slider_track_height,
    };

    const normalized = (value.* - min) / (max - min);
    const clamped_normalized = std.math.clamp(normalized, 0.0, 1.0);

    const fill_rect: Rect = .{
        .x = track_rect.x,
        .y = track_rect.y,
        .width = track_rect.width * clamped_normalized,
        .height = track_rect.height,
    };

    const handle_target = track_rect.x + fill_rect.width - self.style.slider_handle_width * 0.5;
    const handle_min = track_rect.x;
    const handle_max_candidate = track_rect.x + track_rect.width - self.style.slider_handle_width;
    const handle_lower = @min(handle_min, handle_max_candidate);
    const handle_upper = @max(handle_min, handle_max_candidate);

    const handle_rect: Rect = .{
        .x = std.math.clamp(handle_target, handle_lower, handle_upper),
        .y = rect.y,
        .width = self.style.slider_handle_width,
        .height = self.style.slider_height,
    };

    self.main_commands.appendSlice(self.gpa, &.{
        // Track
        .{
            .rect = .{
                .rect = track_rect,
                .color = switch (interact) {
                    .active => self.style.slider_track_active_color,
                    .hover => self.style.slider_track_hover_color,
                    .none => self.style.slider_track_color,
                },
            },
        },
        // Fill
        .{
            .rect = .{
                .rect = fill_rect,
                .color = self.style.accent_color,
            },
        },
        // Handle
        .{
            .rect = .{
                .rect = handle_rect,
                .color = switch (interact) {
                    .active => self.style.slider_handle_active_color,
                    .hover => self.style.slider_handle_hover_color,
                    .none => self.style.slider_handle_color,
                },
            },
        },
    }) catch @panic("oom");

    return new_value != null;
}

pub fn knob(
    self: *Gui,
    name: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    options: KnobOptions,
) bool {
    assert(max > min);
    assert(value.* >= min);
    assert(value.* <= max);

    // Layout
    const parent = self.panel_stack.top() orelse @panic("no parent");

    const size: math.Vec2 = .{ options.radius * 2.0, options.radius * 2.0 };
    const position = parent.place(size);
    const rect: Rect = .{
        .x = position[0],
        .y = position[1],
        .width = size[0],
        .height = size[1],
    };

    // Input

    var interact: DragInteraction = .none;
    var new_value: ?f32 = null;
    switch (self.interactClickable(self.id_stack.getHash(name), rect)) {
        .none => {},
        .hover => interact = .hover,
        .active, .clicked => {
            if (self.action == .knob) {
                const pointer_y = self.input.mouse_position[1];
                const knob_action = &self.action.knob;
                const delta = knob_action.pointer_y - pointer_y;
                knob_action.pointer_y = pointer_y;

                interact = .active;
                new_value = std.math.clamp(
                    value.* + delta * 0.005 * (max - min),
                    min,
                    max,
                );
            } else {
                self.action = .{
                    .knob = .{
                        .pointer_y = self.input.mouse_position[1],
                    },
                };
                interact = .active;
            }
        },
    }

    if (new_value) |v| value.* = v;

    // Drawing

    const knob_min_angle: f32 = -1.3 * std.math.pi;
    const knob_max_angle: f32 = 0.3 * std.math.pi;

    const normalized = (value.* - min) / (max - min);
    const angle = knob_min_angle + normalized * (knob_max_angle - knob_min_angle);
    const c = std.math.cos(angle);
    const s = std.math.sin(angle);

    const center: math.Vec2 = .{
        rect.x + options.radius,
        rect.y + options.radius,
    };

    self.main_commands.appendSlice(self.gpa, &.{
        // Outer
        .{
            .filled_circle = .{
                .center = center,
                .radius = options.radius,
                .color = switch (interact) {
                    .active => self.style.button_hold_background,
                    .hover => self.style.button_hover_background,
                    .none => self.style.button_background,
                },
            },
        },
        // Inner
        .{
            .filled_circle = .{
                .center = center,
                .radius = options.radius * 0.72,
                .color = self.style.background_color,
            },
        },
        // Indicator
        .{
            .filled_circle = .{
                .center = .{
                    center[0] + c * options.radius * 0.65,
                    center[1] + s * options.radius * 0.65,
                },
                .radius = @max(2.0, options.radius * 0.25),
                .color = self.style.accent_color,
            },
        },
    }) catch @panic("oom");

    return new_value != null;
}

fn interactClickable(self: *Gui, id: u64, rect: Rect) ClickInteraction {
    if (self.active_id) |active_id| {
        if (active_id == id) {
            if (self.input.mouse_left_down) {
                return .active;
            } else if (self.prev_input.mouse_left_down) {
                self.active_id = null;
                if (rect.containsPoint(self.input.mouse_position)) {
                    return .clicked;
                }
                return .none;
            }
        } else {
            return .none;
        }
    }

    if (rect.containsPoint(self.input.mouse_position)) {
        self.active_id = id;
        if (self.input.mouse_left_down) {
            return .active;
        }
        return .hover;
    }

    return .none;
}

pub fn getDrawData(self: *const Gui) DrawData {
    return .{
        .display_size = self.display_size,
        .vertices = self.draw_list.vertices.items,
        .indices = self.draw_list.indices.items,
    };
}

pub fn measureText(self: *const Gui, text: []const u8, options: TextOptions) math.Vec2 {
    const pixel_scale = options.size / Atlas.font_glyph_height;
    const line_advance = options.size + Atlas.font_line_spacing;

    var line_width: f32 = 0.0;
    var max_width: f32 = 0.0;
    var line_count: f32 = 1;

    for (text) |cp| {
        if (cp == '\n') {
            max_width = @max(max_width, line_width);
            line_width = 0.0;
            line_count += 1;
            continue;
        }

        const glyph = self.atlas.lookup(cp);
        line_width += glyph.advance * pixel_scale;
    }

    return .{
        @max(max_width, line_width),
        options.size * line_count + line_advance * (line_count - 1.0),
    };
}
