const std = @import("std");

tag: Tag,
range: Range,

pub const Tag = enum(u8) {
    eof,
    invalid,
    identifier,
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
    bang,
    tilde,
    ampersand,
    pipe,
    caret,
    comma,
    colon,
    semicolon,
    plus,
    minus,
    star,
    less_than,
    double_less_than,
    greater_than,
    double_greater_than,
    equal_sign,
    double_equal_sign,
    bang_equal_sign,
    forward_slash,
    keyword_extern,
    keyword_fn,
    keyword_var,
    keyword_const,
    keyword_type,
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
    .{ "extern", .keyword_extern },
    .{ "fn", .keyword_fn },
    .{ "var", .keyword_var },
    .{ "const", .keyword_const },
    .{ "type", .keyword_type },
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "while", .keyword_while },
    .{ "break", .keyword_break },
    .{ "continue", .keyword_continue },
    .{ "asm", .keyword_asm },
    .{ "as", .keyword_as },
    .{ "return", .keyword_return },
});
