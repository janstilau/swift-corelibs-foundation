
/// Decorates types which are backed by a Foundation reference type.
///
/// All `ReferenceConvertible` types are hashable, equatable, and provide description functions.

public protocol ReferenceConvertible : CustomStringConvertible, CustomDebugStringConvertible, Hashable {
    associatedtype ReferenceType : NSObject, NSCopying
}

