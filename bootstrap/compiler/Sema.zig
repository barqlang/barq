//! Semantic Analyzer.
//!
//! An analyzer that lowers down `Sir` to `Air` while checking if the instructions and the types are valid.

const std = @import("std");
const root = @import("root");

const Sir = @import("Sir.zig");
const Name = Sir.Name;
const SourceLoc = Sir.SourceLoc;
const Compilation = @import("Compilation.zig");
const Air = @import("Air.zig");
const Symbol = @import("Symbol.zig");
const Scope = Symbol.Scope;
const Type = Symbol.Type;

const Sema = @This();

allocator: std.mem.Allocator,

compilation: *Compilation,

module: *Compilation.Module,
module_id: u32,

air: *Air,
air_instructions: *std.ArrayListUnmanaged(Air.Instruction) = undefined,

lazy_units: *LazyUnits,

stack: std.ArrayListUnmanaged(Value) = .{},

allocated_scopes: std.ArrayListUnmanaged(Scope(Variable)) = .{},
current_scope: *Scope(Variable),

function_type: Type = undefined,

error_info: ?ErrorInfo = null,

pub const ErrorInfo = struct {
    message: []const u8,
    source_loc: SourceLoc,
};

pub const Error = error{ WithMessage, WithoutMessage } || std.mem.Allocator.Error;

pub const LazyUnits = std.StringHashMapUnmanaged(LazyUnit);

pub const LazyUnit = struct {
    tag: Tag,
    owner: u32,
    sir_definition: Sir.Definition,

    const Tag = enum {
        function,
        global_variable,
        global_constant,
        external_declaration,
    };
};

const Value = union(enum) {
    string: []const u8,
    int: i128,
    float: f64,
    boolean: bool,
    module: u32,
    runtime: Type,

    fn getType(self: Value) Type {
        return switch (self) {
            .string => |string| Type.string(string.len + 1), // +1 for the null termination
            .int => |int| Type.intFittingRange(int, int),
            .float => |float| Type.floatFittingRange(float, float),
            .boolean => .bool,
            .module => .module,
            .runtime => |runtime| runtime,
        };
    }

    pub fn format(self: Value, _: anytype, _: anytype, writer: anytype) !void {
        switch (self) {
            .string => |string| try writer.print("\"{s}\"", .{string}),
            .int => |int| try writer.print("{}", .{int}),
            .float => |float| try writer.print("{d}", .{float}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .module => try writer.writeAll("<module>"),
            .runtime => |runtime| try writer.print("<runtime value '{}'>", .{runtime}),
        }
    }
};

pub const Variable = struct {
    is_const: bool = false,
    is_type_alias: bool = false,
    air_name: []const u8 = undefined,
    type: Type,
    maybe_comptime_value: ?Value = null,
};

pub fn init(
    allocator: std.mem.Allocator,
    compilation: *Compilation,
    module_id: u32,
    air: *Air,
    lazy_units: *LazyUnits,
) Error!Sema {
    const module = &compilation.modules.values()[module_id];

    var sema: Sema = .{
        .allocator = allocator,
        .compilation = compilation,
        .module = module,
        .module_id = module_id,
        .air = air,
        .lazy_units = lazy_units,
        .current_scope = &module.scope,
    };

    try sema.putBuiltinConstants();

    return sema;
}

pub fn deinit(self: *Sema) void {
    self.stack.deinit(self.allocator);
    self.allocated_scopes.deinit(self.allocator);
}

fn putBuiltinConstants(self: *Sema) std.mem.Allocator.Error!void {
    try self.current_scope.ensureTotalCapacity(self.allocator, 256);

    {
        inline for (.{ "void", "bool" }, .{ .void, .bool }) |name, @"type"| {
            self.current_scope.putAssumeCapacity(name, .{
                .type = @"type",
                .is_type_alias = true,
            });
        }
    }

    {
        const c_char_bits = self.compilation.env.target.cTypeBitSize(.char);
        const c_short_bits = self.compilation.env.target.cTypeBitSize(.short);
        const c_ushort_bits = self.compilation.env.target.cTypeBitSize(.ushort);
        const c_int_bits = self.compilation.env.target.cTypeBitSize(.int);
        const c_uint_bits = self.compilation.env.target.cTypeBitSize(.uint);
        const c_long_bits = self.compilation.env.target.cTypeBitSize(.long);
        const c_ulong_bits = self.compilation.env.target.cTypeBitSize(.ulong);
        const c_longlong_bits = self.compilation.env.target.cTypeBitSize(.longlong);
        const c_ulonglong_bits = self.compilation.env.target.cTypeBitSize(.ulonglong);
        const ptr_bits = self.compilation.env.target.ptrBitWidth();

        self.current_scope.putAssumeCapacity("c_char", .{
            .type = .{
                .int = .{
                    .signedness = if (self.compilation.env.target.charSignedness() == .signed) .signed else .unsigned,
                    .bits = c_char_bits,
                },
            },

            .is_type_alias = true,
        });

        inline for (.{ "c_uchar", "c_ushort", "c_uint", "c_ulong", "c_ulonglong", "usize" }, .{ c_char_bits, c_ushort_bits, c_uint_bits, c_ulong_bits, c_ulonglong_bits, ptr_bits }) |name, bits| {
            self.current_scope.putAssumeCapacity(name, .{
                .type = .{ .int = .{ .signedness = .unsigned, .bits = @intCast(bits) } },

                .is_type_alias = true,
            });
        }

        inline for (.{ "c_schar", "c_short", "c_int", "c_long", "c_longlong", "ssize" }, .{ c_char_bits, c_short_bits, c_int_bits, c_long_bits, c_longlong_bits, ptr_bits }) |name, bits| {
            self.current_scope.putAssumeCapacity(name, .{
                .type = .{ .int = .{ .signedness = .signed, .bits = @intCast(bits) } },

                .is_type_alias = true,
            });
        }
    }

    // TODO: Find a better way, this is very verbose and doesn't scale well for bigger arbitrary sized integer types
    {
        const unsigned_int_names = [_][]const u8{ "u0", "u1", "u2", "u3", "u4", "u5", "u6", "u7", "u8", "u9", "u10", "u11", "u12", "u13", "u14", "u15", "u16", "u17", "u18", "u19", "u20", "u21", "u22", "u23", "u24", "u25", "u26", "u27", "u28", "u29", "u30", "u31", "u32", "u33", "u34", "u35", "u36", "u37", "u38", "u39", "u40", "u41", "u42", "u43", "u44", "u45", "u46", "u47", "u48", "u49", "u50", "u51", "u52", "u53", "u54", "u55", "u56", "u57", "u58", "u59", "u60", "u61", "u62", "u63", "u64" };

        for (unsigned_int_names, 0..) |name, bits| {
            self.current_scope.putAssumeCapacity(name, .{
                .type = .{ .int = .{ .signedness = .unsigned, .bits = @intCast(bits) } },

                .is_type_alias = true,
            });
        }

        const signed_int_names = [_][]const u8{ "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16", "s17", "s18", "s19", "s20", "s21", "s22", "s23", "s24", "s25", "s26", "s27", "s28", "s29", "s30", "s31", "s32", "s33", "s34", "s35", "s36", "s37", "s38", "s39", "s40", "s41", "s42", "s43", "s44", "s45", "s46", "s47", "s48", "s49", "s50", "s51", "s52", "s53", "s54", "s55", "s56", "s57", "s58", "s59", "s60", "s61", "s62", "s63", "s64" };

        for (signed_int_names, 0..) |name, bits| {
            self.current_scope.putAssumeCapacity(name, .{
                .type = .{ .int = .{ .signedness = .signed, .bits = @intCast(bits) } },

                .is_type_alias = true,
            });
        }
    }

    {
        const c_float_bits = self.compilation.env.target.cTypeBitSize(.float);
        const c_double_bits = self.compilation.env.target.cTypeBitSize(.double);
        // TODO: Type `c_longdouble` requires `f80` and `f128` to be supported.

        inline for (.{ "f16", "f32", "f64", "c_float", "c_double" }, .{ 16, 32, 64, c_float_bits, c_double_bits }) |float_type, i| {
            self.current_scope.putAssumeCapacity(float_type, .{
                .type = .{ .float = .{ .bits = @intCast(i) } },

                .is_type_alias = true,
            });
        }
    }

    {
        const builtin_target_os = @intFromEnum(self.compilation.env.target.os.tag);
        const builtin_target_arch = @intFromEnum(self.compilation.env.target.cpu.arch);
        const builtin_target_abi = @intFromEnum(self.compilation.env.target.abi);

        inline for (.{ "builtin::target::os", "builtin::target::arch", "builtin::target::abi" }, .{ builtin_target_os, builtin_target_arch, builtin_target_abi }) |builtin_name, builtin_value| {
            self.current_scope.putAssumeCapacity(builtin_name, .{
                .type = Type.intFittingRange(builtin_value, builtin_value),

                .maybe_comptime_value = .{ .int = builtin_value },
                .is_const = true,
            });
        }
    }

    {
        inline for (.{ "true", "false" }, .{ true, false }) |boolean_name, boolean_value| {
            self.current_scope.putAssumeCapacity(boolean_name, .{
                .type = .bool,

                .maybe_comptime_value = .{ .boolean = boolean_value },
                .is_const = true,
            });
        }
    }
}

pub fn analyze(self: *Sema) Error!void {
    try self.air.global_assembly.appendSlice(self.allocator, self.module.sir.global_assembly.items);

    try self.analyzeGlobalConstants();
    try self.analyzeTypeAliases();
    try self.analyzeExternals();
    try self.analyzeGlobalVariables();
    try self.analyzeFunctions();
}

fn analyzeSubTypeOrTypeAlias(self: *Sema, subtype: Sir.SubType) Error!Type {
    switch (subtype) {
        .name => |name| {
            if (self.current_scope.getPtr(name.buffer)) |variable| {
                if (variable.is_type_alias) {
                    if (variable.type == .void)
                        if (self.module.sir.type_aliases.get(subtype.name.buffer)) |type_alias| {
                            variable.type = try self.analyzeTypeAlias(type_alias);
                        };

                    return variable.type;
                }
            }

            try self.reportTypeNotDeclared(name);
        },

        else => return self.analyzeSubType(subtype),
    }
}

fn analyzeTypeAlias(self: *Sema, type_alias: Sir.SubSymbol) Error!Type {
    switch (type_alias.subtype) {
        .pure => |pure| return pure,

        .name => |name| {
            if (self.current_scope.getPtr(name.buffer)) |other_variable| {
                if (other_variable.is_type_alias) {
                    if (other_variable.type == .void)
                        if (self.module.sir.type_aliases.get(name.buffer)) |other_type_alias| {
                            other_variable.type = try self.analyzeTypeAlias(other_type_alias);
                        };

                    const this_variable = self.current_scope.getPtr(type_alias.name.buffer).?;

                    this_variable.maybe_comptime_value = other_variable.maybe_comptime_value;

                    return other_variable.type;
                }
            }

            try self.reportTypeNotDeclared(name);
        },

        .chained_names => |names| {
            const previous_air_instructions = self.air_instructions;
            var air_instructions: @FieldType(Air.Definition, "instructions") = .{};
            self.air_instructions = &air_instructions;
            defer self.air_instructions = previous_air_instructions;

            try self.analyzeGet(null, names[0]);

            for (names[1 .. names.len - 1]) |name| {
                try self.analyzeGetField(name);
            }

            const last_name = names[names.len - 1];

            if (self.stack.getLast() == .module) {
                const module_id = self.stack.pop().module;

                if (self.compilation.modules.values()[module_id].scope.get(last_name.buffer)) |module_variable| {
                    if (!module_variable.is_type_alias) {
                        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

                        try error_message_buf.writer(self.allocator).print("'{s}' is not a type", .{last_name.buffer});

                        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, last_name.token_start) };

                        return error.WithMessage;
                    }

                    const this_variable = self.current_scope.getPtr(type_alias.name.buffer).?;

                    this_variable.maybe_comptime_value = module_variable.maybe_comptime_value;

                    return module_variable.type;
                }
            }

            var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

            try error_message_buf.writer(self.allocator).print("'{s}' is not a field in '{}'", .{ last_name.buffer, self.stack.getLast() });

            self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, last_name.token_start) };

            return error.WithMessage;
        },

        .array, .pointer => return self.analyzeSubType(type_alias.subtype),

        .function => |function| {
            const parameter_types = try self.allocator.alloc(Type, function.parameter_subtypes.len);

            for (function.parameter_subtypes, 0..) |parameter_subtype, i| {
                parameter_types[i] = try self.analyzeSubTypeOrTypeAlias(parameter_subtype);
            }

            const return_type = try self.analyzeSubTypeOrTypeAlias(function.return_subtype.*);

            const return_type_on_heap = try self.allocator.create(Type);
            return_type_on_heap.* = return_type;

            return Type{
                .function = .{
                    .parameter_types = parameter_types,
                    .is_var_args = function.is_var_args,
                    .return_type = return_type_on_heap,
                },
            };
        },

        .@"struct" => |@"struct"| {
            var fields = try self.allocator.alloc(Type.Struct.Field, @"struct".subsymbols.len);

            for (@"struct".subsymbols, 0..) |subsymbol, i| {
                fields[i] = .{ .name = subsymbol.name.buffer, .type = try self.analyzeSubTypeOrTypeAlias(subsymbol.subtype) };
            }

            return Type{ .@"struct" = .{ .fields = fields } };
        },

        .@"enum" => |@"enum"| {
            const enum_type = try self.analyzeSubTypeOrTypeAlias(@"enum".subtype.*);

            try self.checkIntType(enum_type, @"enum".token_start);

            var enum_fields: Scope(Variable) = .{};

            try enum_fields.ensureTotalCapacity(self.allocator, @intCast(@"enum".fields.len));

            std.debug.assert(self.current_scope.maybe_parent == null);

            const this_variable = self.current_scope.getPtr(type_alias.name.buffer).?;

            const enum_module_name = this_variable.air_name;

            for (@"enum".fields) |field| {
                const enum_field_value: Value = .{ .int = field.value };

                try self.checkUnaryImplicitCast(enum_field_value, enum_type, field.name.token_start);

                enum_fields.putAssumeCapacity(field.name.buffer, .{
                    .air_name = enum_module_name,
                    .type = enum_type,
                    .maybe_comptime_value = enum_field_value,
                });
            }

            const enum_module_id: u32 = @intCast((try self.compilation.modules.getOrPutValue(
                self.allocator,
                enum_module_name,
                .{
                    .file = .{ .path = enum_module_name, .buffer = undefined },
                    .sir = undefined,
                    .scope = enum_fields,
                },
            )).index);

            // `getOrPutValue` may invalidate our module pointer
            self.module = &self.compilation.modules.values()[self.module_id];
            self.current_scope = &self.module.scope;

            this_variable.maybe_comptime_value = .{ .module = enum_module_id };

            return enum_type;
        },
    }
}

fn analyzeTypeAliases(self: *Sema) Error!void {
    var type_alias_circular_targets: std.ArrayListUnmanaged(Name) = .{};

    try type_alias_circular_targets.ensureTotalCapacity(self.allocator, self.module.sir.type_aliases.count());

    for (self.module.sir.type_aliases.values()) |type_alias| {
        if (self.current_scope.get(type_alias.name.buffer) != null) try self.reportRedeclaration(type_alias.name);

        type_alias_circular_targets.appendAssumeCapacity(type_alias.name);

        try self.checkTypeAliasCircular(&type_alias_circular_targets, type_alias.subtype);

        _ = type_alias_circular_targets.pop();

        try self.current_scope.put(self.allocator, type_alias.name.buffer, .{
            .air_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.module.file.path, type_alias.name.buffer }),
            .type = .void,
            .is_type_alias = true,
        });
    }

    type_alias_circular_targets.deinit(self.allocator);

    for (self.module.sir.type_aliases.values()) |type_alias| {
        const variable = self.current_scope.getPtr(type_alias.name.buffer).?;

        if (variable.type == .void) {
            variable.type = try self.analyzeTypeAlias(type_alias);
        }
    }
}

fn analyzeExternals(self: *Sema) Error!void {
    try self.lazy_units.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.external_declarations.items.len));
    try self.current_scope.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.external_declarations.items.len));

    for (self.module.sir.external_declarations.items) |external| {
        if (self.current_scope.get(external.name.buffer) != null) try self.reportRedeclaration(external.name);

        const symbol = try self.analyzeSubSymbol(external);

        self.lazy_units.putAssumeCapacity(
            external.name.buffer,
            .{
                .tag = .external_declaration,
                .owner = self.module_id,
                .sir_definition = .{
                    .subsymbol = external,
                    .exported = true,
                },
            },
        );

        self.current_scope.putAssumeCapacity(
            external.name.buffer,
            .{
                .air_name = external.name.buffer,
                .type = symbol.type,
            },
        );
    }
}

fn analyzeGlobalConstant(self: *Sema, variable: *Variable, sir_definition: Sir.Definition) Error!void {
    if (variable.maybe_comptime_value != null) return;

    const previous_air_instructions = self.air_instructions;
    var air_instructions: @FieldType(Air.Definition, "instructions") = .{};
    self.air_instructions = &air_instructions;
    defer self.air_instructions = previous_air_instructions;

    for (sir_definition.instructions.items) |sir_instruction| {
        try self.analyzeInstruction(sir_instruction);
    }

    const value = self.stack.pop();

    if (value == .runtime) {
        self.error_info = .{ .message = "expected the constant value to be compile time known", .source_loc = SourceLoc.find(self.module.file.buffer, sir_definition.subsymbol.name.token_start) };

        return error.WithMessage;
    }

    variable.type = value.getType();
    variable.maybe_comptime_value = value;
}

fn analyzeGlobalConstants(self: *Sema) Error!void {
    try self.lazy_units.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.global_constants.count()));
    try self.current_scope.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.global_constants.count()));

    for (self.module.sir.global_constants.values()) |sir_definition| {
        if (self.current_scope.get(sir_definition.subsymbol.name.buffer) != null) try self.reportRedeclaration(sir_definition.subsymbol.name);

        const symbol = try self.analyzeSubSymbol(sir_definition.subsymbol);

        const air_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.module.file.path, symbol.name.buffer });

        self.lazy_units.putAssumeCapacity(air_name, .{
            .tag = .global_constant,
            .owner = self.module_id,
            .sir_definition = sir_definition,
        });

        self.current_scope.putAssumeCapacity(
            symbol.name.buffer,
            .{
                .is_const = true,
                .air_name = air_name,
                .type = .void,
            },
        );
    }
}

fn analyzeGlobalVariable(self: *Sema, variable: *Variable, sir_definition: Sir.Definition) Error!void {
    if (self.air.global_variables.get(variable.air_name) != null) return;

    const previous_air_instructions = self.air_instructions;
    var air_instructions: @FieldType(Air.Definition, "instructions") = .{};
    self.air_instructions = &air_instructions;
    defer self.air_instructions = previous_air_instructions;

    for (sir_definition.instructions.items) |sir_instruction| {
        try self.analyzeInstruction(sir_instruction);
    }

    if (self.stack.popOrNull()) |last_value| {
        if (last_value == .runtime) {
            self.error_info = .{
                .message = "expected the global variable initializer to be compile time known",
                .source_loc = SourceLoc.find(self.module.file.buffer, sir_definition.subsymbol.name.token_start),
            };

            return error.WithMessage;
        }

        if (sir_definition.subsymbol.subtype == .pure and sir_definition.subsymbol.subtype.pure == .void) {
            variable.type = last_value.getType();
        } else {
            try self.checkUnaryImplicitCast(last_value, variable.type, sir_definition.subsymbol.name.token_start);
        }
    }

    switch (variable.type) {
        .void => {
            self.error_info = .{
                .message = "cannot declare a variable with type 'void'",
                .source_loc = SourceLoc.find(self.module.file.buffer, sir_definition.subsymbol.name.token_start),
            };

            return error.WithMessage;
        },

        .module => {
            self.error_info = .{
                .message = "cannot declare a variable with type 'module'",
                .source_loc = SourceLoc.find(self.module.file.buffer, sir_definition.subsymbol.name.token_start),
            };

            return error.WithMessage;
        },

        else => {},
    }

    try self.air.global_variables.put(
        self.allocator,
        variable.air_name,
        .{
            .symbol = .{
                .type = variable.type,
                .name = .{ .buffer = variable.air_name, .token_start = sir_definition.subsymbol.name.token_start },
            },
            .exported = sir_definition.exported,
            .instructions = air_instructions,
        },
    );
}

fn analyzeGlobalVariables(self: *Sema) Error!void {
    try self.lazy_units.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.global_variables.count()));
    try self.current_scope.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.global_variables.count()));

    for (self.module.sir.global_variables.values()) |sir_definition| {
        if (self.current_scope.get(sir_definition.subsymbol.name.buffer) != null) try self.reportRedeclaration(sir_definition.subsymbol.name);

        const symbol = try self.analyzeSubSymbol(sir_definition.subsymbol);

        const air_name = if (!sir_definition.exported)
            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.module.file.path, symbol.name.buffer })
        else
            symbol.name.buffer;

        self.lazy_units.putAssumeCapacity(air_name, .{
            .tag = .global_variable,
            .owner = self.module_id,
            .sir_definition = sir_definition,
        });

        self.current_scope.putAssumeCapacity(
            symbol.name.buffer,
            .{
                .air_name = air_name,
                .type = symbol.type,
            },
        );
    }
}

fn analyzeFunction(self: *Sema, variable: Variable, sir_definition: Sir.Definition) Error!void {
    if (self.air.functions.get(variable.air_name) != null) return;

    const previous_function_type = self.function_type;
    self.function_type = variable.type;
    defer self.function_type = previous_function_type;

    const previous_air_instructions = self.air_instructions;
    var air_instructions: @FieldType(Air.Definition, "instructions") = .{};
    self.air_instructions = &air_instructions;
    defer self.air_instructions = previous_air_instructions;

    const previous_scope = self.current_scope;
    while (self.current_scope.maybe_parent) |parent| self.current_scope = parent;
    defer self.current_scope = previous_scope;

    // To allow recursive functions we have to remove the current function from the lazy units
    _ = self.lazy_units.remove(variable.air_name);

    for (sir_definition.instructions.items) |sir_instruction| {
        try self.analyzeInstruction(sir_instruction);
    }

    try self.air.functions.put(
        self.allocator,
        variable.air_name,
        .{
            .symbol = .{
                .name = .{ .buffer = variable.air_name, .token_start = sir_definition.subsymbol.name.token_start },
                .type = variable.type,
            },
            .exported = sir_definition.exported,
            .instructions = air_instructions,
        },
    );
}

fn analyzeFunctions(self: *Sema) Error!void {
    var max_scope_depth: usize = 0;

    try self.lazy_units.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.functions.count()));
    try self.current_scope.ensureUnusedCapacity(self.allocator, @intCast(self.module.sir.functions.count()));

    for (self.module.sir.functions.values()) |sir_definition| {
        if (self.current_scope.get(sir_definition.subsymbol.name.buffer) != null) try self.reportRedeclaration(sir_definition.subsymbol.name);

        const symbol = try self.analyzeSubSymbol(sir_definition.subsymbol);

        var scope_depth: usize = 0;

        for (sir_definition.instructions.items) |air_instruction| {
            switch (air_instruction) {
                .start_scope => {
                    scope_depth += 1;
                    max_scope_depth += 1;
                },

                .end_scope => {
                    scope_depth -= 1;
                    if (scope_depth == 0) break;
                },

                else => {},
            }
        }

        const air_name = if (!sir_definition.exported)
            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.module.file.path, symbol.name.buffer })
        else
            symbol.name.buffer;

        if (!sir_definition.exported) {
            self.lazy_units.putAssumeCapacity(air_name, .{
                .tag = .function,
                .owner = self.module_id,
                .sir_definition = sir_definition,
            });
        }

        self.current_scope.putAssumeCapacity(symbol.name.buffer, .{
            .air_name = air_name,
            .type = symbol.type,

            .is_const = true,
        });
    }

    try self.allocated_scopes.ensureTotalCapacity(self.allocator, max_scope_depth);

    try self.air.functions.ensureTotalCapacity(self.allocator, self.module.sir.functions.count());

    for (self.module.sir.functions.values()) |sir_definition| {
        if (sir_definition.exported) {
            const variable = self.current_scope.get(sir_definition.subsymbol.name.buffer).?;

            try self.analyzeFunction(variable, sir_definition);
        }
    }
}

fn analyzeInstruction(self: *Sema, instruction: Sir.Instruction) Error!void {
    switch (instruction) {
        .duplicate => try self.analyzeDuplicate(),
        .reverse => |count| try self.analyzeReverse(count),
        .pop => try self.analyzePop(),

        .string => |string| try self.analyzeString(string),
        .int => |int| try self.analyzeInt(int),
        .float => |float| try self.analyzeFloat(float),

        .negate => |token_start| try self.analyzeNegate(token_start),

        .bool_not => |token_start| try self.analyzeNot(.bool, token_start),
        .bit_not => |token_start| try self.analyzeNot(.bit, token_start),

        .bit_and => |token_start| try self.analyzeBitwiseArithmetic(.bit_and, token_start),
        .bit_or => |token_start| try self.analyzeBitwiseArithmetic(.bit_or, token_start),
        .bit_xor => |token_start| try self.analyzeBitwiseArithmetic(.bit_xor, token_start),

        .write => |token_start| try self.analyzeWrite(token_start),
        .read => |token_start| try self.analyzeRead(token_start),
        .reference => |token_start| try self.analyzeReference(token_start),

        .add => |token_start| try self.analyzeArithmetic(.add, token_start),
        .sub => |token_start| try self.analyzeArithmetic(.sub, token_start),
        .mul => |token_start| try self.analyzeArithmetic(.mul, token_start),
        .div => |token_start| try self.analyzeArithmetic(.div, token_start),
        .rem => |token_start| try self.analyzeArithmetic(.rem, token_start),

        .lt => |token_start| try self.analyzeComparison(.lt, token_start),
        .gt => |token_start| try self.analyzeComparison(.gt, token_start),
        .eql => |token_start| try self.analyzeComparison(.eql, token_start),

        .shl => |token_start| try self.analyzeBitwiseShift(.left, token_start),
        .shr => |token_start| try self.analyzeBitwiseShift(.right, token_start),

        .parameters => |subsymbols| try self.analyzeParameters(subsymbols),

        .cast => |cast| try self.analyzeCast(cast),

        .import => |token_start| try self.analyzeImport(token_start),

        .inline_assembly => |inline_assembly| try self.analyzeInlineAssembly(inline_assembly),

        .call => |call| try self.analyzeCall(call),

        .constant => |subsymbol| try self.analyzeConstant(subsymbol),

        .variable => |variable| try self.analyzeVariable(false, variable),
        .variable_infer => |subsymbol| try self.analyzeVariable(true, subsymbol),

        .get => |name| try self.analyzeGet(null, name),
        .set => |name| try self.analyzeSet(name),
        .pre_get_element => |token_start| try self.analyzePreGetElement(token_start),
        .get_element => |token_start| try self.analyzeGetElement(token_start),
        .get_field => |name| try self.analyzeGetField(name),
        .make_slice => |token_start| try self.analyzeMakeSlice(token_start),

        .block => |block| try self.analyzeBlock(block),
        .br => |br| try self.analyzeBr(br),
        .cond_br => |cond_br| try self.analyzeCondBr(cond_br),
        .@"switch" => |@"switch"| try self.analyzeSwitch(@"switch"),

        .start_scope => try self.modifyScope(true),
        .end_scope => try self.modifyScope(false),

        .ret => |token_start| try self.analyzeReturn(true, token_start),
        .ret_void => |token_start| try self.analyzeReturn(false, token_start),
    }
}

fn modifyScope(self: *Sema, comptime start: bool) Error!void {
    if (start) {
        const new_scope = try self.allocated_scopes.addOne(self.allocator);
        new_scope.* = .{ .maybe_parent = self.current_scope };
        self.current_scope = new_scope;

        try self.air_instructions.append(self.allocator, .start_scope);
    } else {
        self.current_scope.deinit(self.allocator);
        self.current_scope = self.current_scope.maybe_parent.?;
        _ = self.allocated_scopes.pop();

        try self.air_instructions.append(self.allocator, .end_scope);
    }
}

fn analyzeDuplicate(self: *Sema) Error!void {
    try self.stack.append(self.allocator, self.stack.getLast());
    try self.air_instructions.append(self.allocator, .duplicate);
}

fn analyzeReverse(self: *Sema, count: u32) Error!void {
    std.mem.reverse(Value, self.stack.items[self.stack.items.len - count ..]);
    try self.air_instructions.append(self.allocator, .{ .reverse = count });
}

fn analyzePop(self: *Sema) Error!void {
    if (self.stack.popOrNull()) |unused_value| {
        if (unused_value.getType() != .void) {
            try self.air_instructions.append(self.allocator, .pop);
        }
    }
}

fn analyzeString(self: *Sema, string: []const u8) Error!void {
    try self.stack.append(self.allocator, .{ .string = string });

    try self.air_instructions.append(self.allocator, .{ .string = string });
}

fn analyzeInt(self: *Sema, int: i128) Error!void {
    try self.stack.append(self.allocator, .{ .int = int });

    try self.air_instructions.append(self.allocator, .{ .int = int });
}

fn analyzeFloat(self: *Sema, float: f64) Error!void {
    try self.stack.append(self.allocator, .{ .float = float });

    try self.air_instructions.append(self.allocator, .{ .float = float });
}

fn analyzeNegate(self: *Sema, token_start: u32) Error!void {
    const rhs = self.stack.pop();

    if (!rhs.getType().canBeNegative() and rhs != .int) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' cannot be negative", .{rhs.getType()});

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }

    switch (rhs) {
        .int => |rhs_int| {
            self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .int = -rhs_int };

            try self.stack.append(self.allocator, .{ .int = -rhs_int });
        },

        .float => |rhs_float| {
            self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .float = -rhs_float };

            try self.stack.append(self.allocator, .{ .float = -rhs_float });
        },

        .runtime => |rhs_runtime| {
            try self.air_instructions.append(self.allocator, .negate);

            try self.stack.append(self.allocator, .{ .runtime = rhs_runtime });
        },

        else => unreachable,
    }
}

const NotOperation = enum {
    bool,
    bit,
};

fn analyzeNot(self: *Sema, comptime operand: NotOperation, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const rhs_type = rhs.getType();

    if (operand == .bool) {
        try self.checkUnaryImplicitCast(rhs, .bool, token_start);
    } else if (operand == .bit) {
        try self.checkInt(rhs_type, token_start);
    }

    switch (rhs) {
        .int => |rhs_int| {
            self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .int = ~rhs_int };

            try self.stack.append(self.allocator, .{ .int = ~rhs_int });
        },

        .boolean => |rhs_boolean| {
            self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .boolean = !rhs_boolean };

            try self.stack.append(self.allocator, .{ .boolean = !rhs_boolean });
        },

        .runtime => |rhs_runtime| {
            try self.air_instructions.append(self.allocator, if (operand == .bool) .bool_not else .bit_not);

            try self.stack.append(self.allocator, .{ .runtime = rhs_runtime });
        },

        else => unreachable,
    }
}

const BitwiseArithmeticOperation = enum {
    bit_and,
    bit_or,
    bit_xor,
};

fn analyzeBitwiseArithmetic(self: *Sema, comptime operation: BitwiseArithmeticOperation, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const lhs = self.stack.pop();

    var lhs_type = lhs.getType();
    var rhs_type = rhs.getType();

    try self.checkIntOrBool(lhs_type, token_start);
    try self.checkIntOrBool(rhs_type, token_start);

    try self.checkBinaryImplicitCast(lhs, rhs, &lhs_type, &rhs_type, token_start);

    switch (lhs) {
        .int => |lhs_int| switch (rhs) {
            .int => |rhs_int| {
                const result = switch (operation) {
                    .bit_and => lhs_int & rhs_int,
                    .bit_or => lhs_int | rhs_int,
                    .bit_xor => lhs_int ^ rhs_int,
                };

                try self.stack.append(self.allocator, .{ .int = result });

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .int = result };

                return;
            },

            else => {},
        },

        .boolean => |lhs_boolean| switch (rhs) {
            .boolean => |rhs_boolean| {
                const result = switch (operation) {
                    .bit_and => @intFromBool(lhs_boolean) & @intFromBool(rhs_boolean),
                    .bit_or => @intFromBool(lhs_boolean) | @intFromBool(rhs_boolean),
                    .bit_xor => @intFromBool(lhs_boolean) ^ @intFromBool(rhs_boolean),
                } == 1;

                try self.stack.append(self.allocator, .{ .boolean = result });

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .boolean = result };

                return;
            },

            else => {},
        },

        else => {},
    }

    switch (operation) {
        .bit_and => try self.air_instructions.append(self.allocator, .bit_and),
        .bit_or => try self.air_instructions.append(self.allocator, .bit_or),
        .bit_xor => try self.air_instructions.append(self.allocator, .bit_xor),
    }

    try self.stack.append(self.allocator, .{ .runtime = lhs_type });
}

fn analyzeWrite(self: *Sema, token_start: u32) Error!void {
    const lhs = self.stack.pop();
    const lhs_type = lhs.getType();

    const lhs_pointer = lhs_type.getPointer() orelse try self.reportNotPointer(lhs_type, token_start);

    const rhs = self.stack.pop();

    if (lhs_pointer.is_const) {
        self.error_info = .{ .message = "cannot mutate data pointed by this pointer, it points to read-only data", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }

    try self.checkUnaryImplicitCast(rhs, lhs_pointer.child_type.*, token_start);

    try self.air_instructions.append(self.allocator, .write);
}

fn analyzeRead(self: *Sema, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const rhs_type = rhs.getType();

    const rhs_pointer = rhs_type.getPointer() orelse try self.reportNotPointer(rhs_type, token_start);

    if (rhs_pointer.child_type.* == .function) {
        self.error_info = .{ .message = "cannot read from a function pointer, it can only be called", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }

    try self.air_instructions.append(self.allocator, .read);

    try self.stack.append(self.allocator, .{ .runtime = rhs_pointer.child_type.* });
}

fn analyzeGet(self: *Sema, maybe_variable: ?*Variable, name: Name) Error!void {
    const variable = maybe_variable orelse self.current_scope.getPtr(name.buffer) orelse try self.reportNotDeclared(name);

    if (self.lazy_units.get(variable.air_name)) |lazy_unit| {
        try self.analyzeLazyUnit(variable, lazy_unit);

        _ = self.lazy_units.remove(variable.air_name);
    }

    if (variable.maybe_comptime_value) |value| {
        switch (value) {
            .string => |string| try self.air_instructions.append(self.allocator, .{ .string = string }),
            .int => |int| try self.air_instructions.append(self.allocator, .{ .int = int }),
            .float => |float| try self.air_instructions.append(self.allocator, .{ .float = float }),
            .boolean => |boolean| try self.air_instructions.append(self.allocator, .{ .boolean = boolean }),
            .module => {},
            .runtime => unreachable,
        }

        try self.stack.append(self.allocator, value);
    } else if (variable.is_type_alias) {
        try self.reportTypeNotExpression(name);
    } else {
        try self.air_instructions.append(self.allocator, .{ .get_variable_ptr = variable.air_name });

        if (variable.type.getFunction() == null) {
            try self.air_instructions.append(self.allocator, .read);
        }

        try self.stack.append(self.allocator, .{ .runtime = variable.type });
    }
}

fn analyzeSet(self: *Sema, name: Name) Error!void {
    const variable = self.current_scope.getPtr(name.buffer) orelse try self.reportNotDeclared(name);
    if (variable.is_type_alias) try self.reportTypeNotExpression(name);

    if (self.lazy_units.get(variable.air_name)) |lazy_unit| {
        try self.analyzeLazyUnit(variable, lazy_unit);

        _ = self.lazy_units.remove(variable.air_name);
    }

    const value = self.stack.pop();

    try self.checkUnaryImplicitCast(value, variable.type, name.token_start);

    if (variable.is_const) {
        self.error_info = .{ .message = "cannot mutate the value of a constant", .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

        return error.WithMessage;
    } else {
        try self.air_instructions.append(self.allocator, .{ .get_variable_ptr = variable.air_name });
        try self.air_instructions.append(self.allocator, .write);
    }
}

fn analyzeGetField(self: *Sema, name: Name) Error!void {
    const rhs_type = self.stack.getLast().getType();

    if (rhs_type == .@"struct" or (rhs_type == .pointer and rhs_type.pointer.size == .slice))
        try self.analyzeReference(name.token_start);

    const rhs = self.stack.pop();

    if (rhs_type == .module) {
        if (self.compilation.modules.values()[rhs.module].scope.get(name.buffer)) |module_variable| {
            // You may ask why? this is because the `analyzeGet` function may call `analyzeLazyUnit` with the scope of this module
            // which may cause the scope items to be reallocated, therefore we can't use `getPtr`
            var mutable_module_variable = module_variable;
            try self.analyzeGet(&mutable_module_variable, name);

            return self.compilation.modules.values()[rhs.module].scope.put(
                self.allocator,
                name.buffer,
                mutable_module_variable,
            );
        }
    } else if (rhs_type == .array or
        (rhs_type == .pointer and rhs_type.pointer.child_type.* == .array))
    {
        if (std.mem.eql(u8, name.buffer, "len")) {
            const rhs_array = if (rhs_type.getPointer()) |pointer| pointer.child_type.array else rhs_type.array;

            try self.air_instructions.append(self.allocator, .pop);
            try self.air_instructions.append(self.allocator, .{ .int = @intCast(rhs_array.len) });

            return self.stack.append(self.allocator, .{ .int = @intCast(rhs_array.len) });
        }
    } else if (rhs_type == .pointer and (rhs_type.pointer.size == .slice or
        (rhs_type.pointer.child_type.* == .pointer and rhs_type.pointer.child_type.pointer.size == .slice)))
    {
        if (std.mem.eql(u8, name.buffer, "len")) {
            try self.air_instructions.append(self.allocator, .{ .get_field_ptr = 0 });
            try self.air_instructions.append(self.allocator, .read);

            const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

            return self.stack.append(self.allocator, .{ .runtime = usize_type });
        } else if (std.mem.eql(u8, name.buffer, "ptr")) {
            try self.air_instructions.append(self.allocator, .{ .get_field_ptr = 1 });
            try self.air_instructions.append(self.allocator, .read);

            return self.stack.append(self.allocator, .{
                .runtime = .{
                    .pointer = .{
                        .size = .many,
                        .is_const = rhs_type.pointer.is_const,
                        .child_type = rhs_type.pointer.child_type,
                    },
                },
            });
        }
    } else if (rhs_type == .@"struct" or
        (rhs_type == .pointer and rhs_type.pointer.child_type.* == .@"struct"))
    {
        const rhs_struct = if (rhs_type.getPointer()) |pointer| pointer.child_type.@"struct" else rhs_type.@"struct";

        for (rhs_struct.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, name.buffer)) {
                try self.air_instructions.append(self.allocator, .{ .get_field_ptr = @intCast(i) });
                try self.air_instructions.append(self.allocator, .read);

                return self.stack.append(self.allocator, .{ .runtime = field.type });
            }
        }
    }

    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{s}' is not a field in '{}'", .{ name.buffer, rhs });

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}

fn analyzePreGetElement(self: *Sema, token_start: u32) Error!void {
    const lhs = self.stack.getLast();
    const lhs_type = lhs.getType();

    if (lhs_type == .array) {
        try self.analyzeReference(token_start);
    } else if (lhs_type == .pointer and lhs_type.pointer.size == .slice) {
        try self.analyzeReference(token_start);

        try self.air_instructions.append(self.allocator, .{ .get_field_ptr = 1 });
        try self.air_instructions.append(self.allocator, .read);

        self.stack.items[self.stack.items.len - 1] = .{
            .runtime = .{
                .pointer = .{
                    .size = .many,
                    .is_const = lhs_type.pointer.is_const,
                    .child_type = lhs_type.pointer.child_type,
                },
            },
        };
    } else if (lhs_type == .pointer and lhs_type.pointer.size != .many and lhs_type.pointer.child_type.* != .array) {
        try self.reportNotIndexable(lhs_type, token_start);
    }
}

fn analyzeGetElement(self: *Sema, token_start: u32) Error!void {
    const index = self.stack.pop();

    const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

    try self.checkUnaryImplicitCast(index, usize_type, token_start);

    const lhs = self.stack.pop();
    const lhs_pointer = lhs.getType().pointer;

    try self.checkIndexOutOfBounds(index, lhs_pointer, token_start);

    try self.air_instructions.append(self.allocator, .get_element_ptr);
    try self.air_instructions.append(self.allocator, .read);

    const child_type = if (lhs_pointer.size == .one)
        lhs_pointer.child_type.array.child_type
    else
        lhs_pointer.child_type;

    try self.stack.append(self.allocator, .{ .runtime = child_type.* });
}

fn analyzeMakeSlice(self: *Sema, token_start: u32) Error!void {
    const end = self.stack.pop();
    const start = self.stack.pop();

    const lhs = self.stack.pop();
    const lhs_pointer = lhs.getType().pointer;

    const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

    try self.checkUnaryImplicitCast(start, usize_type, token_start);
    try self.checkUnaryImplicitCast(end, usize_type, token_start);

    try self.checkRangeOutOfBounds(start, end, lhs_pointer, token_start);

    try self.air_instructions.append(self.allocator, .slice);

    const child_type = if (lhs_pointer.size == .one)
        lhs_pointer.child_type.array.child_type
    else
        lhs_pointer.child_type;

    try self.stack.append(self.allocator, .{
        .runtime = .{
            .pointer = .{
                .size = .slice,
                .is_const = lhs_pointer.is_const,
                .child_type = child_type,
            },
        },
    });
}

threadlocal var prng = std.Random.DefaultPrng.init(0);

fn analyzeReference(self: *Sema, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const rhs_type = rhs.getType();

    switch (rhs_type) {
        .void => {
            self.error_info = .{ .message = "cannot reference value with type 'void'", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        },

        .module => {
            self.error_info = .{ .message = "cannot reference value with type 'module'", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        },

        else => {},
    }

    const last_instruction = self.air_instructions.items[self.air_instructions.items.len - 1];

    if (last_instruction == .read or rhs != .runtime) {
        _ = self.air_instructions.pop();
    }

    if (last_instruction != .read) {
        const anon_var_name = try std.fmt.allocPrint(self.allocator, "compiler::__anon_{}", .{prng.random().int(u32)});

        if (rhs == .runtime) {
            try self.air_instructions.append(
                self.allocator,
                .{
                    .variable = .{
                        .type = rhs_type,

                        .name = .{ .buffer = anon_var_name, .token_start = 0 },
                    },
                },
            );

            try self.air_instructions.append(self.allocator, .{ .get_variable_ptr = anon_var_name });
            try self.air_instructions.append(self.allocator, .duplicate);
            try self.air_instructions.append(self.allocator, .{ .reverse = 3 });
            try self.air_instructions.append(self.allocator, .{ .reverse = 2 });
            try self.air_instructions.append(self.allocator, .write);
        } else {
            const definition = try self.air.global_variables.getOrPutValue(self.allocator, anon_var_name, .{
                .symbol = .{
                    .type = rhs_type,

                    .name = .{ .buffer = anon_var_name, .token_start = 0 },
                },
                .exported = false,
            });

            std.debug.assert(!definition.found_existing);

            try definition.value_ptr.instructions.append(self.allocator, last_instruction);

            try self.air_instructions.append(self.allocator, .{ .get_variable_ptr = anon_var_name });
        }
    }

    const is_const = false;

    const child_on_heap = try self.allocator.create(Type);
    child_on_heap.* = rhs_type;

    try self.stack.append(self.allocator, .{
        .runtime = .{
            .pointer = .{
                .size = .one,
                .is_const = is_const,
                .child_type = child_on_heap,
            },
        },
    });
}

const ArithmeticOperation = enum {
    add,
    sub,
    mul,
    div,
    rem,
};

fn analyzeArithmetic(self: *Sema, comptime operation: ArithmeticOperation, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const lhs = self.stack.pop();

    var lhs_type = lhs.getType();
    var rhs_type = rhs.getType();

    if (operation == .add or operation == .sub) {
        try self.checkIntOrFloatOrPointer(lhs_type, token_start);
        try self.checkIntOrFloatOrPointer(rhs_type, token_start);

        const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

        if (lhs_type == .pointer and rhs_type != .pointer) {
            try self.checkUnaryImplicitCast(rhs, usize_type, token_start);
        } else if (rhs_type == .pointer and lhs_type != .pointer) {
            try self.checkUnaryImplicitCast(lhs, usize_type, token_start);
        } else if (lhs_type == .pointer and rhs_type == .pointer) {
            try self.checkUnaryImplicitCast(lhs, rhs_type, token_start);
        } else {
            try self.checkBinaryImplicitCast(lhs, rhs, &lhs_type, &rhs_type, token_start);
        }
    } else {
        try self.checkIntOrFloat(lhs_type, token_start);
        try self.checkIntOrFloat(rhs_type, token_start);

        try self.checkBinaryImplicitCast(lhs, rhs, &lhs_type, &rhs_type, token_start);
    }

    switch (lhs) {
        .int => |lhs_int| switch (rhs) {
            .int => |rhs_int| {
                if (rhs_int == 0 and (operation == .div or operation == .rem)) {
                    self.error_info = .{ .message = "division by zero", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

                    return error.WithMessage;
                }

                const result = switch (operation) {
                    .add => lhs_int + rhs_int,
                    .sub => lhs_int - rhs_int,
                    .mul => lhs_int * rhs_int,
                    .div => @divFloor(lhs_int, rhs_int),
                    .rem => @rem(lhs_int, rhs_int),
                };

                try self.stack.append(self.allocator, .{ .int = result });

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .int = result };

                return;
            },

            else => {},
        },

        .float => |lhs_float| switch (rhs) {
            .float => |rhs_float| {
                if (rhs_float == 0 and (operation == .div or operation == .rem)) {
                    self.error_info = .{ .message = "division by zero", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

                    return error.WithMessage;
                }

                const result = switch (operation) {
                    .add => lhs_float + rhs_float,
                    .sub => lhs_float - rhs_float,
                    .mul => lhs_float * rhs_float,
                    .div => lhs_float / rhs_float,
                    .rem => @rem(lhs_float, rhs_float),
                };

                try self.stack.append(self.allocator, .{ .float = result });

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .float = result };

                return;
            },

            else => {},
        },

        else => {},
    }

    if (lhs_type == .pointer) {
        try self.stack.append(self.allocator, .{ .runtime = lhs_type });
    } else if (rhs_type == .pointer) {
        try self.stack.append(self.allocator, .{ .runtime = rhs_type });
    } else {
        try self.stack.append(self.allocator, .{ .runtime = lhs_type });
    }

    switch (operation) {
        .add => try self.air_instructions.append(self.allocator, .add),
        .sub => try self.air_instructions.append(self.allocator, .sub),
        .mul => try self.air_instructions.append(self.allocator, .mul),
        .div => try self.air_instructions.append(self.allocator, .div),
        .rem => try self.air_instructions.append(self.allocator, .rem),
    }
}

const ComparisonOperation = enum {
    lt,
    gt,
    eql,
};

fn analyzeComparison(self: *Sema, comptime operation: ComparisonOperation, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const lhs = self.stack.pop();

    var lhs_type = lhs.getType();
    var rhs_type = rhs.getType();

    if (operation == .lt or operation == .gt) {
        try self.checkIntOrFloat(lhs_type, token_start);
        try self.checkIntOrFloat(rhs_type, token_start);
    }

    try self.checkCanBeCompared(lhs_type, token_start);
    try self.checkCanBeCompared(rhs_type, token_start);

    try self.checkBinaryImplicitCast(lhs, rhs, &lhs_type, &rhs_type, token_start);

    switch (lhs) {
        .int => |lhs_int| switch (rhs) {
            .int => |rhs_int| {
                const result = switch (operation) {
                    .lt => lhs_int < rhs_int,
                    .gt => lhs_int > rhs_int,
                    .eql => lhs_int == rhs_int,
                };

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .boolean = result };

                try self.stack.append(self.allocator, .{ .boolean = result });

                return;
            },

            else => {},
        },

        .float => |lhs_float| switch (rhs) {
            .float => |rhs_float| {
                const result = switch (operation) {
                    .lt => lhs_float < rhs_float,
                    .gt => lhs_float > rhs_float,
                    .eql => lhs_float == rhs_float,
                };

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .boolean = result };

                try self.stack.append(self.allocator, .{ .boolean = result });

                return;
            },

            else => {},
        },

        .boolean => |lhs_boolean| switch (rhs) {
            .boolean => |rhs_boolean| {
                const result = switch (operation) {
                    .eql => lhs_boolean == rhs_boolean,

                    else => unreachable,
                };

                _ = self.air_instructions.pop();

                self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .boolean = result };

                try self.stack.append(self.allocator, .{ .boolean = result });

                return;
            },

            else => {},
        },

        else => {},
    }

    switch (operation) {
        .lt => try self.air_instructions.append(self.allocator, .lt),
        .gt => try self.air_instructions.append(self.allocator, .gt),
        .eql => try self.air_instructions.append(self.allocator, .eql),
    }

    try self.stack.append(self.allocator, .{ .runtime = .bool });
}

const BitwiseShiftDirection = enum {
    left,
    right,
};

fn analyzeBitwiseShift(self: *Sema, comptime direction: BitwiseShiftDirection, token_start: u32) Error!void {
    const rhs = self.stack.pop();
    const lhs = self.stack.pop();

    const lhs_type = lhs.getType();
    const rhs_type = rhs.getType();

    try self.checkInt(lhs_type, token_start);
    try self.checkInt(rhs_type, token_start);

    if (lhs != .runtime and rhs != .runtime) {
        const lhs_int = lhs.int;
        const rhs_int = rhs.int;

        const count_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = 7 } };

        try self.checkBitShiftCount(rhs, count_type, token_start);

        const result = switch (direction) {
            .left => lhs_int << @intCast(rhs_int),
            .right => lhs_int >> @intCast(rhs_int),
        };

        try self.stack.append(self.allocator, .{ .int = result });

        _ = self.air_instructions.pop();

        self.air_instructions.items[self.air_instructions.items.len - 1] = .{ .int = result };
    } else {
        const count_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = std.math.log2(lhs_type.int.bits) } };

        try self.checkBitShiftCount(rhs, count_type, token_start);

        switch (direction) {
            .left => try self.air_instructions.append(self.allocator, .shl),
            .right => try self.air_instructions.append(self.allocator, .shr),
        }

        try self.stack.append(self.allocator, .{ .runtime = lhs_type });
    }
}

fn analyzeCast(self: *Sema, cast: Sir.Instruction.Cast) Error!void {
    const from = self.stack.getLast().getType();
    const to = try self.analyzeSubType(cast.to);

    if (from.eql(to)) return;

    const rhs = self.stack.pop();

    if (to == .void) {
        self.error_info = .{ .message = "cannot cast to 'void' as it is not possible to represent a value of this type", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (to == .function) {
        self.error_info = .{ .message = "cannot cast to a function type as it should be always wrapped in a pointer", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (from == .module) {
        self.error_info = .{ .message = "cannot cast from a module to any type", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (to == .@"struct" or from == .@"struct") {
        self.error_info = .{ .message = "cannot cast from or to a struct", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (to == .array or from == .array) {
        self.error_info = .{ .message = "cannot cast from or to an array", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (to == .pointer and from != .pointer) {
        const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

        try self.checkUnaryImplicitCast(rhs, usize_type, cast.token_start);
    } else if (to == .pointer and to.pointer.size == .slice) {
        self.error_info = .{ .message = "cannot cast explicitly to a slice, use slicing syntax or implicit casting", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (from == .pointer and to != .pointer) {
        const usize_type: Type = .{ .int = .{ .signedness = .unsigned, .bits = self.compilation.env.target.ptrBitWidth() } };

        if (!to.eql(usize_type)) {
            var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

            // zig fmt: off
            try error_message_buf.writer(self.allocator).print(
                "cannot cast from a pointer to '{}', pointers can only cast to '{}' in this target " ++
                "(note: you should use 'usize' as it is an alias for '{}' in cross compilable manner as the size is different in other targets)",
                .{ to, usize_type, usize_type },
            );
            // zig fmt: on

            self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

            return error.WithMessage;
        }
    } else if (to == .bool) {
        self.error_info = .{ .message = "cannot cast to a boolean, use comparison instead", .source_loc = SourceLoc.find(self.module.file.buffer, cast.token_start) };

        return error.WithMessage;
    } else if (from == .bool) {
        try self.checkInt(to, cast.token_start);
    } else if (from == .float) {
        try self.checkIntOrFloat(to, cast.token_start);
    }

    try self.air_instructions.append(self.allocator, .{ .cast = to });

    try self.stack.append(self.allocator, .{ .runtime = to });
}

fn getImportFile(self: *Sema, file_path: []const u8, token_start: u32) Error!Compilation.File {
    if (std.mem.eql(u8, file_path, "root")) return self.compilation.root_file;

    if (std.mem.eql(u8, file_path, "std")) {
        const import_file = self.compilation.env.barq_lib.std_file;
        const import_file_path = self.compilation.env.barq_lib.std_file_path;

        if (self.compilation.modules.get(import_file_path) != null) return .{ .path = import_file_path, .buffer = "" };

        const import_file_buffer = import_file.readToEndAllocOptions(
            self.allocator,
            std.math.maxInt(u32),
            null,
            @alignOf(u8),
            0,
        ) catch |err| {
            var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

            try error_message_buf.writer(self.allocator).print(
                "could not read import file: {s}",
                .{root.Cli.errorDescription(err)},
            );

            self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        };

        return .{ .path = import_file_path, .buffer = import_file_buffer };
    }

    const parent_dir_path = std.fs.path.dirname(self.module.file.path) orelse if (self.module.file.path[0] == std.fs.path.sep)
        std.fs.path.sep_str
    else
        ".";

    var parent_dir = std.fs.cwd().openDir(parent_dir_path, .{}) catch |err| {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print(
            "could not open parent directory of root file: {s}",
            .{root.Cli.errorDescription(err)},
        );

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    };

    defer parent_dir.close();

    const import_file = parent_dir.openFile(file_path, .{}) catch |err| {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print(
            "could not open import file: {s}",
            .{root.Cli.errorDescription(err)},
        );

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    };

    defer import_file.close();

    const import_file_path = try std.fs.path.resolve(self.allocator, &.{ parent_dir_path, file_path });

    if (self.compilation.modules.get(import_file_path) != null) return .{ .path = import_file_path, .buffer = "" };

    const import_file_buffer = import_file.readToEndAllocOptions(
        self.allocator,
        std.math.maxInt(u32),
        null,
        @alignOf(u8),
        0,
    ) catch |err| {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print(
            "could not read import file: {s}",
            .{root.Cli.errorDescription(err)},
        );

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    };

    return .{ .path = import_file_path, .buffer = import_file_buffer };
}

fn analyzeImport(self: *Sema, token_start: u32) Error!void {
    if (self.air_instructions.pop() != .string) {
        self.error_info = .{ .message = "expected a compile time known string for import file path", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }

    const file_path = self.stack.pop().string;

    const import_file = try self.getImportFile(file_path, token_start);

    if (self.compilation.modules.getIndex(import_file.path)) |module_id| {
        try self.stack.append(self.allocator, .{ .module = @intCast(module_id) });
    } else {
        var sir_parser = try Sir.Parser.init(self.allocator, self.compilation.env, import_file);
        defer sir_parser.deinit();

        sir_parser.parse() catch |err| {
            switch (err) {
                error.OutOfMemory => std.debug.print("Error: {s}\n", .{root.Cli.errorDescription(err)}),

                error.WithMessage => std.debug.print("{s}:{}:{}: {s}\n", .{
                    import_file.path,
                    sir_parser.error_info.?.source_loc.line,
                    sir_parser.error_info.?.source_loc.column,
                    sir_parser.error_info.?.message,
                }),

                error.WithoutMessage => {},
            }

            return error.WithoutMessage;
        };

        const module_id: u32 = @intCast((try self.compilation.modules.getOrPutValue(
            self.allocator,
            import_file.path,
            .{
                .file = import_file,
                .sir = sir_parser.sir,
            },
        )).index);

        // `getOrPutValue` may invalidate our module pointer
        self.module = &self.compilation.modules.values()[self.module_id];

        var sema = try Sema.init(
            self.allocator,
            self.compilation,
            module_id,
            self.air,
            self.lazy_units,
        );

        defer sema.deinit();

        sema.analyze() catch |err| {
            switch (err) {
                error.OutOfMemory => std.debug.print("Error: {s}\n", .{root.Cli.errorDescription(err)}),

                error.WithMessage => std.debug.print("{s}:{}:{}: {s}\n", .{
                    import_file.path,
                    sema.error_info.?.source_loc.line,
                    sema.error_info.?.source_loc.column,
                    sema.error_info.?.message,
                }),

                error.WithoutMessage => {},
            }

            return error.WithoutMessage;
        };

        try self.stack.append(self.allocator, .{ .module = module_id });
    }
}

fn analyzeInlineAssembly(self: *Sema, inline_assembly: Sir.Instruction.InlineAssembly) Error!void {
    self.stack.shrinkRetainingCapacity(self.stack.items.len - inline_assembly.input_constraints.len);

    if (inline_assembly.output_constraint) |output_constraint| {
        const output_constraint_type = try self.analyzeSubType(output_constraint.subtype);

        try self.air_instructions.append(self.allocator, .{
            .inline_assembly = .{
                .content = inline_assembly.content,
                .input_constraints = inline_assembly.input_constraints,
                .output_constraint = .{
                    .register = output_constraint.register,
                    .type = output_constraint_type,
                },
                .clobbers = inline_assembly.clobbers,
            },
        });

        try self.stack.append(self.allocator, .{ .runtime = output_constraint_type });
    } else {
        try self.air_instructions.append(self.allocator, .{
            .inline_assembly = .{
                .content = inline_assembly.content,
                .input_constraints = inline_assembly.input_constraints,
                .output_constraint = null,
                .clobbers = inline_assembly.clobbers,
            },
        });

        try self.stack.append(self.allocator, .{ .runtime = .void });
    }
}

fn analyzeCall(self: *Sema, call: Sir.Instruction.Call) Error!void {
    const callable = self.stack.pop();
    const callable_type = callable.getType();

    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    if (callable_type.getFunction()) |function| {
        if ((function.is_var_args and function.parameter_types.len > call.arguments_count) or
            (!function.is_var_args and function.parameter_types.len != call.arguments_count))
        {
            try error_message_buf.writer(self.allocator).print("expected {} argument(s) got {} argument(s)", .{ function.parameter_types.len, call.arguments_count });

            self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, call.token_start) };

            return error.WithMessage;
        }

        for (function.parameter_types) |parameter_type| {
            const argument = self.stack.pop();

            try self.checkUnaryImplicitCast(argument, parameter_type, call.token_start);
        }

        if (function.is_var_args) {
            self.stack.shrinkRetainingCapacity(self.stack.items.len - (call.arguments_count - function.parameter_types.len));
        }

        try self.air_instructions.append(self.allocator, .{ .call = call.arguments_count });

        try self.stack.append(self.allocator, .{ .runtime = function.return_type.* });
    } else {
        try error_message_buf.writer(self.allocator).print("'{}' is not a callable", .{callable_type});

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, call.token_start) };

        return error.WithMessage;
    }
}

fn analyzeParameters(self: *Sema, subsymbols: []const Sir.SubSymbol) Error!void {
    var symbols: std.ArrayListUnmanaged(Symbol) = .{};
    try symbols.ensureTotalCapacity(self.allocator, subsymbols.len);

    for (subsymbols) |subsymbol| {
        const symbol = try self.analyzeSubSymbol(subsymbol);
        if (self.current_scope.get(symbol.name.buffer) != null) try self.reportRedeclaration(symbol.name);

        if (symbol.type == .void) {
            self.error_info = .{ .message = "a function cannot have 'void' parameter", .source_loc = SourceLoc.find(self.module.file.buffer, symbol.name.token_start) };

            return error.WithMessage;
        }

        symbols.appendAssumeCapacity(symbol);

        try self.current_scope.put(
            self.allocator,
            symbol.name.buffer,
            .{
                .air_name = symbol.name.buffer,
                .type = symbol.type,
            },
        );
    }

    try self.air_instructions.append(self.allocator, .{ .parameters = try symbols.toOwnedSlice(self.allocator) });
}

fn analyzeConstant(self: *Sema, subsymbol: Sir.SubSymbol) Error!void {
    const symbol = try self.analyzeSubSymbol(subsymbol);
    if (self.current_scope.get(symbol.name.buffer) != null) try self.reportRedeclaration(symbol.name);

    const value = self.stack.pop();

    if (value == .runtime) {
        self.error_info = .{ .message = "expected the constant value to be compile time known", .source_loc = SourceLoc.find(self.module.file.buffer, symbol.name.token_start) };

        return error.WithMessage;
    }

    try self.current_scope.put(
        self.allocator,
        symbol.name.buffer,
        .{
            .type = value.getType(),

            .is_const = true,
            .maybe_comptime_value = value,
        },
    );
}

fn analyzeVariable(self: *Sema, infer: bool, subsymbol: Sir.SubSymbol) Error!void {
    var symbol = try self.analyzeSubSymbol(subsymbol);
    if (self.current_scope.get(symbol.name.buffer) != null) try self.reportRedeclaration(symbol.name);

    if (infer) {
        symbol.type = self.stack.getLast().getType();
    }

    switch (symbol.type) {
        .void => {
            self.error_info = .{
                .message = "cannot declare a variable with type 'void'",
                .source_loc = SourceLoc.find(self.module.file.buffer, subsymbol.name.token_start),
            };

            return error.WithMessage;
        },

        .module => {
            self.error_info = .{
                .message = "cannot declare a variable with type 'module'",
                .source_loc = SourceLoc.find(self.module.file.buffer, subsymbol.name.token_start),
            };

            return error.WithMessage;
        },

        else => {},
    }

    const variable: Variable = .{
        .air_name = symbol.name.buffer,
        .type = symbol.type,
    };

    try self.current_scope.put(self.allocator, symbol.name.buffer, variable);

    try self.air_instructions.append(self.allocator, .{ .variable = symbol });
}

fn analyzeLazyUnit(self: *Sema, variable: *Variable, lazy_unit: LazyUnit) Error!void {
    const sir_definition = lazy_unit.sir_definition;

    switch (lazy_unit.tag) {
        .function => {
            if (lazy_unit.owner != self.module_id) {
                var sema = try Sema.init(
                    self.allocator,
                    self.compilation,
                    lazy_unit.owner,
                    self.air,
                    self.lazy_units,
                );

                defer sema.deinit();

                sema.analyzeFunction(variable.*, sir_definition) catch |err| {
                    switch (err) {
                        error.OutOfMemory => std.debug.print("Error: {s}\n", .{root.Cli.errorDescription(err)}),

                        error.WithMessage => std.debug.print("{s}:{}:{}: {s}\n", .{
                            sema.module.file.path,
                            sema.error_info.?.source_loc.line,
                            sema.error_info.?.source_loc.column,
                            sema.error_info.?.message,
                        }),

                        error.WithoutMessage => {},
                    }

                    return error.WithoutMessage;
                };
            } else {
                try self.analyzeFunction(variable.*, sir_definition);
            }
        },

        .external_declaration => {
            try self.air.external_declarations.append(self.allocator, .{
                .name = sir_definition.subsymbol.name,
                .type = variable.type,
            });
        },

        .global_variable => {
            if (lazy_unit.owner != self.module_id) {
                var sema = try Sema.init(
                    self.allocator,
                    self.compilation,
                    lazy_unit.owner,
                    self.air,
                    self.lazy_units,
                );

                defer sema.deinit();

                sema.analyzeGlobalVariable(variable, sir_definition) catch |err| {
                    switch (err) {
                        error.OutOfMemory => std.debug.print("Error: {s}\n", .{root.Cli.errorDescription(err)}),

                        error.WithMessage => std.debug.print("{s}:{}:{}: {s}\n", .{
                            sema.module.file.path,
                            sema.error_info.?.source_loc.line,
                            sema.error_info.?.source_loc.column,
                            sema.error_info.?.message,
                        }),

                        error.WithoutMessage => {},
                    }

                    return error.WithoutMessage;
                };
            } else {
                try self.analyzeGlobalVariable(variable, sir_definition);
            }
        },

        .global_constant => {
            if (lazy_unit.owner != self.module_id) {
                var sema = try Sema.init(
                    self.allocator,
                    self.compilation,
                    lazy_unit.owner,
                    self.air,
                    self.lazy_units,
                );

                defer sema.deinit();

                sema.analyzeGlobalConstant(variable, sir_definition) catch |err| {
                    switch (err) {
                        error.OutOfMemory => std.debug.print("Error: {s}\n", .{root.Cli.errorDescription(err)}),

                        error.WithMessage => std.debug.print("{s}:{}:{}: {s}\n", .{
                            sema.module.file.path,
                            sema.error_info.?.source_loc.line,
                            sema.error_info.?.source_loc.column,
                            sema.error_info.?.message,
                        }),

                        error.WithoutMessage => {},
                    }

                    return error.WithoutMessage;
                };
            } else {
                try self.analyzeGlobalConstant(variable, sir_definition);
            }
        },
    }
}

fn analyzeBlock(self: *Sema, id: u32) Error!void {
    try self.air_instructions.append(self.allocator, .{ .block = id });
}

fn analyzeBr(self: *Sema, id: u32) Error!void {
    try self.air_instructions.append(self.allocator, .{ .br = id });
}

fn analyzeCondBr(self: *Sema, cond_br: Sir.Instruction.CondBr) Error!void {
    const condition = self.stack.pop();

    try self.checkUnaryImplicitCast(condition, .bool, cond_br.token_start);

    switch (condition) {
        .boolean => |condition_boolean| {
            _ = self.air_instructions.pop();

            try self.air_instructions.append(
                self.allocator,
                .{
                    .br = if (condition_boolean)
                        cond_br.true_id
                    else
                        cond_br.false_id,
                },
            );
        },

        else => {
            try self.air_instructions.append(
                self.allocator,
                .{
                    .cond_br = .{
                        .true_id = cond_br.true_id,
                        .false_id = cond_br.false_id,
                    },
                },
            );
        },
    }
}

fn analyzeSwitch(self: *Sema, @"switch": Sir.Instruction.Switch) Error!void {
    const switched_value = self.stack.pop();
    const switched_value_type = switched_value.getType();

    try self.checkIntOrBool(switched_value_type, @"switch".token_start);

    var case_values: std.AutoHashMapUnmanaged(i128, void) = .{};

    for (@"switch".case_token_starts) |case_token_start| {
        const case_value = self.stack.pop();

        try self.checkUnaryImplicitCast(case_value, switched_value_type, case_token_start);

        if (case_value == .runtime) {
            self.error_info = .{ .message = "expected switch case value to be compile time known", .source_loc = SourceLoc.find(self.module.file.buffer, case_token_start) };

            return error.WithMessage;
        }

        const case_value_int = switch (case_value) {
            .int => |int| int,
            .boolean => |boolean| @as(i128, @intFromBool(boolean)),

            else => unreachable,
        };

        if (case_values.get(case_value_int) != null) {
            self.error_info = .{ .message = "duplcicte switch case", .source_loc = SourceLoc.find(self.module.file.buffer, case_token_start) };

            return error.WithMessage;
        }

        try case_values.put(self.allocator, case_value_int, {});
    }

    case_values.deinit(self.allocator);

    try self.air_instructions.append(self.allocator, .{
        .@"switch" = .{
            .case_block_ids = @"switch".case_block_ids,
            .else_block_id = @"switch".else_block_id,
        },
    });
}

fn analyzeReturn(self: *Sema, comptime with_value: bool, token_start: u32) Error!void {
    const return_type = self.function_type.pointer.child_type.*.function.return_type.*;

    if (with_value) {
        try self.checkUnaryImplicitCast(self.stack.pop(), return_type, token_start);
    } else {
        if (return_type != .void) {
            self.error_info = .{ .message = "function with non void return type returns void", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        }
    }

    try self.air_instructions.append(self.allocator, if (with_value) .ret else .ret_void);
}

fn analyzeSubType(self: *Sema, subtype: Sir.SubType) Error!Type {
    switch (subtype) {
        .name => |name| {
            if (self.current_scope.get(name.buffer)) |variable|
                if (variable.is_type_alias)
                    return variable.type;

            try self.reportTypeNotDeclared(name);
        },

        .chained_names => |names| {
            const previous_air_instructions = self.air_instructions;
            var air_instructions: @FieldType(Air.Definition, "instructions") = .{};
            self.air_instructions = &air_instructions;
            defer self.air_instructions = previous_air_instructions;

            try self.analyzeGet(null, names[0]);

            for (names[1 .. names.len - 1]) |name| {
                try self.analyzeGetField(name);
            }

            const last_name = names[names.len - 1];

            if (self.stack.getLast() == .module) {
                const module_id = self.stack.pop().module;

                if (self.compilation.modules.values()[module_id].scope.get(last_name.buffer)) |module_variable| {
                    if (!module_variable.is_type_alias) {
                        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

                        try error_message_buf.writer(self.allocator).print("'{s}' is not a type", .{last_name.buffer});

                        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, last_name.token_start) };

                        return error.WithMessage;
                    }

                    return module_variable.type;
                }
            }

            var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

            try error_message_buf.writer(self.allocator).print("'{s}' is not a field in '{}'", .{ last_name.buffer, self.stack.getLast() });

            self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, last_name.token_start) };

            return error.WithMessage;
        },

        .function => |function| {
            const parameter_types = try self.allocator.alloc(Type, function.parameter_subtypes.len);

            for (function.parameter_subtypes, 0..) |parameter_subtype, i| {
                parameter_types[i] = try self.analyzeSubType(parameter_subtype);
            }

            const return_type = try self.analyzeSubType(function.return_subtype.*);

            const return_type_on_heap = try self.allocator.create(Type);
            return_type_on_heap.* = return_type;

            return Type{
                .function = .{
                    .parameter_types = parameter_types,
                    .is_var_args = function.is_var_args,
                    .return_type = return_type_on_heap,
                },
            };
        },

        .pointer => |pointer| {
            if (pointer.child_subtype.* == .name) {
                const child_subtype_name = pointer.child_subtype.name;

                if (self.current_scope.getPtr(child_subtype_name.buffer)) |child_subtype_variable| {
                    if (child_subtype_variable.is_type_alias) {
                        return Type{
                            .pointer = .{
                                .size = pointer.size,
                                .is_const = pointer.is_const,
                                .child_type = &child_subtype_variable.type,
                            },
                        };
                    }
                }

                try self.reportTypeNotDeclared(child_subtype_name);
            } else {
                const child_type = try self.analyzeSubType(pointer.child_subtype.*);

                const child_type_on_heap = try self.allocator.create(Type);
                child_type_on_heap.* = child_type;

                return Type{
                    .pointer = .{
                        .size = pointer.size,
                        .is_const = pointer.is_const,
                        .child_type = child_type_on_heap,
                    },
                };
            }
        },

        .array => |array| {
            if (array.child_subtype.* == .name) {
                const child_subtype_name = array.child_subtype.name;

                if (self.current_scope.getPtr(child_subtype_name.buffer)) |child_subtype_variable| {
                    if (child_subtype_variable.is_type_alias) {
                        return Type{
                            .array = .{
                                .len = array.len,
                                .child_type = &child_subtype_variable.type,
                            },
                        };
                    }
                }

                try self.reportTypeNotDeclared(child_subtype_name);
            } else {
                const child_type = try self.analyzeSubType(array.child_subtype.*);

                const child_type_on_heap = try self.allocator.create(Type);
                child_type_on_heap.* = child_type;

                return Type{
                    .array = .{
                        .len = array.len,
                        .child_type = child_type_on_heap,
                    },
                };
            }
        },

        .@"struct" => |@"struct"| {
            var fields = try self.allocator.alloc(Type.Struct.Field, @"struct".subsymbols.len);

            for (@"struct".subsymbols, 0..) |subsymbol, i| {
                const symbol = try self.analyzeSubSymbol(subsymbol);

                fields[i] = .{ .name = symbol.name.buffer, .type = symbol.type };
            }

            return Type{ .@"struct" = .{ .fields = fields } };
        },

        .@"enum" => |@"enum"| {
            self.error_info = .{ .message = "enums should be in a type alias as they require a namespace", .source_loc = SourceLoc.find(self.module.file.buffer, @"enum".token_start) };

            return error.WithMessage;
        },

        .pure => |pure| return pure,
    }
}

fn analyzeSubSymbol(self: *Sema, subsymbol: Sir.SubSymbol) Error!Symbol {
    return Symbol{
        .name = subsymbol.name,
        .type = try self.analyzeSubType(subsymbol.subtype),
    };
}

fn checkTypeAliasCircular(self: *Sema, targets: *std.ArrayListUnmanaged(Name), subtype: Sir.SubType) Error!void {
    switch (subtype) {
        .name => |name| {
            try targets.append(self.allocator, name);

            for (targets.items[0 .. targets.items.len - 1]) |target| {
                if (std.mem.eql(u8, name.buffer, target.buffer)) {
                    try self.reportCircularDependency(target);
                }
            }

            if (self.module.sir.type_aliases.get(name.buffer)) |type_alias| {
                try self.checkTypeAliasCircular(targets, type_alias.subtype);
            }

            _ = targets.pop();
        },

        .@"struct" => |@"struct"| {
            for (@"struct".subsymbols) |field_subsymbol| {
                try self.checkTypeAliasCircular(targets, field_subsymbol.subtype);
            }
        },

        .@"enum" => |@"enum"| {
            try self.checkTypeAliasCircular(targets, @"enum".subtype.*);
        },

        else => {},
    }
}

fn checkTypeAliasWaitsOthers(subtype: Sir.SubType, type_aliases: *std.StringHashMapUnmanaged(Sir.SubSymbol)) bool {
    return switch (subtype) {
        .pure, .pointer, .array => false,

        .name => |name| type_aliases.get(name.buffer) != null,

        .@"enum" => |@"enum"| checkTypeAliasWaitsOthers(@"enum".subtype.*, type_aliases),

        .function => |function| blk: {
            for (function.parameter_subtypes) |parameter_subtype|
                if (checkTypeAliasWaitsOthers(parameter_subtype, type_aliases))
                    break :blk true;

            break :blk checkTypeAliasWaitsOthers(function.return_subtype.*, type_aliases);
        },

        .@"struct" => |@"struct"| blk: {
            for (@"struct".subsymbols) |field_subsymbol|
                if (checkTypeAliasWaitsOthers(field_subsymbol.subtype, type_aliases))
                    break :blk true;

            break :blk false;
        },
    };
}

fn canUnaryImplicitCast(lhs: Value, to: Type) bool {
    const lhs_type = lhs.getType();

    return (lhs_type.eql(to) or
        (lhs == .int and to == .int and lhs.int >= to.minInt() and
        lhs == .int and to == .int and lhs.int <= to.maxInt()) or
        (lhs == .float and to == .float and lhs.float >= -to.maxFloat() and
        lhs == .float and to == .float and lhs.float <= to.maxFloat()) or
        (lhs_type == .int and to == .int and
        lhs_type.maxInt() <= to.maxInt() and lhs_type.minInt() >= to.minInt() and
        lhs_type.canBeNegative() == to.canBeNegative()) or
        (lhs_type == .float and to == .float and
        lhs_type.maxFloat() <= to.maxFloat()) or
        (lhs_type == .pointer and to == .pointer and lhs_type.pointer.child_type.* == .array and
        (to.pointer.size == .many or to.pointer.size == .slice) and
        lhs_type.pointer.child_type.array.child_type.eql(to.pointer.child_type.*)));
}

fn checkUnaryImplicitCast(self: *Sema, lhs: Value, to: Type, token_start: u32) Error!void {
    if (!canUnaryImplicitCast(lhs, to)) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' cannot be implicitly casted to '{}'", .{ lhs.getType(), to });

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkIndexOutOfBounds(self: *Sema, index: Value, lhs_pointer: Type.Pointer, token_start: u32) Error!void {
    if (index == .int and lhs_pointer.child_type.* == .array and
        index.int >= lhs_pointer.child_type.array.len)
    {
        self.error_info = .{ .message = "index out of bounds", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkRangeOutOfBounds(self: *Sema, start: Value, end: Value, lhs_pointer: Type.Pointer, token_start: u32) Error!void {
    if (start == .int) {
        if (end == .int and start.int > end.int) {
            self.error_info = .{ .message = "range start is greater than range end", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        }

        if (lhs_pointer.child_type.* == .array and
            start.int >= lhs_pointer.child_type.array.len)
        {
            self.error_info = .{ .message = "range start out of bounds", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

            return error.WithMessage;
        }
    }

    if (end == .int and lhs_pointer.child_type.* == .array and
        end.int > lhs_pointer.child_type.array.len)
    {
        self.error_info = .{ .message = "range end out of bounds", .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkBitShiftCount(self: *Sema, rhs: Value, count_type: Type, token_start: u32) Error!void {
    if (!canUnaryImplicitCast(rhs, count_type)) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' cannot be used as a bit shift count, as it cannot be implicitly casted to '{}'", .{ rhs, count_type });

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkBinaryImplicitCast(self: *Sema, lhs: Value, rhs: Value, lhs_type: *Type, rhs_type: *Type, token_start: u32) Error!void {
    if (std.meta.activeTag(lhs_type.*) == std.meta.activeTag(rhs_type.*)) {
        if (lhs == .runtime and rhs == .runtime and
            lhs_type.canBeNegative() != rhs_type.canBeNegative())
        {
            try self.reportIncompatibleTypes(lhs_type.*, rhs_type.*, token_start);
        }

        if (lhs_type.* == .int and lhs_type.int.bits > rhs_type.int.bits or
            lhs_type.* == .float and lhs_type.float.bits > rhs_type.float.bits)
        {
            // lhs as u64 > rhs as u16
            // lhs as f64 > rhs as f32
            // lhs as f64 > rhs as f16
            try self.checkUnaryImplicitCast(rhs, lhs_type.*, token_start);

            rhs_type.* = lhs_type.*;
        } else if (lhs_type.* == .int and lhs_type.int.bits < rhs_type.int.bits or
            lhs_type.* == .float and lhs_type.float.bits < rhs_type.float.bits)
        {
            // lhs as u16 > rhs as u64
            // lhs as f32 > rhs as f64
            // lhs as f16 > rhs as f64
            try self.checkUnaryImplicitCast(lhs, rhs_type.*, token_start);

            lhs_type.* = rhs_type.*;
        } else if (lhs_type.* == .pointer) {
            // lhs as *const u8 == rhs as *const u8
            // lhs as *const u8 == rhs as *const u16
            //
            // Both are allowed since it is a pointer comparison which compares the addresses
        }
    } else {
        try self.reportIncompatibleTypes(lhs_type.*, rhs_type.*, token_start);
    }
}

fn checkIntOrBool(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type != .int and provided_type != .bool) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' is provided while expected an integer or boolean", .{provided_type});
        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkIntOrFloat(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type != .int and provided_type != .float) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' is provided while expected an integer or float", .{provided_type});
        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkIntOrFloatOrPointer(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type != .int and provided_type != .float and provided_type != .pointer) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' is provided while expected an integer or float or pointer", .{provided_type});

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkInt(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type != .int) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' is provided while expected an integer", .{provided_type});

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkIntType(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type != .int) {
        var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

        try error_message_buf.writer(self.allocator).print("'{}' is provided while expected an integer type", .{provided_type});

        self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

        return error.WithMessage;
    }
}

fn checkCanBeCompared(self: *Sema, provided_type: Type, token_start: u32) Error!void {
    if (provided_type == .@"struct" or provided_type == .void or provided_type == .function) {
        try self.reportNotComparable(provided_type, token_start);
    }
}

fn reportIncompatibleTypes(self: *Sema, lhs: Type, rhs: Type, token_start: u32) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{}' is not compatible with '{}'", .{ lhs, rhs });

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

    return error.WithMessage;
}

fn reportNotDeclared(self: *Sema, name: Name) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{s}' is not declared", .{name.buffer});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}

fn reportRedeclaration(self: *Sema, name: Name) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("redeclaration of '{s}'", .{name.buffer});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}

fn reportTypeNotDeclared(self: *Sema, name: Name) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("type '{s}' is not declared", .{name.buffer});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}

fn reportTypeNotExpression(self: *Sema, name: Name) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{s}' is a type not an expression", .{name.buffer});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}

fn reportNotPointer(self: *Sema, provided_type: Type, token_start: u32) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{}' is not a pointer", .{provided_type});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

    return error.WithMessage;
}

fn reportNotIndexable(self: *Sema, provided_type: Type, token_start: u32) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{}' does not support indexing", .{provided_type});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

    return error.WithMessage;
}

fn reportNotComparable(self: *Sema, provided_type: Type, token_start: u32) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{}' does not support comparison", .{provided_type});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, token_start) };

    return error.WithMessage;
}

fn reportCircularDependency(self: *Sema, name: Name) Error!noreturn {
    var error_message_buf: std.ArrayListUnmanaged(u8) = .{};

    try error_message_buf.writer(self.allocator).print("'{s}' is circularly dependent on itself", .{name.buffer});

    self.error_info = .{ .message = error_message_buf.items, .source_loc = SourceLoc.find(self.module.file.buffer, name.token_start) };

    return error.WithMessage;
}
