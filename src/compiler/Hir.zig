//! High Intermediate Representation.
//!
//! An unchecked stack-based intermediate representation lowered from `Ast`.
//! Passed to `Sema` which checks all the instructions and types to be valid and lowers it down to `Lir`,
//! And then `Lir` gets lowered down to machine code.

const std = @import("std");

const Ast = @import("Ast.zig");
const Symbol = @import("Symbol.zig");
const Type = @import("Type.zig");

const Hir = @This();

instructions: std.ArrayListUnmanaged(Instruction) = .{},

pub const Instruction = union(enum) {
    /// Start a labeled block, the boolean specifies whether this is a label for a function or a label for a global variable
    label: struct { bool, Ast.Name },
    /// Start a function block, pass the function declaration node to enable more checks
    function_proluge: Ast.Node.Stmt.FunctionDeclaration,
    /// End a function block
    function_epilogue,
    /// Declare a function parameter
    function_parameter,
    /// Call a specific function pointer on the stack with the specified argument count
    call: struct { usize, Ast.SourceLoc },
    /// Declare a constant using the specified name and type
    constant: Symbol,
    /// Same as `constant` but the type is unknown at the point of declaration
    constant_infer: Symbol,
    /// Declare a variable using the specified name and type
    variable: Symbol,
    /// Same as `variable` but the type is unknown at the point of declaration
    variable_infer: Symbol,
    /// Set a value using the specified name
    set: Ast.Name,
    /// Get a value using the specified name
    get: Ast.Name,
    /// Push a string onto the stack
    string: []const u8,
    /// Push an integer onto the stack
    int: i128,
    /// Push a float onto the stack
    float: f64,
    /// Negate an integer or float
    negate: Ast.SourceLoc,
    /// Reverse a boolean from true to false and from false to true
    bool_not: Ast.SourceLoc,
    /// Reverse the bits of an integer on the stack
    bit_not: Ast.SourceLoc,
    /// Get a pointer of a value on the stack
    reference: Ast.SourceLoc,
    /// Read the data that the pointer is pointing to
    read: Ast.SourceLoc,
    /// Override the data that the pointer is pointing to
    write: Ast.SourceLoc,
    /// Add two integers or floats on the top of the stack
    add: Ast.SourceLoc,
    /// Subtract two integers or floats on the top of the stack
    sub: Ast.SourceLoc,
    /// Multiply two integers or floats on the top of the stack
    mul: Ast.SourceLoc,
    /// Divide two integers or floats on the top of the stack
    div: Ast.SourceLoc,
    /// Compare between two integers or floats on the stack and check for order (in this case, lhs less than rhs)
    lt: Ast.SourceLoc,
    /// Compare between two integers or floats on the stack and check for order (in this case, lhs greater than rhs)
    gt: Ast.SourceLoc,
    /// Compare between two values on the stack and check for equality
    eql: Ast.SourceLoc,
    /// Shift to left the bits of lhs using rhs offset
    shl: Ast.SourceLoc,
    /// Shift to right the bits of lhs using rhs offset
    shr: Ast.SourceLoc,
    /// Place a machine-specific assembly in the output
    assembly: Ast.Node.Expr.Assembly,
    /// Pop a value from the stack
    pop,
    /// Return to the parent block
    @"return",
};

pub const Generator = struct {
    allocator: std.mem.Allocator,

    hir: Hir = .{},

    in_function: bool = false,

    error_info: ?ErrorInfo = null,

    pub const ErrorInfo = struct {
        message: []const u8,
        source_loc: Ast.SourceLoc,
    };

    pub const Error = error{
        UnexpectedStatement,
        UnexpectedExpression,
        UnsupportedFeature,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator) Generator {
        return Generator{
            .allocator = allocator,
        };
    }

    pub fn generate(self: *Generator, ast: Ast) Error!void {
        for (ast.body) |node| {
            try self.generateNode(node);
        }
    }

    fn generateNode(self: *Generator, node: Ast.Node) Error!void {
        switch (node) {
            .stmt => |stmt| try self.generateStmt(stmt),
            .expr => |expr| {
                if (!self.in_function and expr != .assembly) {
                    self.error_info = .{ .message = "did not expect an expression to be in top level", .source_loc = expr.getSourceLoc() };

                    return error.UnexpectedExpression;
                }

                try self.generateExpr(expr);

                try self.hir.instructions.append(self.allocator, .pop);
            },
        }
    }

    fn generateStmt(self: *Generator, stmt: Ast.Node.Stmt) Error!void {
        switch (stmt) {
            .function_declaration => try self.generateFunctionDeclarationStmt(stmt.function_declaration),

            .variable_declaration => try self.generateVariableDeclarationStmt(stmt.variable_declaration),

            .@"return" => try self.generateReturnStmt(stmt.@"return"),
        }
    }

    fn generateFunctionDeclarationStmt(self: *Generator, function: Ast.Node.Stmt.FunctionDeclaration) Error!void {
        if (self.in_function) {
            self.error_info = .{ .message = "cannot declare functions inside other functions", .source_loc = function.prototype.name.source_loc };

            return error.UnexpectedStatement;
        }

        self.in_function = true;
        defer self.in_function = false;

        try self.hir.instructions.append(self.allocator, .{ .label = .{ true, function.prototype.name } });

        var function_parameter_types: std.ArrayListUnmanaged(Type) = .{};

        for (function.prototype.parameters) |ast_function_parameter| {
            try function_parameter_types.append(self.allocator, ast_function_parameter.expected_type);
        }

        const function_return_type_on_heap = try self.allocator.create(Type);
        function_return_type_on_heap.* = function.prototype.return_type;

        const function_symbol: Symbol = .{
            .name = function.prototype.name,
            .type = .{
                .tag = .function,
                .data = .{
                    .function = .{
                        .parameter_types = try function_parameter_types.toOwnedSlice(self.allocator),
                        .return_type = function_return_type_on_heap,
                    },
                },
            },
            .linkage = .global,
        };

        try self.hir.instructions.append(self.allocator, .{ .variable = function_symbol });

        try self.hir.instructions.append(self.allocator, .{ .function_proluge = function });

        for (0..function.prototype.parameters.len) |_| {
            try self.hir.instructions.append(self.allocator, .function_parameter);
        }

        for (function.body) |node| {
            try self.generateNode(node);
        }

        try self.hir.instructions.append(self.allocator, .function_epilogue);

        try self.hir.instructions.append(self.allocator, .@"return");
    }

    fn generateVariableDeclarationStmt(self: *Generator, variable: Ast.Node.Stmt.VariableDeclaration) Error!void {
        if (!self.in_function) try self.hir.instructions.append(self.allocator, .{ .label = .{ false, variable.name } });

        try self.generateExpr(variable.value);

        try self.hir.instructions.append(
            self.allocator,
            if (variable.type) |@"type"|
                if (variable.is_const)
                    .{
                        .constant = .{
                            .name = variable.name,
                            .type = @"type",
                            .linkage = if (self.in_function) .local else .global,
                        },
                    }
                else
                    .{
                        .variable = .{
                            .name = variable.name,
                            .type = @"type",
                            .linkage = if (self.in_function) .local else .global,
                        },
                    }
            else if (variable.is_const)
                .{
                    .constant_infer = .{
                        .name = variable.name,
                        .type = .{ .tag = .void },
                        .linkage = if (self.in_function) .local else .global,
                    },
                }
            else
                .{
                    .variable_infer = .{
                        .name = variable.name,
                        .type = .{ .tag = .void },
                        .linkage = if (self.in_function) .local else .global,
                    },
                },
        );

        try self.hir.instructions.append(self.allocator, .{ .set = variable.name });
    }

    fn generateReturnStmt(self: *Generator, @"return": Ast.Node.Stmt.Return) Error!void {
        if (!self.in_function) {
            self.error_info = .{ .message = "expected the return statement to be inside a function", .source_loc = @"return".source_loc };

            return error.UnexpectedStatement;
        }

        try self.generateExpr(@"return".value);

        try self.hir.instructions.append(self.allocator, .function_epilogue);

        try self.hir.instructions.append(self.allocator, .@"return");
    }

    fn generateExpr(self: *Generator, expr: Ast.Node.Expr) Error!void {
        switch (expr) {
            .identifier => |identifier| try self.generateIdentifierExpr(identifier),

            .string => |string| try self.generateStringExpr(string),

            .int => |int| try self.generateIntExpr(int),

            .float => |float| try self.generateFloatExpr(float),

            .assembly => |assembly| try self.generateAssemblyExpr(assembly),

            .unary_operation => |unary_operation| try self.generateUnaryOperationExpr(unary_operation),

            .binary_operation => |binary_operation| try self.generateBinaryOperationExpr(binary_operation),

            .call => |call| try self.generateCallExpr(call),
        }
    }

    fn generateIdentifierExpr(self: *Generator, identifier: Ast.Node.Expr.Identifier) Error!void {
        try self.hir.instructions.append(self.allocator, .{ .get = identifier.name });
    }

    fn generateStringExpr(self: *Generator, string: Ast.Node.Expr.String) Error!void {
        try self.hir.instructions.append(self.allocator, .{ .string = string.value });
    }

    fn generateIntExpr(self: *Generator, int: Ast.Node.Expr.Int) Error!void {
        try self.hir.instructions.append(self.allocator, .{ .int = int.value });
    }

    fn generateFloatExpr(self: *Generator, float: Ast.Node.Expr.Float) Error!void {
        try self.hir.instructions.append(self.allocator, .{ .float = float.value });
    }

    fn generateAssemblyExpr(self: *Generator, assembly: Ast.Node.Expr.Assembly) Error!void {
        for (assembly.input_constraints) |input_constraint| {
            try self.generateExpr(input_constraint.value.*);
        }

        try self.hir.instructions.append(self.allocator, .{ .assembly = assembly });
    }

    fn generateUnaryOperationExpr(self: *Generator, unary_operation: Ast.Node.Expr.UnaryOperation) Error!void {
        try self.generateExpr(unary_operation.rhs.*);

        switch (unary_operation.operator) {
            .minus => {
                try self.hir.instructions.append(self.allocator, .{ .negate = unary_operation.source_loc });
            },

            .bang => {
                try self.hir.instructions.append(self.allocator, .{ .bool_not = unary_operation.source_loc });
            },

            .tilde => {
                try self.hir.instructions.append(self.allocator, .{ .bit_not = unary_operation.source_loc });
            },

            .ampersand => {
                try self.hir.instructions.append(self.allocator, .{ .reference = unary_operation.source_loc });
            },

            .star => {
                try self.hir.instructions.append(self.allocator, .{ .read = unary_operation.source_loc });
            },
        }
    }

    fn generateBinaryOperationExpr(self: *Generator, binary_operation: Ast.Node.Expr.BinaryOperation) Error!void {
        switch (binary_operation.operator) {
            .plus => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .add = binary_operation.source_loc });
            },

            .minus => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .sub = binary_operation.source_loc });
            },

            .star => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .mul = binary_operation.source_loc });
            },

            .forward_slash => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .div = binary_operation.source_loc });
            },

            .equal_sign => {
                if (binary_operation.lhs.* == .unary_operation and binary_operation.lhs.unary_operation.operator == .star) {
                    try self.generateExpr(binary_operation.lhs.unary_operation.rhs.*);
                    try self.generateExpr(binary_operation.rhs.*);

                    try self.hir.instructions.append(self.allocator, .{ .write = binary_operation.source_loc });
                } else if (binary_operation.lhs.* == .identifier) {
                    try self.generateExpr(binary_operation.rhs.*);

                    try self.hir.instructions.append(self.allocator, .{ .set = binary_operation.lhs.identifier.name });
                } else {
                    self.error_info = .{ .message = "expected an identifier or a pointer dereference", .source_loc = binary_operation.lhs.getSourceLoc() };

                    return error.UnexpectedExpression;
                }

                try self.generateExpr(binary_operation.rhs.*);
            },

            .less_than => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .lt = binary_operation.source_loc });
            },

            .greater_than => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .gt = binary_operation.source_loc });
            },

            .double_less_than => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .shl = binary_operation.source_loc });
            },

            .double_greater_than => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .shr = binary_operation.source_loc });
            },

            .double_equal_sign, .bang_equal_sign => {
                try self.generateExpr(binary_operation.lhs.*);
                try self.generateExpr(binary_operation.rhs.*);

                try self.hir.instructions.append(self.allocator, .{ .eql = binary_operation.source_loc });

                if (binary_operation.operator == .bang_equal_sign) {
                    try self.hir.instructions.append(self.allocator, .{ .bool_not = binary_operation.source_loc });
                }
            },
        }
    }

    fn generateCallExpr(self: *Generator, call: Ast.Node.Expr.Call) Error!void {
        for (call.arguments) |argument| {
            try self.generateExpr(argument);
        }

        try self.generateExpr(call.callable.*);

        try self.hir.instructions.append(self.allocator, .{ .call = .{ call.arguments.len, call.source_loc } });
    }
};
