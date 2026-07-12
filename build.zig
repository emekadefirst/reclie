//! Build the reclie native engine (`_reclie`) as a CPython extension.
//!
//! Strategy (see src/root.zig): hand-declared Zig externs for the ABI-stable
//! CPython functions, plus one tiny C shim (`src/py_module.c`) the C compiler
//! expands. Targets Py_LIMITED_API 3.11, so a single abi3 wheel serves 3.11+.
//!
//! Linking libpython differs per OS:
//!   * Windows  - link `python3.lib` (the limited-API import lib).
//!   * else     - do NOT link libpython; the interpreter resolves those
//!                symbols at import time (`linker_allow_shlib_undefined`).
//!
//! Options:
//!   -Dpython="C:/path/PythonXY"    convenience: derives Include/ and libs/
//!   -Dpython-include="/path"       explicit dir containing Python.h
//!   -Dpython-libs="/path"          explicit dir with python3.lib (Windows)
//!
//! Output: the built shared library is copied into the package as
//! `reclie/_reclie.pyd` (Windows) or `reclie/_reclie.abi3.so` (else).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    const py_prefix = b.option(
        []const u8,
        "python",
        "Python install prefix (Windows layout: contains Include/ and libs/)",
    ) orelse "C:/Users/PC/AppData/Local/Programs/Python/Python311";

    const py_include = b.option(
        []const u8,
        "python-include",
        "Directory containing Python.h",
    ) orelse b.pathJoin(&.{ py_prefix, "Include" });

    const py_libs = b.option(
        []const u8,
        "python-libs",
        "Directory containing python3.lib (Windows only)",
    ) orelse b.pathJoin(&.{ py_prefix, "libs" });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // CPython headers for the C shim.
    mod.addIncludePath(.{ .cwd_relative = py_include });
    mod.addCSourceFile(.{ .file = b.path("src/py_module.c") });

    if (os_tag == .windows) {
        // Windows requires linking the limited-API import library.
        mod.addLibraryPath(.{ .cwd_relative = py_libs });
        mod.linkSystemLibrary("python3", .{}); // -> python3.lib -> python3.dll
    }

    const lib = b.addLibrary(.{
        .name = "_reclie",
        .linkage = .dynamic,
        .root_module = mod,
    });

    if (os_tag != .windows) {
        // libpython symbols are undefined until the interpreter loads us. This
        // emits `-fallow-shlib-undefined`, which on ELF permits the undefined
        // symbols and on Mach-O maps to `-undefined dynamic_lookup` (verified:
        // a macOS-targeted dynamic lib with an undefined extern links only with
        // this set). So both Linux and macOS are covered.
        lib.linker_allow_shlib_undefined = true;
    }

    // Copy the built shared library into the Python package under its abi3
    // extension name so `from reclie import _reclie` resolves and packaging
    // picks it up.
    const ext_name = if (os_tag == .windows)
        "reclie/_reclie.pyd"
    else
        "reclie/_reclie.abi3.so";

    const install_ext = b.addUpdateSourceFiles();
    install_ext.addCopyFileToSource(lib.getEmittedBin(), ext_name);
    install_ext.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&install_ext.step);

    b.installArtifact(lib);

    // `zig build test` — run the bridge + core unit tests.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
