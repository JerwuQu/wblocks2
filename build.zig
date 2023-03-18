const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = std.zig.CrossTarget.parse(.{
            .arch_os_abi = "x86_64-windows-gnu",
            .cpu_features = "baseline",
        }) catch unreachable,
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "wblocks",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    // Manually link pthread since zig doesn't ship with it
    // https://github.com/ziglang/zig/issues/10989
    exe.addIncludePath("third_party/mingw64/include");
    exe.addObjectFile("third_party/mingw64/lib/libpthread.a");

    // QuickJS
    exe.addIncludePath("third_party");
    exe.addCSourceFiles(&[_][]const u8{
        "third_party/quickjs/quickjs.c",
        "third_party/quickjs/quickjs-libc.c",
        "third_party/quickjs/cutils.c",
        "third_party/quickjs/libregexp.c",
        "third_party/quickjs/libbf.c",
        "third_party/quickjs/libunicode.c",
    }, &[_][]const u8{
        "-DCONFIG_BIGNUM",
        "-DCONFIG_VERSION=\"" ++ (comptime std.mem.trim(u8, @embedFile("third_party/quickjs/VERSION"), " \n\r\t")) ++ "\"",
    });

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
