// fetch.zig - a dependency management solution for zig projects!
// see the repo at https://github.com/bootradev/zig-fetch for more info

const std = @import("std");

pub const GitDependency = struct {
    name: []const u8,
    url: []const u8,
    commit: []const u8,
};

pub const Dependency = union(enum) {
    git: GitDependency,

    pub fn eql(a: Dependency, b: Dependency) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            return false;
        }

        return switch (a) {
            .git => std.mem.eql(u8, a.git.name, b.git.name) and
                std.mem.eql(u8, a.git.url, b.git.url) and
                std.mem.eql(u8, a.git.commit, b.git.commit),
        };
    }
};

pub fn fetchAndBuild(
    builder: *std.build.Builder,
    deps_dir: []const u8,
    deps: []const Dependency,
    build_file: []const u8,
) !void {
    const fetch_and_build = try FetchAndBuild.init(builder, deps_dir, deps, build_file);
    builder.getInstallStep().dependOn(&fetch_and_build.step);
}

const FetchAndBuild = struct {
    builder: *std.build.Builder,
    step: std.build.Step,
    deps: []const Dependency,
    build_file: []const u8,
    write_fetch_cache: bool,

    fn init(
        builder: *std.build.Builder,
        deps_dir: []const u8,
        deps: []const Dependency,
        build_file: []const u8,
    ) !*FetchAndBuild {
        var fetch_and_build = try builder.allocator.create(FetchAndBuild);
        fetch_and_build.* = .{
            .builder = builder,
            .step = std.build.Step.init(.custom, "fetch and build", builder.allocator, make),
            .deps = try builder.allocator.dupe(Dependency, deps),
            .build_file = builder.dupe(build_file),
            .write_fetch_cache = false,
        };

        const skip_fetch = builder.option(
            bool,
            "fetch-skip",
            "Skip fetching dependencies",
        ) orelse false;
        if (!skip_fetch) {
            const fetch_cache = try readFetchCache(builder);

            for (deps) |dep| {
                if (fetch_cache) |cache| {
                    var dep_in_cache = false;
                    for (cache) |cache_dep| {
                        if (dep.eql(cache_dep)) {
                            dep_in_cache = true;
                            break;
                        }
                    }
                    if (dep_in_cache) {
                        continue;
                    }
                }

                fetch_and_build.step.dependOn(switch (dep) {
                    .git => |git_dep| &(try GitFetch.init(builder, deps_dir, git_dep)).step,
                });
                fetch_and_build.write_fetch_cache = true;
            }
        }

        return fetch_and_build;
    }

    fn make(step: *std.build.Step) !void {
        const fetch_and_build = @fieldParentPtr(FetchAndBuild, "step", step);
        const builder = fetch_and_build.builder;

        if (fetch_and_build.write_fetch_cache) {
            try writeFetchCache(builder, fetch_and_build.deps);
        }

        const args = try std.process.argsAlloc(builder.allocator);
        defer std.process.argsFree(builder.allocator, args);

        // TODO: this might be platform specific.
        // on windows, 5 args are prepended before the user defined args
        const build_args_offset = 5;

        var zig_build_args = std.ArrayList([]const u8).init(builder.allocator);
        defer zig_build_args.deinit();

        try zig_build_args.appendSlice(
            &.{ "zig", "build", "--build-file", fetch_and_build.build_file },
        );
        for (args[build_args_offset..]) |arg| {
            if (std.mem.startsWith(u8, arg, "-Dfetch-skip=")) {
                continue;
            }
            try zig_build_args.append(arg);
        }

        try runChildProcess(builder, builder.build_root, zig_build_args.items);
    }
};

fn getFetchCachePath(builder: *std.build.Builder) []const u8 {
    return builder.pathJoin(&.{ builder.build_root, builder.cache_root, "fetch_cache" });
}

fn readFetchCache(builder: *std.build.Builder) !?[]const Dependency {
    const cache_path = getFetchCachePath(builder);
    const cache_file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
    defer cache_file.close();
    const reader = cache_file.reader();

    var dependencies = std.ArrayList(Dependency).init(builder.allocator);
    var read_buf: [256]u8 = undefined;
    while (true) {
        const vcs_type = reader.readUntilDelimiter(&read_buf, '\n') catch |e| {
            if (e == error.EndOfStream) {
                break;
            } else {
                return e;
            }
        };

        if (std.mem.eql(u8, vcs_type, "git")) {
            const name = builder.dupe(try reader.readUntilDelimiter(&read_buf, '\n'));
            const url = builder.dupe(try reader.readUntilDelimiter(&read_buf, '\n'));
            const commit = builder.dupe(try reader.readUntilDelimiter(&read_buf, '\n'));

            try dependencies.append(.{ .git = .{ .name = name, .url = url, .commit = commit } });
        } else {
            return error.InvalidVcsType;
        }
    }

    return dependencies.toOwnedSlice();
}

fn writeFetchCache(builder: *std.build.Builder, deps: []const Dependency) !void {
    const cache_path = getFetchCachePath(builder);
    try std.fs.cwd().makePath(std.fs.path.dirname(cache_path) orelse unreachable);

    const cache_file = try std.fs.cwd().createFile(cache_path, .{});
    const writer = cache_file.writer();

    for (deps) |dep| {
        switch (dep) {
            .git => |git_dep| {
                try writer.print("git\n", .{});
                try writer.print("{s}\n", .{git_dep.name});
                try writer.print("{s}\n", .{git_dep.url});
                try writer.print("{s}\n", .{git_dep.commit});
            },
        }
    }
}

const GitFetch = struct {
    builder: *std.build.Builder,
    step: std.build.Step,
    dep: GitDependency,
    repo_dir: []const u8,

    pub fn init(
        builder: *std.build.Builder,
        deps_dir: []const u8,
        dep: GitDependency,
    ) !*GitFetch {
        var git_fetch = try builder.allocator.create(GitFetch);
        git_fetch.* = .{
            .builder = builder,
            .step = std.build.Step.init(.custom, "git fetch", builder.allocator, make),
            .dep = dep,
            .repo_dir = builder.pathJoin(&.{ builder.build_root, deps_dir, dep.name }),
        };
        return git_fetch;
    }

    pub fn make(step: *std.build.Step) !void {
        const git_fetch = @fieldParentPtr(GitFetch, "step", step);
        const builder = git_fetch.builder;

        std.fs.accessAbsolute(git_fetch.repo_dir, .{}) catch {
            const clone_args = &.{ "git", "clone", git_fetch.dep.url, git_fetch.repo_dir };
            try runChildProcess(builder, builder.build_root, clone_args);
        };

        const checkout_args = &.{ "git", "checkout", git_fetch.dep.commit };
        try runChildProcess(builder, git_fetch.repo_dir, checkout_args);
    }
};

fn runChildProcess(builder: *std.build.Builder, cwd: []const u8, args: []const []const u8) !void {
    var child_process = std.ChildProcess.init(args, builder.allocator);
    child_process.cwd = cwd;
    child_process.env_map = builder.env_map;
    child_process.stdin_behavior = .Ignore;

    if (builder.verbose) {
        var command = std.ArrayList(u8).init(builder.allocator);
        defer command.deinit();

        try command.appendSlice("RUNNING COMMAND:");
        for (args) |arg| {
            try command.append(' ');
            try command.appendSlice(arg);
        }

        std.log.info("{s}", .{command.items});
    }

    switch (try child_process.spawnAndWait()) {
        .Exited => |code| if (code != 0) {
            std.log.err("Command failed with exit code {}!", .{code});
            return error.RunChildProcessFailed;
        },
        else => |result| {
            std.log.err("Command failed with result {}!", .{result});
            return error.RunChildProcessFailed;
        },
    }
}
