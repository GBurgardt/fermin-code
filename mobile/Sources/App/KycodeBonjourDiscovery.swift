import Darwin
import Foundation

struct KycodeDiscoveredDesktop: Equatable, Sendable {
    let baseURL: String
    let authToken: String
    let serviceName: String
}

@MainActor
final class KycodeBonjourDiscovery: NSObject {
    private var browser: NetServiceBrowser?
    private var resolvedServices: Set<String> = []
    private var activeServices: [String: NetService] = [:]
    private var discoveredDesktops: [String: KycodeDiscoveredDesktop] = [:]
    private var continuation: CheckedContinuation<[KycodeDiscoveredDesktop], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var onResolvedDesktop: ((KycodeDiscoveredDesktop) -> Void)?
    private var hasFinished = false

    func discoverCandidates(
        timeout: Duration = .seconds(3),
        onResolvedDesktop: ((KycodeDiscoveredDesktop) -> Void)? = nil
    ) async -> [KycodeDiscoveredDesktop] {
        hasFinished = false
        resolvedServices.removeAll()
        activeServices.removeAll()
        discoveredDesktops.removeAll()
        self.onResolvedDesktop = onResolvedDesktop
        browser?.stop()
        browser = nil
        log("Iniciando busqueda de _kycode._tcp en local.")

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_kycode._tcp.", inDomain: "local.")
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(reason: "timeout")
            }
        }
    }

    func finishEarly(reason: String = "candidato valido") {
        finish(reason: reason)
    }

    private func finish(reason: String) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        onResolvedDesktop = nil
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        activeServices.removeAll()
        let candidates = discoveredDesktops.values.sorted { lhs, rhs in
            if lhs.serviceName == rhs.serviceName {
                return lhs.baseURL < rhs.baseURL
            }
            return lhs.serviceName < rhs.serviceName
        }
        log("Busqueda finalizada (\(reason)). Candidatos resueltos: \(candidates.count)")
        continuation?.resume(returning: candidates)
        continuation = nil
    }

    private func log(_ message: String) {
        NSLog("%@", "[Bonjour] \(message)")
    }

    private func resolvedHost(for service: NetService) -> String? {
        let addresses = service.addresses ?? []
        for address in addresses {
            if let host = ipAddress(from: address) {
                return host
            }
        }

        if let hostName = service.hostName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            return hostName
        }
        return nil
    }

    private func ipAddress(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            let result = getnameinfo(
                sockaddrPointer,
                socklen_t(data.count),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { return nil }
            return String(cString: host)
        }
    }

    private func normalizedBasePath(from text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" {
            return ""
        }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func normalizedURLHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains(":") && !trimmed.hasPrefix("[") && !trimmed.hasSuffix("]") {
            return "[\(trimmed)]"
        }
        return trimmed
    }

    private func errorDescription(from errorDict: [String: NSNumber]) -> String {
        errorDict
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ", ")
    }
}

extension KycodeBonjourDiscovery: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        guard resolvedServices.insert(key).inserted else { return }
        log("Encontrado servicio: \(service.name)")
        activeServices[key] = service
        service.delegate = self
        log("Resolviendo \(service.name)...")
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log("Busqueda fallo: \(errorDescription(from: errorDict))")
        finish(reason: "error")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        activeServices.removeValue(forKey: key)
        log("Servicio removido: \(service.name)")
    }
}

extension KycodeBonjourDiscovery: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = resolvedHost(for: sender), sender.port > 0 else {
            log("Resolve incompleto para \(sender.name): sin host o puerto")
            return
        }
        guard let txtData = sender.txtRecordData() else {
            log("Resolve incompleto para \(sender.name): sin TXT record")
            return
        }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        let token = txt["token"].flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            log("Resolve incompleto para \(sender.name): sin token")
            return
        }
        let basePath = normalizedBasePath(from: txt["path"].flatMap { String(data: $0, encoding: .utf8) })
        let baseURL = "http://\(normalizedURLHost(host)):\(sender.port)\(basePath)"
        let desktop = KycodeDiscoveredDesktop(
            baseURL: baseURL,
            authToken: token,
            serviceName: sender.name
        )
        discoveredDesktops[baseURL] = desktop
        log("Resolve completo: \(sender.name) -> \(baseURL)")
        onResolvedDesktop?(desktop)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        activeServices.removeValue(forKey: key)
        log("Resolve fallo para \(sender.name): \(errorDescription(from: errorDict))")
    }
}
