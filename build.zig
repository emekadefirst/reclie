//! Build the reclie native engine (`_reclie`) as a CPython extension.
//!
//! Strategy (see src/root.zig): link against libpython's Py_LIMITED_API
//! import library and let the C compiler handle the one macro-heavy shim
//! (`src/py_module.c`); everything else is hand-declared Zig externs.
//!
//! The Python install prefix defaults to the machine where this was set up.
//! Override it with:  zig build -Dpython="C:/path/to/PythonXY"
//!
//! Output: the built DLL is copied into the package as `reclie/_reclie.pyd`
//! so `from reclie import _reclie` resolves without an install step.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const py_prefix = b.option(
        []const u8,
        "python",
        "Python install prefix (contains Include/ and libs/)",
    ) orelse "C:/Users/PC/AppData/Local/Programs/Python/Python311";

    const py_include = b.pathJoin(&.{ py_prefix, "Include" });
    const py_libs = b.pathJoin(&.{ py_prefix, "libs" });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // CPython headers for the C shim, plus the limited-API import library.
    mod.addIncludePath(.{ .cwd_relative = py_include });
    mod.addLibraryPath(.{ .cwd_relative = py_libs });
    mod.linkSystemLibrary("python3", .{}); // -> python3.lib -> python3.dll

    // The only C we compile: the PyModuleDef / PyInit shim.
    mod.addCSourceFile(.{ .file = b.path("src/py_module.c") });

    const lib = b.addLibrary(.{
        .name = "_reclie",
        .linkage = .dynamic,
        .root_module = mod,
    });

    // Copy the built DLL into the Python package as `_reclie.pyd`.
    const install_ext = b.addUpdateSourceFiles();
    install_ext.addCopyFileToSource(lib.getEmittedBin(), "reclie/_reclie.pyd");
    install_ext.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&install_ext.step);

    // Also install the raw artifact into zig-out for inspection.
    b.installArtifact(lib);

    // `zig build test` — run the bridge + core unit tests.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
