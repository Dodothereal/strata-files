import Foundation

/// A language the code preview can highlight.
nonisolated package struct Language: Sendable {
    package let name: String
    package let lexer: Lexer

    package init(name: String, lexer: Lexer) {
        self.name = name
        self.lexer = lexer
    }
}

/// Language definitions, and detection from a file name.
nonisolated package enum Languages {
    /// The language for `fileName` (matched on exact names such as `Dockerfile` first, then the extension).
    package static func detect(fileName: String) -> Language? {
        let name = fileName.lowercased()
        if let language = byName[name] { return language }
        if name.hasPrefix(".env") || name.hasSuffix(".env") { return dotenv }
        if name.hasSuffix(".gradle.kts") { return kotlin }
        if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") || name.hasPrefix("containerfile") { return dockerfile }
        if name.hasSuffix("ignore") && name.hasPrefix(".") { return ignoreList }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[String(name[name.index(after: dot)...])]
    }

    /// Language for a fenced Markdown code block's info string (`swift`, `ts`, `shell`…).
    package static func detect(fenceInfo: String) -> Language? {
        let tag = fenceInfo.lowercased().split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        guard !tag.isEmpty else { return nil }
        return fenceAliases[tag] ?? byExtension[tag] ?? byName[tag]
    }

    // MARK: C family

    package static let c = Language(name: "C", lexer: .generic(cRules(cKeywords, types: cTypes)))
    package static let cHeader = Language(name: "C Header", lexer: .generic(cRules(cKeywords.union(objcKeywords), types: cTypes, objc: true)))
    package static let cpp = Language(name: "C++", lexer: .generic(cRules(cKeywords.union(cppKeywords), types: cTypes, capitalized: true)))
    package static let objc = Language(name: "Objective-C", lexer: .generic(cRules(cKeywords.union(objcKeywords), types: cTypes, objc: true)))
    package static let objcpp = Language(name: "Objective-C++", lexer: .generic(cRules(cKeywords.union(cppKeywords).union(objcKeywords), types: cTypes, objc: true)))
    package static let shader = Language(name: "Shader", lexer: .generic(cRules(cKeywords.union(cppKeywords).union(shaderKeywords), types: cTypes.union(shaderTypes), capitalized: true)))

    package static let swift = Language(name: "Swift", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], nestedComments: true,
        strings: [.tripleDouble, .double],
        keywords: words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private \
            precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer \
            do else fallthrough for guard if in repeat return throw switch where while as false is nil self Self super throws true \
            try await async actor nonisolated isolated some any consume borrowing consuming sending mutating nonmutating override \
            final lazy weak unowned convenience required dynamic indirect optional macro package each get set willSet didSet then
            """),
        declarationKeywords: words("class struct enum protocol extension func typealias actor associatedtype macro let var case"),
        capitalizedTypes: true, functionCalls: true, allCapsTypes: true, attributePrefix: "@", preprocessorPrefix: "#",
        preprocessorAnywhere: true)))

    package static let rust = Language(name: "Rust", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], nestedComments: true,
        strings: [.double], stringPrefixes: ["r", "b", "br", "r#", "c"],
        keywords: words("""
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub \
            ref return self Self static struct super trait true type unsafe use where while union macro_rules yield
            """),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        declarationKeywords: words("fn struct enum trait type mod union let const static"),
        capitalizedTypes: true, functionCalls: true, rustSyntax: true)))

    package static let javaScript = Language(name: "JavaScript", lexer: .generic(jsRules(typeScript: false)))
    package static let typeScript = Language(name: "TypeScript", lexer: .generic(jsRules(typeScript: true)))

    package static let python = Language(name: "Python", lexer: .generic(LexRules(
        lineComments: ["#"],
        strings: [.tripleDouble, .tripleSingle, .double, .single],
        stringPrefixes: ["f", "r", "b", "u", "rb", "br", "fr", "rf"],
        keywords: words("""
            False None True and as assert async await break class continue def del elif else except finally for from global if \
            import in is lambda nonlocal not or pass raise return try while with yield match case self cls
            """),
        types: words("int float str bool list dict set tuple bytes bytearray object type complex frozenset"),
        declarationKeywords: words("def class"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let go = Language(name: "Go", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [.double, .single, StringRule(open: "`", close: "`", multiline: true, escapes: false)],
        keywords: words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface map package range \
            return select struct switch type var true false nil iota
            """),
        types: words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 \
            uint64 uintptr any comparable
            """),
        declarationKeywords: words("func type var const"),
        functionCalls: true)))

    package static let csharp = Language(name: "C#", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [.tripleDouble, .double, .single], stringPrefixes: ["@", "$", "$@", "@$"],
        keywords: words("""
            abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else \
            enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long \
            namespace new null object operator out override params private protected public readonly ref return sbyte sealed short \
            sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual \
            void volatile while var async await dynamic get set init record yield when where nameof partial global value required \
            file scoped with not and or
            """),
        declarationKeywords: words("class struct interface enum record namespace"),
        capitalizedTypes: true, functionCalls: true, preprocessorPrefix: "#")))

    package static let java = Language(name: "Java", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [.tripleDouble, .double, .single],
        keywords: words("""
            abstract assert boolean break byte case catch char class const continue default do double else enum extends final \
            finally float for goto if implements import instanceof int interface long native new package private protected public \
            return short static strictfp super switch synchronized this throw throws transient try void volatile while true false \
            null var record sealed permits yield
            """),
        declarationKeywords: words("class interface enum record"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let kotlin = Language(name: "Kotlin", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], nestedComments: true,
        strings: [.tripleDouble, .double, .single],
        keywords: words("""
            as break class continue do else false for fun if in interface is null object package return super this throw true try \
            typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param \
            property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external \
            final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed \
            suspend tailrec vararg value
            """),
        declarationKeywords: words("class interface object fun val var typealias"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let scala = Language(name: "Scala", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], nestedComments: true,
        strings: [.tripleDouble, .double, .single], stringPrefixes: ["s", "f", "raw"],
        keywords: words("""
            abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new null \
            object override package private protected return sealed super this throw trait try true type val var while with yield \
            given using enum then export
            """),
        declarationKeywords: words("class object trait def val var type enum"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let groovy = Language(name: "Groovy", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [.tripleDouble, .tripleSingle, .double, .single],
        keywords: words("""
            def class interface enum trait extends implements import package return if else for while switch case default break \
            continue try catch finally throw new this super true false null in as instanceof static final public private protected \
            void int boolean
            """),
        declarationKeywords: words("def class interface enum trait"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let gradle = Language(name: "Gradle", lexer: groovy.lexer)

    package static let dart = Language(name: "Dart", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], nestedComments: true,
        strings: [.tripleDouble, .tripleSingle, .double, .single], stringPrefixes: ["r"],
        keywords: words("""
            abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else \
            enum export extends extension external factory false final finally for Function get hide if implements import in \
            interface is late library mixin new null on operator part required rethrow return sealed set show static super switch \
            sync this throw true try typedef var void when while with yield
            """),
        types: words("int double num bool String List Map Set Future Stream Object"),
        declarationKeywords: words("class enum mixin extension typedef"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let ruby = Language(name: "Ruby", lexer: .generic(LexRules(
        lineComments: ["#"], blockComments: [("=begin", "=end")], commentNeedsBoundary: true,
        strings: [.double, .single, .backtick],
        keywords: words("""
            BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not \
            or redo rescue retry return self super then true undef unless until when while yield require require_relative \
            attr_accessor attr_reader attr_writer private protected public include extend raise lambda proc
            """),
        declarationKeywords: words("def class module"),
        capitalizedTypes: true, identifierExtras: "?!", attributePrefix: "@", variablePrefix: "$", symbols: true)))

    package static let php = Language(name: "PHP", lexer: .generic(LexRules(
        lineComments: ["//", "#"], blockComments: [("/*", "*/")],
        strings: [.double, .single, .backtick],
        keywords: words("""
            abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty \
            enddeclare endfor endforeach endif endswitch endwhile eval exit extends final finally fn for foreach function global goto \
            if implements include include_once instanceof insteadof interface isset list match namespace new or print private \
            protected public readonly require require_once return static switch throw trait try unset use var while xor yield true \
            false null self parent enum
            """),
        declarationKeywords: words("function class interface trait enum"),
        capitalizedTypes: true, functionCalls: true, variablePrefix: "$")))

    package static let shell = Language(name: "Shell", lexer: .generic(shellRules))
    package static let fish = Language(name: "Fish", lexer: .generic(shellRules))
    package static let powershell = Language(name: "PowerShell", lexer: .generic(LexRules(
        lineComments: ["#"], blockComments: [("<#", "#>")],
        strings: [.double, .single],
        keywords: words("""
            begin break catch class continue data define do dynamicparam else elseif end exit filter finally for foreach from \
            function if in param process return switch throw trap try until using var while true false null
            """),
        declarationKeywords: words("function class filter"),
        caseInsensitive: true, identifierExtras: "-", variablePrefix: "$")))

    package static let sql = Language(name: "SQL", lexer: .generic(LexRules(
        lineComments: ["--", "#"], blockComments: [("/*", "*/")], commentNeedsBoundary: true,
        strings: [.single, StringRule(open: "\"", close: "\"", escapes: false, kind: .key), StringRule(open: "`", close: "`", escapes: false, kind: .key)],
        keywords: words("""
            select from where and or not insert into values update set delete create table view index drop alter add column primary \
            key foreign references unique null is in exists between like glob limit offset order by group having join inner left \
            right outer full cross on as distinct union all case when then else end begin commit rollback transaction if replace \
            default constraint check trigger returning with recursive asc desc cascade autoincrement true false pragma explain \
            using natural over partition window collate escape except intersect conflict abort fail ignore temp temporary \
            virtual rowid without do nothing materialized
            """),
        types: words("""
            integer int smallint bigint tinyint text varchar char nchar nvarchar clob real double float numeric decimal boolean \
            bool date datetime time timestamp timestamptz interval blob bytea json jsonb uuid serial bigserial
            """),
        caseInsensitive: true, functionCalls: true)))

    package static let lua = Language(name: "Lua", lexer: .generic(LexRules(
        lineComments: ["--"], blockComments: [("--[[", "]]"), ("--[==[", "]==]")],
        strings: [StringRule(open: "[[", close: "]]", multiline: true, escapes: false), .double, .single],
        keywords: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while self"),
        declarationKeywords: words("function local"),
        functionCalls: true)))

    package static let gdscript = Language(name: "GDScript", lexer: .generic(LexRules(
        lineComments: ["#"],
        strings: [.tripleDouble, .double, .single], stringPrefixes: ["&", "^", "r"],
        keywords: words("""
            if elif else for while match break continue pass return class class_name extends is in as self signal func static \
            const enum var breakpoint preload await yield assert void PI TAU INF NAN true false null and or not super when
            """),
        types: words("int float bool"),
        declarationKeywords: words("func class_name class signal var const enum"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@", variablePrefix: "$")))

    package static let elixir = Language(name: "Elixir", lexer: .generic(LexRules(
        lineComments: ["#"], strings: [.tripleDouble, .double, .single],
        keywords: words("""
            def defp defmodule defmacro defstruct defprotocol defimpl do end fn if else unless case cond with when true false nil \
            import alias require use quote unquote receive try catch rescue after raise and or not in
            """),
        declarationKeywords: words("def defp defmodule defmacro"),
        capitalizedTypes: true, identifierExtras: "?!", attributePrefix: "@", symbols: true)))

    package static let haskell = Language(name: "Haskell", lexer: .generic(LexRules(
        lineComments: ["--"], blockComments: [("{-", "-}")], nestedComments: true,
        strings: [.double],
        keywords: words("""
            module where import qualified as hiding data type newtype class instance deriving if then else case of let in do \
            forall infixl infixr infix family
            """),
        capitalizedTypes: true, identifierExtras: "'")))

    package static let lisp = Language(name: "Lisp", lexer: .generic(LexRules(
        lineComments: [";"], strings: [.double],
        keywords: words("def defn defn- defmacro defun defvar defparameter let let* fn lambda if do loop recur cond when unless ns require import quote"),
        declarationKeywords: words("def defn defn- defmacro defun defvar"),
        identifierExtras: "-?!*<>=/+.", symbols: true)))

    package static let r = Language(name: "R", lexer: .generic(LexRules(
        lineComments: ["#"], strings: [.double, .single],
        keywords: words("if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA library require return"),
        functionCalls: true, identifierExtras: ".")))

    package static let perl = Language(name: "Perl", lexer: .generic(LexRules(
        lineComments: ["#"], commentNeedsBoundary: true, strings: [.double, .single],
        keywords: words("my our local sub use package if elsif else unless while until for foreach return last next redo require no and or not eq ne lt gt le ge"),
        declarationKeywords: words("sub package"),
        variablePrefix: "$")))

    package static let zig = Language(name: "Zig", lexer: .generic(LexRules(
        lineComments: ["//"], strings: [.double, .single],
        keywords: words("""
            const var fn pub return if else while for switch struct enum union error try catch defer errdefer comptime test \
            usingnamespace and or orelse unreachable undefined null true false inline export extern packed opaque anytype
            """),
        types: words("u8 u16 u32 u64 usize i8 i16 i32 i64 isize f16 f32 f64 bool void type anyerror noreturn"),
        declarationKeywords: words("fn const var"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let julia = Language(name: "Julia", lexer: .generic(LexRules(
        lineComments: ["#"], blockComments: [("#=", "=#")], strings: [.tripleDouble, .double],
        keywords: words("function end if else elseif for while return module using import export struct mutable abstract type begin let do try catch finally true false nothing const local global macro quote"),
        declarationKeywords: words("function struct module macro"),
        capitalizedTypes: true, functionCalls: true, attributePrefix: "@")))

    package static let protobuf = Language(name: "Protocol Buffers", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], strings: [.double, .single],
        keywords: words("syntax package import option message enum service rpc returns repeated optional required oneof map reserved extensions extend stream to max true false public weak edition"),
        types: words("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes"),
        declarationKeywords: words("message enum service rpc"),
        capitalizedTypes: true)))

    package static let graphql = Language(name: "GraphQL", lexer: .generic(LexRules(
        lineComments: ["#"], strings: [.tripleDouble, .double],
        keywords: words("query mutation subscription fragment on type interface union enum input scalar schema extend implements directive true false null"),
        declarationKeywords: words("query mutation subscription fragment type interface union enum input scalar"),
        capitalizedTypes: true, attributePrefix: "@", variablePrefix: "$")))

    package static let hcl = Language(name: "HCL", lexer: .generic(LexRules(
        lineComments: ["#", "//"], blockComments: [("/*", "*/")], strings: [.double],
        keywords: words("resource data variable output module provider locals terraform true false null for in if each count"),
        functionCalls: true, identifierExtras: "-", keyAssignment: "=")))

    package static let cmake = Language(name: "CMake", lexer: .generic(LexRules(
        lineComments: ["#"], strings: [.double],
        keywords: words("if else elseif endif foreach endforeach while endwhile function endfunction macro endmacro return"),
        caseInsensitive: true, functionCalls: true, variablePrefix: "$")))

    package static let makefile = Language(name: "Makefile", lexer: .generic(LexRules(
        lineComments: ["#"], commentNeedsBoundary: true, strings: [.double, .single],
        keywords: words("include -include sinclude ifeq ifneq ifdef ifndef else endif define endef export unexport override vpath"),
        identifierExtras: "-./%", variablePrefix: "$", variableParens: true, keyAssignment: "=:")))

    package static let dockerfile = Language(name: "Dockerfile", lexer: .generic(LexRules(
        lineComments: ["#"], commentNeedsBoundary: true, strings: [.double, .single],
        keywords: ["as"],
        lineStartKeywords: words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"),
        caseInsensitive: true, variablePrefix: "$")))

    // MARK: Data and config

    package static let json = Language(name: "JSON", lexer: .json)
    package static let jsonLines = Language(name: "JSON Lines", lexer: .json)
    package static let yaml = Language(name: "YAML", lexer: .yaml)
    package static let toml = Language(name: "TOML", lexer: .generic(configRules(comments: ["#"], tripleQuotes: true)))
    package static let ini = Language(name: "INI", lexer: .generic(configRules(comments: ["#", ";"])))
    package static let properties = Language(name: "Properties", lexer: .generic(configRules(comments: ["#", "!"], assignment: "=:")))
    package static let dotenv = Language(name: "Environment", lexer: .generic(configRules(comments: ["#"], keywords: ["export"], variables: true)))
    package static let xcconfig = Language(name: "Xcode Config", lexer: .generic(configRules(comments: ["//"], variables: true)))
    package static let godotResource = Language(name: "Godot Resource", lexer: .generic(configRules(comments: [";"], functions: true)))
    package static let ignoreList = Language(name: "Ignore List", lexer: .generic(LexRules(lineComments: ["#"], strings: [])))
    package static let pbxproj = Language(name: "Xcode Project", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], strings: [.double], identifierExtras: ".", keyAssignment: "=")))
    package static let stringsFile = Language(name: "Strings", lexer: .generic(LexRules(
        lineComments: ["//"], blockComments: [("/*", "*/")], strings: [.double])))

    package static let html = Language(name: "HTML", lexer: .markup)
    package static let xml = Language(name: "XML", lexer: .markup)
    package static let plist = Language(name: "Property List", lexer: .markup)
    package static let css = Language(name: "CSS", lexer: .css(lineComments: false))
    package static let scss = Language(name: "SCSS", lexer: .css(lineComments: true))
    package static let less = Language(name: "Less", lexer: .css(lineComments: true))
    package static let diff = Language(name: "Diff", lexer: .diff)

    /// Values on the right of a YAML key.
    package static let yamlValueRules = LexRules(
        lineComments: ["#"], commentNeedsBoundary: true, strings: [.double, StringRule(open: "'", close: "'", escapes: false)],
        keywords: words("true false null yes no on off True False Null TRUE FALSE NULL Yes No ~"),
        identifierExtras: "-./")

    // MARK: Rule builders

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    private static let cKeywords = words("""
        auto break case char const continue default do double else enum extern float for goto if inline int long register \
        restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex \
        _Atomic _Thread_local _Noreturn _Static_assert _Alignas _Alignof bool true false NULL nullptr
        """)
    private static let cppKeywords = words("""
        alignas alignof and asm catch char8_t char16_t char32_t class co_await co_return co_yield concept const_cast consteval \
        constexpr constinit decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or \
        private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid \
        typename using virtual wchar_t override final
        """)
    private static let objcKeywords = words("""
        @interface @implementation @end @property @protocol @class @selector @synthesize @dynamic @autoreleasepool @try @catch \
        @finally @throw @optional @required @public @private @protected @package @import @encode @available self super nil Nil \
        YES NO id instancetype SEL BOOL IBOutlet IBAction nonatomic atomic strong weak copy assign retain readonly readwrite \
        nullable nonnull _Nullable _Nonnull __weak __strong __block __kindof
        """)
    private static let shaderKeywords = words("""
        uniform varying attribute in out inout layout precision highp mediump lowp discard kernel vertex fragment device \
        constant threadgroup shader_type render_mode instance global
        """)
    private static let cTypes = words("""
        size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE \
        wchar_t off_t pid_t
        """)
    private static let shaderTypes = words("""
        vec2 vec3 vec4 ivec2 ivec3 ivec4 mat2 mat3 mat4 sampler2D samplerCube float2 float3 float4 half half2 half3 half4 \
        float2x2 float3x3 float4x4 texture2d
        """)

    private static func cRules(_ keywords: Set<String>, types: Set<String>, capitalized: Bool = false, objc: Bool = false) -> LexRules {
        LexRules(
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: [.double, .single], stringPrefixes: objc ? ["@", "L", "u8", "u", "U", "R"] : ["L", "u8", "u", "U", "R"],
            keywords: keywords, types: types,
            declarationKeywords: words("struct enum union class namespace @interface @implementation @protocol"),
            capitalizedTypes: capitalized || objc, functionCalls: true, allCapsMacros: true,
            attributePrefix: objc ? "@" : nil, preprocessorPrefix: "#")
    }

    private static func jsRules(typeScript: Bool) -> LexRules {
        var keywords = words("""
            break case catch class const continue debugger default delete do else export extends finally for function if import \
            in instanceof new return super switch this throw try typeof var void while with yield let static async await of get \
            set from as true false null undefined NaN Infinity
            """)
        if typeScript {
            keywords.formUnion(words("""
                interface type enum implements namespace module declare abstract readonly private protected public keyof infer is \
                asserts satisfies override accessor
                """))
        }
        return LexRules(
            lineComments: ["//"], blockComments: [("/*", "*/")],
            strings: [.double, .single, .backtick],
            keywords: keywords,
            types: typeScript ? words("any unknown never number string boolean symbol bigint object void") : [],
            declarationKeywords: words("function class interface type enum namespace const let var"),
            capitalizedTypes: true, functionCalls: true, identifierExtras: "$", attributePrefix: "@")
    }

    private static let shellRules = LexRules(
        lineComments: ["#"], commentNeedsBoundary: true,
        strings: [.double, StringRule(open: "'", close: "'", multiline: true, escapes: false), .backtick],
        keywords: words("""
            if then else elif fi case esac for select while until do done in function time coproc return exit break continue local \
            export readonly declare typeset unset shift source alias set eval exec trap true false echo printf cd end begin \
            switch not and or
            """),
        declarationKeywords: words("function"),
        identifierExtras: "-", variablePrefix: "$")

    private static func configRules(comments: [String], assignment: String = "=", tripleQuotes: Bool = false,
                                    keywords: Set<String> = [], variables: Bool = false, functions: Bool = false) -> LexRules {
        var strings: [StringRule] = [.double, .single]
        if tripleQuotes { strings.insert(contentsOf: [.tripleDouble, StringRule(open: "'''", close: "'''", multiline: true, escapes: false)], at: 0) }
        return LexRules(
            lineComments: comments, commentNeedsBoundary: true, strings: strings,
            keywords: keywords.union(["true", "false"]),
            functionCalls: functions, identifierExtras: "-.", variablePrefix: variables ? "$" : nil, variableParens: variables,
            keyAssignment: assignment, sectionHeaders: true)
    }

    // MARK: Tables

    private static let byExtension: [String: Language] = [
        "swift": swift, "swiftinterface": swift,
        "rs": rust,
        "ts": typeScript, "tsx": typeScript, "mts": typeScript, "cts": typeScript,
        "js": javaScript, "jsx": javaScript, "mjs": javaScript, "cjs": javaScript,
        "py": python, "pyw": python, "pyi": python,
        "go": go,
        "c": c, "h": cHeader,
        "cpp": cpp, "cc": cpp, "cxx": cpp, "c++": cpp, "hpp": cpp, "hh": cpp, "hxx": cpp, "ipp": cpp, "inl": cpp, "tpp": cpp,
        "m": objc, "mm": objcpp,
        "metal": shader, "glsl": shader, "vert": shader, "frag": shader, "hlsl": shader, "gdshader": shader, "shader": shader,
        "cs": csharp, "csx": csharp,
        "java": java, "kt": kotlin, "kts": kotlin, "scala": scala, "sc": scala, "groovy": groovy, "gradle": gradle,
        "dart": dart,
        "rb": ruby, "rake": ruby, "gemspec": ruby, "podspec": ruby, "ru": ruby,
        "php": php, "phtml": php,
        "sh": shell, "bash": shell, "zsh": shell, "ksh": shell, "command": shell, "fish": fish,
        "ps1": powershell, "psm1": powershell, "psd1": powershell,
        "sql": sql, "psql": sql, "ddl": sql,
        "lua": lua, "gd": gdscript, "tscn": godotResource, "tres": godotResource, "godot": godotResource, "import": godotResource,
        "ex": elixir, "exs": elixir, "hs": haskell,
        "clj": lisp, "cljs": lisp, "cljc": lisp, "edn": lisp, "el": lisp, "lisp": lisp, "scm": lisp, "rkt": lisp,
        "r": r, "pl": perl, "pm": perl, "zig": zig, "jl": julia,
        "proto": protobuf, "graphql": graphql, "gql": graphql,
        "tf": hcl, "tfvars": hcl, "hcl": hcl,
        "cmake": cmake, "mk": makefile, "mak": makefile,
        "html": html, "htm": html, "xhtml": html, "vue": html, "svelte": html,
        "xml": xml, "xib": xml, "storyboard": xml, "entitlements": plist, "xcprivacy": plist, "plist": plist,
        "xcscheme": xml, "xcworkspacedata": xml, "csproj": xml, "fsproj": xml, "vbproj": xml, "props": xml, "targets": xml,
        "resx": xml, "xaml": xml, "axml": xml, "xsd": xml, "xsl": xml, "xslt": xml, "wsdl": xml, "rss": xml, "atom": xml,
        "opml": xml, "gpx": xml, "kml": xml, "nuspec": xml, "manifest": xml, "config": xml,
        "css": css, "scss": scss, "sass": scss, "less": less,
        "yaml": yaml, "yml": yaml,
        "toml": toml, "ini": ini, "cfg": ini, "conf": ini, "desktop": ini, "service": ini, "editorconfig": ini,
        "properties": properties, "env": dotenv, "xcconfig": xcconfig, "pbxproj": pbxproj, "strings": stringsFile,
        "diff": diff, "patch": diff,
        "jsonl": jsonLines, "ndjson": jsonLines,
    ]

    private static let byName: [String: Language] = [
        "dockerfile": dockerfile, "containerfile": dockerfile,
        "makefile": makefile, "gnumakefile": makefile, "cmakelists.txt": cmake,
        "podfile": ruby, "gemfile": ruby, "rakefile": ruby, "fastfile": ruby, "appfile": ruby, "matchfile": ruby,
        "brewfile": ruby, "vagrantfile": ruby, "guardfile": ruby, "dangerfile": ruby, "capfile": ruby,
        "jenkinsfile": groovy,
        ".gitmodules": ini, ".gitconfig": ini, ".editorconfig": ini, ".npmrc": ini, ".pypirc": ini, ".flake8": ini,
        ".coveragerc": ini, ".pylintrc": ini, "setup.cfg": ini, "tox.ini": ini, ".gitattributes": ignoreList,
        ".bashrc": shell, ".bash_profile": shell, ".bash_logout": shell, ".zshrc": shell, ".zprofile": shell, ".zshenv": shell,
        ".zlogin": shell, ".profile": shell, ".envrc": shell,
        "pipfile": toml, "cargo.lock": toml, "poetry.lock": toml, "uv.lock": toml, "go.mod": go, "go.sum": ignoreList,
        "yarn.lock": yaml, "procfile": yaml, ".babelrc": json, ".swcrc": json,
        "package.resolved": json,
    ]

    private static let fenceAliases: [String: Language] = [
        "swift": swift, "rust": rust, "typescript": typeScript, "javascript": javaScript, "node": javaScript, "python": python,
        "python3": python, "golang": go, "c": c, "objc": objc, "objective-c": objc, "objectivec": objc, "cpp": cpp,
        "csharp": csharp, "c#": csharp, "kotlin": kotlin, "ruby": ruby, "shell": shell, "sh": shell, "bash": shell,
        "zsh": shell, "console": shell, "terminal": shell, "shellscript": shell, "powershell": powershell, "pwsh": powershell,
        "html": html, "xml": xml, "svg": xml, "css": css, "yaml": yaml, "json": json, "jsonc": json, "json5": json,
        "toml": toml, "ini": ini, "docker": dockerfile, "dockerfile": dockerfile, "make": makefile, "makefile": makefile,
        "sql": sql, "lua": lua, "gdscript": gdscript, "godot": gdscript, "dart": dart, "diff": diff, "patch": diff,
        "graphql": graphql, "hcl": hcl, "terraform": hcl, "elixir": elixir, "haskell": haskell, "clojure": lisp,
        "scala": scala, "groovy": groovy, "java": java, "php": php, "perl": perl, "zig": zig, "julia": julia, "protobuf": protobuf,
        "cmake": cmake, "glsl": shader, "metal": shader, "env": dotenv, "dotenv": dotenv, "jsx": javaScript, "tsx": typeScript,
    ]
}
