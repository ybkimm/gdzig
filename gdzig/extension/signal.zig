const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;
const gdzig = @import("gdzig");
const classdb = gdzig.class.ClassDb;
const StringName = gdzig.builtin.StringName;

const meta = @import("../meta.zig");

pub fn registerSignal(comptime T: type, comptime S: type) void {
    const class_name: StringName = .fromComptimeLatin1(meta.typeShortName(T));
    const signal_name: StringName = .fromComptimeLatin1(casez.comptimeConvert(godot_case.signal, meta.typeShortName(S)));

    const fields = @typeInfo(S).@"struct".fields;
    var arg_info: [fields.len]classdb.PropertyInfo = undefined;
    var names: [fields.len]StringName = undefined;
    inline for (fields, 0..) |field, i| {
        names[i] = .fromComptimeLatin1(field.name);
        arg_info[i] = .{
            .type = .forType(field.type),
            .name = &names[i],
        };
    }

    classdb.registerSignal(&class_name, &signal_name, &arg_info);
}
