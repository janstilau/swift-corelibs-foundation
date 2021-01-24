#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

extension _NativeProtocol {
    // 枚举, 是一个值类型. 如果里面的关联值, 是一个引用语义的, 那么每次拿到引用值, 然后调用方法修改里面的值.
    // 如果里面的是值语义的, 那么每次, 其实是替换关联值
    // 前一种, 不算是修改枚举的值, 后一种, 一定是修改枚举的值.
    
    
    // 主要存了, 1 状态值. 2 每一行的协议头的数据.
    internal enum _ParsedResponseHeader {
        case partial(_ResponseHeaderLines)
        case complete(_ResponseHeaderLines)
        init() {
            self = .partial(_ResponseHeaderLines())
        }
    }
    
    internal struct _ResponseHeaderLines {
        let lines: [String]
        init() {
            self.lines = []
        }
        init(headerLines: [String]) {
            self.lines = headerLines
        }
    }
}

extension _NativeProtocol._ParsedResponseHeader {
   
    func byAppending(headerLine data: Data, onHeaderCompleted: (String) -> Bool) -> _NativeProtocol._ParsedResponseHeader? {
        // 这个方法, 主要就是核实一下, 传递过来的 data 是不是合法的 data
        // 真正的对于 lines 的操作, 放到了 _byAppending 里面
        // 这种设计手法, 很常见. 数据的修改, 专门有一个方法, 而暴露出去的, 会将之前的一些其他逻辑实现了.
        guard 2 <= data.count &&
            data[data.endIndex - 2] == _Delimiters.CR &&
            data[data.endIndex - 1] == _Delimiters.LF
            else { return nil }
        let lineBuffer = data.subdata(in: data.startIndex..<data.endIndex-2)
        guard let line = String(data: lineBuffer, encoding: .utf8) else { return nil}
        return _byAppending(headerLine: line, onHeaderCompleted: onHeaderCompleted)
    }
    
    // 虽然, 有着 private 的表示, 但是这里还是使用了 _ 开头作为方法的作用域的暗示.
    private func _byAppending(headerLine line: String, onHeaderCompleted: (String) -> Bool) -> _NativeProtocol._ParsedResponseHeader {
        // 如果, 是一个空行, 就代表着之前累加的, 已经是最后的 responseHeader 了. 否则, 继续接受.
        // 这个方法, 一定要用闭包的方式吗?? 自己写应该就不用了, 但是这个可能会被 FTP 使用, 所以留了一个扩展的点.
        if onHeaderCompleted(line) {
            switch self {
            case .partial(let header): return .complete(header) // 把 header 的值, 取出来, 包装成为新的状态, 在天回去.
            case .complete: return .partial(_NativeProtocol._ResponseHeaderLines()) // ???, 这里应该是错了.
            }
        } else {
            let header = partialResponseHeader
            return .partial(header.byAppending(headerLine: line))
        }
    }

    private var partialResponseHeader: _NativeProtocol._ResponseHeaderLines {
        switch self {
        case .partial(let header): return header
        case .complete: return _NativeProtocol._ResponseHeaderLines()
        }
    }
}

private extension _NativeProtocol._ResponseHeaderLines {
    /// Returns a copy of the lines with the new line appended to it.
    func byAppending(headerLine line: String) -> _NativeProtocol._ResponseHeaderLines {
        var l = self.lines
        l.append(line)
        return _NativeProtocol._ResponseHeaderLines(headerLines: l)
    }
}

// 特殊的值, 专门定义了一个类型标识.
// 他本质上来说, 就是一个 UInt8 的包装, 但是没有必要去自定义值, 所有的值, 都用类属性的方式, 提供出去.
struct _Delimiters {
    /// *Carriage Return* symbol
    static let CR: UInt8 = 0x0d
    /// *Line Feed* symbol
    static let LF: UInt8 = 0x0a
    /// *Space* symbol
    static let Space = UnicodeScalar(0x20)
    static let HorizontalTab = UnicodeScalar(0x09)
    static let Colon = UnicodeScalar(0x3a)
    static let Backslash = UnicodeScalar(0x5c)!
    static let Comma = UnicodeScalar(0x2c)!
    static let DoubleQuote = UnicodeScalar(0x22)!
    static let Equals = UnicodeScalar(0x3d)!
    /// *Separators* according to RFC 2616
    static let Separators = NSCharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
}
