
extension NSLock {
    // Swift 里面, 有很多这种操作, 就是根据闭包的返回值, 来确定实际的返回值的类型.
    func performLocked<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

extension URLCache {
    public enum StoragePolicy : UInt {
        case allowed
        case allowedInMemoryOnly
        case notAllowed
    }
}

// 注意, 这是 NSCoding 协议, 不是 Coadable.
// 这是对于 OC 库的封装.
// 专门有一个存储相关的类, 进行 CachedURLResponse 的序列化, 反序列化的操作.
// CachedURLResponse 没有存储相关的代码, 责任更加的清晰
class StoredCachedURLResponse: NSObject, NSSecureCoding {
    class var supportsSecureCoding: Bool { return true }
    let cachedURLResponse: CachedURLResponse
    
    init(cachedURLResponse: CachedURLResponse) {
        self.cachedURLResponse = cachedURLResponse
    }
    
    func encode(with aCoder: NSCoder) {
        aCoder.encode(cachedURLResponse.response, forKey: "response")
        aCoder.encode(cachedURLResponse.data as NSData, forKey: "data")
        aCoder.encode(Int(bitPattern: cachedURLResponse.storagePolicy.rawValue), forKey: "storagePolicy")
        aCoder.encode(cachedURLResponse.userInfo as NSDictionary?, forKey: "userInfo")
        aCoder.encode(cachedURLResponse.date as NSDate, forKey: "date")
    }
    required init?(coder aDecoder: NSCoder) {
        guard let response = aDecoder.decodeObject(of: URLResponse.self, forKey: "response"),
              let data = aDecoder.decodeObject(of: NSData.self, forKey: "data"),
              let storagePolicy = URLCache.StoragePolicy(rawValue: UInt(bitPattern: aDecoder.decodeInteger(forKey: "storagePolicy"))),
              let date = aDecoder.decodeObject(of: NSDate.self, forKey: "date") else {
            return nil
        }
        let userInfo = aDecoder.decodeObject(of: NSDictionary.self, forKey: "userInfo") as? [AnyHashable: Any]
        cachedURLResponse = CachedURLResponse(response: response,
                                              data: data as Data,
                                              userInfo: userInfo,
                                              storagePolicy: storagePolicy)
        cachedURLResponse.date = date as Date
    }
}

open class CachedURLResponse : NSObject, NSCopying {
    open override func copy() -> Any {
        return copy(with: nil)
    }
    open func copy(with zone: NSZone? = nil) -> Any {
        return self
    }
    
    // 这里, URLResponse 显式地调用 Copy, 切断原来数据和这里的联系.
    public init(response: URLResponse, data: Data) {
        self.response = response.copy() as! URLResponse
        self.data = data
        self.userInfo = nil
        self.storagePolicy = .allowed
    }
    
    public init(response: URLResponse, data: Data, userInfo: [AnyHashable : Any]? = nil, storagePolicy: URLCache.StoragePolicy) {
        self.response = response.copy() as! URLResponse
        self.data = data
        self.userInfo = userInfo
        self.storagePolicy = storagePolicy
    }
    
    open private(set) var response: URLResponse
    open private(set) var data: Data
    open private(set) var userInfo: [AnyHashable : Any]?
    open private(set) var storagePolicy: URLCache.StoragePolicy
    // 因为, NSObject 对象很多操作都是 Id 的, 所以类型, 已经 null, 都应该注意.
    // 在这里, 通过 switch, 让代码变得非常简单.
    // switch, case, 就是简易版的 if 判断.
    open override func isEqual(_ value: Any?) -> Bool {
        switch value {
        case let other as CachedURLResponse:
            return self.isEqual(to: other)
        default:
            return false
        }
    }
    
    private func isEqual(to other: CachedURLResponse) -> Bool {
        if self === other {
            return true
        }
        // 这是通用的写法, 就是值相等, 就是里面的各个值的相等
        return self.response == other.response &&
            self.data == other.data &&
            self.storagePolicy == other.storagePolicy
    }
    
    internal fileprivate(set) var date: Date = Date()
    
    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(response)
        hasher.combine(data)
        hasher.combine(storagePolicy)
        return hasher.finalize()
    }
}

extension URLCache {
    // 这个东西, 应该专门写到一个 extension 里面
    // 这样会清晰一点, 这种把类型定义, 成员变量定义写在一起, 让代码太乱了.
    // 这里, id, cachedURLResponse 都应该设计成为 let.
    private struct CacheEntry: Hashable {
        var identifier: String
        var date: Date
        var cost: Int
        var cachedURLResponse: CachedURLResponse
        
        init(identifier: String, cachedURLResponse: CachedURLResponse, serializedVersion: Data? = nil) {
            self.identifier = identifier
            self.cachedURLResponse = cachedURLResponse
            self.date = Date()
            self.cost = serializedVersion?.count ?? (cachedURLResponse.data.count + 500 * (cachedURLResponse.userInfo?.count ?? 0))
        }
        // 数据部分, 真正重要的就是 id.
        func hash(into hasher: inout Hasher) {
            hasher.combine(identifier)
        }
        static func ==(_ lhs: CacheEntry, _ rhs: CacheEntry) -> Bool {
            return lhs.identifier == rhs.identifier
        }
    }
    
    private struct DiskEntry {
        static let pathExtension = "storedcachedurlresponse"
        
        var url: URL
        var date: Date
        var identifier: String
        
        init?(_ url: URL) {
            if url.pathExtension.caseInsensitiveCompare(DiskEntry.pathExtension) != .orderedSame {
                return nil
            }
            
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: ".")
            guard parts.count == 2 else { return nil }
            let (timeString, identifier) = (parts[0], parts[1])
            
            guard let time = Int64(timeString) else { return nil }
            
            self.date = Date(timeIntervalSinceReferenceDate: TimeInterval(time))
            self.identifier = identifier
            self.url = url
        }
    }
}

open class URLCache : NSObject {
    // 内部使用的, private 修饰.
    private static let sharedLock = NSLock()
    // 内部使用的, _shared 修饰.
    private static var _shared: URLCache?
    
    open class var shared: URLCache {
        get {
            return sharedLock.performLocked {
                if let shared = _shared {
                    return shared
                }
                // 这里, 是真正的懒加载的使用方式.
                let shared = URLCache(memoryCapacity: 4 * 1024 * 1024,
                                      diskCapacity: 20 * 1024 * 1024,
                                      diskPath: nil)
                _shared = shared
                return shared
            }
        }
        set {
            sharedLock.performLocked {
                _shared = newValue
            }
        }
    }
    
    private let cacheDirectory: URL?
    private let inMemoryCacheLock = NSLock()
    private var inMemoryCacheOrder: [String] = []
    private var inMemoryCacheContents: [String: CacheEntry] = [:]
    
    public init(memoryCapacity: Int, diskCapacity: Int, diskPath path: String?) {
        self.memoryCapacity = memoryCapacity
        self.diskCapacity = diskCapacity
        
        let url: URL?
        if let path = path {
            url = URL(fileURLWithPath: path)
        } else {
            do {
                let caches = try FileManager.default.url(for: .cachesDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true)
                let directoryName = (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                url = caches
                    .appendingPathComponent("org.swift.foundation.URLCache", isDirectory: true)
                    .appendingPathComponent(directoryName, isDirectory: true)
                // 实际上, 系统库和平时我们自己写的业务库没有太大的不一样.
            } catch {
                url = nil
            }
        }
        
        if let url = url {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                cacheDirectory = url
            } catch {
                cacheDirectory = nil
            }
        } else {
            cacheDirectory = nil
        }
    }
    
    // 根据 request, 生成对应的 id 值.
    private func identifier(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        
        if let host = url.host {
            var data = Data()
            data.append(Data(host.lowercased(with: NSLocale.system).utf8))
            data.append(0)
            let port = url.port ?? -1
            data.append(Data("\(port)".utf8))
            data.append(0)
            data.append(Data(url.path.utf8))
            data.append(0)
            
            return data.base64EncodedString()
        } else {
            return nil
        }
    }
    
    // 这种方式, 利用了 Block 做了收集的工作.
    // 不是很直观.
    private func enumerateDiskEntries(includingPropertiesForKeys keys: [URLResourceKey] = [],
                                      using block: (DiskEntry, inout Bool) -> Void) {
        guard let directory = cacheDirectory else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [] {
            if let entry = DiskEntry(url) {
                var stop = false
                block(entry, &stop)
                if stop { return }
            }
        }
    }
    
    private func diskEntries(includingPropertiesForKeys keys: [URLResourceKey] = []) -> [DiskEntry] {
        var entries: [DiskEntry] = []
        enumerateDiskEntries(includingPropertiesForKeys: keys) { (entry, stop) in
            entries.append(entry)
        }
        return entries
    }
    
    private func diskContentLocators(for request: URLRequest, forCreationAt date: Date? = nil) -> (identifier: String, url: URL)? {
        guard let directory = cacheDirectory else { return nil }
        guard let identifier = self.identifier(for: request) else { return nil }
        
        if let date = date {
            // Create a new URL, which may or may not exist on disk.
            let interval = Int64(date.timeIntervalSinceReferenceDate)
            return (identifier, directory.appendingPathComponent("\(interval).\(identifier).\(DiskEntry.pathExtension)"))
        } else {
            var foundURL: URL?
            
            enumerateDiskEntries { (entry, stop) in
                if entry.identifier == identifier {
                    foundURL = entry.url
                    stop = true
                }
            }
            
            if let foundURL = foundURL {
                return (identifier, foundURL)
            }
        }
        
        return nil
    }
    
    private func diskContents(for request: URLRequest) throws -> StoredCachedURLResponse? {
        guard let url = diskContentLocators(for: request)?.url else { return nil }
        
        let data = try Data(contentsOf: url)
        return try NSKeyedUnarchiver.unarchivedObject(ofClasses: [StoredCachedURLResponse.self], from: data) as? StoredCachedURLResponse
    }
    
    /*! 
     @method cachedResponseForRequest:
     @abstract Returns the NSCachedURLResponse stored in the cache with
     the given request.
     @discussion The method returns nil if there is no
     NSCachedURLResponse stored using the given request.
     @param request the NSURLRequest to use as a key for the lookup.
     @result The NSCachedURLResponse stored in the cache with the given
     request, or nil if there is no NSCachedURLResponse stored with the
     given request.
     */
    open func cachedResponse(for request: URLRequest) -> CachedURLResponse? {
        let result = inMemoryCacheLock.performLocked { () -> CachedURLResponse? in
            if let identifier = identifier(for: request),
               let entry = inMemoryCacheContents[identifier] {
                return entry.cachedURLResponse
            } else {
                return nil
            }
        }
        
        if let result = result {
            return result
        }
        
        guard let contents = try? diskContents(for: request) else { return nil }
        return contents.cachedURLResponse
    }
    
    open var memoryCapacity: Int {
        didSet {
            // 在 DidSet 里面, 去调用属性的修改后的逻辑, 这样代码更加简单.
            inMemoryCacheLock.performLocked {
                evictFromMemoryCacheAssumingLockHeld(maximumSize: memoryCapacity)
            }
        }
    }
    
    /*! 
     @method diskCapacity
     @abstract The on-disk capacity of the receiver.
     @discussion At the time this call is made, the on-disk cache will truncate its contents to the size given, if necessary.
     @param diskCapacity the new on-disk capacity, measured in bytes, for the receiver.
     */
    open var diskCapacity: Int {
        didSet { evictFromDiskCache(maximumSize: diskCapacity) }
    }
    
    /*! 
     @method currentMemoryUsage
     @abstract Returns the current amount of space consumed by the
     in-memory cache of the receiver.
     @discussion This size, measured in bytes, indicates the current
     usage of the in-memory cache.
     @result the current usage of the in-memory cache of the receiver.
     */
    open var currentMemoryUsage: Int {
        return inMemoryCacheLock.performLocked {
            return inMemoryCacheContents.values.reduce(0) { (result, entry) in
                return result + entry.cost
            }
        }
    }
    
    open var currentDiskUsage: Int {
        var total = 0
        enumerateDiskEntries(includingPropertiesForKeys: [.fileSizeKey]) { (entry, stop) in
            if let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
            }
        }
        
        return total
    }
    
    open func storeCachedResponse(_ cachedResponse: CachedURLResponse, for dataTask: URLSessionDataTask) {
        guard let request = dataTask.currentRequest else { return }
        storeCachedResponse(cachedResponse, for: request)
    }
    
    open func getCachedResponse(for dataTask: URLSessionDataTask, completionHandler: @escaping (CachedURLResponse?) -> Void) {
        guard let request = dataTask.currentRequest else {
            completionHandler(nil)
            return
        }
        DispatchQueue.global(qos: .background).async {
            completionHandler(self.cachedResponse(for: request))
        }
    }
    
    open func removeCachedResponse(for dataTask: URLSessionDataTask) {
        guard let request = dataTask.currentRequest else { return }
        removeCachedResponse(for: request)
    }
}

extension URLCache {
    /*!
     @method storeCachedResponse:forRequest:
     @abstract Stores the given NSCachedURLResponse in the cache using
     the given request.
     @param cachedResponse The cached response to store.
     @param request the NSURLRequest to use as a key for the storage.
     */
    open func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        let inMemory = cachedResponse.storagePolicy == .allowed || cachedResponse.storagePolicy == .allowedInMemoryOnly
        let onDisk = cachedResponse.storagePolicy == .allowed
        guard inMemory || onDisk else { return }
        
        guard let identifier = identifier(for: request) else { return }
        
        // Only create a serialized version if we are writing to disk:
        let object = StoredCachedURLResponse(cachedURLResponse: cachedResponse)
        let serialized = (onDisk && diskCapacity > 0) ? try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true) : nil
        
        let entry = CacheEntry(identifier: identifier, cachedURLResponse: cachedResponse, serializedVersion: serialized)
        
        if inMemory && entry.cost < memoryCapacity {
            inMemoryCacheLock.performLocked {
                evictFromMemoryCacheAssumingLockHeld(maximumSize: memoryCapacity - entry.cost)
                inMemoryCacheOrder.append(identifier)
                inMemoryCacheContents[identifier] = entry
            }
        }
        
        if onDisk, let serialized = serialized, entry.cost < diskCapacity {
            do {
                evictFromDiskCache(maximumSize: diskCapacity - entry.cost)
                
                let locators = diskContentLocators(for: request, forCreationAt: Date())
                if let newURL = locators?.url {
                    try serialized.write(to: newURL, options: .atomic)
                }
                
                if let identifier = locators?.identifier {
                    // Multiple threads and/or processes may be writing the same key at the same time. If writing the contents race for the exact same timestamp, we can't do much about that. (One of the two will exist, due to the .atomic; the other will error out.) But if the timestamps differ, we may end up with duplicate keys on disk.
                    // If so, best-effort clear all entries except the one with the highest date.
                    
                    // Refetch a snapshot of the directory contents from disk; do not trust prior state:
                    let entriesToRemove = diskEntries().filter {
                        $0.identifier == identifier
                    }.sorted {
                        $1.date < $0.date
                    }.dropFirst() // Keep the one with the latest date.
                    
                    for entry in entriesToRemove {
                        // Do not interrupt cleanup if one fails.
                        try? FileManager.default.removeItem(at: entry.url)
                    }
                }
                
            } catch { /* Best effort -- do not store on error. */ }
        }
    }
    
    open func removeCachedResponse(for request: URLRequest) {
        guard let identifier = identifier(for: request) else { return }
        
        inMemoryCacheLock.performLocked {
            if inMemoryCacheContents[identifier] != nil {
                inMemoryCacheOrder.removeAll(where: { $0 == identifier })
                inMemoryCacheContents.removeValue(forKey: identifier)
            }
        }
        
        if let oldURL = diskContentLocators(for: request)?.url {
            try? FileManager.default.removeItem(at: oldURL)
        }
    }
    
    // 清空, 内存清空, 文件清空
    open func removeAllCachedResponses() {
        inMemoryCacheLock.performLocked {
            inMemoryCacheContents = [:]
            inMemoryCacheOrder = []
        }
        evictFromDiskCache(maximumSize: 0)
    }
    
    open func removeCachedResponses(since date: Date) {
        // 通过 {} 的包裹, 两个代码段, 分别为内存修改, 文件修改, 这样代码清晰一点.
        inMemoryCacheLock.performLocked {
            var identifiersToRemove: Set<String> = []
            for entry in inMemoryCacheContents {
                if entry.value.date > date {
                    identifiersToRemove.insert(entry.key)
                }
            }
            for toRemove in identifiersToRemove {
                inMemoryCacheContents.removeValue(forKey: toRemove)
            }
            inMemoryCacheOrder.removeAll { identifiersToRemove.contains($0) }
        }
        // Do 可以单独使用, 这样可以显示的定义一个代码块
        do {
            let entriesToRemove = diskEntries().filter {
                $0.date > date
            }
            for entry in entriesToRemove {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }
    
    // evictFromMemoryCacheAssumingLockHeld 这个代码有点问题.
    // 加锁解锁是调用者的义务, 根本不应该使用函数名进行提醒.
    func evictFromMemoryCache(maximumSize: Int) {
        // 多多使用函数式编程, 这是 Swift 面向协议的优势所在.
        var totalSize = inMemoryCacheContents.values.reduce(0) { $0 + $1.cost }
        
        var countEvicted = 0
        for identifier in inMemoryCacheOrder {
            if totalSize > maximumSize {
                countEvicted += 1
                let entry = inMemoryCacheContents.removeValue(forKey: identifier)!
                totalSize -= entry.cost
            } else {
                break
            }
        }
        
        inMemoryCacheOrder.removeSubrange(0 ..< countEvicted)
    }
    
    func evictFromDiskCache(maximumSize: Int) {
        // 以往, 比较费时的操作, 在 Swift 里面, 通过三个 sequence 上的方法, 很简单的就完成了
        let entries = diskEntries(includingPropertiesForKeys: [.fileSizeKey]).sorted {
            $0.date < $1.date
        }
        let sizes = entries.map { (entry) in
            (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var totalSize = sizes.reduce(0, +)
        
        for (index, entry) in entries.enumerated() {
            if totalSize > maximumSize {
                try? FileManager.default.removeItem(at: entry.url)
                totalSize -= sizes[index]
            }
        }
    }
}
