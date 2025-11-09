# simeks-zig

Small personal toolbox.

## Usage

Add the dependency:
```
> zig fetch git+https://github.com/simeks/simeks-zig.git --save
```

Import in `build.zig`:

```zig
const simeks = b.dependency("simeks", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("score", simeks.module("core"));
exe.root_module.addImport("smath", simeks.module("math"));
exe.root_module.addImport("sgpu", simeks.module("gpu"));
exe.root_module.addImport("sgui", simeks.module("gui"));
exe.root_module.addImport("sos", simeks.module("os"));
```

Use:

```zig
const sgpu = @import("sgpu");
const sgui = @import("sgui");
const smath = @import("smath");
```

## Modules

* `core`: Kitchen sink
* `math`: Basic math library, mostly for supporting 3D graphics
* `gpu`: Vulkan wrapper, similar API as webgpu but very hands-off
* `gui`: Prototype-ish immediate-mode style GUI.
* `os`: OS specifics

## Example

See `example/`.
