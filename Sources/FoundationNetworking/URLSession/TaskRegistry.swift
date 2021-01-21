#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

@_implementationOnly import CoreFoundation
import Dispatch

extension URLSession {
    /// This helper class keeps track of all tasks, and their behaviours.
    ///
    /// Each `URLSession` has a `TaskRegistry` for its running tasks. The
    /// *behaviour* defines what action is to be taken e.g. upon completion.
    /// The behaviour stores the completion handler for tasks that are
    /// completion handler based.
    ///
    /// - Note: This must **only** be accessed on the owning session's work queue.
    class _TaskRegistry {
        /// Completion handler for `URLSessionDataTask`, and `URLSessionUploadTask`.
        typealias DataTaskCompletion = (Data?, URLResponse?, Error?) -> Void
        /// Completion handler for `URLSessionDownloadTask`.
        typealias DownloadTaskCompletion = (URL?, URLResponse?, Error?) -> Void
        /// What to do upon events (such as completion) of a specific task.
        enum _Behaviour {
            /// Call the `URLSession`s delegate
            case callDelegate
            /// Default action for all events, except for completion.
            case dataCompletionHandler(DataTaskCompletion)
            /// Default action for all events, except for completion.
            case downloadCompletionHandler(DownloadTaskCompletion)
        }
        
        // 使用了两个 hash 表, 但是其实, 一个哈希表和一个更好的数据结构, 更加优雅.
        
        fileprivate var tasks: [Int: URLSessionTask] = [:] // task id 为 key 的哈希表, 存储 task.
        fileprivate var behaviours: [Int: _Behaviour] = [:] // task id 可 key 的哈希表, 存储回调.
        fileprivate var tasksFinishedCallback: (() -> Void)? // session 所有的任务执行完之后, 最终的回调
    }
}

extension URLSession._TaskRegistry {
    func add(_ task: URLSessionTask, behaviour: _Behaviour) {
        let identifier = task.taskIdentifier
        guard identifier != 0 else { fatalError("Invalid task identifier") }
        
        guard tasks.index(forKey: identifier) == nil else {
            // 自己写代码的时候, 经常不去注意这些异常判断. 应该引起重视.
            if tasks[identifier] === task {
                fatalError("Trying to re-insert a task that's already in the registry.")
            } else {
                fatalError("Trying to insert a task, but a different task with the same identifier is already in the registry.")
            }
        }
        // 核心的逻辑, 就是把数据藏到自己的结构里面. 这些数据, 稍后的算法会用到.
        tasks[identifier] = task
        behaviours[identifier] = behaviour
    }
    /// Remove a task
    ///
    /// - Note: This must **only** be accessed on the owning session's work queue.
    func remove(_ task: URLSessionTask) {
        let identifier = task.taskIdentifier
        // 所有的操作, 都使用 guard 进行判断, 如果不可以, 提前退出.
        guard identifier != 0 else { fatalError("Invalid task identifier") }
        guard let tasksIdx = tasks.index(forKey: identifier) else {
            fatalError("Trying to remove task, but it's not in the registry.")
        }
        tasks.remove(at: tasksIdx)
        guard let behaviourIdx = behaviours.index(forKey: identifier) else {
            fatalError("Trying to remove task's behaviour, but it's not in the registry.")
        }
        behaviours.remove(at: behaviourIdx)

        guard let allTasksFinished = tasksFinishedCallback else { return }
        // 如果, 没有了数据, 就调用该方法???
        if self.isEmpty {
            allTasksFinished()
        }
    }

    func notify(on tasksCompletion: @escaping () -> Void) {
        tasksFinishedCallback = tasksCompletion
    }

    var isEmpty: Bool {
        return tasks.isEmpty
    }
    
    var allTasks: [URLSessionTask] {
        return tasks.map { $0.value }
    }
}
extension URLSession._TaskRegistry {
    /// The behaviour that's registered for the given task.
    ///
    /// - Note: It is a programming error to pass a task that isn't registered.
    /// - Note: This must **only** be accessed on the owning session's work queue.
    // 取行为, 是为了做处理.
    // AFN 里面, 行为是用闭包的形式存储起来了. 存储了 结束, 和 过程两个行为
    // 这里, 行为也是用闭包存储起来了, 并且通过 枚举, 让代理调用更加清晰.
    func behaviour(for task: URLSessionTask) -> _Behaviour {
        guard let b = behaviours[task.taskIdentifier] else {
            fatalError("Trying to access a behaviour for a task that in not in the registry.")
        }
        return b
    }
}
