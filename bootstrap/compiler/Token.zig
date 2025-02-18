const std = @import("std");

tag: Tag,
range: Range,

pub const Tag = enum(u8) {
    eof,
    invalid,
    identifier,
    special_identifier,
    string_literal,
    char_literal,
    int,
    float,
    open_paren,
    close_paren,
    open_brace,
    close_brace,
    open_bracket,
    close_bracket,
    comma,
    period,
    double_period,
    triple_period,
    colon,
    semicolon,
    fat_arrow,
    plus,
    minus,
    star,
    divide,
    modulo,
    bool_not,
    bit_not,
    bit_and,
    bit_or,
    bit_xor,
    less_than,
    greater_than,
    less_or_eql,
    greater_or_eql,
    left_shift,
    right_shift,
    eql,
    not_eql,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    divide_assign,
    modulo_assign,
    bit_and_assign,
    bit_or_assign,
    bit_xor_assign,
    left_shift_assign,
    right_shift_assign,
    keyword_defer,
    keyword_struct,
    keyword_enum,
    keyword_pub,
    keyword_extern,
    keyword_export,
    keyword_fn,
    keyword_var,
    keyword_const,
    keyword_type,
    keyword_switch,
    keyword_if,
    keyword_else,
    keyword_while,
    keyword_break,
    keyword_continue,
    keyword_asm,
    keyword_as,
    keyword_return,
};

pub const Range = packed struct(u64) {
    start: u32,
    end: u32,
};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "defer", .keyword_defer },
    .{ "struct", .keyword_struct },
    .{ "enum", .keyword_enum },
    .{ "pub", .keyword_pub },
    .{ "extern", .keyword_extern },
    .{ "export", .keyword_export },
    .{ "fn", .keyword_fn },
    .{ "var", .keyword_var },
    .{ "const", .keyword_const },
    .{ "type", .keyword_type },
    .{ "switch", .keyword_switch },
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "while", .keyword_while },
    .{ "break", .keyword_break },
    .{ "continue", .keyword_continue },
    .{ "asm", .keyword_asm },
    .{ "as", .keyword_as },
    .{ "return", .keyword_return },
});
