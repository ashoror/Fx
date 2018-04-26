import Foundation

public extension PromiseType {

	@discardableResult
	func onSuccess(_ context: ExecutionContext = .default(), callback: @escaping Sink<Value>) -> Self {
		return onComplete(context) { result in
			result.analysis(ifSuccess: callback, ifFailure: { _ in })
		}
	}

	@discardableResult
	func onFailure(_ context: ExecutionContext = .default(), callback: @escaping Sink<Error>) -> Self {
		return onComplete(context) { result in
			result.analysis(ifSuccess: { _ in }, ifFailure: callback)
		}
	}

	func map<B>(_ f: @escaping (Value) -> B) -> Promise<B> {
		return map(.default(), f: f)
	}

	func map<B>(_ context: ExecutionContext, f: @escaping (Value) -> B) -> Promise<B> {
		return Promise { resolve in
			onComplete(context) { result in
				resolve(result.map(f))
			}
		}
	}

	func flatMap<B>(_ f: @escaping (Value) -> Promise<B>) -> Promise<B> {
		return flatMap(.default(), f: f)
	}

	func flatMap<B>(_ context: ExecutionContext, f: @escaping (Value) -> Promise<B>) -> Promise<B> {
		return Promise { resolve in
			onComplete(context) { result in
				result.map(f).analysis(
					ifSuccess: { $0.onComplete(.sync, callback: resolve) },
					ifFailure: { resolve(.error($0)) }
				)
			}
		}
	}

	func tryMap<B>(_ f: @escaping (Value) throws -> B) -> Promise<B> {
		return tryMap(.default(), f: f)
	}

	func tryMap<B>(_ context: ExecutionContext, f: @escaping (Value) throws -> B) -> Promise<B> {
		return Promise { resolve in
			onComplete(context) { result in
				resolve(result.tryMap(f))
			}
		}
	}

	func recover(_ context: ExecutionContext = .default(), f: @escaping (Error) -> Value) -> Promise<Value> {
		return Promise { resolve in
			onComplete(context) { result in
				resolve(.value(result.analysis(ifSuccess: id, ifFailure: f)))
			}
		}
	}

	func recover(_ context: ExecutionContext = .default(), f: @escaping (Error) -> Promise<Value>) -> Promise<Value> {
		return Promise { resolve in
			onComplete(context) { result in
				result.analysis(ifSuccess: Promise.init(value:), ifFailure: f)
					.onComplete(.sync, callback: resolve)
			}
		}
	}

	func mapError(_ f: @escaping (Error) -> Error) -> Promise<Value> {
		return mapError(.default(), f: f)
	}

	func mapError(_ context: ExecutionContext, f: @escaping (Error) -> Error) -> Promise<Value> {
		return Promise { resolve in
			onComplete(context) { result in
				resolve(result.analysis(ifSuccess: Result.value, ifFailure: Result.error • f))
			}
		}
	}

	func zip<B>(_ that: Promise<B>) -> Promise<(Value, B)> {
		return flatMap(.sync) { thisVal -> Promise<(Value, B)> in
			that.map(.sync) { thatVal in
				(thisVal, thatVal)
			}
		}
	}

	func asVoid() -> Promise<Void> {
		return self.map(.sync, f: { _ in () })
	}

	static func retry(_ times: Int, _ task: @escaping () -> Promise<Value>) -> Promise<Value> {
		var attempts = 0

		func attempt() -> Promise<Value> {
			attempts += 1
			return task().recover { error -> Promise<Value> in
				guard attempts < times else { return Promise(error: error) }
				return attempt()
			}
		}

		return attempt()
	}
}

public extension PromiseType where Value: PromiseType {

	func flatten() -> Promise<Value.Value> {
		return Promise { resolve in
			onComplete(.sync) { result in
				result.analysis(
					ifSuccess: { _ = $0.onComplete(.sync, callback: resolve) },
					ifFailure: resolve • Result.error
				)
			}
		}
	}
}

public extension Promise {

	/// Blocks the current thread until the promise is completed and then returns the result
	func forced() -> Result<A> {
		return forced(.distantFuture)!
	}

	/// Blocks the current thread until the promise is completed, but no longer than the given timeout
	/// If the promise did not complete before the timeout, `nil` is returned, otherwise the result of the promise is returned
	func forced(_ timeout: DispatchTime) -> Result<A>? {
		if let result = result {
			return result
		}

		let sema = DispatchSemaphore(value: 0)
		var res: Result<A>? = nil
		onComplete(.global) {
			res = $0
			sema.signal()
		}

		let _ = sema.wait(timeout: timeout)

		return res
	}

	/// Alias of delay(queue:interval:)
	/// Will pass the main queue if we are currently on the main thread, or the
	/// global queue otherwise
	func delay(_ interval: DispatchTimeInterval) -> Promise<A> {
		if Thread.isMainThread {
			return delay(DispatchQueue.main, interval: interval)
		}

		return delay(DispatchQueue.global(), interval: interval)
	}

	/// Returns an Promise that will complete with the result that this Promise completes with
	/// after waiting for the given interval
	/// The delay is implemented using dispatch_after. The given queue is passed to that function.
	/// If you want a delay of 0 to mean 'delay until next runloop', you will want to pass the main
	/// queue.
	func delay(_ queue: DispatchQueue, interval: DispatchTimeInterval) -> Promise<A> {
		return Promise { complete in
			onComplete(.sync) { result in
				queue.asyncAfter(deadline: DispatchTime.now() + interval) {
					complete(result)
				}
			}
		}
	}
}

public extension DispatchQueue {

	func asyncResult<A>(_ f: @escaping () -> Result<A>) -> Promise<A> {
		return Promise { resolve in
			async {
				resolve(f())
			}
		}
	}

	func promise<A>(_ f: @escaping () throws -> A) -> Promise<A> {
		return Promise { resolve in
			async { resolve(Result(f)) }
		}
	}
}

public extension Sequence where Iterator.Element: PromiseType {

	func fold<R>(_ zero: R, f: @escaping (R, Iterator.Element.Value) -> R) -> Promise<R> {
		return reduce(Promise(value: zero)) { result, element in
			result.flatMap { resultValue in
				element.map { elementValue in
					f(resultValue, elementValue)
				}
			}
		}
	}

	func all() -> Promise<[Iterator.Element.Value]> {
		return fold([]) { $0 + [$1] }
	}
}
