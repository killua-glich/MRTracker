//
//  TLSDiagnosticsTests.swift
//  MyAppTests
//
//  MRT-025: TLS failure classification, user-facing messages, preflight probe, first-run
//  persistence, and https-only scheme validation. Uses MockURLProtocol to simulate TLS
//  failures; each test gets its own UserDefaults suite, removed afterwards.
//

import Foundation
import Testing
@testable import MyApp

struct TLSDiagnosticsTests {

    private let baseURL = URL(string: "https://gitlab.corp.example")!
    private let host = "gitlab.corp.example"
    private let probePath = "/api/v4/version"

    /// Runs `body` with an isolated `UserDefaults` suite and removes it afterwards.
    private func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let suiteName = "TLSDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try await body(defaults)
    }

    // MARK: - Classification

    @Test(arguments: [
        (URLError.Code.serverCertificateUntrusted, TLSDiagnosis.Category.untrustedCertificate),
        (.serverCertificateHasUnknownRoot, .untrustedCertificate),
        (.serverCertificateHasBadDate, .certificateDateInvalid),
        (.serverCertificateNotYetValid, .certificateDateInvalid),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.clientCertificateRequired, .clientCertificateRequired),
        (.clientCertificateRejected, .clientCertificateRequired),
    ])
    func tlsCodesClassifyAndMentionHost(code: URLError.Code, expected: TLSDiagnosis.Category) async {
        let fromAPIError = TLSDiagnostics.diagnose(GitLabAPIError.transport(code), baseURL: baseURL)
        #expect(fromAPIError.category == expected)
        #expect(fromAPIError.isTLSRelated)
        #expect(fromAPIError.code == code)
        #expect(fromAPIError.message.contains(host))
        #expect(!fromAPIError.title.isEmpty)

        let fromURLError = await TLSDiagnostics.diagnose(URLError(code), fallbackHost: host)
        #expect(fromURLError.category == expected)
        #expect(fromURLError.message.contains(host))
    }

    @Test func untrustedMessagePointsAtCorpCAAndVPN() {
        let diagnosis = TLSDiagnostics.diagnose(code: .serverCertificateUntrusted, host: host)
        #expect(diagnosis.message.contains("Keychain Access"))
        #expect(diagnosis.message.contains("Always Trust"))
        #expect(diagnosis.message.contains("VPN"))
    }

    @Test func untrustedMessageIncludesIssuerWhenKnown() {
        let diagnosis = TLSDiagnostics.diagnose(code: .serverCertificateHasUnknownRoot, host: host, issuer: "Corp Root CA")
        #expect(diagnosis.message.contains("Corp Root CA"))
    }

    @Test func dateInvalidMessageAdvisesClock() {
        let diagnosis = TLSDiagnostics.diagnose(code: .serverCertificateHasBadDate, host: host)
        #expect(diagnosis.message.contains("date and time"))
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost, .unknown])
    func nonTLSCodesAreNotTLSRelated(code: URLError.Code) async {
        #expect(TLSDiagnostics.diagnose(GitLabAPIError.transport(code), baseURL: baseURL).category == .notTLSRelated)
        #expect(await TLSDiagnostics.diagnose(URLError(code), fallbackHost: host).category == .notTLSRelated)
    }

    @Test(arguments: [GitLabAPIError.unauthorized, .forbidden, .notFound, .server(status: 502), .decoding("x"), .invalidURL])
    func nonTransportAPIErrorsAreNotTLSRelated(error: GitLabAPIError) {
        let diagnosis = TLSDiagnostics.diagnose(error, baseURL: baseURL)
        #expect(diagnosis.category == .notTLSRelated)
        #expect(diagnosis.code == nil)
    }

    @Test func hostComesFromFailingURLAndIncludesNonDefaultPort() async {
        let failing = URL(string: "https://git.other.example:8443/api/v4/version")!
        let error = URLError(.serverCertificateUntrusted, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        let diagnosis = await TLSDiagnostics.diagnose(error, fallbackHost: host)
        #expect(diagnosis.host == "git.other.example:8443")
        #expect(diagnosis.message.contains("git.other.example:8443"))
    }

    @Test func missingPeerTrustYieldsNilIssuerWithoutCrashing() async {
        let error = URLError(.serverCertificateUntrusted)
        #expect(error.failureURLPeerTrust == nil)
        let diagnosis = await TLSDiagnostics.diagnose(error, fallbackHost: host)
        #expect(diagnosis.category == .untrustedCertificate)
        #expect(diagnosis.issuer == nil)
        #expect(!diagnosis.message.contains("issued by"))
    }

    // MARK: - Scheme validation

    @Test func httpsIsAccepted() throws {
        try TLSDiagnostics.validateScheme(baseURL)
        try TLSDiagnostics.validateScheme(URL(string: "HTTPS://gitlab.corp.example:8443/gitlab")!)
    }

    @Test(arguments: ["http://gitlab.corp.example", "ftp://gitlab.corp.example", "gitlab.corp.example", "https://"])
    func nonHTTPSIsRejected(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(throws: TLSDiagnostics.InsecureSchemeError.self) {
            try TLSDiagnostics.validateScheme(url)
        }
    }

    @Test func preflightRejectsHTTPWithoutNetwork() async {
        let (session, controller) = URLSession.mock()
        let result = await TLSPreflight.check(baseURL: URL(string: "http://gitlab.corp.example")!, session: session)
        guard case .otherFailure(let message) = result else {
            Issue.record("expected .otherFailure, got \(result)")
            return
        }
        #expect(message.contains("https://"))
        #expect(controller.recordedRequests.isEmpty)
    }

    // MARK: - Preflight probe

    @Test func preflightSucceedsOnAnyHTTPResponseAndSendsNoToken() async {
        let (session, controller) = URLSession.mock()
        controller.stub(path: probePath, status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8))

        let result = await TLSPreflight.check(baseURL: baseURL, session: session)

        #expect(result == .ok)
        let sent = controller.recordedRequests
        #expect(sent.count == 1)
        #expect(sent.first?.url?.path == probePath)
        #expect(sent.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func preflightReportsTLSFailure() async {
        let (session, controller) = URLSession.mock()
        controller.stub(path: probePath, error: URLError(.serverCertificateUntrusted))

        let result = await TLSPreflight.check(baseURL: baseURL, session: session)

        guard case .tlsFailure(let diagnosis) = result else {
            Issue.record("expected .tlsFailure, got \(result)")
            return
        }
        #expect(diagnosis.category == .untrustedCertificate)
        #expect(diagnosis.message.contains(host))
    }

    @Test func preflightReportsNonTLSFailureSeparately() async {
        let (session, controller) = URLSession.mock()
        controller.stub(path: probePath, error: URLError(.notConnectedToInternet))

        let result = await TLSPreflight.check(baseURL: baseURL, session: session)

        guard case .otherFailure(let message) = result else {
            Issue.record("expected .otherFailure, got \(result)")
            return
        }
        #expect(message.contains(host))
    }

    // MARK: - First-run policy

    @Test func runIfNeededIsSilentOnSuccessAndPersistsHost() async {
        await withDefaults { defaults in
            let preflight = TLSPreflight(defaults: defaults)
            let (session, controller) = URLSession.mock()
            controller.stub(path: probePath, status: 401)

            #expect(!preflight.isVerified(baseURL))
            #expect(await preflight.runIfNeeded(baseURL: baseURL, session: session) == .ok)
            #expect(preflight.isVerified(baseURL))
            #expect(defaults.stringArray(forKey: TLSPreflight.verifiedHostsKey) == [host])

            // Second launch: no network at all.
            #expect(await preflight.runIfNeeded(baseURL: baseURL, session: session) == .ok)
            #expect(controller.recordedRequests.count == 1)
        }
    }

    @Test func runIfNeededDoesNotPersistOnTLSFailure() async {
        await withDefaults { defaults in
            let preflight = TLSPreflight(defaults: defaults)
            let (session, controller) = URLSession.mock()
            controller.stub(path: probePath, error: URLError(.serverCertificateHasUnknownRoot))

            let result = await preflight.runIfNeeded(baseURL: baseURL, session: session)

            guard case .tlsFailure = result else {
                Issue.record("expected .tlsFailure, got \(result)")
                return
            }
            #expect(!preflight.isVerified(baseURL))
        }
    }

    @Test func recheckAfterTLSFailureForgetsHostAndReprobes() async {
        await withDefaults { defaults in
            let preflight = TLSPreflight(defaults: defaults)
            preflight.markVerified(baseURL)
            let (session, controller) = URLSession.mock()
            controller.stub(path: probePath, error: URLError(.serverCertificateUntrusted))

            let diagnosis = await preflight.recheckAfterFailure(.transport(.serverCertificateUntrusted), baseURL: baseURL, session: session)

            #expect(diagnosis?.category == .untrustedCertificate)
            #expect(diagnosis?.message.contains(host) == true)
            #expect(!preflight.isVerified(baseURL))
            #expect(controller.recordedRequests.count == 1)
        }
    }

    @Test func recheckIgnoresNonTLSFailures() async {
        await withDefaults { defaults in
            let preflight = TLSPreflight(defaults: defaults)
            preflight.markVerified(baseURL)
            let (session, controller) = URLSession.mock()

            #expect(await preflight.recheckAfterFailure(.transport(.timedOut), baseURL: baseURL, session: session) == nil)
            #expect(await preflight.recheckAfterFailure(.unauthorized, baseURL: baseURL, session: session) == nil)
            #expect(preflight.isVerified(baseURL))
            #expect(controller.recordedRequests.isEmpty)
        }
    }
}
