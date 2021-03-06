//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers


/// A thread pool that should be used for blocking IO.
public final class BlockingIOThreadPool {
    
    /// The state of the `WorkItem`.
    public enum WorkItemState {
        /// The `WorkItem` is active now and in process by the `BlockingIOThreadPool`.
        case active
        /// The `WorkItem` was cancelled and will not be processed by the `BlockingIOThreadPool`.
        case cancelled
    }
    
    /// The work that should be done by the `BlockingIOThreadPool`.
    public typealias WorkItem = (WorkItemState) -> Void
    
    private enum State {
        /// The `BlockingIOThreadPool` is already stopped.
        case stopped
        /// The `BlockingIOThreadPool` is shutting down, the array has one boolean entry for each thread indicating if it has shut down already.
        case shuttingDown([Bool])
        /// The `BlockingIOThreadPool` is up and running, the `CircularBuffer` containing the yet unprocessed `WorkItems`.
        case running(CircularBuffer<WorkItem>)
    }
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = Lock()
    private let queues: [DispatchQueue]
    private var state: State = .stopped
    private let numberOfThreads: Int
    
    /// Gracefully shutdown this `BlockingIOThreadPool`. All tasks will be run before shutdown will take place.
    ///
    /// - parameters:
    ///     - queue: The `DispatchQueue` used to executed the callback
    ///     - callback: The function to be executed once the shutdown is complete.
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        let g = DispatchGroup()
        self.lock.withLock {
            switch self.state {
            case .running(let items):
                items.forEach { $0(.cancelled) }
                self.state = .shuttingDown(Array(repeating: true, count: numberOfThreads))
                (0..<numberOfThreads).forEach { _ in
                    self.semaphore.signal()
                }
            case .shuttingDown, .stopped:
                ()
            }
            
            self.queues.forEach { q in
                q.async(group: g) {}
            }
            
            g.notify(queue: queue) {
                callback(nil)
            }
        }
    }
    
    /// Submit a `WorkItem` to process.
    ///
    /// - parameters:
    ///     - body: The `WorkItem` to process by the `BlockingIOThreadPool`.
    public func submit(_ body: @escaping WorkItem) {
        let item = self.lock.withLock { () -> WorkItem? in
            switch self.state {
            case .running(var items):
                items.append(body)
                self.state = .running(items)
                self.semaphore.signal()
                return nil
            case .shuttingDown, .stopped:
                return body
            }
        }
        /* if item couldn't be added run it immediately indicating that it couldn't be run */
        item.map { $0(.cancelled) }
    }
    
    /// Initialize a `BlockingIOThreadPool` thread pool with `numberOfThreads` threads.
    ///
    /// - parameters:
    ///   - numberOfThreads: The number of threads to use for the thread pool.
    public init(numberOfThreads: Int) {
        self.numberOfThreads = numberOfThreads
        self.queues = (0..<numberOfThreads).map {
            DispatchQueue(label: "BlockingIOThreadPool thread #\($0)")
        }
    }
    
    private func process(identifier: Int) {
        var item: WorkItem? = nil
        repeat {
            /* wait until work has become available */
            self.semaphore.wait()
            
            item = self.lock.withLock { () -> (WorkItem)? in
                switch self.state {
                case .running(var items):
                    let item = items.removeFirst()
                    self.state = .running(items)
                    return item
                case .shuttingDown(var aliveStates):
                    assert(aliveStates[identifier])
                    aliveStates[identifier] = false
                    self.state = .shuttingDown(aliveStates)
                    return nil
                case .stopped:
                    return nil
                }
            }
            /* if there was a work item popped, run it */
            item.map { $0(.active) }
        } while item != nil
    }
    
    /// Start the `NonBlockingIOThreadPool` if not already started.
    public func start() {
        self.lock.withLock {
            switch self.state {
            case .running(_):
                return
            case .shuttingDown(_):
                // This should never happen
                fatalError("start() called while in shuttingDown")
            case .stopped:
                self.state = .running(CircularBuffer(initialRingCapacity: 16))
            }
        }
        self.queues.enumerated().forEach { idAndQueue in
            let id = idAndQueue.0
            let q = idAndQueue.1
            q.async { [unowned self] in
                self.process(identifier: id)
            }
        }
    }
}

extension BlockingIOThreadPool {
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }
    
    public func syncShutdownGracefully() throws {
        let errorStorageLock = Lock()
        var errorStorage: Swift.Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }
}
