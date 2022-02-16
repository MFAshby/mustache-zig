const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache.zig");
const MustacheError = mustache.MustacheError;
const TemplateOptions = mustache.TemplateOptions;
const Delimiters = mustache.Delimiters;

const scanner = @import("scanner/scanner.zig");

pub const Parser = scanner.Parser;

pub const LastError = struct {
    last_error: MustacheError,
    row: usize,
    col: usize,
    detail: ?[]const u8 = null,
};

pub const Interpolation = struct {
    escaped: bool,
    key: []const u8,
};

pub const Section = struct {
    inverted: bool,
    key: []const u8,
    content: ?[]const Element,
};

pub const Partials = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Inheritance = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Element = union(enum) {

    /// Static text
    StaticText: []const u8,

    /// Interpolation tags are used to integrate dynamic content into the template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the data to replace the tag.  A single period (`.`)
    /// indicates that the item currently sitting atop the context stack should be
    /// used; otherwise, name resolution is as follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object, the data is the value returned by the
    ///   method with the given name.
    ///   5) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// Data should be coerced into a string (and escaped, if appropriate) before
    /// interpolation.
    /// The Interpolation tags MUST NOT be treated as standalone.    
    Interpolation: Interpolation,

    /// Section tags and End Section tags are used in combination to wrap a section
    /// of the template for iteration
    /// These tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Section tag MUST be followed
    /// by an End Section tag with the same content within the same section.
    /// This tag's content names the data to replace the tag.  Name resolution is as
    /// follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object and the method with the given name has an
    ///   arity of 1, the method SHOULD be called with a String containing the
    ///   unprocessed contents of the sections; the data is the value returned.
    ///   5) Otherwise, the data is the value returned by calling the method with
    ///   the given name.
    ///   6) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// If the data is not of a list type, it is coerced into a list as follows: if
    /// the data is truthy (e.g. `!!data == true`), use a single-element list
    /// containing the data, otherwise use an empty list.
    /// For each element in the data list, the element MUST be pushed onto the
    /// context stack, the section MUST be rendered, and the element MUST be popped
    /// off the context stack.
    /// Section and End Section tags SHOULD be treated as standalone when
    /// appropriate.    
    Section: Section,

    /// Partial tags are used to expand an external template into the current
    /// template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the partial to inject.  Set Delimiter tags MUST NOT
    /// affect the parsing of a partial.  The partial MUST be rendered against the
    /// context stack local to the tag.  If the named partial cannot be found, the
    /// empty string SHOULD be used instead, as in interpolations.
    /// Partial tags SHOULD be treated as standalone when appropriate.  If this tag
    /// is used standalone, any whitespace preceding the tag should treated as
    /// indentation, and prepended to each line of the partial before rendering.    
    Partials: Partials,

    /// Like partials, Parent tags are used to expand an external template into the
    /// current template. Unlike partials, Parent tags may contain optional
    /// arguments delimited by Block tags. For this reason, Parent tags may also be
    /// referred to as Parametric Partials.
    /// The Parent tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Parent tag MUST be followed by
    /// an End Section tag with the same content within the matching Parent tag.
    /// This tag's content names the Parent template to inject. Set Delimiter tags
    /// Preceding a Parent tag MUST NOT affect the parsing of the injected external
    /// template. The Parent MUST be rendered against the context stack local to the
    /// tag. If the named Parent cannot be found, the empty string SHOULD be used
    /// instead, as in interpolations.
    /// Parent tags SHOULD be treated as standalone when appropriate. If this tag is
    /// used standalone, any whitespace preceding the tag should be treated as
    /// indentation, and prepended to each line of the Parent before rendering.
    /// The Block tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter. Each Block tag MUST be followed by
    /// an End Section tag with the same content within the matching Block tag. This
    /// tag's content determines the parameter or argument name.
    /// Block tags may appear both inside and outside of Parent tags. In both cases,
    /// they specify a position within the template that can be overridden; it is a
    /// parameter of the containing template. The template text between the Block tag
    /// and its matching End Section tag defines the default content to render when
    /// the parameter is not overridden from outside.
    /// In addition, when used inside of a Parent tag, the template text between a
    /// Block tag and its matching End Section tag defines content that replaces the
    /// default defined in the Parent template. This content is the argument passed
    /// to the Parent template.try self.parseAction(.Partial, content)
    /// The practice of injecting an external template using a Parent tag is referred
    /// to as inheritance. If the Parent tag includes a Block tag that overrides a
    /// parameter of the Parent template, this may also be referred to as
    /// substitution.
    /// Parent templates are taken from the same namespace as regular Partial
    /// templates and in fact, injecting a regular Partial is exactly equivalent to
    /// injecting a Parent without making any substitutions. Parameter and arguments
    /// names live in a namespace that is distinct from both Partials and the context.
    Inheritance: Inheritance,

    pub fn free(self: *Element, allocator: Allocator) void {
        switch (self) {
            .StaticText => |content| allocator.free(content),
            .Interpolation => |interpolation| allocator.free(interpolation.key),
            .Section => |section| {
                allocator.free(section.key);
                freeChildren(allocator, section.content);
            },

            .Partials => |partials| {
                allocator.free(partials.key);
                freeChildren(allocator, partials.content);
            },

            .Inheritance => |inheritance| {
                allocator.free(inheritance.key);
                freeChildren(allocator, inheritance.content);
            },
        }
    }

    fn freeChildren(allocator: Allocator, content: ?[]Element) void {
        if (content) |children| {
            for (children) |child| {
                child.free(allocator);
            }
        }
    }
};

pub const Template = struct {
    const Self = @This();

    allocator: Allocator,
    elements: ?[]const Element,
    last_error: ?LastError,

    pub fn init(allocator: Allocator, template_text: []const u8, options: TemplateOptions) !Template {
        var parser = scanner.Parser.init(allocator, template_text, options);
        defer parser.deinit();

        return try parser.parse();
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.allocator;

        for (self.elements) |element| {
            element.free(allocator);
        }

        allocator.free(self.elements);
    }
};

test {
    _ = @import("scanner/scanner.zig");
}
