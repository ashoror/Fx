import Foundation

public func throttle<A>(_ interval: TimeInterval, on queue: DispatchQueue = DispatchQueue.main, function f: @escaping (A) -> ()) -> ((A) -> ()) {

	var sharedBlock = nil as DispatchWorkItem?
	let disposable = ActionDisposable {
		sharedBlock?.cancel()
	}

	return { x in
		capture(disposable)

		let block = DispatchWorkItem(flags: .inheritQoS) {
			queue.async {
				sharedBlock = nil
				f(x)
			}
		}

		sharedBlock?.cancel()
		sharedBlock = block

		let globalQueue = DispatchQueue.global(qos: DispatchQoS.QoSClass.userInteractive)
		globalQueue.asyncAfter(deadline: .now() + .init(interval), execute: block)
	}
}
