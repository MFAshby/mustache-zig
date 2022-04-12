// Bench suite based on Ramhorns benchmarkw
// https://github.com/maciejhirsz/ramhorns/tree/master/tests/benches

const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache");
const TIMES = if (builtin.mode == .Debug) 10_000 else 1_000_000;

const Mode = enum {
    Counter,
    String,
    Writer,
};

pub fn main() anyerror!void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        try simpleTemplate(gpa.allocator(), .Counter);
        try simpleTemplate(gpa.allocator(), .String);
    } else {
        var file = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
        defer file.close();

        try simpleTemplate(std.heap.raw_c_allocator, .Counter, std.io.null_writer);
        try simpleTemplate(std.heap.raw_c_allocator, .String, std.io.null_writer);
        try simpleTemplate(std.heap.raw_c_allocator, .Writer, file.writer());
        try partialTemplates(std.heap.raw_c_allocator, .Counter, std.io.null_writer);
        try partialTemplates(std.heap.raw_c_allocator, .String, std.io.null_writer);
    }
}

pub fn simpleTemplate(allocator: Allocator, comptime mode: Mode, writer: anytype) !void {
    const template_text = "<title>{{&title}}</title><h1>{{&title}}</h1><div>{{{body}}}</div>";
    const fmt_template = "<title>{s}</title><h1>{s}</h1><div>{s}</div>";

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var template = (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false })).Success;
    defer template.deinit(allocator);

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    const reference = try repeat("Reference: Zig fmt", zigFmt, .{
        allocator,
        mode,
        fmt_template,
        .{ data.title, data.title, data.body },
        writer,
    }, null);
    _ = try repeat("Mustache pre-parsed", preParsed, .{ allocator, mode, template, data, writer }, reference);
    _ = try repeat("Mustache not parsed", notParsed, .{ allocator, mode, template_text, data, writer }, reference);
    std.debug.print("\n\n", .{});
}

pub fn partialTemplates(allocator: Allocator, comptime mode: Mode, writer: anytype) !void {
    const template_text =
        \\{{>head.html}}
        \\<body>
        \\    <div>{{body}}</div>
        \\    {{>footer.html}}
        \\</body>
    ;

    const head_partial_text =
        \\<head>
        \\    <title>{{title}}</title>
        \\</head>
    ;

    const footer_partial_text = "<footer>Sup?</footer>";

    var template = (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false })).Success;
    defer template.deinit(allocator);

    var head_template = (try mustache.parseText(allocator, head_partial_text, .{}, .{ .copy_strings = false })).Success;
    defer head_template.deinit(allocator);

    var footer_template = (try mustache.parseText(allocator, footer_partial_text, .{}, .{ .copy_strings = false })).Success;
    defer footer_template.deinit(allocator);

    var partial_templates = std.StringHashMap(mustache.Template).init(allocator);
    defer partial_templates.deinit();

    try partial_templates.put("head.html", head_template);
    try partial_templates.put("footer.html", footer_template);

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    _ = try repeat("Mustache pre-parsed partials", preParsedPartials, .{ allocator, mode, template, partial_templates, data, writer }, null);
    std.debug.print("\n\n", .{});
}

fn repeat(comptime caption: []const u8, comptime func: anytype, args: anytype, reference: ?i128) !i128 {
    var index: usize = 0;
    var total_bytes: usize = 0;

    const start = std.time.nanoTimestamp();
    while (index < TIMES) : (index += 1) {
        total_bytes += try @call(.{}, func, args);
    }
    const ellapsed = std.time.nanoTimestamp() - start;

    printSummary(caption, ellapsed, total_bytes, reference);
    return ellapsed;
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize, reference: ?i128) void {
    std.debug.print("{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_s});

    if (reference) |reference_time| {
        const perf = if (reference_time > 0) @intToFloat(f64, ellapsed) / @intToFloat(f64, reference_time) else 0;
        std.debug.print("Comparation {d:.3}x {s}\n", .{ perf, (if (perf > 0) "slower" else "faster") });
    }

    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@intToFloat(f64, ellapsed) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@intToFloat(f64, total_bytes) / 1024 / 1024) / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("\n", .{});
}

fn zigFmt(allocator: Allocator, mode: Mode, comptime fmt_template: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try std.fmt.format(counter.writer(), fmt_template, data);
            return counter.bytes_written;
        },
        .String => {
            const ret = try std.fmt.allocPrint(allocator, fmt_template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsed(allocator: Allocator, mode: Mode, template: mustache.Template, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.render(template, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRender(allocator, template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsedPartials(allocator: Allocator, mode: Mode, template: mustache.Template, partial_templates: anytype, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderPartialsWithOptions(template, partial_templates, data, counter.writer(), .{});
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRenderPartialsWithOptions(allocator, template, partial_templates, data, .{});
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsed(allocator: Allocator, mode: Mode, template_text: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderText(allocator, template_text, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRenderText(allocator, template_text, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}
