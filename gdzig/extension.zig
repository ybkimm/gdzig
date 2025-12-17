pub fn registerExtension(comptime T: type, comptime opt: ExtensionOptions) void {
    const Cache = struct {
        var state: T = undefined;
    };

    @export(&struct {
        fn entrypoint(
            p_get_proc_address: c.GDExtensionInterfaceGetProcAddress,
            p_library: c.GDExtensionClassLibraryPtr,
            r_initialization: [*c]c.GDExtensionInitialization,
        ) callconv(.c) c.GDExtensionBool {
            gdzig.raw = .init(p_get_proc_address.?, p_library.?);
            gdzig.raw.getGodotVersion(@ptrCast(&gdzig.version));

            Cache.state = init() catch |err| {
                std.log.err("Failed to initialize extension: {}", .{err});
                return @intFromBool(false);
            };

            r_initialization.*.userdata = @ptrCast(&Cache.state);
            r_initialization.*.initialize = @ptrCast(&enter);
            r_initialization.*.deinitialize = @ptrCast(&exit);
            r_initialization.*.minimum_initialization_level = @intFromEnum(opt.minimum_initialization_level);

            return @intFromBool(true);
        }

        fn init() anyerror!T {
            if (@hasDecl(T, "init")) {
                const return_type = @typeInfo(@TypeOf(T.init)).@"fn".return_type.?;
                return if (@typeInfo(return_type) == .error_union)
                    T.init()
                else
                    T.init();
            } else {
                comptime assertDefaultInitializable();
                return .{};
            }
        }

        fn enter(userdata: ?*anyopaque, p_level: c.GDExtensionInitializationLevel) callconv(.c) void {
            const self: *T = @ptrCast(@alignCast(userdata.?));
            const level: InitializationLevel = @enumFromInt(p_level);

            if (@hasDecl(T, "enter")) {
                self.enter(level);
            }
        }

        fn exit(userdata: ?*anyopaque, p_level: c.GDExtensionInitializationLevel) callconv(.c) void {
            const self: *T = @ptrCast(@alignCast(userdata.?));
            const level: InitializationLevel = @enumFromInt(p_level);

            if (@hasDecl(T, "exit")) {
                self.exit(level);
            }

            if (level == opt.minimum_initialization_level) {
                PropertyListInstanceBinding.cleanup();
                DestroyInstanceBinding.cleanup();
                if (@hasDecl(T, "destroy")) self.destroy();
            }
        }

        fn assertDefaultInitializable() void {
            const info = @typeInfo(T);

            if (info != .@"struct") @compileError(@typeName(T) ++ " is not a struct, and cannot be default-initialized. It must have an initializer function.");

            comptime var missing: []const u8 = "";
            for (info.@"struct".fields) |field| {
                if (field.default_value_ptr == null) {
                    missing = missing ++ if (missing.len > 0) ", " else "";
                    missing = missing ++ "'" ++ field.name ++ "'";
                }
            }

            if (missing.len > 0) {
                @compileError("Cannot default-initialize '" ++ @typeName(T) ++ "' because field(s) " ++ missing ++ " are missing default values. Either provide default values for all fields, or implement 'pub fn init() " ++ @typeName(T) ++ " {}'.");
            }
        }
    }.entrypoint, .{
        .name = opt.entry_symbol,
        .linkage = .strong,
    });
}

pub const ExtensionOptions = struct {
    entry_symbol: []const u8,
    minimum_initialization_level: InitializationLevel = .core,
};

pub const InitializationLevel = enum(c_int) {
    core = 0,
    servers = 1,
    scene = 2,
    editor = 3,
};

const std = @import("std");

const c = @import("gdextension");
const gdzig = @import("gdzig");

const class = @import("extension/class.zig");
pub const registerClass = class.registerClass;
pub const ClassUserdataOf = class.ClassUserdataOf;
pub const DestroyInstanceBinding = class.DestroyInstanceBinding;
pub const PropertyListInstanceBinding = class.PropertyListInstanceBinding;
const method = @import("extension/method.zig");
pub const registerMethod = method.registerMethod;
const signal = @import("extension/signal.zig");
pub const registerSignal = signal.registerSignal;
