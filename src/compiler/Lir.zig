//! Low Intermediate Representation.
//!
//! An analyzed and checked stack-based intermediate representation lowered from `Hir`.
//! Returned from `Sema` and is the last intermediate representation to be used before lowering to machine code.

const std = @import("std");

const Symbol = @import("Symbol.zig");
const Type = Symbol.Type;

const Lir = @This();

external_variables: std.StringArrayHashMapUnmanaged(Type) = .{},
global_blocks: std.StringArrayHashMapUnmanaged(Block) = .{},
functions: std.StringArrayHashMapUnmanaged(Function) = .{},

pub const Function = struct {
    type: Type,
    blocks: std.StringArrayHashMapUnmanaged(Block) = .{},
};

pub const Block = struct {
    tag: Tag = .basic,
    instructions: std.ArrayListUnmanaged(Instruction) = .{},

    pub const Tag = enum {
        basic,
        control_flow,
    };

    pub const Instruction = union(enum) {
        /// Declare function parameters
        parameters: []const Symbol,
        /// Call a specific function pointer on the stack with the specified type
        call: Type.Function,
        /// Declare a variable using the specified name and type
        variable: Symbol,
        /// Set a value using the specified name
        set: []const u8,
        /// Get a value using the specified name
        get: []const u8,
        /// Get a pointer to value using the specified name
        get_ptr: []const u8,
        /// Push a string onto the stack
        string: []const u8,
        /// Push an integer onto the stack
        int: i128,
        /// Push a float onto the stack
        float: f64,
        /// Push a boolean onto the stack
        boolean: bool,
        /// Negate an integer or float
        negate,
        /// Reverse a boolean from true to false and from false to true
        bool_not,
        /// Perform bitwise NOT operation on the bits of rhs (Which is to reverse its bits representation)
        bit_not,
        /// Perform bitwise AND operation on the bits of lhs and rhs
        bit_and,
        /// Perform bitwise OR operation on the bits of lhs and rhs
        bit_or,
        /// Perform bitwise XOR operation on the bits of lhs and rhs
        bit_xor,
        /// Read the data that the pointer is pointing to
        read: Type,
        /// Override the data that the pointer is pointing to
        write,
        /// Add two integers or floats on the top of the stack
        add,
        /// Subtract two integers or floats on the top of the stack
        sub,
        /// Multiply two integers or floats on the top of the stack
        mul,
        /// Divide two integers or floats on the top of the stack
        div,
        /// Compare between two integers or floats on the stack and check for order (in this case, lhs less than rhs)
        lt,
        /// Compare between two integers or floats on the stack and check for order (in this case, lhs greater than rhs)
        gt,
        /// Compare between two values on the stack and check for equality
        eql,
        /// Shift to left the bits of lhs using rhs offset
        shl,
        /// Shift to right the bits of lhs using rhs offset
        shr,
        /// Jump to block if the value on stack is false
        jmp_if_false: []const u8,
        /// Jump to block
        jmp: []const u8,
        /// Place a machine-specific assembly in the output
        assembly: Assembly,
        /// Pop a value from the stack
        pop,
        /// Return out of the function
        @"return",

        pub const Assembly = struct {
            content: []const u8,
            input_constraints: []const []const u8,
            output_constraint: ?OutputConstraint,

            pub const OutputConstraint = struct {
                register: []const u8,
                type: Type,
            };
        };
    };
};

pub fn deinit(self: *Lir, allocator: std.mem.Allocator) void {
    for (self.global.values()) |*block| {
        block.instructions.deinit(allocator);
    }

    self.global.deinit(allocator);

    self.external.deinit(allocator);

    for (self.functions.values()) |*function| {
        for (function.blocks.values()) |*block| {
            block.instructions.deinit(allocator);
        }

        function.blocks.deinit(allocator);
    }

    self.functions.deinit(allocator);
}
