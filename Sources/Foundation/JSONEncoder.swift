@_implementationOnly import CoreFoundation

// 这个类, 仅仅是类型判断, 只会有一种情况, 就是 Dict key 为 string, value 是 Encodable
fileprivate protocol _JSONStringDictionaryEncodableMarker { }
extension Dictionary : _JSONStringDictionaryEncodableMarker where Key == String, Value: Encodable { }

fileprivate protocol _JSONStringDictionaryDecodableMarker {
    static var elementType: Decodable.Type { get }
}
extension Dictionary : _JSONStringDictionaryDecodableMarker where Key == String, Value: Decodable {
    static var elementType: Decodable.Type { return Value.self }
}

// 实验所得, JSONEncoder, 其实没有解决循环存储的问题.
//===----------------------------------------------------------------------===//
// JSON Encoder
//===----------------------------------------------------------------------===//
/*
 实际上，JSONEncoder 甚至都没有实现 Encoder 协议。相反，它只是一个叫做 _JSONEncoder 的私有类的封装，这个私有类实现了 Encoder 协议，并且进行实际的编码工 作。
 之所以这样做，是因为顶层编码器 (译注:这里指 JSONEncoder) 应该提供的 API (这个 API 通常只用于启动编码过程)，和在编码过程中传递给可编码类型的 Encoder 对象 (译注:这 里指 _JSONEncoder) 是截然不同的。
 将这些任务清晰地分开，意味着在任意给定的情景下，使用编码器的一方只能访问到适当的 API。例如，一个 Codable 类型不能在编码过程中重新配置 编码器，因为公开的配置 API 只暴露在顶层编码器的定义里。
 这是正确的 Api 的设计. 对外暴露的, 就应该是简单的一个返回值是 data 的接口.
 实际上, 将值变为序列化的格式, 然后写入, 这两个过程在 JSONEncoder 中是分开的.
 */
open class JSONEncoder {
    // MARK: Options
    
    // 总的输出格式的配置
    public struct OutputFormatting : OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }
        
        // OptionSet 类型里面, 必要有几个 static 的值, 这些值是 set 的有意义的值
        public static let prettyPrinted = OutputFormatting(rawValue: 1 << 0)
        public static let sortedKeys    = OutputFormatting(rawValue: 1 << 1)
        public static let withoutEscapingSlashes = OutputFormatting(rawValue: 1 << 3)
    }
    
    // 对于时间如何输出的配置.
    public enum DateEncodingStrategy {
        // 所谓, deferredToDate, 就是调用 date 的 encode 方法来获取对应的数据
        case deferredToDate
        // 使用 时间戳来保存 NSDate
        case secondsSince1970
        // 使用 毫秒时间戳来保存 Date
        case millisecondsSince1970
        // 使用特殊的格式, 来保存 date.
        @available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601
        // 使用关联值的 DateFormatter 来保存 Date.
        case formatted(DateFormatter)
        // 传入 Date, Encode 对象, 由闭包规定方法.
        case custom((Date, Encoder) throws -> Void)
    }
    
    // 如何将 Data 进行输出的配置
    public enum DataEncodingStrategy {
        case deferredToData
        case base64
        case custom((Data, Encoder) throws -> Void)
    }
    
    /// The strategy to use for non-JSON-conforming floating-point values (IEEE 754 infinity and NaN).
    public enum NonConformingFloatEncodingStrategy {
        /// Throw upon encountering non-conforming values. This is the default strategy.
        case `throw`
        
        /// Encode the values using the given representation strings.
        case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }
    
    // 如何输出 key 的配置
    public enum KeyEncodingStrategy {
        // 使用原始的 key 值.
        case useDefaultKeys
        
        // 使用下划线的方式. 是和下面的 _convertToSnakeCase 配套使用的.
        case convertToSnakeCase
        
        /// Provide a custom conversion to the key in the encoded JSON from the keys specified by the encoded types.
        /// The full path to the current encoding position is provided for context (in case you need to locate this key within the payload). The returned key is used in place of the last component in the coding path before encoding.
        /// If the result of the conversion is a duplicate key, then only one value will be present in the result.
        case custom((_ codingPath: [CodingKey]) -> CodingKey)
        
        fileprivate static func _convertToSnakeCase(_ stringKey: String) -> String {
            guard !stringKey.isEmpty else { return stringKey }
            
            var words : [Range<String.Index>] = []
            // The general idea of this algorithm is to split words on transition from lower to upper case, then on transition of >1 upper case characters to lowercase
            //
            // myProperty -> my_property
            // myURLProperty -> my_url_property
            //
            // We assume, per Swift naming conventions, that the first character of the key is lowercase.
            var wordStart = stringKey.startIndex
            var searchRange = stringKey.index(after: wordStart)..<stringKey.endIndex
            
            // Find next uppercase character
            while let upperCaseRange = stringKey.rangeOfCharacter(from: CharacterSet.uppercaseLetters, options: [], range: searchRange) {
                let untilUpperCase = wordStart..<upperCaseRange.lowerBound
                words.append(untilUpperCase)
                
                // Find next lowercase character
                searchRange = upperCaseRange.lowerBound..<searchRange.upperBound
                guard let lowerCaseRange = stringKey.rangeOfCharacter(from: CharacterSet.lowercaseLetters, options: [], range: searchRange) else {
                    // There are no more lower case letters. Just end here.
                    wordStart = searchRange.lowerBound
                    break
                }
                
                // Is the next lowercase letter more than 1 after the uppercase? If so, we encountered a group of uppercase letters that we should treat as its own word
                let nextCharacterAfterCapital = stringKey.index(after: upperCaseRange.lowerBound)
                if lowerCaseRange.lowerBound == nextCharacterAfterCapital {
                    // The next character after capital is a lower case character and therefore not a word boundary.
                    // Continue searching for the next upper case for the boundary.
                    wordStart = upperCaseRange.lowerBound
                } else {
                    // There was a range of >1 capital letters. Turn those into a word, stopping at the capital before the lower case character.
                    let beforeLowerIndex = stringKey.index(before: lowerCaseRange.lowerBound)
                    words.append(upperCaseRange.lowerBound..<beforeLowerIndex)
                    
                    // Next word starts at the capital before the lowercase we just found
                    wordStart = beforeLowerIndex
                }
                searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
            }
            words.append(wordStart..<searchRange.upperBound)
            let result = words.map({ (range) in
                return stringKey[range].lowercased()
            }).joined(separator: "_")
            return result
        }
    }
    
    
    // 上面的配置, 都被存了起来. 在真正输出的时候, 按照这些存储的值, 进行最终的字符串的书写.
    open var outputFormatting: OutputFormatting = []
    open var dateEncodingStrategy: DateEncodingStrategy = .deferredToDate
    open var dataEncodingStrategy: DataEncodingStrategy = .base64
    open var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw
    open var keyEncodingStrategy: KeyEncodingStrategy = .useDefaultKeys
    open var userInfo: [CodingUserInfoKey : Any] = [:]
    
    fileprivate struct _CodingFormatConfig {
        let dateEncodingStrategy: DateEncodingStrategy
        let dataEncodingStrategy: DataEncodingStrategy
        let nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy
        let keyEncodingStrategy: KeyEncodingStrategy
        let userInfo: [CodingUserInfoKey : Any]
    }
    
    fileprivate var options: _CodingFormatConfig {
        return _CodingFormatConfig(dateEncodingStrategy: dateEncodingStrategy,
                        dataEncodingStrategy: dataEncodingStrategy,
                        nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
                        keyEncodingStrategy: keyEncodingStrategy,
                        userInfo: userInfo)
    }
    
    public init() {}
    
    // Encoder 作为整个序列化的过程的发起者.
    // 它在里面, 存储了一系列的如何序列化的配置信息.
    // 真正的具体某个值如何进行 string 的变化, 交给了 _JSONEncoder
    open func encode<T : Encodable>(_ value: T) throws -> Data {
        
        let encoder = _JSONEncoder(options: self.options)
        
        // topLevel 最后, 会是一个 Dict, 一个 Array, 一个字符串, 或者一个数字. 也就是, JSON 所规定的类型.
        guard let topLevel = try encoder.boxObject(value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
        
        let writingOptions = JSONSerialization.WritingOptions(rawValue: self.outputFormatting.rawValue).union(.fragmentsAllowed)
        
        do {
            // 最后, 变为 Data 的过程还是交给 JSONSerialization
            // TopLevel, 现在只会是 Array, 或者 Dict.
            // TopLevel 里面的值, 也仅仅会是 Dict, Array, String, Number, URL, Date, Data, Null 这些, JSON 相互配合的类型了
            return try JSONSerialization.data(withJSONObject: topLevel, options: writingOptions)
        } catch {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unable to encode the given top-level value to JSON.", underlyingError: error))
        }
    }
}

// MARK: - _JSONEncoder

// 真正的进行序列化的类. 
fileprivate class _JSONEncoder : Encoder {
    // MARK: Properties
    
    /// The encoder's storage.
    fileprivate var storage: _JSONEncodingStorage
    
    /// Options set on the top-level encoder.
    fileprivate let options: JSONEncoder._CodingFormatConfig
    
    // Json 的序列化, 本身就是一个栈的模型, 这里数组, 主要就是记录了当前正在序列化的 key, 使用的时候, 要注意入栈出栈的时机
    public var codingPath: [CodingKey]
    
    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey : Any] {
        return self.options.userInfo
    }
    
    // MARK: - Initialization
    
    /// Initializes `self` with the given top-level encoder options.
    fileprivate init(options: JSONEncoder._CodingFormatConfig, codingPath: [CodingKey] = []) {
        self.options = options
        self.storage = _JSONEncodingStorage()
        self.codingPath = codingPath
    }
    
    /// Returns whether a new element can be encoded at this coding path.
    ///
    /// `true` if an element has not yet been encoded at this coding path; `false` otherwise.
    // 这是一个计算属性.
    fileprivate var canEncodeNewValue: Bool {
        // Every time a new value gets encoded, the key it's encoded for is pushed onto the coding path (even if it's a nil key from an unkeyed container).
        // At the same time, every time a container is requested, a new value gets pushed onto the storage stack.
        // If there are more values on the storage stack than on the coding path, it means the value is requesting more than one container, which violates the precondition.
        //
        // This means that anytime something that can request a new container goes onto the stack, we MUST push a key onto the coding path.
        // Things which will not request containers do not need to have the coding path extended for them (but it doesn't matter if it is, because they will not reach here).
        return self.storage.count == self.codingPath.count
    }
    
    // 各种, 取得相关 Container 的时候, 都会有一个入栈 Container 的动作
    // var container = encoder.container(keyedBy: CodingKeys.self)
    // 这里, 传递过来的 key, 其实是各个类型自己定义的 CodingKeys 类.
    // 所以, 改名的工作, 其实就是 KeyedEncodingContainer 这个类完成的
    public func container<Key>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        // If an existing keyed container was already requested, return that one.
        let topContainer: NSMutableDictionary
        if self.canEncodeNewValue {
            // We haven't yet pushed a container at this level; do so here.
            topContainer = self.storage.pushKeyedContainer()
        } else {
            guard let container = self.storage.containers.last as? NSMutableDictionary else {
                preconditionFailure("Attempt to push new keyed encoding container when already previously encoded at this path.")
            }
            topContainer = container
        }
        
        let container = _JSONKeyedEncodingContainer<Key>(referencing: self, codingPath: self.codingPath, wrapping: topContainer)
        return KeyedEncodingContainer(container)
    }
    
    public func unkeyedContainer() -> UnkeyedEncodingContainer {
        // If an existing unkeyed container was already requested, return that one.
        let topContainer: NSMutableArray
        if self.canEncodeNewValue {
            // We haven't yet pushed a container at this level; do so here.
            topContainer = self.storage.pushUnkeyedContainer()
        } else {
            guard let container = self.storage.containers.last as? NSMutableArray else {
                preconditionFailure("Attempt to push new unkeyed encoding container when already previously encoded at this path.")
            }
            
            topContainer = container
        }
        
        return _JSONUnkeyedEncodingContainer(referencing: self, codingPath: self.codingPath, wrapping: topContainer)
    }
    
    public func singleValueContainer() -> SingleValueEncodingContainer {
        return self
    }
}

// MARK: - Encoding Storage and Containers

// 序列化是一个层级序列的过程, 使用一个专门的数据结构, 记录一下当前的层级.
// _JSONEncodingStorage 保证了, 层级里面, 都是 JSON 想对应的数据结构.
// 对象, 就是 Dict, Array 就是 Array. 其他的, 就都是各自对应的 Number, Date 等.
// 在
fileprivate struct _JSONEncodingStorage {
    // MARK: Properties
    
    /// The container stack.
    /// Elements may be any one of the JSON types (NSNull, NSNumber, NSString, NSArray, NSDictionary).
    private(set) fileprivate var containers: [NSObject] = []
    
    // MARK: - Initialization
    
    /// Initializes `self` with no containers.
    fileprivate init() {}
    
    // MARK: - Modifying the Stack
    
    fileprivate var count: Int {
        return self.containers.count
    }
    
    fileprivate mutating func pushKeyedContainer() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        self.containers.append(dictionary)
        return dictionary
    }
    
    fileprivate mutating func pushUnkeyedContainer() -> NSMutableArray {
        let array = NSMutableArray()
        self.containers.append(array)
        return array
    }
    
    fileprivate mutating func push(container: NSObject) {
        self.containers.append(container)
    }
    
    fileprivate mutating func popContainer() -> NSObject {
        precondition(!self.containers.isEmpty, "Empty container stack.")
        return self.containers.popLast()!
    }
}


// JSON 实现的, 对于 KeyedEncodingContainerProtocol 的实现.
// 对于 JSON 来说, 他其实只能序列化, Number, String, Bool, Null , Array, Dict 这些值, 而 Array, Dict 最终又会变为前面的基本数据类型.
fileprivate struct _JSONKeyedEncodingContainer<K : CodingKey> : KeyedEncodingContainerProtocol {
    
    typealias Key = K
    
    // MARK: Properties
    
    /// A reference to the encoder we're writing to.
    private let encoder: _JSONEncoder
    
    /// A reference to the container we're writing to.
    private let container: NSMutableDictionary
    
    /// The path of coding keys taken to get to this point in encoding.
    private(set) public var codingPath: [CodingKey]
    
    /// Initializes `self` with the given references.
    fileprivate init(referencing encoder: _JSONEncoder,
                     codingPath: [CodingKey],
                     wrapping container: NSMutableDictionary) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }
    
    // MARK: - Coding Path Operations
    
    private func _converted(_ key: CodingKey) -> CodingKey {
        switch encoder.options.keyEncodingStrategy {
        case .useDefaultKeys:
            return key
        case .convertToSnakeCase:
            let newKeyString = JSONEncoder.KeyEncodingStrategy._convertToSnakeCase(key.stringValue)
            return _JSONKey(stringValue: newKeyString, intValue: key.intValue)
        case .custom(let converter):
            return converter(codingPath + [key])
        }
    }
    
    // MARK: - KeyedEncodingContainerProtocol Methods
    // 各个业务数据类里面, encode value for key, 就是在这里完成的.
    
    // self.container 里面, 对应的是对象相关的 NSMutableDict/
    // self.encoder 里面, 是每个对象如何序列化的序列化器.
    
    // encode value for key 中, key 是 CodingKey 类型的.
    // 每个类里面, 专门定义自己的 CodingKey 的 enum, 这样, 类型就固定住了.
    // value 如何表示, 由 self.encoder 的 box 函数决定
    // 而 key 值, 由 enum 的 stringValue 来决定. 这就是为什么, 我们能够替换 case 名作为 key 名的原因所在.
    
    // 所有的 Key, 都 _bridgeToObjectiveC, 是因为 NSDict 里面, 就是存的 NSString.
    public mutating func encodeNil(forKey key: Key)               throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = NSNull() }
    public mutating func encode(_ value: Bool, forKey key: Key)   throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: Int, forKey key: Key)    throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: Int8, forKey key: Key)   throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: Int16, forKey key: Key)  throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: Int32, forKey key: Key)  throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: Int64, forKey key: Key)  throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: UInt, forKey key: Key)   throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: UInt8, forKey key: Key)  throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: UInt16, forKey key: Key) throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: UInt32, forKey key: Key) throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: UInt64, forKey key: Key) throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.box(value) }
    public mutating func encode(_ value: String, forKey key: Key) throws { self.container[_converted(key).stringValue._bridgeToObjectiveC()] = self.encoder.boxString(value) }
    
    public mutating func encode(_ value: Float, forKey key: Key)  throws {
        // Since the float may be invalid and throw, the coding path needs to contain this key.
        self.encoder.codingPath.append(key)
        defer { self.encoder.codingPath.removeLast() }
        self.container[_converted(key).stringValue._bridgeToObjectiveC()] = try self.encoder.box(value)
    }
    
    public mutating func encode(_ value: Double, forKey key: Key) throws {
        // Since the double may be invalid and throw, the coding path needs to contain this key.
        self.encoder.codingPath.append(key)
        defer { self.encoder.codingPath.removeLast() }
        self.container[_converted(key).stringValue._bridgeToObjectiveC()] = try self.encoder.box(value)
    }
    
    public mutating func encode<T : Encodable>(_ value: T, forKey key: Key) throws {
        self.encoder.codingPath.append(key)
        defer { self.encoder.codingPath.removeLast() }
        self.container[_converted(key).stringValue._bridgeToObjectiveC()] = try self.encoder.box(value)
    }
    
    public mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let dictionary = NSMutableDictionary()
        self.container[_converted(key).stringValue._bridgeToObjectiveC()] = dictionary
        self.codingPath.append(key)
        defer { self.codingPath.removeLast() }
        
        let container = _JSONKeyedEncodingContainer<NestedKey>(referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary)
        return KeyedEncodingContainer(container)
    }
    
    public mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let array = NSMutableArray()
        self.container[_converted(key).stringValue._bridgeToObjectiveC()] = array
        self.codingPath.append(key)
        defer { self.codingPath.removeLast() }
        return _JSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
    }
    
    public mutating func superEncoder() -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: _JSONKey.super, wrapping: self.container)
    }
    
    public mutating func superEncoder(forKey key: Key) -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: key, wrapping: self.container)
    }
}

// UnkeyedEncodingContainer 和 Keyed 没有太大的区别, 就是存储的结构变为了 Array
fileprivate struct _JSONUnkeyedEncodingContainer : UnkeyedEncodingContainer {
    // MARK: Properties
    
    private let encoder: _JSONEncoder
    private let container: NSMutableArray
    private(set) public var codingPath: [CodingKey]
    public var count: Int {
        return self.container.count
    }
    
    fileprivate init(referencing encoder: _JSONEncoder, codingPath: [CodingKey], wrapping container: NSMutableArray) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.container = container
    }
    
    // 使用 unkeyed 进行 encode, 就是不断的向 数组里面, 填充数据而已了.
    public mutating func encodeNil()             throws { self.container.add(NSNull()) }
    public mutating func encode(_ value: Bool)   throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: Int)    throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: Int8)   throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: Int16)  throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: Int32)  throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: Int64)  throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: UInt)   throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: UInt8)  throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: UInt16) throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: UInt32) throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: UInt64) throws { self.container.add(self.encoder.box(value)) }
    public mutating func encode(_ value: String) throws { self.container.add(self.encoder.boxString(value)) }
    
    public mutating func encode(_ value: Float)  throws {
        self.encoder.codingPath.append(_JSONKey(index: self.count))
        defer { self.encoder.codingPath.removeLast() }
        self.container.add(try self.encoder.box(value))
    }
    
    public mutating func encode(_ value: Double) throws {
        self.encoder.codingPath.append(_JSONKey(index: self.count))
        defer { self.encoder.codingPath.removeLast() }
        self.container.add(try self.encoder.box(value))
    }
    
    public mutating func encode<T : Encodable>(_ value: T) throws {
        self.encoder.codingPath.append(_JSONKey(index: self.count))
        defer { self.encoder.codingPath.removeLast() }
        self.container.add(try self.encoder.box(value))
    }
    
    public mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        self.codingPath.append(_JSONKey(index: self.count))
        defer { self.codingPath.removeLast() }
        
        let dictionary = NSMutableDictionary()
        self.container.add(dictionary)
        
        let container = _JSONKeyedEncodingContainer<NestedKey>(referencing: self.encoder, codingPath: self.codingPath, wrapping: dictionary)
        return KeyedEncodingContainer(container)
    }
    
    public mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        self.codingPath.append(_JSONKey(index: self.count))
        defer { self.codingPath.removeLast() }
        
        let array = NSMutableArray()
        self.container.add(array)
        return _JSONUnkeyedEncodingContainer(referencing: self.encoder, codingPath: self.codingPath, wrapping: array)
    }
    
    public mutating func superEncoder() -> Encoder {
        return _JSONReferencingEncoder(referencing: self.encoder, at: self.container.count, wrapping: self.container)
    }
}

// JSONEncoder 是如何实现 SingleValueEncodingContainer 协议的.
// 里面的每一个 encode, 都有着 storage 的 push 操作.
// 相应的, 在序列化完毕之后, 应该有 pop 操作.

extension _JSONEncoder : SingleValueEncodingContainer {
    fileprivate func assertCanEncodeNewValue() {
        precondition(self.canEncodeNewValue, "Attempt to encode value through single value container when previously value already encoded.")
    }
    
    // SingleValueEncodingContainer 里面, 所有的都有一个 push 的操作.
    public func encodeNil() throws {
        assertCanEncodeNewValue()
        self.storage.push(container: NSNull())
    }
    
    public func encode(_ value: Bool) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Int) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Int8) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Int16) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Int32) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Int64) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: UInt) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: UInt8) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: UInt16) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: UInt32) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: UInt64) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: String) throws {
        assertCanEncodeNewValue()
        self.storage.push(container: self.boxString(value))
    }
    
    public func encode(_ value: Float) throws {
        assertCanEncodeNewValue()
        try self.storage.push(container: self.box(value))
    }
    
    public func encode(_ value: Double) throws {
        assertCanEncodeNewValue()
        try self.storage.push(container: self.box(value))
    }
    
    public func encode<T : Encodable>(_ value: T) throws {
        assertCanEncodeNewValue()
        try self.storage.push(container: self.box(value))
    }
}














// MARK: - Concrete Value Representations

// 实际的, 对于值如何写入到 Dict 里面, 还是在 JSONEncode 里面
// 将, 值如何进行序列化的过程, 统一到一个地方.
// 感觉可以专门写一个类来做这件事.
extension _JSONEncoder {
    
    // 基本数据类型的包装. 这里, 都包装成为了 OC 的类型.
    fileprivate func box(_ value: Bool)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int)    -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int8)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int16)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int32)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: Int64)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt)   -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt8)  -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt16) -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt32) -> NSObject { return NSNumber(value: value) }
    fileprivate func box(_ value: UInt64) -> NSObject { return NSNumber(value: value) }
    fileprivate func boxString(_ value: String) -> NSObject {
        return NSString(string: value)
    }
    
    fileprivate func box(_ float: Float) throws -> NSObject {
        // 对于一些特殊值, 需要直接抛出错误.
        guard !float.isInfinite && !float.isNaN else {
            guard case let .convertToString(positiveInfinity: posInfString,
                                            negativeInfinity: negInfString,
                                            nan: nanString) = self.options.nonConformingFloatEncodingStrategy else {
                throw EncodingError._invalidFloatingPointValue(float, at: codingPath)
            }
            
            if float == Float.infinity {
                return NSString(string: posInfString)
            } else if float == -Float.infinity {
                return NSString(string: negInfString)
            } else {
                return NSString(string: nanString)
            }
        }
        
        return NSNumber(value: float)
    }
    
    fileprivate func box(_ double: Double) throws -> NSObject {
        guard !double.isInfinite && !double.isNaN else {
            guard case let .convertToString(positiveInfinity: posInfString,
                                            negativeInfinity: negInfString,
                                            nan: nanString) = self.options.nonConformingFloatEncodingStrategy else {
                throw EncodingError._invalidFloatingPointValue(double, at: codingPath)
            }
            
            if double == Double.infinity {
                return NSString(string: posInfString)
            } else if double == -Double.infinity {
                return NSString(string: negInfString)
            } else {
                return NSString(string: nanString)
            }
        }
        
        return NSNumber(value: double)
    }
    
    fileprivate func boxDate(_ date: Date) throws -> NSObject {
        switch self.options.dateEncodingStrategy {
        case .deferredToDate:
            // 为什么, 被序列化的对象, 实现 public func encode(to encoder: Encoder) throws
            // 方法, 就会被调用的原因
            // 因为, 逻辑类, 主动调用了他们的 encode 方法.
            // 对于, 不是 Dict, Array 的数据, encode 的过程, 会有一次 container 的入栈的过程. pop 恢复栈的状态, 并且返回刚刚生成的数据.
            try date.encode(to: self)
            return self.storage.popContainer()
        // 其他的 dateFormat 的 case, 就是按照 Case 的要求, 进行对应的字符串操作.
        case .secondsSince1970:
            return NSNumber(value: date.timeIntervalSince1970)
        case .millisecondsSince1970:
            return NSNumber(value: 1000.0 * date.timeIntervalSince1970)
        case .iso8601:
            if #available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                return NSString(string: _iso8601Formatter.string(from: date))
            } else {
                fatalError("ISO8601DateFormatter is unavailable on this platform.")
            }
        case .formatted(let formatter):
            return NSString(string: formatter.string(from: date))
        
        case .custom(let closure):
            let depth = self.storage.count
            do {
                try closure(date, self)
            } catch {
                // If the value pushed a container before throwing, pop it back off to restore state.
                // 当发生了错误的时候, 恢复数据到错误发生前的状态.
                if self.storage.count > depth {
                    let _ = self.storage.popContainer()
                }
                throw error
            }
            
            guard self.storage.count > depth else {
                // The closure didn't encode anything. Return the default keyed container.
                return NSDictionary()
            }
            
            // We can pop because the closure encoded something.
            return self.storage.popContainer()
        }
    }
    
    fileprivate func boxData(_ data: Data) throws -> NSObject {
        switch self.options.dataEncodingStrategy {
        case .deferredToData:
            // Must be called with a surrounding with(pushedKey:) call.
            let depth = self.storage.count
            do {
                try data.encode(to: self)
            } catch {
                if self.storage.count > depth {
                    let _ = self.storage.popContainer()
                }
                throw error
            }
            return self.storage.popContainer()
            
        // 用 base 64 的方式, 表示 data. base 64 是一个通用的表示二进制数据的方式.
        case .base64:
            return NSString(string: data.base64EncodedString())
            
        case .custom(let closure):
            let depth = self.storage.count
            do {
                try closure(data, self)
            } catch {
                // If the value pushed a container before throwing, pop it back off to restore state.
                if self.storage.count > depth {
                    let _ = self.storage.popContainer()
                }
                throw error
            }
            
            guard self.storage.count > depth else {
                // The closure didn't encode anything. Return the default keyed container.
                return NSDictionary()
            }
            // We can pop because the closure encoded something.
            return self.storage.popContainer()
        }
    }
    
    fileprivate func boxDict(_ dict: [String : Encodable]) throws -> NSObject? {
        let depth = self.storage.count
        // result 就是一个字典.
        let result = self.storage.pushKeyedContainer()
        do {
            for (key, value) in dict {
                // 在这个过程中, 可能会发生递归调用.
                self.codingPath.append(_JSONKey(stringValue: key, intValue: nil))
                defer { self.codingPath.removeLast() }
                result[key] = try box(value)
            }
        } catch {
            // If the value pushed a container before throwing, pop it back off to restore state.
            if self.storage.count > depth {
                // 不需要的值, 需要显示的标明, 不想要使用返回值.
                let _ = self.storage.popContainer()
            }
            
            throw error
        }
        
        // The top container should be a new container.
        guard self.storage.count > depth else {
            return nil
        }
        
        return self.storage.popContainer()
    }
    
    
    fileprivate func box(_ value: Encodable) throws -> NSObject {
        return try self.boxObject(value) ?? NSDictionary()
    }
    
    // 这个函数, 是将 Encodable 对象, 变为符合 JSON 格式的对象.
    fileprivate func boxObject(_ value: Encodable) throws -> NSObject? {
        let type = Swift.type(of: value)
        
        if type == Date.self {
            return try self.boxDate((value as! Date))
        } else if type == Data.self {
            return try self.boxData((value as! Data))
        } else if type == URL.self {
            return self.boxString((value as! URL).absoluteString)
        } else if type == Decimal.self {
            return NSDecimalNumber(decimal: value as! Decimal)
        } else if value is _JSONStringDictionaryEncodableMarker {
            // extension Dictionary : _JSONStringDictionaryEncodableMarker where Key == String, Value: Encodable { }
            // 对于 Dict, 专门设计了一个协议. 注意 _JSONStringDictionaryEncodableMarker 是一个空协议
            // Swift 有很多这种空协议, 为的就是类型的识别. 而且, 是用的泛型的限制进行的识别. 这样代码有了很强的灵活性.
            return try boxDict(value as! [String : Encodable])
        }
        
        // 不是上面的几个, JSON 可以直接关联的类型, 就要调用自定义对象的 encode 方法了.
        let depth = self.storage.count
        do {
            try value.encode(to: self)
        } catch {
            // If the value pushed a container before throwing, pop it back off to restore state.
            if self.storage.count > depth {
                let _ = self.storage.popContainer()
            }
            throw error
        }
        
        // The top container should be a new container.
        guard self.storage.count > depth else {
            return nil
        }
        
        return self.storage.popContainer()
    }
}

// MARK: - _JSONReferencingEncoder

/// _JSONReferencingEncoder is a special subclass of _JSONEncoder which has its own storage, but references the contents of a different encoder.
/// It's used in superEncoder(), which returns a new encoder for encoding a superclass -- the lifetime of the encoder should not escape the scope it's created in, but it doesn't necessarily know when it's done being used (to write to the original container).
fileprivate class _JSONReferencingEncoder : _JSONEncoder {
    // MARK: Reference types.
    
    /// The type of container we're referencing.
    private enum Reference {
        /// Referencing a specific index in an array container.
        case array(NSMutableArray, Int)
        
        /// Referencing a specific key in a dictionary container.
        case dictionary(NSMutableDictionary, String)
    }
    
    // MARK: - Properties
    
    /// The encoder we're referencing.
    fileprivate let encoder: _JSONEncoder
    
    /// The container reference itself.
    private let reference: Reference
    
    // MARK: - Initialization
    
    /// Initializes `self` by referencing the given array container in the given encoder.
    fileprivate init(referencing encoder: _JSONEncoder, at index: Int, wrapping array: NSMutableArray) {
        self.encoder = encoder
        self.reference = .array(array, index)
        super.init(options: encoder.options, codingPath: encoder.codingPath)
        
        self.codingPath.append(_JSONKey(index: index))
    }
    
    /// Initializes `self` by referencing the given dictionary container in the given encoder.
    fileprivate init(referencing encoder: _JSONEncoder, at key: CodingKey, wrapping dictionary: NSMutableDictionary) {
        self.encoder = encoder
        self.reference = .dictionary(dictionary, key.stringValue)
        super.init(options: encoder.options, codingPath: encoder.codingPath)
        
        self.codingPath.append(key)
    }
    
    // MARK: - Coding Path Operations
    
    fileprivate override var canEncodeNewValue: Bool {
        // With a regular encoder, the storage and coding path grow together.
        // A referencing encoder, however, inherits its parents coding path, as well as the key it was created for.
        // We have to take this into account.
        return self.storage.count == self.codingPath.count - self.encoder.codingPath.count - 1
    }
    
    // MARK: - Deinitialization
    
    // Finalizes `self` by writing the contents of our storage to the referenced encoder's storage.
    deinit {
        let value: Any
        switch self.storage.count {
        case 0: value = NSDictionary()
        case 1: value = self.storage.popContainer()
        default: fatalError("Referencing encoder deallocated with multiple containers on stack.")
        }
        
        switch self.reference {
        case .array(let array, let index):
            array.insert(value, at: index)
            
        case .dictionary(let dictionary, let key):
            dictionary[NSString(string: key)] = value
        }
    }
}

//===----------------------------------------------------------------------===//
// JSON Decoder
//===----------------------------------------------------------------------===//

// Decode 应该是 Encode 的逆过程. 所以这些值, 应该是和 Encode 配置是一样的才可以.
open class JSONDecoder {
    
    public enum DateDecodingStrategy {
        case deferredToDate
        case secondsSince1970
        case millisecondsSince1970
        @available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601
        case formatted(DateFormatter)
        case custom((_ decoder: Decoder) throws -> Date)
    }
    
    public enum DataDecodingStrategy {
        case deferredToData
        case base64
        case custom((_ decoder: Decoder) throws -> Data)
    }
    
    public enum NonConformingFloatDecodingStrategy {
        case `throw`
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }
    
    public enum KeyDecodingStrategy {
        case useDefaultKeys
        case convertFromSnakeCase
        case custom((_ codingPath: [CodingKey]) -> CodingKey)
        
        fileprivate static func _convertFromSnakeCase(_ stringKey: String) -> String {
            guard !stringKey.isEmpty else { return stringKey }
            
            // Find the first non-underscore character
            guard let firstNonUnderscore = stringKey.firstIndex(where: { $0 != "_" }) else {
                // Reached the end without finding an _
                return stringKey
            }
            
            // Find the last non-underscore character
            var lastNonUnderscore = stringKey.index(before: stringKey.endIndex)
            while lastNonUnderscore > firstNonUnderscore && stringKey[lastNonUnderscore] == "_" {
                stringKey.formIndex(before: &lastNonUnderscore)
            }
            
            let keyRange = firstNonUnderscore...lastNonUnderscore
            let leadingUnderscoreRange = stringKey.startIndex..<firstNonUnderscore
            let trailingUnderscoreRange = stringKey.index(after: lastNonUnderscore)..<stringKey.endIndex
            
            let components = stringKey[keyRange].split(separator: "_")
            let joinedString : String
            if components.count == 1 {
                // No underscores in key, leave the word as is - maybe already camel cased
                joinedString = String(stringKey[keyRange])
            } else {
                joinedString = ([components[0].lowercased()] + components[1...].map { $0.capitalized }).joined()
            }
            
            // Do a cheap isEmpty check before creating and appending potentially empty strings
            let result : String
            if (leadingUnderscoreRange.isEmpty && trailingUnderscoreRange.isEmpty) {
                result = joinedString
            } else if (!leadingUnderscoreRange.isEmpty && !trailingUnderscoreRange.isEmpty) {
                // Both leading and trailing underscores
                result = String(stringKey[leadingUnderscoreRange]) + joinedString + String(stringKey[trailingUnderscoreRange])
            } else if (!leadingUnderscoreRange.isEmpty) {
                // Just leading
                result = String(stringKey[leadingUnderscoreRange]) + joinedString
            } else {
                // Just trailing
                result = joinedString + String(stringKey[trailingUnderscoreRange])
            }
            return result
        }
    }
    
    /// The strategy to use in decoding dates. Defaults to `.deferredToDate`.
    open var dateDecodingStrategy: DateDecodingStrategy = .deferredToDate
    
    /// The strategy to use in decoding binary data. Defaults to `.base64`.
    open var dataDecodingStrategy: DataDecodingStrategy = .base64
    
    /// The strategy to use in decoding non-conforming numbers. Defaults to `.throw`.
    open var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw
    
    /// The strategy to use for decoding keys. Defaults to `.useDefaultKeys`.
    open var keyDecodingStrategy: KeyDecodingStrategy = .useDefaultKeys
    
    /// Contextual user-provided information for use during decoding.
    open var userInfo: [CodingUserInfoKey : Any] = [:]
    
    /// Options set on the top-level encoder to pass down the decoding hierarchy.
    fileprivate struct _Options {
        let dateDecodingStrategy: DateDecodingStrategy
        let dataDecodingStrategy: DataDecodingStrategy
        let nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy
        let keyDecodingStrategy: KeyDecodingStrategy
        let userInfo: [CodingUserInfoKey : Any]
    }
    
    /// The options set on the top-level decoder.
    fileprivate var options: _Options {
        return _Options(dateDecodingStrategy: dateDecodingStrategy,
                        dataDecodingStrategy: dataDecodingStrategy,
                        nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
                        keyDecodingStrategy: keyDecodingStrategy,
                        userInfo: userInfo)
    }
    
    // MARK: - Constructing a JSON Decoder
    
    /// Initializes `self` with default strategies.
    public init() {}
    
    open func decode<T : Decodable>(_ type: T.Type,
                                    from data: Data) throws -> T {
        let topLevel: Any
        // 首先, 是根据 JSONSerialization 进行反序列化, 然后 _JSONDecoder 将数据从基本数据类型, 转化到对应的数据类型.
        do {
            topLevel = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "The given data was not valid JSON.", underlyingError: error))
        }
        
        let decoder = _JSONDecoder(referencing: topLevel,
                                   options: self.options)
        // 从 NSArray, NSDict 中, 构建 type 的过程.
        guard let value = try decoder.unbox(topLevel, as: type) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: [], debugDescription: "The given data did not contain a top-level value."))
        }
        
        return value
    }
}

// MARK: - _JSONDecoder

fileprivate class _JSONDecoder : Decoder {
    // MARK: Properties
    
    /// The decoder's storage.
    fileprivate var storage: _JSONDecodingStorage
    
    /// Options set on the top-level decoder.
    fileprivate let options: JSONDecoder._Options
    
    /// The path to the current point in encoding.
    fileprivate(set) public var codingPath: [CodingKey]
    
    /// Contextual user-provided information for use during encoding.
    public var userInfo: [CodingUserInfoKey : Any] {
        return self.options.userInfo
    }
    
    // MARK: - Initialization
    
    fileprivate init(referencing container: Any, at codingPath: [CodingKey] = [], options: JSONDecoder._Options) {
        // 默认, 吧 contianer push 到 storage. 也就是顶层中.
        self.storage = _JSONDecodingStorage()
        self.storage.push(container: container)
        self.codingPath = codingPath
        self.options = options
    }
    
    // MARK: - Decoder Methods
    
    
    public func container<Key>(keyedBy KeyName: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard !(self.storage.topContainer is NSNull) else {
            throw DecodingError.valueNotFound(KeyedDecodingContainer<Key>.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get keyed decoding container -- found null value instead."))
        }
        
        guard let topContainer = self.storage.topContainer as? [String : Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: self.storage.topContainer)
        }
        
        let container = _JSONKeyedDecodingContainer<Key>(referencing: self,
                                                         wrapping: topContainer)
        return KeyedDecodingContainer(container)
    }
    
    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard !(self.storage.topContainer is NSNull) else {
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get unkeyed decoding container -- found null value instead."))
        }
        
        guard let topContainer = self.storage.topContainer as? [Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: self.storage.topContainer)
        }
        
        return _JSONUnkeyedDecodingContainer(referencing: self, wrapping: topContainer)
    }
    
    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        return self
    }
}

// MARK: - Decoding Storage

fileprivate struct _JSONDecodingStorage {
    // MARK: Properties
    
    /// The container stack.
    /// Elements may be any one of the JSON types (NSNull, NSNumber, String, Array, [String : Any]).
    private(set) fileprivate var containers: [Any] = []
    
    // MARK: - Initialization
    
    /// Initializes `self` with no containers.
    fileprivate init() {}
    
    // MARK: - Modifying the Stack
    
    fileprivate var count: Int {
        return self.containers.count
    }
    
    fileprivate var topContainer: Any {
        precondition(!self.containers.isEmpty, "Empty container stack.")
        return self.containers.last!
    }
    
    fileprivate mutating func push(container: Any) {
        self.containers.append(container)
    }
    
    fileprivate mutating func popContainer() {
        precondition(!self.containers.isEmpty, "Empty container stack.")
        self.containers.removeLast()
    }
}

// KeyValue 形式的解档工具类.
fileprivate struct _JSONKeyedDecodingContainer<K : CodingKey> : KeyedDecodingContainerProtocol {
    typealias Key = K
    
    // MARK: Properties
    
    /// A reference to the decoder we're reading from.
    private let decoder: _JSONDecoder
    
    /// A reference to the container we're reading from.
    private let container: [String : Any]
    
    /// The path of coding keys taken to get to this point in decoding.
    private(set) public var codingPath: [CodingKey]
    
    // MARK: - Initialization
    
    /// Initializes `self` by referencing the given decoder and container.
    fileprivate init(referencing decoder: _JSONDecoder, wrapping container: [String : Any]) {
        self.decoder = decoder
        switch decoder.options.keyDecodingStrategy {
        case .useDefaultKeys:
            self.container = container
        case .convertFromSnakeCase:
            // Convert the snake case keys in the container to camel case.
            // If we hit a duplicate key after conversion, then we'll use the first one we saw. Effectively an undefined behavior with JSON dictionaries.
            self.container = Dictionary(container.map {
                key, value in (JSONDecoder.KeyDecodingStrategy._convertFromSnakeCase(key), value)
            }, uniquingKeysWith: { (first, _) in first })
        case .custom(let converter):
            self.container = Dictionary(container.map {
                key, value in (converter(decoder.codingPath + [_JSONKey(stringValue: key, intValue: nil)]).stringValue, value)
            }, uniquingKeysWith: { (first, _) in first })
        }
        self.codingPath = decoder.codingPath
    }
    
    // MARK: - KeyedDecodingContainerProtocol Methods
    
    public var allKeys: [Key] {
        return self.container.keys.compactMap { Key(stringValue: $0) }
    }
    
    public func contains(_ key: Key) -> Bool {
        return self.container[key.stringValue] != nil
    }
    
    private func _errorDescription(of key: CodingKey) -> String {
        switch decoder.options.keyDecodingStrategy {
        case .convertFromSnakeCase:
            // In this case we can attempt to recover the original value by reversing the transform
            let original = key.stringValue
            let converted = JSONEncoder.KeyEncodingStrategy._convertToSnakeCase(original)
            if converted == original {
                return "\(key) (\"\(original)\")"
            } else {
                return "\(key) (\"\(original)\"), converted to \(converted)"
            }
        default:
            // Otherwise, just report the converted string
            return "\(key) (\"\(key.stringValue)\")"
        }
    }
    
    public func decodeNil(forKey key: Key) throws -> Bool {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        return entry is NSNull
    }
    
    public func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Bool.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Int.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Int8.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Int16.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Int32.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Int64.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: UInt.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: UInt8.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: UInt16.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: UInt32.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: UInt64.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Float.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: Double.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func decode(_ type: String.Type, forKey key: Key) throws -> String {
        // 使用的是 key.stringValue, 所以, 这里也会使用到我们改名后的 string
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: String.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    // 按照 key, 获取到对应的 JSON 对象之后, 转化为 T 的过程.
    public func decode<T : Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        // 先从 Json 对象里面, 按照 key 获取到对应的下一层 JSON 对象.
        guard let entry = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = try self.decoder.unbox(entry, as: type) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath, debugDescription: "Expected \(type) value but found null instead."))
        }
        
        return value
    }
    
    public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key,
                                            DecodingError.Context(codingPath: self.codingPath,
                                                                  debugDescription: "Cannot get \(KeyedDecodingContainer<NestedKey>.self) -- no value found for key \(_errorDescription(of: key))"))
        }
        
        guard let dictionary = value as? [String : Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: value)
        }
        
        let container = _JSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: dictionary)
        return KeyedDecodingContainer(container)
    }
    
    public func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        guard let value = self.container[key.stringValue] else {
            throw DecodingError.keyNotFound(key,
                                            DecodingError.Context(codingPath: self.codingPath,
                                                                  debugDescription: "Cannot get UnkeyedDecodingContainer -- no value found for key \(_errorDescription(of: key))"))
        }
        
        guard let array = value as? [Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: value)
        }
        
        return _JSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
    }
    
    private func _superDecoder(forKey key: CodingKey) throws -> Decoder {
        self.decoder.codingPath.append(key)
        defer { self.decoder.codingPath.removeLast() }
        
        let value: Any = self.container[key.stringValue] ?? NSNull()
        return _JSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
    }
    
    public func superDecoder() throws -> Decoder {
        return try _superDecoder(forKey: _JSONKey.super)
    }
    
    public func superDecoder(forKey key: Key) throws -> Decoder {
        return try _superDecoder(forKey: key)
    }
}

fileprivate struct _JSONUnkeyedDecodingContainer : UnkeyedDecodingContainer {
    // MARK: Properties
    
    /// A reference to the decoder we're reading from.
    private let decoder: _JSONDecoder
    
    /// A reference to the container we're reading from.
    private let container: [Any]
    
    /// The path of coding keys taken to get to this point in decoding.
    private(set) public var codingPath: [CodingKey]
    
    /// The index of the element we're about to decode.
    private(set) public var currentIndex: Int
    
    // MARK: - Initialization
    
    /// Initializes `self` by referencing the given decoder and container.
    fileprivate init(referencing decoder: _JSONDecoder, wrapping container: [Any]) {
        self.decoder = decoder
        self.container = container
        self.codingPath = decoder.codingPath
        self.currentIndex = 0
    }
    
    // MARK: - UnkeyedDecodingContainer Methods
    
    public var count: Int? {
        return self.container.count
    }
    
    public var isAtEnd: Bool {
        return self.currentIndex >= self.count!
    }
    
    public mutating func decodeNil() throws -> Bool {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(Any?.self, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        if self.container[self.currentIndex] is NSNull {
            self.currentIndex += 1
            return true
        } else {
            return false
        }
    }
    
    public mutating func decode(_ type: Bool.Type) throws -> Bool {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Bool.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Int.Type) throws -> Int {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Int8.Type) throws -> Int8 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int8.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Int16.Type) throws -> Int16 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int16.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Int32.Type) throws -> Int32 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int32.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Int64.Type) throws -> Int64 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Int64.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: UInt.Type) throws -> UInt {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt8.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt16.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt32.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: UInt64.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Float.Type) throws -> Float {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Float.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: Double.Type) throws -> Double {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: Double.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode(_ type: String.Type) throws -> String {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: String.self) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func decode<T : Decodable>(_ type: T.Type) throws -> T {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Unkeyed container is at end."))
        }
        
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard let decoded = try self.decoder.unbox(self.container[self.currentIndex], as: type) else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.decoder.codingPath + [_JSONKey(index: self.currentIndex)], debugDescription: "Expected \(type) but found null instead."))
        }
        
        self.currentIndex += 1
        return decoded
    }
    
    public mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get nested keyed container -- unkeyed container is at end."))
        }
        
        let value = self.container[self.currentIndex]
        guard !(value is NSNull) else {
            throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get keyed decoding container -- found null value instead."))
        }
        
        guard let dictionary = value as? [String : Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [String : Any].self, reality: value)
        }
        
        self.currentIndex += 1
        let container = _JSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: dictionary)
        return KeyedDecodingContainer(container)
    }
    
    public mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get nested keyed container -- unkeyed container is at end."))
        }
        
        let value = self.container[self.currentIndex]
        guard !(value is NSNull) else {
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get keyed decoding container -- found null value instead."))
        }
        
        guard let array = value as? [Any] else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: [Any].self, reality: value)
        }
        
        self.currentIndex += 1
        return _JSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
    }
    
    public mutating func superDecoder() throws -> Decoder {
        self.decoder.codingPath.append(_JSONKey(index: self.currentIndex))
        defer { self.decoder.codingPath.removeLast() }
        
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(Decoder.self,
                                              DecodingError.Context(codingPath: self.codingPath,
                                                                    debugDescription: "Cannot get superDecoder() -- unkeyed container is at end."))
        }
        
        let value = self.container[self.currentIndex]
        self.currentIndex += 1
        return _JSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
    }
}

extension _JSONDecoder : SingleValueDecodingContainer {
    // MARK: SingleValueDecodingContainer Methods
    
    private func expectNonNull<T>(_ type: T.Type) throws {
        guard !self.decodeNil() else {
            throw DecodingError.valueNotFound(type, DecodingError.Context(codingPath: self.codingPath, debugDescription: "Expected \(type) but found null value instead."))
        }
    }
    
    public func decodeNil() -> Bool {
        return self.storage.topContainer is NSNull
    }
    
    public func decode(_ type: Bool.Type) throws -> Bool {
        try expectNonNull(Bool.self)
        return try self.unbox(self.storage.topContainer, as: Bool.self)!
    }
    
    public func decode(_ type: Int.Type) throws -> Int {
        try expectNonNull(Int.self)
        return try self.unbox(self.storage.topContainer, as: Int.self)!
    }
    
    public func decode(_ type: Int8.Type) throws -> Int8 {
        try expectNonNull(Int8.self)
        return try self.unbox(self.storage.topContainer, as: Int8.self)!
    }
    
    public func decode(_ type: Int16.Type) throws -> Int16 {
        try expectNonNull(Int16.self)
        return try self.unbox(self.storage.topContainer, as: Int16.self)!
    }
    
    public func decode(_ type: Int32.Type) throws -> Int32 {
        try expectNonNull(Int32.self)
        return try self.unbox(self.storage.topContainer, as: Int32.self)!
    }
    
    public func decode(_ type: Int64.Type) throws -> Int64 {
        try expectNonNull(Int64.self)
        return try self.unbox(self.storage.topContainer, as: Int64.self)!
    }
    
    public func decode(_ type: UInt.Type) throws -> UInt {
        try expectNonNull(UInt.self)
        return try self.unbox(self.storage.topContainer, as: UInt.self)!
    }
    
    public func decode(_ type: UInt8.Type) throws -> UInt8 {
        try expectNonNull(UInt8.self)
        return try self.unbox(self.storage.topContainer, as: UInt8.self)!
    }
    
    public func decode(_ type: UInt16.Type) throws -> UInt16 {
        try expectNonNull(UInt16.self)
        return try self.unbox(self.storage.topContainer, as: UInt16.self)!
    }
    
    public func decode(_ type: UInt32.Type) throws -> UInt32 {
        try expectNonNull(UInt32.self)
        return try self.unbox(self.storage.topContainer, as: UInt32.self)!
    }
    
    public func decode(_ type: UInt64.Type) throws -> UInt64 {
        try expectNonNull(UInt64.self)
        return try self.unbox(self.storage.topContainer, as: UInt64.self)!
    }
    
    public func decode(_ type: Float.Type) throws -> Float {
        try expectNonNull(Float.self)
        return try self.unbox(self.storage.topContainer, as: Float.self)!
    }
    
    public func decode(_ type: Double.Type) throws -> Double {
        try expectNonNull(Double.self)
        return try self.unbox(self.storage.topContainer, as: Double.self)!
    }
    
    public func decode(_ type: String.Type) throws -> String {
        try expectNonNull(String.self)
        return try self.unbox(self.storage.topContainer, as: String.self)!
    }
    
    public func decode<T : Decodable>(_ type: T.Type) throws -> T {
        try expectNonNull(type)
        return try self.unbox(self.storage.topContainer, as: type)!
    }
}

// MARK: - Concrete Value Representations

extension _JSONDecoder {
    
    fileprivate func unbox(_ value: Any, as type: Bool.Type) throws -> Bool? {
        guard !(value is NSNull) else { return nil }
        
        if let number = value as? NSNumber {
            // TODO: Add a flag to coerce non-boolean numbers into Bools?
            if number === kCFBooleanTrue as NSNumber {
                return true
            } else if number === kCFBooleanFalse as NSNumber {
                return false
            }
        }
        
        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }
    
    fileprivate func unbox(_ value: Any, as type: Int.Type) throws -> Int? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let int = number.intValue
        guard NSNumber(value: int) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return int
    }
    
    fileprivate func unbox(_ value: Any, as type: Int8.Type) throws -> Int8? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let int8 = number.int8Value
        guard NSNumber(value: int8) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return int8
    }
    
    fileprivate func unbox(_ value: Any, as type: Int16.Type) throws -> Int16? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let int16 = number.int16Value
        guard NSNumber(value: int16) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return int16
    }
    
    fileprivate func unbox(_ value: Any, as type: Int32.Type) throws -> Int32? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let int32 = number.int32Value
        guard NSNumber(value: int32) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return int32
    }
    
    fileprivate func unbox(_ value: Any, as type: Int64.Type) throws -> Int64? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let int64 = number.int64Value
        guard NSNumber(value: int64) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return int64
    }
    
    fileprivate func unbox(_ value: Any, as type: UInt.Type) throws -> UInt? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let uint = number.uintValue
        guard NSNumber(value: uint) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return uint
    }
    
    fileprivate func unbox(_ value: Any, as type: UInt8.Type) throws -> UInt8? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let uint8 = number.uint8Value
        guard NSNumber(value: uint8) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return uint8
    }
    
    fileprivate func unbox(_ value: Any, as type: UInt16.Type) throws -> UInt16? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let uint16 = number.uint16Value
        guard NSNumber(value: uint16) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return uint16
    }
    
    fileprivate func unbox(_ value: Any, as type: UInt32.Type) throws -> UInt32? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let uint32 = number.uint32Value
        guard NSNumber(value: uint32) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return uint32
    }
    
    fileprivate func unbox(_ value: Any, as type: UInt64.Type) throws -> UInt64? {
        guard !(value is NSNull) else { return nil }
        
        guard let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        let uint64 = number.uint64Value
        guard NSNumber(value: uint64) == number else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number <\(number)> does not fit in \(type)."))
        }
        
        return uint64
    }
    
    fileprivate func unbox(_ value: Any, as type: Float.Type) throws -> Float? {
        guard !(value is NSNull) else { return nil }
        
        if let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse {
            // We are willing to return a Float by losing precision:
            // * If the original value was integral,
            //   * and the integral value was > Float.greatestFiniteMagnitude, we will fail
            //   * and the integral value was <= Float.greatestFiniteMagnitude, we are willing to lose precision past 2^24
            // * If it was a Float, you will get back the precise value
            // * If it was a Double or Decimal, you will get back the nearest approximation if it will fit
            let double = number.doubleValue
            guard abs(double) <= Double(Float.greatestFiniteMagnitude) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Parsed JSON number \(number) does not fit in \(type)."))
            }
            
            return Float(double)
            
            /* FIXME: If swift-corelibs-foundation doesn't change to use NSNumber, this code path will need to be included and tested:
             } else if let double = value as? Double {
             if abs(double) <= Double(Float.max) {
             return Float(double)
             }
             overflow = true
             } else if let int = value as? Int {
             if let float = Float(exactly: int) {
             return float
             }
             
             overflow = true
             */
            
        } else if let string = value as? String,
                  case .convertFromString(let posInfString, let negInfString, let nanString) = self.options.nonConformingFloatDecodingStrategy {
            if string == posInfString {
                return Float.infinity
            } else if string == negInfString {
                return -Float.infinity
            } else if string == nanString {
                return Float.nan
            }
        }
        
        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }
    
    fileprivate func unbox(_ value: Any, as type: Double.Type) throws -> Double? {
        guard !(value is NSNull) else { return nil }
        
        if let number = __SwiftValue.store(value) as? NSNumber, number !== kCFBooleanTrue, number !== kCFBooleanFalse {
            // We are always willing to return the number as a Double:
            // * If the original value was integral, it is guaranteed to fit in a Double; we are willing to lose precision past 2^53 if you encoded a UInt64 but requested a Double
            // * If it was a Float or Double, you will get back the precise value
            // * If it was Decimal, you will get back the nearest approximation
            return number.doubleValue
            
            /* FIXME: If swift-corelibs-foundation doesn't change to use NSNumber, this code path will need to be included and tested:
             } else if let double = value as? Double {
             return double
             } else if let int = value as? Int {
             if let double = Double(exactly: int) {
             return double
             }
             
             overflow = true
             */
            
        } else if let string = value as? String,
                  case .convertFromString(let posInfString, let negInfString, let nanString) = self.options.nonConformingFloatDecodingStrategy {
            if string == posInfString {
                return Double.infinity
            } else if string == negInfString {
                return -Double.infinity
            } else if string == nanString {
                return Double.nan
            }
        }
        
        throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
    }
    
    fileprivate func unbox(_ value: Any, as type: String.Type) throws -> String? {
        guard !(value is NSNull) else { return nil }
        
        guard let string = value as? String else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        
        return string
    }
    
    // 如果 unbox 不成功, 默认是 throw error 的.
    fileprivate func unboxDate(_ value: Any, as type: Date.Type) throws -> Date? {
        
        guard !(value is NSNull) else { return nil }
        
        switch self.options.dateDecodingStrategy {
        case .deferredToDate:
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try Date(from: self)
            
        case .secondsSince1970:
            let double = try self.unbox(value, as: Double.self)!
            return Date(timeIntervalSince1970: double)
            
        case .millisecondsSince1970:
            let double = try self.unbox(value, as: Double.self)!
            return Date(timeIntervalSince1970: double / 1000.0)
            
        case .iso8601:
            if #available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                let string = try self.unbox(value, as: String.self)!
                guard let date = _iso8601Formatter.date(from: string) else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Expected date string to be ISO8601-formatted."))
                }
                
                return date
            } else {
                fatalError("ISO8601DateFormatter is unavailable on this platform.")
            }
            
        case .formatted(let formatter):
            let string = try self.unbox(value, as: String.self)!
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Date string does not match format expected by formatter."))
            }
            
            return date
            
        case .custom(let closure):
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try closure(self)
        }
    }
    
    fileprivate func unbox(_ value: Any, as type: Data.Type) throws -> Data? {
        guard !(value is NSNull) else { return nil }
        
        switch self.options.dataDecodingStrategy {
        case .deferredToData:
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try Data(from: self)
            
        case .base64:
            guard let string = value as? String else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
            }
            
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath, debugDescription: "Encountered Data is not valid Base64."))
            }
            
            return data
            
        case .custom(let closure):
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try closure(self)
        }
    }
    
    fileprivate func unbox(_ value: Any, as type: Decimal.Type) throws -> Decimal? {
        guard !(value is NSNull) else { return nil }
        if let decimal = value as? Decimal {
            return decimal
        } else {
            let doubleValue = try self.unbox(value, as: Double.self)!
            return Decimal(doubleValue)
        }
    }
    
    // Dict 的反序列化
    fileprivate func unbox<T>(_ value: Any, as type: _JSONStringDictionaryDecodableMarker.Type) throws -> T? {
        guard !(value is NSNull) else { return nil }
        
        var result = [String : Any]()
        guard let dict = value as? NSDictionary else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        let elementType = type.elementType // 可以通过类型. associateType, 取到类型.
        for (key, value) in dict {
            let key = key as! String
            self.codingPath.append(_JSONKey(stringValue: key, intValue: nil))
            defer { self.codingPath.removeLast() } // defer 的大量使用.
            result[key] = try unbox_(value, as: elementType)
        }
        
        return result as? T
    }
    
    fileprivate func unbox<T : Decodable>(_ value: Any,
                                          as type: T.Type) throws -> T? {
        return try unbox_(value, as: type) as? T
    }
    
    // 这里, 必须是 Decodable.Type. 因为上面的 T: Decodable, 所以这里可以这样写.
    fileprivate func unbox_(_ value: Any, as type: Decodable.Type) throws -> Any? {
        // 所以, 最终还是根据参数, 作为 Type 的分发器.
        if type == Date.self || type == NSDate.self {
            return try self.unboxDate(value, as: Date.self)
        } else if type == Data.self || type == NSData.self {
            return try self.unbox(value, as: Data.self)
        } else if type == URL.self || type == NSURL.self {
            // 如果是 Url, 就按照字符串处理, 这是在 encode 逻辑里面写好的.
            guard let urlString = try self.unbox(value, as: String.self) else {
                return nil
            }
            guard let url = URL(string: urlString) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: self.codingPath,
                                                                        debugDescription: "Invalid URL string."))
            }
            return url
        } else if type == Decimal.self || type == NSDecimalNumber.self {
            return try self.unbox(value, as: Decimal.self)
        } else if let stringKeyedDictType = type as? _JSONStringDictionaryDecodableMarker.Type {
            return try self.unbox(value, as: stringKeyedDictType)
        } else {
            // type 不是上面的 JSON 关联的类型, 那么使用各个类自己定义的 init 方法, 进行初始化.
            // 所以, 这里对象的创建, 还是要构建的过程.
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try type.init(from: self)
        }
    }
}

//===----------------------------------------------------------------------===//
// Shared Key Types
//===----------------------------------------------------------------------===//

fileprivate struct _JSONKey : CodingKey {
    public var stringValue: String
    public var intValue: Int?
    
    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    public init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
    
    public init(stringValue: String, intValue: Int?) {
        self.stringValue = stringValue
        self.intValue = intValue
    }
    fileprivate init(index: Int) {
        self.stringValue = "Index \(index)"
        self.intValue = index
    }
    
    fileprivate static let `super` = _JSONKey(stringValue: "super")!
}

//===----------------------------------------------------------------------===//
// Shared ISO8601 Date Formatter
//===----------------------------------------------------------------------===//

// NOTE: This value is implicitly lazy and _must_ be lazy. We're compiled against the latest SDK (w/ ISO8601DateFormatter), but linked against whichever Foundation the user has. ISO8601DateFormatter might not exist, so we better not hit this code path on an older OS.
@available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
fileprivate var _iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = .withInternetDateTime
    return formatter
}()

//===----------------------------------------------------------------------===//
// Error Utilities
//===----------------------------------------------------------------------===//

extension EncodingError {
    /// Returns a `.invalidValue` error describing the given invalid floating-point value.
    ///
    ///
    /// - parameter value: The value that was invalid to encode.
    /// - parameter path: The path of `CodingKey`s taken to encode this value.
    /// - returns: An `EncodingError` with the appropriate path and debug description.
    fileprivate static func _invalidFloatingPointValue<T : FloatingPoint>(_ value: T, at codingPath: [CodingKey]) -> EncodingError {
        let valueDescription: String
        if value == T.infinity {
            valueDescription = "\(T.self).infinity"
        } else if value == -T.infinity {
            valueDescription = "-\(T.self).infinity"
        } else {
            valueDescription = "\(T.self).nan"
        }
        
        let debugDescription = "Unable to encode \(valueDescription) directly in JSON. Use JSONEncoder.NonConformingFloatEncodingStrategy.convertToString to specify how the value should be encoded."
        return .invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: debugDescription))
    }
}
