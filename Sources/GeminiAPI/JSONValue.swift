// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A JSON value.
///
/// Objects keep their keys in insertion order, and ``jsonText`` writes them in
/// that order. Request bodies are built from these values, so a schema's
/// properties are sent in the order they are declared: a model generates the
/// properties of a structured response in the order of the schema, and an
/// alphabetical order can make it skip over the content that matters.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)
}

/// The members of a JSON object, in insertion order. Equality and hashing
/// ignore the order.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
  package private(set) var keys: [String] = []
  private var storage: [String: JSONValue] = [:]

  package init() {}

  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    for (key, value) in elements { self[key] = value }
  }

  package init<S: Sequence>(_ members: S) where S.Element == (String, JSONValue) {
    for (key, value) in members { self[key] = value }
  }

  package subscript(key: String) -> JSONValue? {
    get { storage[key] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  package var count: Int { keys.count }
  package var isEmpty: Bool { keys.isEmpty }
  package var values: [JSONValue] { keys.map { storage[$0]! } }

  package func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
    keys.map { (key: $0, value: storage[$0]!) }.makeIterator()
  }

  /// Moves the keys in `order` to the front, in that order. Keys that are not
  /// members are skipped; members missing from `order` keep their relative
  /// order after the others.
  package mutating func reorder(_ order: [String]) {
    let front = order.filter { storage[$0] != nil }
    var seen = Set<String>()
    let unique = front.filter { seen.insert($0).inserted }
    keys = unique + keys.filter { !seen.contains($0) }
  }

  /// A copy with the values transformed, in the same key order.
  package func mapValues(_ transform: (JSONValue) throws -> JSONValue) rethrows -> JSONObject {
    var result = JSONObject()
    for key in keys { result[key] = try transform(storage[key]!) }
    return result
  }

  package static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    lhs.storage == rhs.storage
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(storage)
  }
}

// MARK: - Literals

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  package init(nilLiteral: ()) { self = .null }
  package init(booleanLiteral value: Bool) { self = .bool(value) }
  package init(integerLiteral value: Int) { self = .number(Double(value)) }
  package init(floatLiteral value: Double) { self = .number(value) }
  package init(stringLiteral value: String) { self = .string(value) }
  package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(JSONObject(elements))
  }
}

// MARK: - Access

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue {
  /// The member `key` of an object; `nil` for anything else.
  package subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { object[key] } else { nil }
  }

  /// The element at `index` of an array; `nil` when out of range or not an array.
  package subscript(index: Int) -> JSONValue? {
    if case .array(let array) = self, array.indices.contains(index) { array[index] } else { nil }
  }

  package var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  package var doubleValue: Double? {
    if case .number(let value) = self { value } else { nil }
  }

  package var intValue: Int? {
    if case .number(let value) = self { Int(exactly: value) } else { nil }
  }

  package var boolValue: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  package var arrayValue: [JSONValue]? {
    if case .array(let value) = self { value } else { nil }
  }

  package var objectValue: JSONObject? {
    if case .object(let value) = self { value } else { nil }
  }

  package var isNull: Bool {
    if case .null = self { true } else { false }
  }
}

// MARK: - Parsing

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
package enum JSONValueError: Error, Sendable, Equatable {
  case malformed(String)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue {
  /// Parses JSON text. Object members are ordered by key, so equal input
  /// always produces equal output.
  package static func parse(_ data: Data) throws -> JSONValue {
    do {
      let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      return try JSONValue(foundation: object)
    } catch let error as JSONValueError {
      throw error
    } catch {
      throw JSONValueError.malformed(error.localizedDescription)
    }
  }

  package static func parse(_ text: String) throws -> JSONValue {
    try parse(Data(text.utf8))
  }

  /// Parses JSON text, or returns `nil` when it is malformed.
  package static func parsed(_ text: String) -> JSONValue? {
    try? parse(text)
  }

  /// The value of an `Encodable`, as JSON.
  package static func encoded<T: Encodable>(_ value: T) -> JSONValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? parse(data)
  }

  private init(foundation object: Any) throws {
    switch object {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let string as String:
      self = .string(string)
    case let array as [Any]:
      self = .array(try array.map { try JSONValue(foundation: $0) })
    case let dictionary as [String: Any]:
      var object = JSONObject()
      for key in dictionary.keys.sorted() {
        object[key] = try JSONValue(foundation: dictionary[key]!)
      }
      self = .object(object)
    default:
      throw JSONValueError.malformed("Unsupported JSON value \(type(of: object))")
    }
  }
}

// MARK: - Writing

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue {
  /// Compact JSON text with object members in their order. Integral numbers
  /// are written without a fraction; numbers that aren't finite are written
  /// as `null`, since JSON can't express them.
  package var jsonText: String {
    var out = ""
    write(to: &out)
    return out
  }

  package var jsonData: Data {
    Data(jsonText.utf8)
  }

  private func write(to out: inout String) {
    switch self {
    case .null:
      out += "null"
    case .bool(let value):
      out += value ? "true" : "false"
    case .number(let value):
      out += Self.text(of: value)
    case .string(let value):
      Self.write(string: value, to: &out)
    case .array(let values):
      out += "["
      for (i, value) in values.enumerated() {
        if i > 0 { out += "," }
        value.write(to: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      var first = true
      for (key, value) in object {
        if !first { out += "," }
        first = false
        Self.write(string: key, to: &out)
        out += ":"
        value.write(to: &out)
      }
      out += "}"
    }
  }

  private static func text(of value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
      return String(Int64(value))
    }
    return "\(value)"
  }

  private static func write(string: String, to out: inout String) {
    out += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case let c where c.value < 0x20:
        out += String(format: "\\u%04x", c.value)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
  }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension JSONValue: CustomStringConvertible {
  package var description: String { jsonText }
}
