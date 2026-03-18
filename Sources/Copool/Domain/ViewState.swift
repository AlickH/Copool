import Foundation

enum ViewState<Value> {
    case loading
    case empty(message: String)
    case content(Value)
    case error(message: String)
}

extension ViewState: Equatable where Value: Equatable {}
