const builtin = @import("builtin");
const std = @import("std");
const Builder = std.build.Builder;

const system_sdk = @import("system_sdk.zig");

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&(try testStep(b, mode, target)).step);
    test_step.dependOn(&(try testStepShared(b, mode, target)).step);
}

pub fn testStep(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) !*std.build.RunStep {
    const main_tests = b.addTestExe("glfw-tests", sdkPath("/src/main.zig"));
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    try link(b, main_tests, .{});
    main_tests.install();
    return main_tests.run();
}

fn testStepShared(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) !*std.build.RunStep {
    const main_tests = b.addTestExe("glfw-tests-shared", sdkPath("/src/main.zig"));
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    try link(b, main_tests, .{ .shared = true });
    main_tests.install();
    return main_tests.run();
}

pub const LinuxWindowManager = enum {
    X11,
    Wayland,
};

pub const Options = struct {
    /// Not supported on macOS.
    vulkan: bool = true,

    /// Only respected on macOS.
    metal: bool = true,

    /// Deprecated on macOS.
    opengl: bool = false,

    /// Not supported on macOS. GLES v3.2 only, currently.
    gles: bool = false,

    /// Only respected on Linux.
    x11: bool = true,

    /// Only respected on Linux.
    wayland: bool = true,

    /// System SDK options.
    system_sdk: system_sdk.Options = .{},

    /// Build and link GLFW as a shared library.
    shared: bool = false,

    install_libs: bool = false,
};

pub const pkg = std.build.Pkg{
    .name = "glfw",
    .source = .{ .path = sdkPath("/src/main.zig") },
};

// TODO(self-hosted): HACK: workaround https://github.com/ziglang/zig/issues/12784
//
// Extracted from a build using stage1 from zig-cache/ (`cimport/c_darwin_native.zig`)
// Then find+replace `= ?fn` -> `= ?*const fn`
fn cimportWorkaround() void {
    const dest_dir = std.fs.cwd().openDir(sdkPath("/src"), .{}) catch unreachable;
    const cn_path = sdkPath("/src/cimport/" ++ if (builtin.os.tag == .macos) "c_darwin_native.zig" else "c_normal_native.zig");
    std.fs.cwd().copyFile(cn_path, dest_dir, sdkPath("/src/c_native.zig"), .{}) catch unreachable;
}

pub const LinkError = error{FailedToLinkGPU} || BuildError;
pub fn link(b: *Builder, step: *std.build.LibExeObjStep, options: Options) LinkError!void {
    cimportWorkaround();

    const lib = try buildLibrary(b, step.build_mode, step.target, options);
    step.linkLibrary(lib);
    addGLFWIncludes(step);
    if (options.shared) {
        step.defineCMacro("GLFW_DLL", null);
        system_sdk.include(b, step, options.system_sdk);
    } else {
        linkGLFWDependencies(b, step, options);
    }
}

pub const BuildError = error{CannotEnsureDependency} || std.mem.Allocator.Error;
fn buildLibrary(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget, options: Options) BuildError!*std.build.LibExeObjStep {
    // TODO(build-system): https://github.com/hexops/mach/issues/229#issuecomment-1100958939
    ensureDependencySubmodule(b.allocator, "upstream") catch return error.CannotEnsureDependency;

    const lib = if (options.shared)
        b.addSharedLibrary("glfw", null, .unversioned)
    else
        b.addStaticLibrary("glfw", null);
    lib.setBuildMode(mode);
    lib.setTarget(target);

    if (options.shared)
        lib.defineCMacro("_GLFW_BUILD_DLL", null);

    addGLFWIncludes(lib);
    try addGLFWSources(b, lib, options);
    linkGLFWDependencies(b, lib, options);

    if (options.install_libs)
        lib.install();

    return lib;
}

fn addGLFWIncludes(step: *std.build.LibExeObjStep) void {
    step.addIncludePath(sdkPath("/upstream/glfw/include"));
    step.addIncludePath(sdkPath("/upstream/vulkan_headers/include"));
}

fn addGLFWSources(b: *Builder, lib: *std.build.LibExeObjStep, options: Options) std.mem.Allocator.Error!void {
    const include_glfw_src = comptime "-I" ++ sdkPath("/upstream/glfw/src");
    switch (lib.target_info.target.os.tag) {
        .windows => lib.addCSourceFiles(&.{
            sdkPath("/src/sources_all.c"),
            sdkPath("/src/sources_windows.c"),
        }, &.{ "-D_GLFW_WIN32", include_glfw_src }),
        .macos => lib.addCSourceFiles(&.{
            sdkPath("/src/sources_all.c"),
            sdkPath("/src/sources_macos.m"),
            sdkPath("/src/sources_macos.c"),
        }, &.{ "-D_GLFW_COCOA", include_glfw_src }),
        else => {
            // TODO(future): for now, Linux can't be built with musl:
            //
            // ```
            // ld.lld: error: cannot create a copy relocation for symbol stderr
            // thread 2004762 panic: attempt to unwrap error: LLDReportedFailure
            // ```
            var sources = std.ArrayList([]const u8).init(b.allocator);
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try sources.append(sdkPath("/src/sources_all.c"));
            try sources.append(sdkPath("/src/sources_linux.c"));
            if (options.x11) {
                try sources.append(sdkPath("/src/sources_linux_x11.c"));
                try flags.append("-D_GLFW_X11");
            }
            if (options.wayland) {
                try sources.append(sdkPath("/src/sources_linux_wayland.c"));
                try flags.append("-D_GLFW_WAYLAND");
            }
            try flags.append(comptime "-I" ++ sdkPath("/upstream/glfw/src"));
            // TODO(upstream): glfw can't compile on clang15 without this flag
            try flags.append("-Wno-implicit-function-declaration");

            lib.addCSourceFiles(sources.items, flags.items);
        },
    }
}

fn linkGLFWDependencies(b: *Builder, step: *std.build.LibExeObjStep, options: Options) void {
    step.linkLibC();
    system_sdk.include(b, step, options.system_sdk);
    switch (step.target_info.target.os.tag) {
        .windows => {
            step.linkSystemLibraryName("gdi32");
            step.linkSystemLibraryName("user32");
            step.linkSystemLibraryName("shell32");
            if (options.opengl) {
                step.linkSystemLibraryName("opengl32");
            }
            if (options.gles) {
                step.linkSystemLibraryName("GLESv3");
            }
        },
        .macos => {
            step.linkFramework("IOKit");
            step.linkFramework("CoreFoundation");
            if (options.metal) {
                step.linkFramework("Metal");
            }
            if (options.opengl) {
                step.linkFramework("OpenGL");
            }
            step.linkSystemLibraryName("objc");
            step.linkFramework("AppKit");
            step.linkFramework("CoreServices");
            step.linkFramework("CoreGraphics");
            step.linkFramework("Foundation");
        },
        else => {
            // Assume Linux-like
            if (options.wayland) {
                step.defineCMacro("WL_MARSHAL_FLAG_DESTROY", null);
            }
        },
    }
}

fn ensureDependencySubmodule(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.process.getEnvVarOwned(allocator, "NO_ENSURE_SUBMODULES")) |no_ensure_submodules| {
        defer allocator.free(no_ensure_submodules);
        if (std.mem.eql(u8, no_ensure_submodules, "true")) return;
    } else |_| {}
    var child = std.ChildProcess.init(&.{ "git", "submodule", "update", "--init", path }, allocator);
    child.cwd = sdkPath("/");
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();

    _ = try child.spawnAndWait();
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}
