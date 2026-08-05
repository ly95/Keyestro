import Foundation
@testable import KeyestroCore

actor FakeNetworkService: NetworkServicing {
    private(set) var requests: [NetworkRequest] = []
    var response: Result<NetworkResponse, NetworkServiceError>

    init(
        response: Result<NetworkResponse, NetworkServiceError> = .success(
            NetworkResponse(statusCode: 200, headers: [:], body: Data())
        )
    ) {
        self.response = response
    }

    func send(_ request: NetworkRequest) throws -> NetworkResponse {
        requests.append(request)
        return try response.get()
    }
}
