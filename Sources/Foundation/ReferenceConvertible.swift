
/// Decorates types which are backed by a Foundation reference type.
///
/// All `ReferenceConvertible` types are hashable, equatable, and provide description functions.
// ReferenceConvertible 表明了, 这个数据, 内部实际数据, 是一个引用类型.
// 不过, 这个类型没有使用的场合啊. 难道就是为了标明自己的内部数据结构吗
public protocol ReferenceConvertible : CustomStringConvertible, CustomDebugStringConvertible, Hashable {
    associatedtype ReferenceType : NSObject, NSCopying
}

