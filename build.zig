const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reusable hardware device models live in the virtual-platform package.
    const vp = b.dependency("virtual_platform", .{});

    const exe = b.addExecutable(.{
        .name = "vmm-arm64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "virtual_devices", .module = vp.module("virtual_devices") },
                .{ .name = "fdt", .module = vp.module("fdt") },
                .{ .name = "linux_boot", .module = vp.module("linux_boot") },
            },
        }),
    });

    // HVF lives in Apple's Hypervisor.framework; the exe must link it to resolve
    // the hv_* symbols. (The binary also needs the com.apple.security.hypervisor
    // entitlement + a codesign step to actually be granted a VM at runtime.)
    exe.root_module.linkFramework("Hypervisor", .{});

    // Ad-hoc codesign the compiled binary with the hypervisor entitlement.
    // HVF only grants a VM to a signed binary carrying
    // com.apple.security.hypervisor, so signing must happen on every build or
    // hv_vm_create returns HV_DENIED. We sign the emitted Mach-O (the signature
    // is embedded in __LINKEDIT, so the subsequent install copy carries it
    // through); passing paths as LazyPath file args avoids the removed
    // pathFromRoot/getInstallPath build APIs on this 0.17-dev compiler.
    // Chain: compile → codesign → install, so `zig build` (and `zig build run`,
    // which depends on install) always produce a signed binary.
    const codesign = b.addSystemCommand(&.{
        "codesign",
        "-s",      "-", // ad-hoc signing identity (no developer cert needed for local HVF)
        "--force", "--entitlements",
    });
    codesign.addFileArg(b.path("vmm-arm64.entitlements"));
    codesign.addFileArg(exe.getEmittedBin());

    const install = b.addInstallArtifact(exe, .{});
    install.step.dependOn(&codesign.step);
    b.getInstallStep().dependOn(&install.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Run from the install dir rather than the cache dir, so the binary that runs
    // is the signed, installed one and payload paths resolve against the repo root.
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Tests live in the exe's module: the servicing logic, the decode tables, and
    // (via refAllDecls) a type-check of decls nothing calls. main.zig imports each
    // tested file explicitly, since lazy analysis would otherwise drop them.
    // This binary is UNSIGNED — any hv_* call inside a test returns HV_DENIED, so
    // tests must never reach the framework.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
