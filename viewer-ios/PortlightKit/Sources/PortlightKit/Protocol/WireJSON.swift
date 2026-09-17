import Foundation

extension PortlightWire {
    /// Strict, bounded JSON reading shared by text control messages and binary envelope headers.
    /// Callers enforce the byte budget first; this rejects malformed UTF-8 and excessive nesting before
    /// JSONSerialization sees the bytes, so hostile input never drives the Foundation parser deep.
    enum StrictJSON {
        /// Parses one JSON document whose top level must be an object.
        static func parseObject(_ bytes: Data) throws -> JSONFields {
            try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
                guard isValidUTF8(raw) else { throw ProtocolError.invalidUTF8 }
                guard !exceedsNesting(raw, limit: Limits.maxNestingDepth) else { throw ProtocolError.nestingTooDeep }
            }
            let parsed: Any
            do {
                // Fragments are allowed so a scalar or array top level reports `notAnObject`, not `invalidJSON`.
                parsed = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
            } catch {
                throw ProtocolError.invalidJSON
            }
            guard let object = parsed as? [String: Any] else { throw ProtocolError.notAnObject }
            return JSONFields(object)
        }

        /// Well-formed UTF-8 per Unicode Table 3-7: no overlong forms, surrogates, or scalars above U+10FFFF.
        static func isValidUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
            var index = 0
            let count = bytes.count
            while index < count {
                let lead = bytes[index]
                if lead < 0x80 { index += 1; continue }
                let length: Int
                // Allowed range for the byte after the lead; later continuation bytes are always 80...BF.
                var low: UInt8 = 0x80, high: UInt8 = 0xBF
                switch lead {
                case 0xC2...0xDF: length = 2
                case 0xE0: length = 3; low = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: length = 3
                case 0xED: length = 3; high = 0x9F
                case 0xF0: length = 4; low = 0x90
                case 0xF1...0xF3: length = 4
                case 0xF4: length = 4; high = 0x8F
                default: return false
                }
                guard count - index >= length, (low...high).contains(bytes[index + 1]) else { return false }
                for offset in 2..<length where bytes[index + offset] & 0xC0 != 0x80 { return false }
                index += length
            }
            return true
        }

        /// True when object/array nesting exceeds `limit` outside string literals. Runs after UTF-8
        /// validation, so a multi-byte sequence can't contain the ASCII quote, backslash or brackets.
        static func exceedsNesting(_ bytes: UnsafeRawBufferPointer, limit: Int) -> Bool {
            var depth = 0
            var inString = false
            var escaped = false
            for byte in bytes {
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    continue
                }
                switch byte {
                case 0x22: inString = true
                case 0x5B, 0x7B:
                    depth += 1
                    if depth > limit { return true }
                case 0x5D, 0x7D:
                    // Clamped so stray closers can't hide later nesting (the parser rejects them anyway).
                    depth = max(0, depth - 1)
                default: break
                }
            }
            return false
        }
    }

    /// Type-exact views of JSONSerialization values. Foundation bridges JSON `true` to an NSNumber that
    /// `as? Int` reads as 1 and lets `as? Int` accept `1.0`, so every conversion checks the CF type.
    enum JSONScalar {
        static func isBoolean(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        /// JSON `true`/`false` only; numbers never count as booleans.
        static func bool(_ value: Any) -> Bool? {
            guard let number = value as? NSNumber, isBoolean(number) else { return nil }
            return number.boolValue
        }

        /// A JSON integer that fits `Int`. Floats (even `1.0`), booleans, decimals and strings fail.
        static func int(_ value: Any) -> Int? {
            guard let number = value as? NSNumber, !isBoolean(number), !CFNumberIsFloatType(number as CFNumber) else { return nil }
            // JSONSerialization stores integers above Int64.max as unsigned 64-bit values, which
            // `int64Value` and CFNumberGetValue silently wrap, so unsigned storage is range-checked.
            switch UInt8(bitPattern: number.objCType.pointee) {
            case UInt8(ascii: "Q"), UInt8(ascii: "L"), UInt8(ascii: "I"), UInt8(ascii: "S"), UInt8(ascii: "C"):
                let unsigned = number.uint64Value
                return unsigned <= UInt64(Int.max) ? Int(unsigned) : nil
            default:
                return Int(exactly: number.int64Value)
            }
        }

        /// Any finite JSON number, integer or not. Booleans fail.
        static func double(_ value: Any) -> Double? {
            guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }

        static func string(_ value: Any) -> String? {
            value as? String
        }
    }

    /// A JSON object with strict typed accessors. Errors carry the full field path ("displays[2].width").
    /// Required fields: absent → `missingField`, present with the wrong type (including null) → `invalidField`.
    /// Optional fields: absent or null → nil, present with the wrong type → `invalidField`.
    struct JSONFields {
        let values: [String: Any]
        /// Path of this object inside the message; empty at the top level.
        let prefix: String

        init(_ values: [String: Any], prefix: String = "") {
            self.values = values
            self.prefix = prefix
        }

        func fieldPath(_ key: String) -> String {
            prefix.isEmpty ? key : "\(prefix).\(key)"
        }

        /// The value for `key`, or nil when absent or JSON null.
        func value(_ key: String) -> Any? {
            guard let raw = values[key], !(raw is NSNull) else { return nil }
            return raw
        }

        private func required(_ key: String) throws -> Any {
            guard let raw = values[key] else { throw ProtocolError.missingField(fieldPath(key)) }
            return raw
        }

        private func convert<T>(_ raw: Any, _ key: String, _ conversion: (Any) -> T?) throws -> T {
            guard let result = conversion(raw) else { throw ProtocolError.invalidField(fieldPath(key)) }
            return result
        }

        func int(_ key: String) throws -> Int { try convert(required(key), key, JSONScalar.int) }
        func double(_ key: String) throws -> Double { try convert(required(key), key, JSONScalar.double) }
        func string(_ key: String) throws -> String { try convert(required(key), key, JSONScalar.string) }
        func array(_ key: String) throws -> [Any] { try convert(required(key), key) { $0 as? [Any] } }

        func optionalInt(_ key: String) throws -> Int? { try value(key).map { try convert($0, key, JSONScalar.int) } }
        func optionalDouble(_ key: String) throws -> Double? { try value(key).map { try convert($0, key, JSONScalar.double) } }
        func optionalString(_ key: String) throws -> String? { try value(key).map { try convert($0, key, JSONScalar.string) } }
        func optionalBool(_ key: String) throws -> Bool? { try value(key).map { try convert($0, key, JSONScalar.bool) } }

        func optionalObject(_ key: String) throws -> JSONFields? {
            try value(key).map { raw in
                JSONFields(try convert(raw, key) { $0 as? [String: Any] }, prefix: fieldPath(key))
            }
        }

        /// An optional array whose every element must be a string.
        func optionalStrings(_ key: String) throws -> [String]? {
            guard let raw = value(key) else { return nil }
            let items = try convert(raw, key) { $0 as? [Any] }
            return try items.enumerated().map { index, item in
                guard let text = JSONScalar.string(item) else { throw ProtocolError.invalidField("\(fieldPath(key))[\(index)]") }
                return text
            }
        }

        /// Element `index` of `items` (the array at `key`), which must be an object.
        func object(in items: [Any], at index: Int, of key: String) throws -> JSONFields {
            let elementPath = "\(fieldPath(key))[\(index)]"
            guard let object = items[index] as? [String: Any] else { throw ProtocolError.invalidField(elementPath) }
            return JSONFields(object, prefix: elementPath)
        }

        /// Diagnostics-only read: absent or mistyped values become nil instead of failing the message.
        func lenient<T>(_ key: String, _ conversion: (Any) -> T?) -> T? {
            value(key).flatMap(conversion)
        }
    }
}
