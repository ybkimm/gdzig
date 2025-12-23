//! Test coordinator that bridges the Zig build system and Godot processes.
//!
//! This executable:
//! 1. Speaks the std.zig.Server protocol with the build system (via stdin/stdout)
//! 2. Spawns Godot processes for each test folder
//! 3. Communicates with test harnesses via TCP using our protocol
//!
//! The coordinator maintains a mapping from global test indices to (folder, local_index) pairs.
//!
//! For standalone test execution without the build system, run Godot directly:
//! ```
//! godot --headless --quiet --path ./zig-out/test/classdb
//! ```
//! The test harness will automatically run all tests when GDZIG_TEST_PORT is not set.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ZigServer = std.zig.Server;
const ZigClient = std.zig.Client;

const log = std.log.scoped(.gdzig_testing);

/// Timeout for waiting for Godot to connect (in milliseconds)
const ACCEPT_TIMEOUT_MS = 30_000;

/// Runtime configuration from build-time options
const Config = struct {
    godot_exe: []const u8,
    test_folders: []const []const u8,
};

pub const std_options: std.Options = .{
    // Set gdzig_testing scope to .warn by default (silent)
    // To enable debug logging, set GDZIG_TEST_DEBUG=1 environment variable
    .log_scope_levels = &.{
        .{ .scope = .gdzig_testing, .level = .warn },
    },
};

/// Mapping from global test index to folder and local index
const TestMapping = struct {
    folder_index: u32,
    local_index: u32,
};

/// State for the test runner
const Runner = struct {
    allocator: Allocator,
    config: Config,
    server: ZigServer,
    test_mappings: std.ArrayList(TestMapping),
    string_bytes: std.ArrayList(u8),
    test_name_indices: std.ArrayList(u32),

    fn init(allocator: Allocator, config: Config, in: *Io.Reader, out: *Io.Writer) !Runner {
        const server = try ZigServer.init(.{
            .in = in,
            .out = out,
            .zig_version = builtin.zig_version_string,
        });

        return .{
            .allocator = allocator,
            .config = config,
            .server = server,
            .test_mappings = .empty,
            .string_bytes = .empty,
            .test_name_indices = .empty,
        };
    }

    fn deinit(self: *Runner) void {
        self.test_mappings.deinit(self.allocator);
        self.string_bytes.deinit(self.allocator);
        self.test_name_indices.deinit(self.allocator);
    }

    fn run(self: *Runner) !void {
        log.debug("runner started, waiting for messages from build system", .{});
        log.debug("test_folders: {d}", .{self.config.test_folders.len});
        for (self.config.test_folders) |folder| {
            log.debug("  folder: {s}", .{folder});
        }

        const server = &self.server;

        while (true) {
            log.debug("waiting for message...", .{});
            const header = server.receiveMessage() catch |err| {
                log.debug("receiveMessage error: {}", .{err});
                // End of input from build system
                if (err == error.EndOfStream) break;
                return err;
            };

            log.debug("received message tag: {} (raw={d}) bytes_len={d}", .{ header.tag, @intFromEnum(header.tag), header.bytes_len });

            switch (header.tag) {
                .exit => {
                    log.debug("exit requested", .{});
                    break;
                },
                .query_test_metadata => {
                    log.debug("query_test_metadata requested", .{});
                    try self.handleQueryTestMetadata();
                },
                .run_test => {
                    const index = try server.receiveBody_u32();
                    log.debug("run_test requested: index={d}", .{index});
                    try self.handleRunTest(index);
                },
                else => {
                    log.debug("unknown message, skipping {d} bytes", .{header.bytes_len});
                    // Unknown message, skip body
                    _ = try server.in.discard(Io.Limit.limited(header.bytes_len));
                },
            }
        }
        log.debug("runner finished", .{});
    }

    fn handleQueryTestMetadata(self: *Runner) !void {
        log.debug("handleQueryTestMetadata: starting", .{});
        // Clear previous state
        self.test_mappings.clearRetainingCapacity();
        self.string_bytes.clearRetainingCapacity();
        self.test_name_indices.clearRetainingCapacity();

        // Collect metadata from each test folder
        for (self.config.test_folders, 0..) |folder, folder_idx| {
            try self.collectFolderMetadata(folder, @intCast(folder_idx));
        }
        log.debug("handleQueryTestMetadata: collected {d} tests", .{self.test_name_indices.items.len});

        // Build expected_panic_msgs (all zeros - we don't use panic expectations)
        const expected_panic_msgs = try self.allocator.alloc(u32, self.test_name_indices.items.len);
        defer self.allocator.free(expected_panic_msgs);
        @memset(expected_panic_msgs, 0);

        // Send metadata to build system
        log.debug("handleQueryTestMetadata: sending {d} tests to build system", .{self.test_name_indices.items.len});

        try self.server.serveTestMetadata(.{
            .names = self.test_name_indices.items,
            .expected_panic_msgs = expected_panic_msgs,
            .string_bytes = self.string_bytes.items,
        });
        log.debug("handleQueryTestMetadata: sent metadata", .{});
    }

    fn collectFolderMetadata(self: *Runner, folder: []const u8, folder_idx: u32) !void {
        log.debug("collectFolderMetadata: folder={s} idx={d}", .{ folder, folder_idx });

        // Extract folder name for prefixing
        const folder_name = std.fs.path.basename(folder);
        log.debug("  folder_name={s}", .{folder_name});

        // Start TCP listener
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var listener = try address.listen(.{ .reuse_address = true });
        defer listener.stream.close();

        const port = listener.listen_address.getPort();
        log.debug("  listening on port {d}", .{port});

        // Spawn Godot
        log.debug("  spawning godot: {s}", .{self.config.godot_exe});
        var child = try self.spawnGodot(folder, port);
        defer {
            // Collect and log Godot output before waiting
            const output = self.collectGodotOutput(&child) catch "";
            defer if (output.len > 0) self.allocator.free(output);
            if (output.len > 0) {
                log.debug("  godot output:\n{s}", .{output});
            }
            _ = child.wait() catch {};
        }
        log.debug("  godot spawned, pid={d}", .{child.id});

        // Accept connection with timeout
        log.debug("  waiting for connection (timeout: {d}ms)...", .{ACCEPT_TIMEOUT_MS});
        var conn = acceptWithTimeout(&listener, ACCEPT_TIMEOUT_MS) catch |err| {
            if (err == error.Timeout) {
                log.debug("  timeout waiting for Godot to connect", .{});
                // Collect Godot output to help diagnose the issue
                const output = self.collectGodotOutput(&child) catch "";
                defer if (output.len > 0) self.allocator.free(output);
                if (output.len > 0) {
                    std.debug.print("Godot output (timed out):\n{s}\n", .{output});
                }
            }
            return err;
        };
        defer conn.stream.close();
        log.debug("  connection accepted!", .{});

        // Set up buffered I/O
        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = std.net.Stream.Reader.init(conn.stream, &read_buf);
        var writer = std.net.Stream.Writer.init(conn.stream, &write_buf);

        // Query test metadata
        log.debug("  sending query_test_metadata to extension...", .{});
        try protocol.writeMessage(&writer.interface, .query_test_metadata, &.{});
        log.debug("  sent query_test_metadata, waiting for response...", .{});

        // Read response
        var msg_buf: [65536]u8 = undefined;
        const msg = try protocol.readMessage(reader.interface(), &msg_buf);
        log.debug("  received response from extension, tag={}", .{msg.tag});

        if (msg.tag != .test_metadata) {
            return error.UnexpectedResponse;
        }

        // Parse test names and add to our mappings
        var iter = protocol.decodeTestMetadata(msg.payload);
        var local_idx: u32 = 0;
        while (iter.next()) |name| {
            // Record the string index before adding the prefixed name
            const string_idx: u32 = @intCast(self.string_bytes.items.len);
            try self.test_name_indices.append(self.allocator, string_idx);

            // Add prefixed name: "folder.test name\0"
            try self.string_bytes.appendSlice(self.allocator, folder_name);
            try self.string_bytes.append(self.allocator, '.');
            try self.string_bytes.appendSlice(self.allocator, name);
            try self.string_bytes.append(self.allocator, 0);

            // Record mapping
            try self.test_mappings.append(self.allocator, .{
                .folder_index = folder_idx,
                .local_index = local_idx,
            });

            local_idx += 1;
        }

        // Tell extension to exit
        try protocol.writeMessage(&writer.interface, .exit, &.{});
    }

    fn handleRunTest(self: *Runner, global_index: u32) !void {
        if (global_index >= self.test_mappings.items.len) {
            try self.server.serveTestResults(.{
                .index = global_index,
                .flags = .{ .fail = true, .skip = false, .leak = false, .fuzz = false },
            });
            return;
        }

        const mapping = self.test_mappings.items[global_index];
        const folder = self.config.test_folders[mapping.folder_index];

        // Start TCP listener
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var listener = try address.listen(.{ .reuse_address = true });
        defer listener.stream.close();

        const port = listener.listen_address.getPort();

        // Spawn Godot
        var child = try self.spawnGodot(folder, port);
        errdefer {
            _ = child.wait() catch {};
        }

        // Accept connection with timeout
        var conn = acceptWithTimeout(&listener, ACCEPT_TIMEOUT_MS) catch |err| {
            if (err == error.Timeout) {
                // Collect Godot output to help diagnose the issue
                const output = self.collectGodotOutput(&child) catch "";
                defer if (output.len > 0) self.allocator.free(output);
                if (output.len > 0) {
                    std.debug.print("Godot output (timed out):\n{s}\n", .{output});
                }
            }
            return err;
        };
        defer conn.stream.close();

        // Set up buffered I/O
        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = std.net.Stream.Reader.init(conn.stream, &read_buf);
        var writer = std.net.Stream.Writer.init(conn.stream, &write_buf);

        // Send run_test command
        const run_payload = protocol.encodeRunTest(mapping.local_index);
        try protocol.writeMessage(&writer.interface, .run_test, &run_payload);

        // Read result
        var msg_buf: [65536]u8 = undefined;
        const msg = try protocol.readMessage(reader.interface(), &msg_buf);

        var failed = false;
        if (msg.tag != .test_result) {
            failed = true;
        } else {
            const result = protocol.decodeTestResult(msg.payload);
            failed = !result.passed;
        }

        // Tell extension to exit
        try protocol.writeMessage(&writer.interface, .exit, &.{});

        // Collect Godot output (contains stack traces on failure)
        const output = self.collectGodotOutput(&child) catch "";
        defer if (output.len > 0) self.allocator.free(output);

        // Wait for child to exit
        _ = child.wait() catch {};

        // If test failed, print Godot's output to stderr so user sees stack trace
        if (failed and output.len > 0) {
            std.fs.File.stderr().writeAll(output) catch {};
        }

        log.debug("godot output:\n{s}", .{output});

        // Send result to build system
        try self.server.serveTestResults(.{
            .index = global_index,
            .flags = .{
                .fail = failed,
                .skip = false,
                .leak = false,
                .fuzz = false,
            },
        });
    }

    /// Collect any remaining output from a Godot child process
    fn collectGodotOutput(self: *Runner, child: *std.process.Child) ![]const u8 {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(self.allocator);

        // Read stdout
        if (child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stdout.read(&buf) catch break;
                if (n == 0) break;
                try output.appendSlice(self.allocator, buf[0..n]);
            }
        }

        // Read stderr
        if (child.stderr) |stderr| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stderr.read(&buf) catch break;
                if (n == 0) break;
                try output.appendSlice(self.allocator, buf[0..n]);
            }
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn spawnGodot(self: *Runner, folder: []const u8, port: u16) !std.process.Child {
        // Format port as string (must be heap-allocated to outlive this function)
        const port_str = std.fmt.allocPrint(self.allocator, "{d}", .{port}) catch unreachable;
        defer self.allocator.free(port_str);

        // Copy existing environment and add our port
        var env_map = std.process.getEnvMap(self.allocator) catch return error.EnvironmentError;
        defer env_map.deinit();

        try env_map.put("GDZIG_TEST_PORT", port_str);

        var child = std.process.Child.init(
            &.{ self.config.godot_exe, "--headless", "--quiet", "--path", folder, "--quit-after", "60" },
            self.allocator,
        );
        child.env_map = &env_map;
        // CRITICAL: Don't let Godot's stdout/stderr pollute our protocol stream
        // Capture them so we can display on test failure
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        return child;
    }
};

/// Accept a connection with a timeout using poll.
/// Returns error.Timeout if no connection is received within the timeout period.
fn acceptWithTimeout(listener: *std.net.Server, timeout_ms: i32) !std.net.Server.Connection {
    // Use platform-appropriate poll types
    const native_os = builtin.os.tag;
    if (native_os == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        var pollfds = [_]ws2_32.pollfd{
            .{
                .fd = listener.stream.handle,
                .events = ws2_32.POLL.RDNORM, // POLLRDNORM for incoming connections on Windows
                .revents = 0,
            },
        };

        const result = std.os.windows.poll(&pollfds, 1, timeout_ms);
        if (result == ws2_32.SOCKET_ERROR) {
            log.debug("WSAPoll error: {}", .{ws2_32.WSAGetLastError()});
            return error.Unexpected;
        }

        if (result == 0) {
            return error.Timeout;
        }

        if (pollfds[0].revents & ws2_32.POLL.RDNORM != 0) {
            return listener.accept();
        }

        return error.Unexpected;
    } else {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = listener.stream.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const result = posix.poll(&pollfds, timeout_ms) catch |err| {
            log.debug("poll error: {}", .{err});
            return err;
        };

        if (result == 0) {
            return error.Timeout;
        }

        if (pollfds[0].revents & posix.POLL.IN != 0) {
            return listener.accept();
        }

        return error.Unexpected;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use build-time options
    const options = @import("runner_options");
    const config: Config = .{
        .godot_exe = options.godot_exe,
        .test_folders = options.test_folders,
    };

    log.debug("config: godot_exe={s}, folders={d}", .{
        config.godot_exe,
        config.test_folders.len,
    });

    // Communicate with build system via stdin/stdout
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin_reader = std.fs.File.Reader.initStreaming(std.fs.File.stdin(), &stdin_buf);
    var stdout_writer = std.fs.File.Writer.initStreaming(std.fs.File.stdout(), &stdout_buf);

    var runner = try Runner.init(allocator, config, &stdin_reader.interface, &stdout_writer.interface);
    defer runner.deinit();
    log.debug("runner initialized", .{});

    try runner.run();
}
