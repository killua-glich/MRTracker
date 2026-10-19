//
//  TLSDiagnostics.swift
//  MyApp
//
//  Corp TLS sanity check (MRT-025): turn TLS-related transport failures into a clear,
//  actionable, user-facing message that points at the corporate root CA, instead of a
//  generic "network error".
//
//  This file only *reads* and *classifies*. It never installs a custom trust override,
//  never implements `urlSession(_:didReceive:completionHandler:)`, and never offers an
//  "allow insecure" escape hatch — the default `URLSession` + system trust store (which
//  includes the corp root CA installed in the macOS Keychain) stays the sole authority.
//  See PLAN.md → Security / Risks.
//

import Foundation
import Security

/// A user-facing classification of a (possibly) TLS-related failure.
///
/// Secret-free by construction: it carries only the host name, the issuer common name of
/// the certificate chain the server presented (public data), and the `URLError.Code`.
nonisolated struct TLSDiagnosis: Sendable, Equatable {

    nonisolated enum Category: Sendable, Equatable {
        /// The chain doesn't lead to a root the Mac trusts — the typical "corp root CA not
        /// installed / not trusted" case (`serverCertificateUntrusted`,
        /// `serverCertificateHasUnknownRoot`).
        case untrustedCertificate
        /// The certificate is expired or not yet valid — usually the Mac's clock, otherwise
        /// an expired server cert (`serverCertificateHasBadDate`,
        /// `serverCertificateNotYetValid`). Different advice than an untrusted root.
        case certificateDateInvalid
        /// The TLS handshake failed for a non-trust reason — often a proxy / security
        /// software intercepting TLS, or a protocol/cipher mismatch
        /// (`secureConnectionFailed`).
        case secureConnectionFailed
        /// The server demands (or rejected) a client certificate
        /// (`clientCertificateRequired`, `clientCertificateRejected`).
        case clientCertificateRequired
        /// Offline, timeout, DNS, HTTP status, decoding… — not this check's business.
        case notTLSRelated
    }

    let category: Category
    /// Host the failure is about (from the failing URL when available, else the
    /// configured base URL's host).
    let host: String
    /// Common name of the CA that issued the topmost certificate the server presented —
    /// i.e. the root the Mac would need to trust (e.g. "Corp Root CA"). `nil` when the
    /// peer trust wasn't available (it isn't for most failures, and never in mocks).
    let issuer: String?
    /// The underlying `URLError.Code`, when there was one.
    let code: URLError.Code?

    var isTLSRelated: Bool { category != .notTLSRelated }

    /// Short headline, e.g. for an alert title or the first line of an inline error.
    var title: String {
        switch category {
        case .untrustedCertificate: "Certificate not trusted"
        case .certificateDateInvalid: "Certificate date invalid"
        case .secureConnectionFailed: "Secure connection failed"
        case .clientCertificateRequired: "Client certificate required"
        case .notTLSRelated: "Connection failed"
        }
    }

    /// Actionable, single-paragraph explanation. Always mentions `host`.
    var message: String {
        switch category {
        case .untrustedCertificate:
            let issuedBy = issuer.map { " (issued by '\($0)')" } ?? ""
            return "Your Mac doesn't trust the certificate presented by \(host)\(issuedBy). "
                + "If your company uses its own root certificate, make sure it is installed in "
                + "Keychain Access → System and set to 'Always Trust', then try again. "
                + "If you're off the corporate network, connect to the VPN first."
        case .certificateDateInvalid:
            return "The certificate presented by \(host) is expired or not yet valid. "
                + "Check that your Mac's date and time are correct (System Settings → General → "
                + "Date & Time). If they are, the server's certificate may have expired — "
                + "contact your GitLab administrator."
        case .secureConnectionFailed:
            return "A secure connection to \(host) couldn't be established. A proxy, VPN, or "
                + "security software may be intercepting the connection. Make sure you're on the "
                + "corporate network or VPN and try again; if it keeps happening, contact IT."
        case .clientCertificateRequired:
            return "\(host) requires a client certificate, which this app doesn't support. "
                + "Contact your GitLab administrator."
        case .notTLSRelated:
            return "The connection to \(host) failed for a reason unrelated to its TLS certificate."
        }
    }
}

/// Pure classification helpers. All `static`, no state.
nonisolated enum TLSDiagnostics {

    // MARK: - Classification

    /// Maps a `URLError.Code` to a category. The single source of truth for which codes
    /// count as "TLS".
    static func category(for code: URLError.Code) -> TLSDiagnosis.Category {
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            .untrustedCertificate
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            .certificateDateInvalid
        case .secureConnectionFailed:
            .secureConnectionFailed
        case .clientCertificateRequired, .clientCertificateRejected:
            .clientCertificateRequired
        default:
            .notTLSRelated
        }
    }

    /// Classifies a code for `host` (no peer-trust inspection).
    static func diagnose(code: URLError.Code, host: String, issuer: String? = nil) -> TLSDiagnosis {
        TLSDiagnosis(category: category(for: code), host: host, issuer: issuer, code: code)
    }

    /// Classifies a `GitLabClient` error. `GitLabAPIError.transport` keeps only the code
    /// (no peer trust), so `issuer` is always `nil` here — run `TLSPreflight` for the
    /// richer diagnosis.
    static func diagnose(_ error: GitLabAPIError, baseURL: URL) -> TLSDiagnosis {
        let host = displayHost(of: baseURL)
        guard case .transport(let code) = error else {
            return TLSDiagnosis(category: .notTLSRelated, host: host, issuer: nil, code: nil)
        }
        return diagnose(code: code, host: host)
    }

    /// Classifies a raw `URLError`, inspecting its peer trust (when present) to report the
    /// issuer of the presented chain. A `secureConnectionFailed` whose peer trust doesn't
    /// evaluate is upgraded to `.untrustedCertificate`, since that's the actionable cause.
    ///
    /// `@concurrent`: `SecTrustEvaluateWithError` is synchronous and may block, so this
    /// always runs off the main actor.
    @concurrent
    static func diagnose(_ error: URLError, fallbackHost: String) async -> TLSDiagnosis {
        let host = error.failingURL.map(displayHost(of:)) ?? fallbackHost
        var category = category(for: error.code)
        guard category != .notTLSRelated, let trust = error.failureURLPeerTrust else {
            return TLSDiagnosis(category: category, host: host, issuer: nil, code: error.code)
        }
        if category == .secureConnectionFailed, !SecTrustEvaluateWithError(trust, nil) {
            category = .untrustedCertificate
        }
        return TLSDiagnosis(category: category, host: host, issuer: chainIssuer(of: trust), code: error.code)
    }

    // MARK: - Peer trust inspection (read-only)

    /// Common name of the CA that issued the topmost certificate in `trust`'s chain —
    /// the root the Mac must trust. For a self-signed top certificate that is its own
    /// name. Falls back to the top certificate's subject summary. Never modifies trust.
    static func chainIssuer(of trust: SecTrust) -> String? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let top = chain.last
        else { return nil }
        return issuerCommonName(of: top) ?? (SecCertificateCopySubjectSummary(top) as String?)
    }

    /// Issuer CN of `certificate`, via `SecCertificateCopyValues` (macOS-only API).
    static func issuerCommonName(of certificate: SecCertificate) -> String? {
        let issuerKey = kSecOIDX509V1IssuerName as String
        guard
            let values = SecCertificateCopyValues(certificate, [issuerKey] as CFArray, nil) as? [String: Any],
            let issuer = values[issuerKey] as? [String: Any],
            let fields = issuer[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }
        let commonNameOID = kSecOIDCommonName as String
        for field in fields where (field[kSecPropertyKeyLabel as String] as? String) == commonNameOID {
            if let name = field[kSecPropertyKeyValue as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    // MARK: - Scheme validation

    /// Thrown by `validateScheme(_:)`. Secret-free: carries only the offending scheme.
    nonisolated struct InsecureSchemeError: Error, Sendable, Equatable, CustomStringConvertible {
        let scheme: String?
        var description: String {
            "The GitLab URL must start with https://. Over \(scheme.map { "\($0)://" } ?? "a URL without a scheme") "
                + "your access token would be sent unencrypted."
        }
    }

    /// Rejects any base URL that isn't `https://` with a host. The PAT travels in a header on
    /// every request, so plain `http://` would leak it; there is deliberately no opt-out.
    static func validateScheme(_ url: URL) throws(InsecureSchemeError) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https", let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw InsecureSchemeError(scheme: scheme)
        }
    }

    // MARK: - Helpers

    /// `host` or `host:port` (port only when non-default), for messages and storage keys.
    static func displayHost(of url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        if let port = url.port, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }
}

// MARK: - Preflight

/// Outcome of `TLSPreflight.check(baseURL:session:)`.
nonisolated enum TLSPreflightResult: Sendable, Equatable {
    /// The TLS handshake succeeded (any HTTP response, whatever its status). Show nothing.
    case ok
    /// TLS validation failed — show `diagnosis.title` / `diagnosis.message`.
    case tlsFailure(TLSDiagnosis)
    /// Something else went wrong (offline, DNS, timeout, non-https URL…). Secret-free,
    /// user-readable. Not a TLS verdict, so the host is *not* marked verified.
    case otherFailure(String)
}

/// One cheap, unauthenticated HTTPS request that answers "does this Mac trust the GitLab
/// server's certificate?" before (and independently of) the PAT.
///
/// **Probe endpoint:** `GET <baseURL>/api/v4/version` *without* a token. Unauthenticated,
/// GitLab answers `401` with a tiny JSON body — and *any* HTTP response at all proves the
/// TLS handshake (including chain validation against the system trust store) succeeded,
/// which is all we want to know. The API path is used rather than `/` or `/users/sign_in`
/// because it never redirects to a (possibly differently-hosted) SSO login page, and
/// rather than `/-/health` / `/-/readiness` because those are IP-allowlisted by default.
/// No `Authorization` header is ever attached here.
///
/// **First-run policy** (`runIfNeeded` / `recheckAfterFailure`):
/// 1. On launch / after saving settings, `runIfNeeded(baseURL:)` probes once per host. On
///    `.ok` the host (`host[:port]`) is stored in `defaults` under `verifiedHostsKey`, and
///    later launches skip the probe entirely (no network, no UI).
/// 2. When a normal `GitLabClient` request fails with a TLS-classified error,
///    `recheckAfterFailure` drops the host from the verified set and re-probes once (the
///    raw `URLError` from the probe carries the peer trust, so the message can name the
///    issuing CA). Non-TLS failures are ignored (returns `nil`).
/// 3. An unverified host is probed again on the next `runIfNeeded` — i.e. next launch or
///    settings save — so a fixed Keychain is picked up without user action.
///
/// Never installs a trust override or session delegate: validation stays entirely with
/// the system (see PLAN.md → Security).
nonisolated struct TLSPreflight: Sendable {

    /// `UserDefaults` key holding `[String]` of verified `host[:port]` values.
    static let verifiedHostsKey = "TLSPreflight.verifiedHosts"

    /// Timeout for the probe; short, it's a single tiny request.
    static let timeout: TimeInterval = 15

    /// `UserDefaults` is documented thread-safe but not annotated `Sendable` in the SDK.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Probe

    /// The unauthenticated probe URL for `baseURL` (see type docs for the choice).
    static func probeURL(for baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api").appendingPathComponent("v4").appendingPathComponent("version")
    }

    /// Performs the probe. Does not read or write `UserDefaults`.
    static func check(baseURL: URL, session: URLSession = .shared) async -> TLSPreflightResult {
        do {
            try TLSDiagnostics.validateScheme(baseURL)
        } catch {
            return .otherFailure(error.description)
        }
        let host = TLSDiagnostics.displayHost(of: baseURL)

        var request = URLRequest(url: probeURL(for: baseURL), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false

        do {
            let (_, response) = try await session.data(for: request)
            // Any HTTP response — 200, 401, 404, 5xx — means the handshake succeeded.
            guard response is HTTPURLResponse else {
                return .otherFailure("\(host) returned an unexpected, non-HTTP response.")
            }
            return .ok
        } catch let urlError as URLError {
            let diagnosis = await TLSDiagnostics.diagnose(urlError, fallbackHost: host)
            if diagnosis.isTLSRelated {
                return .tlsFailure(diagnosis)
            }
            return .otherFailure("Couldn't reach \(host) (\(urlError.code.rawValue)): \(urlError.localizedDescription)")
        } catch {
            return .otherFailure("Couldn't reach \(host).")
        }
    }

    // MARK: Persistence / policy

    /// Whether `baseURL`'s host already passed the probe on an earlier run.
    func isVerified(_ baseURL: URL) -> Bool {
        verifiedHosts.contains(TLSDiagnostics.displayHost(of: baseURL))
    }

    /// First-run gate: returns `.ok` immediately (no network) for an already-verified host,
    /// otherwise probes and, on `.ok`, remembers the host.
    func runIfNeeded(baseURL: URL, session: URLSession = .shared) async -> TLSPreflightResult {
        if isVerified(baseURL) { return .ok }
        let result = await Self.check(baseURL: baseURL, session: session)
        if result == .ok { markVerified(baseURL) }
        return result
    }

    /// Call when a normal `GitLabClient` request failed. Returns `nil` for non-TLS errors
    /// (handle those as usual). For TLS errors: forgets the host's verified state, re-probes,
    /// and returns the probe's (richer, issuer-bearing) diagnosis — or, if the probe itself
    /// now succeeds or fails for a non-TLS reason, the classification of `error` itself.
    func recheckAfterFailure(_ error: GitLabAPIError, baseURL: URL, session: URLSession = .shared) async -> TLSDiagnosis? {
        let basic = TLSDiagnostics.diagnose(error, baseURL: baseURL)
        guard basic.isTLSRelated else { return nil }
        forget(baseURL)
        switch await Self.check(baseURL: baseURL, session: session) {
        case .tlsFailure(let diagnosis):
            return diagnosis
        case .ok:
            markVerified(baseURL)
            return basic
        case .otherFailure:
            return basic
        }
    }

    func markVerified(_ baseURL: URL) {
        let host = TLSDiagnostics.displayHost(of: baseURL)
        var hosts = verifiedHosts
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        defaults.set(hosts, forKey: Self.verifiedHostsKey)
    }

    func forget(_ baseURL: URL) {
        let host = TLSDiagnostics.displayHost(of: baseURL)
        defaults.set(verifiedHosts.filter { $0 != host }, forKey: Self.verifiedHostsKey)
    }

    private var verifiedHosts: [String] {
        defaults.stringArray(forKey: Self.verifiedHostsKey) ?? []
    }
}
