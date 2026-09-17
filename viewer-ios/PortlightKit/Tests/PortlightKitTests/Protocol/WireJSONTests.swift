import Testing
@testable import PortlightKit

@Suite("Wire: strict JSON layer")
struct WireJSONTests {
    private typealias F = WireFixtures
    private typealias Scalar = PortlightWire.JSONScalar
    private typealias Strict = PortlightWire.StrictJSON

    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { Strict.isValidUTF8($0) }
    }

    private static func parse(_ json: String) throws -> PortlightWire.JSONFields {
        try Strict.parseObject(F.Bytes(json.utf8))
    }

    /// The raw JSONSerialization value of `literal`, read through the strict parser.
    private static func raw(_ literal: String) throws -> Any {
        let object = try parse(#"{"v":\#(literal)}"#)
        return try #require(object.values["v"])
    }

    /// An object whose member nests `depth - 1` arrays, so the document is `depth` levels deep.
    private static func nested(depth: Int) -> String {
        #"{"a":"# + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "}"
    }

    // MARK: UTF-8

    @Test func acceptsWellFormedUTF8() {
        let samples: [[UInt8]] = [
            [], Array(#"plain {"ascii":1}"#.utf8), Array("héllo wörld".utf8), Array("€ 中文 😀 🇸🇪".utf8),
            [0xC2, 0x80], [0xDF, 0xBF],                         // U+0080, U+07FF
            [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],             // U+0800, U+D7FF (last before the surrogates)
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF],             // U+E000, U+FFFF
            [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF], // U+10000, U+10FFFF
        ]
        for sample in samples {
            #expect(Self.isValidUTF8(sample), "\(sample)")
        }
    }

    @Test func rejectsMalformedUTF8() {
        #expect(!Self.isValidUTF8([0x41, 0x80]), "lone continuation byte")
        #expect(!Self.isValidUTF8([0xC0, 0xAF]), "overlong slash")
        #expect(!Self.isValidUTF8([0xC1, 0xBF]), "C1 lead byte")
        #expect(!Self.isValidUTF8([0xE0, 0x9F, 0xBF]), "overlong 3-byte form")
        #expect(!Self.isValidUTF8([0xED, 0xA0, 0x80]), "UTF-16 surrogate")
        #expect(!Self.isValidUTF8([0xF0, 0x8F, 0xBF, 0xBF]), "overlong 4-byte form")
        #expect(!Self.isValidUTF8([0xF4, 0x90, 0x80, 0x80]), "above U+10FFFF")
        #expect(!Self.isValidUTF8([0xF5, 0x80, 0x80, 0x80]), "F5 lead byte")
        #expect(!Self.isValidUTF8([0xFF]), "FF byte")
        #expect(!Self.isValidUTF8([0x41, 0xE2, 0x82]), "sequence truncated at the end")
        #expect(!Self.isValidUTF8([0xE2, 0x41, 0x82]), "ASCII inside a sequence")
        #expect(!Self.isValidUTF8([0xF0, 0x9F, 0x98, 0x41]), "missing fourth byte")
    }

    // MARK: Nesting

    @Test func nestingLimitIsSixteenLevels() throws {
        _ = try Self.parse(Self.nested(depth: 16))
        #expect(throws: ProtocolError.nestingTooDeep) { try Self.parse(Self.nested(depth: 17)) }
        #expect(throws: ProtocolError.nestingTooDeep) { try Self.parse(String(repeating: "[", count: 60_000)) }
    }

    @Test func nestingScanSkipsStringLiterals() throws {
        // Brackets after an escaped quote are still inside the string.
        _ = try Self.parse(#"{"a":"\"[[[[[[[[[[[[[[[[[[[[{{{{","b":"]]]]"}"#)
        // An escaped backslash ends with the closing quote, so the 16 arrays after it count (depth 17).
        let afterBackslash = #"{"a":"\\","b":"# + String(repeating: "[", count: 16) + String(repeating: "]", count: 16) + "}"
        #expect(throws: ProtocolError.nestingTooDeep) { try Self.parse(afterBackslash) }
        // Stray closers can't bank depth for later openers.
        let strayClosers = #"{"a":]]]]]"# + String(repeating: "[", count: 17)
        #expect(throws: ProtocolError.nestingTooDeep) { try Self.parse(strayClosers) }
    }

    // MARK: Document shape

    @Test func topLevelMustBeAnObject() {
        for literal in ["[]", #"[{"type":"welcome"}]"#, "3", #""welcome""#, "null", "true"] {
            #expect(throws: ProtocolError.notAnObject, "\(literal)") { try Self.parse(literal) }
        }
        for literal in ["", "   ", "{", #"{"type":"#, "{'type':'welcome'}", #"{"a":1e400}"#, "NaN", #"{"a":01}"#] {
            #expect(throws: ProtocolError.invalidJSON, "\(literal)") { try Self.parse(literal) }
        }
    }

    // MARK: Scalars

    @Test func integersAreExact() throws {
        #expect(try Scalar.int(Self.raw("0")) == 0)
        #expect(try Scalar.int(Self.raw("-7")) == -7)
        #expect(try Scalar.int(Self.raw("9223372036854775807")) == Int.max)
        #expect(try Scalar.int(Self.raw("-9223372036854775808")) == Int.min)
        let rejected = ["true", "false", "1.0", "1.5", "1e2", "-0.0", #""3""#, "null", "[]", "{}",
                        "9223372036854775808", "18446744073709551615", "18446744073709551616", "123456789012345678901234567890"]
        for literal in rejected {
            #expect(try Scalar.int(Self.raw(literal)) == nil, "\(literal)")
        }
    }

    @Test func doublesAcceptAnyFiniteNumberButNotBooleans() throws {
        #expect(try Scalar.double(Self.raw("1")) == 1)
        #expect(try Scalar.double(Self.raw("1.5")) == 1.5)
        #expect(try Scalar.double(Self.raw("-0.25")) == -0.25)
        #expect(try Scalar.double(Self.raw("1.00000000000000000001")) == 1)
        // JSONSerialization turns -1e400 into -infinity rather than failing.
        for literal in ["true", "false", #""1.5""#, "null", "[]", "-1e400"] {
            #expect(try Scalar.double(Self.raw(literal)) == nil, "\(literal)")
        }
    }

    @Test func booleansAreOnlyJSONBooleans() throws {
        #expect(try Scalar.bool(Self.raw("true")) == true)
        #expect(try Scalar.bool(Self.raw("false")) == false)
        for literal in ["1", "0", "1.0", #""true""#, "null"] {
            #expect(try Scalar.bool(Self.raw(literal)) == nil, "\(literal)")
        }
    }

    // MARK: Field accessors

    @Test func accessorsDistinguishMissingNullAndMistyped() throws {
        let object = try Self.parse(#"{"n":null,"s":"x","i":3,"row":{"w":true},"list":["a",1]}"#)
        #expect(throws: ProtocolError.missingField("absent")) { try object.int("absent") }
        #expect(throws: ProtocolError.invalidField("n")) { try object.int("n") }
        #expect(throws: ProtocolError.invalidField("s")) { try object.int("s") }
        #expect(try object.int("i") == 3)
        #expect(try object.optionalInt("n") == nil)
        #expect(try object.optionalInt("absent") == nil)
        #expect(throws: ProtocolError.invalidField("s")) { try object.optionalInt("s") }
        #expect(throws: ProtocolError.invalidField("s")) { try object.optionalObject("s") }
        let row = try #require(try object.optionalObject("row"))
        #expect(throws: ProtocolError.invalidField("row.w")) { try row.int("w") }
        #expect(throws: ProtocolError.missingField("row.h")) { try row.int("h") }
        #expect(throws: ProtocolError.invalidField("list[1]")) { try object.optionalStrings("list") }
        #expect(object.lenient("s", Scalar.int) == nil)
        #expect(object.lenient("i", Scalar.int) == 3)
    }
}
