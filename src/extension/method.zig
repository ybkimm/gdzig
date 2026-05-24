const std = @import("std");
const DeclEnum = std.meta.DeclEnum;

const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;

const gdzig = @import("gdzig");
const class = gdzig.class;
const classdb = gdzig.class.ClassDb;
const MethodFlags = gdzig.global.MethodFlags;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

const Registry = @import("Registry.zig");

/// Returns a pointer to a StringName for the given type.
/// For class pointer types, returns a lazily-initialized StringName with the class name.
/// For other types, returns &StringName.empty.
fn classNameForType(comptime T: type) *const StringName {
    if (comptime class.isClassPtr(T)) {
        const S = struct {
            var name: StringName = undefined;
            var init: bool = false;
        };
        if (!S.init) {
            S.name = StringName.fromType(std.meta.Child(T));
            S.init = true;
        }
        return &S.name;
    }
    return &StringName.empty;
}

/// Registers a method on a class.
///
/// Example:
/// ```
/// godot.registerMethod(MyClass, .decl(.myMethod));
/// ```
pub fn registerMethod(comptime Class: type, comptime config: MethodConfig(Class)) void {
    var class_name: StringName = .fromType(Class);
    var method_name: StringName = .fromComptimeLatin1(config.name);

    // Create runtime PropertyInfo with class_name set for class pointer types
    var return_value: ?classdb.PropertyInfo = if (config.return_value_info) |info| blk: {
        var info_mut = info.*;
        if (info_mut.type == .object) {
            info_mut.class_name = classNameForType(config.return_type);
        }
        break :blk info_mut;
    } else null;

    var arg_infos: [config.argument_info.len]classdb.PropertyInfo = undefined;
    inline for (0..config.argument_info.len) |i| {
        arg_infos[i] = config.argument_info[i];
        if (arg_infos[i].type == .object and config.argument_types.len > 0) {
            arg_infos[i].class_name = classNameForType(config.argument_types[i]);
        }
    }

    classdb.registerMethod(Class, void, &class_name, .{
        .name = &method_name,
        .flags = config.flags,
        .return_value_info = if (return_value) |*info| @constCast(info) else null,
        .return_value_metadata = config.return_value_metadata,
        .argument_info = &arg_infos,
        .argument_metadata = config.argument_metadata,
        .default_arguments = config.default_arguments,
    }, .{
        .call = config.call,
        .ptr_call = config.ptr_call,
    });
}

pub fn MethodConfig(comptime Class: type) type {
    return struct {
        name: [:0]const u8,
        return_type: type = void,
        flags: MethodFlags = .{},
        return_value_info: ?*classdb.PropertyInfo = null,
        return_value_metadata: classdb.MethodArgumentMetadata = .none,
        argument_info: []const classdb.PropertyInfo = &.{},
        argument_types: []const type = &.{},
        argument_metadata: []const classdb.MethodArgumentMetadata = &.{},
        default_arguments: []const *const Variant = &.{},
        call: ?classdb.Call(Class, void) = null,
        ptr_call: ?classdb.PtrCall(Class, void) = null,

        const Self = @This();

        /// Creates a MethodConfig from a method name and decl name.
        /// The name is what Godot sees (snake_case), decl_name is the Zig decl.
        pub fn fromName(comptime name: [:0]const u8, comptime decl_name: [:0]const u8, comptime options: Registry.Method(Class).CreateOptions) Self {
            const MethodType = @TypeOf(@field(Class, decl_name));
            const fn_info = @typeInfo(MethodType).@"fn";
            const Args = fn_info.params;
            const ReturnType = fn_info.return_type orelse void;
            const arg_count = Args.len - 1;

            const return_value: classdb.PropertyInfo = .{
                .type = .forType(ReturnType),
            };

            const arg_infos: [arg_count]classdb.PropertyInfo = comptime blk: {
                var infos: [arg_count]classdb.PropertyInfo = undefined;
                for (0..arg_count) |i| {
                    const ArgType = Args[i + 1].type.?;
                    infos[i] = .{ .type = .forType(ArgType) };
                }
                break :blk infos;
            };

            const arg_metas: [arg_count]classdb.MethodArgumentMetadata = comptime blk: {
                var metas: [arg_count]classdb.MethodArgumentMetadata = undefined;
                for (0..arg_count) |i| {
                    metas[i] = .none;
                }
                break :blk metas;
            };

            const arg_types: [arg_count]type = comptime blk: {
                var types: [arg_count]type = undefined;
                for (0..arg_count) |i| {
                    types[i] = Args[i + 1].type.?;
                }
                break :blk types;
            };

            const Callbacks = struct {
                const method = @field(Class, decl_name);

                fn call(instance: *Class, args: []const *const Variant) gdzig.CallError!Variant {
                    var call_args: std.meta.ArgsTuple(MethodType) = undefined;
                    call_args[0] = instance;
                    inline for (1..Args.len) |i| {
                        const ArgType = Args[i].type.?;
                        if (i - 1 < args.len) {
                            call_args[i] = args[i - 1].as(ArgType) orelse return error.InvalidArgument;
                        }
                    }
                    if (ReturnType == void) {
                        @call(.auto, method, call_args);
                        return Variant.nil;
                    } else {
                        const result = @call(.auto, method, call_args);
                        return Variant.init(ReturnType, result);
                    }
                }

                fn ptrCall(instance: *Class, args: [*]const *const anyopaque, ret: ?*anyopaque) void {
                    var call_args: std.meta.ArgsTuple(MethodType) = undefined;
                    call_args[0] = instance;
                    inline for (1..Args.len) |i| {
                        const ArgType = Args[i].type.?;
                        call_args[i] = ptrToArg(ArgType, args[i - 1]);
                    }
                    if (ReturnType == void) {
                        @call(.auto, method, call_args);
                        return;
                    }
                    const result = @call(.auto, method, call_args);
                    const r = ret orelse return;
                    retToPtr(ReturnType, result, r);
                }

                fn retToPtr(comptime RetType: type, value: RetType, r: *anyopaque) void {
                    if (comptime class.isClassPtr(RetType)) {
                        // For class pointer returns, the ptrcall ABI expects a raw engine Object
                        // pointer in the return slot, not the Zig struct pointer.
                        const obj: ?*gdzig.class.Object = if (@typeInfo(RetType) == .optional) blk: {
                            if (value) |v| {
                                if (comptime class.isRefCountedPtr(RetType)) {
                                    _ = gdzig.class.RefCounted.upcast(v).reference();
                                }
                                break :blk gdzig.class.Object.upcast(v);
                            }
                            break :blk null;
                        } else blk: {
                            if (comptime class.isRefCountedPtr(RetType)) {
                                _ = gdzig.class.RefCounted.upcast(value).reference();
                            }
                            break :blk gdzig.class.Object.upcast(value);
                        };
                        @as(*?*gdzig.class.Object, @ptrCast(@alignCast(r))).* = obj;
                        return;
                    }
                    @as(*RetType, @ptrCast(@alignCast(r))).* = value;
                }

                fn ptrToArg(comptime ArgType: type, p_arg: *const anyopaque) ArgType {
                    if (comptime class.isRefCountedPtr(ArgType) and class.isOpaqueClassPtr(ArgType)) {
                        const obj = gdzig.raw.refGetObject(@ptrCast(p_arg));
                        return @ptrCast(obj.?);
                    } else if (comptime class.isOpaqueClassPtr(ArgType)) {
                        return @ptrCast(@constCast(p_arg));
                    } else {
                        return @as(*const ArgType, @ptrCast(@alignCast(p_arg))).*;
                    }
                }
            };

            return .{
                .name = name,
                .return_type = ReturnType,
                .flags = options.flags,
                .return_value_info = if (ReturnType != void) @constCast(&return_value) else null,
                .argument_info = @constCast(&arg_infos),
                .argument_types = &arg_types,
                .argument_metadata = @constCast(&arg_metas),
                .default_arguments = options.default_arguments,
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }

        /// Creates a getter method for a class field.
        /// name: the method name Godot sees (e.g., "get_health")
        /// field_name: the Zig field name (e.g., "health")
        pub fn getter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const FieldType = @FieldType(Class, field_name);

            const return_value: classdb.PropertyInfo = .{ .type = .forType(FieldType) };

            const Callbacks = struct {
                fn call(instance: *Class, _: []const *const Variant) gdzig.CallError!Variant {
                    return Variant.init(FieldType, @field(instance, field_name));
                }

                fn ptrCall(instance: *Class, _: [*]const *const anyopaque, ret: ?*anyopaque) void {
                    if (ret) |r| {
                        @as(*FieldType, @ptrCast(@alignCast(r))).* = @field(instance, field_name);
                    }
                }
            };

            return .{
                .name = name,
                .return_type = FieldType,
                .return_value_info = @constCast(&return_value),
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }

        /// Creates a setter method for a class field.
        /// name: the method name Godot sees (e.g., "set_health")
        /// field_name: the Zig field name (e.g., "health")
        pub fn setter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const FieldType = @FieldType(Class, field_name);

            const arg_info: [1]classdb.PropertyInfo = .{.{ .type = .forType(FieldType) }};
            const arg_meta: [1]classdb.MethodArgumentMetadata = .{.none};

            const Callbacks = struct {
                fn call(instance: *Class, args: []const *const Variant) gdzig.CallError!Variant {
                    if (args.len < 1) return error.TooFewArguments;
                    const value = args[0].as(FieldType) orelse return error.InvalidArgument;
                    @field(instance, field_name) = value;
                    return Variant.nil;
                }

                fn ptrCall(instance: *Class, args: [*]const *const anyopaque, _: ?*anyopaque) void {
                    @field(instance, field_name) = @as(*const FieldType, @ptrCast(@alignCast(args[0]))).*;
                }
            };

            return .{
                .name = name,
                .argument_info = @constCast(&arg_info),
                .argument_metadata = @constCast(&arg_meta),
                .call = Callbacks.call,
                .ptr_call = Callbacks.ptrCall,
            };
        }
    };
}
