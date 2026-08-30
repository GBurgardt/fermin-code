import SwiftUI

struct KycodeSessionHistoryView: View {
    @EnvironmentObject private var store: KycodeConnectionStore
    @Environment(\.dismiss) private var dismiss

    let onOpenSession: (String) -> Void

    @State private var searchText = ""
    @State private var stateFilter: KycodeSessionHistoryState = .all
    @State private var sort: KycodeSessionHistorySort = .recent
    @State private var dateRange: KycodeSessionHistoryDateRange = .any
    @State private var projectPath: String?
    @State private var items: [KycodeSessionHistoryItem] = []
    @State private var total = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var openingItemId: String?
    @State private var errorText: String?
    @State private var lastUpdatedAt: Date?
    @State private var searchMs: Double?
    @State private var recentSearches: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var cachedCorpus: [KycodeSessionHistoryItem] = []
    @State private var cachedCorpusAt: Date?
    @State private var uiTestRetryAttempt = 0
    @FocusState private var searchFocused: Bool

    private static var isUITestFixtureEnabled: Bool {
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_HISTORY_FIXTURE"] == "1"
    }

    private static var isUITestRetryFixtureEnabled: Bool {
        ProcessInfo.processInfo.environment["KYCODE_UI_TEST_HISTORY_RETRY"] == "1"
    }

    private static var uiTestFixtureItems: [KycodeSessionHistoryItem] {
        let now = Date().timeIntervalSince1970 * 1_000
        return [
            KycodeSessionHistoryItem(
                id: "fixture-repetidor",
                sessionUUID: "fixture-repetidor",
                projectKey: "home-network",
                projectName: "Casa",
                sessionId: "fixture-session-repetidor",
                sessionName: "Repetidor WiFi",
                sessionPath: "/tmp/casa",
                createdAt: now - 10_000,
                updatedAt: now,
                state: .archived,
                windowId: nil,
                archivedId: "archive-repetidor",
                score: 120,
                preview: "Configuración del repetidor y señal WiFi del living.",
                matchedIn: "Conversación",
                canResume: true
            ),
            KycodeSessionHistoryItem(
                id: "fixture-mobile",
                sessionUUID: "fixture-mobile",
                projectKey: "kycode-mobile",
                projectName: "KyCode Mobile",
                sessionId: "fixture-session-mobile",
                sessionName: "QA Mobile",
                sessionPath: "/tmp/kycode-mobile",
                createdAt: now - 20_000,
                updatedAt: now - 10_000,
                state: .active,
                windowId: "fixture-window-mobile",
                archivedId: nil,
                score: 80,
                preview: "Pruebas del chat y streaming progresivo.",
                matchedIn: "Nombre",
                canResume: true
            ),
            KycodeSessionHistoryItem(
                id: "fixture-acentos",
                sessionUUID: "fixture-acentos",
                projectKey: "diseno",
                projectName: "Diseño",
                sessionId: "fixture-session-acentos",
                sessionName: "Revisión de navegación",
                sessionPath: "/tmp/diseno",
                createdAt: now - 30_000,
                updatedAt: now - 20_000,
                state: .archived,
                windowId: nil,
                archivedId: "archive-acentos",
                score: 70,
                preview: "Análisis de navegación, búsqueda y accesibilidad.",
                matchedIn: "Conversación",
                canResume: true
            ),
        ]
    }

    private var query: KycodeSessionHistoryQuery {
        KycodeSessionHistoryQuery(
            text: searchText,
            state: stateFilter,
            sort: sort,
            dateRange: dateRange,
            projectPath: projectPath,
            offset: 0,
            limit: 30,
            refresh: false
        )
    }

    private var queryRevision: String {
        [
            searchText,
            stateFilter.rawValue,
            sort.rawValue,
            dateRange.rawValue,
            projectPath ?? "",
        ].joined(separator: "|")
    }

    private var visibleProjects: [(path: String, name: String)] {
        let pairs = items.map { ($0.sessionPath, $0.projectName.isEmpty ? $0.sessionPath : $0.projectName) }
        var seen = Set<String>()
        return pairs.filter { seen.insert($0.0).inserted }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchSurface
                filters
                Divider().overlay(AppTheme.line)
                content
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Historial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") {
                        dismiss()
                    }
                    .accessibilityIdentifier("history-close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Orden", selection: $sort) {
                            ForEach(KycodeSessionHistorySort.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Picker("Fecha", selection: $dateRange) {
                            ForEach(KycodeSessionHistoryDateRange.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        if !visibleProjects.isEmpty {
                            Divider()
                            Button("Todos los proyectos") {
                                projectPath = nil
                            }
                            ForEach(visibleProjects, id: \.path) { project in
                                Button(project.name) {
                                    projectPath = project.path
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Orden y filtros")
                    .accessibilityIdentifier("history-advanced-filters")
                }
            }
            .task {
                if Self.isUITestRetryFixtureEnabled {
                    await loadUITestRetryFixture()
                    return
                }
                if Self.isUITestFixtureEnabled {
                    applyUITestFixture()
                    return
                }
                recentSearches = store.recentSessionHistorySearches()
                if let cached = store.cachedSessionHistoryCorpus() {
                    cachedCorpus = cached.items
                    cachedCorpusAt = cached.cachedAt
                }
                applyCache()
                await load(reset: true, refresh: false)
            }
            .onChange(of: queryRevision) { _, _ in
                if Self.isUITestFixtureEnabled {
                    applyUITestFixture()
                } else {
                    applyCache()
                }
                scheduleSearch()
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var searchSurface: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.inkSoft)
            TextField("Buscar nombre, proyecto o chat", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .accessibilityIdentifier("history-search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpiar búsqueda")
                .accessibilityIdentifier("history-search-clear")
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(AppTheme.ink)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.inputSurface)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(KycodeSessionHistoryState.allCases, id: \.self) { option in
                    Button {
                        stateFilter = option
                    } label: {
                        Text(option.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(stateFilter == option ? AppTheme.backgroundSolid : AppTheme.inkSoft)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(stateFilter == option ? AppTheme.ink : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history-filter-\(option.rawValue)")
                }

                if dateRange != .any {
                    activeFilterLabel(dateRange.title) {
                        dateRange = .any
                    }
                }
                if let projectPath {
                    activeFilterLabel(URL(fileURLWithPath: projectPath).lastPathComponent) {
                        self.projectPath = nil
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
        .background(AppTheme.background)
    }

    private func activeFilterLabel(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(AppTheme.accent)
                Text("Buscando en tus conversaciones…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("history-loading")
        } else if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: errorText == nil ? "clock.arrow.circlepath" : "wifi.slash")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)
                Text(errorText == nil ? "No encontré sesiones" : "Sin conexión")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text(errorText ?? "Probá otra palabra o quitá filtros.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.inkSoft)
                    .multilineTextAlignment(.center)
                Button("Reintentar") {
                    Task { await load(reset: true, refresh: true) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("history-retry")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history-empty")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if searchText.isEmpty, !recentSearches.isEmpty {
                        recentSearchStrip
                    }
                    resultSummary
                    ForEach(items) { item in
                        historyRow(item)
                        Divider().overlay(AppTheme.line)
                            .padding(.leading, 16)
                    }
                    if hasMore {
                        ProgressView()
                            .tint(AppTheme.accent)
                            .frame(height: 52)
                            .task {
                                await loadMore()
                            }
                    }
                }
            }
            .refreshable {
                await load(reset: true, refresh: true)
            }
            .accessibilityIdentifier("history-results")
        }
    }

    private var recentSearchStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text("Recientes")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.inkSoft)
                ForEach(recentSearches, id: \.self) { recent in
                    Button(recent) {
                        searchText = recent
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(minHeight: 36)
                }
                Button("Borrar") {
                    store.clearRecentSessionHistorySearches()
                    recentSearches = []
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.inkSoft)
                .frame(minHeight: 36)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
    }

    private var resultSummary: some View {
        HStack {
            Text("\(total) \(total == 1 ? "sesión" : "sesiones")")
            Spacer()
            if let searchMs {
                Text(String(format: "%.1f ms", searchMs))
            } else if let lastUpdatedAt {
                Text(lastUpdatedAt, style: .relative)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(AppTheme.inkSoft)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .accessibilityIdentifier("history-result-summary")
    }

    private func historyRow(_ item: KycodeSessionHistoryItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.state == .active ? "bolt.fill" : "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(item.state == .active ? AppTheme.statusReady : AppTheme.accent)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.sessionName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(item.updatedDate, style: .relative)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.inkSoft)
                    }
                    HStack(spacing: 5) {
                        Text(item.projectName.isEmpty ? item.sessionPath : item.projectName)
                        if let source = item.sourceProfileName, !source.isEmpty {
                            Text("·")
                            Text(source)
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.inkSoft)
                    .lineLimit(1)
                    if !item.preview.isEmpty {
                        Text(item.preview)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let matchedIn = item.matchedIn {
                        Text("Coincidencia · \(matchedIn)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                if openingItemId == item.id {
                    ProgressView()
                        .tint(AppTheme.accent)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: item.state == .active ? "arrow.right" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.inkSoft)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(openingItemId != nil)
        .accessibilityLabel("\(item.sessionName), \(item.projectName)")
        .accessibilityHint(item.state == .active ? "Abre la sesión" : "Reanuda la sesión")
        .accessibilityIdentifier("history-session-\(item.id)")
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let expectedRevision = queryRevision
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, expectedRevision == queryRevision else { return }
            await load(reset: true, refresh: false, expectedRevision: expectedRevision)
        }
    }

    private func applyCache() {
        if cachedCorpus.isEmpty, let cached = store.cachedSessionHistoryCorpus() {
            cachedCorpus = cached.items
            cachedCorpusAt = cached.cachedAt
        }
        guard !cachedCorpus.isEmpty else { return }
        let filtered = KycodeSessionHistorySearch.cachedResults(cachedCorpus, query: query)
        items = filtered
        total = filtered.count
        lastUpdatedAt = cachedCorpusAt
    }

    @MainActor
    private func load(
        reset: Bool,
        refresh: Bool,
        expectedRevision: String? = nil
    ) async {
        if Self.isUITestRetryFixtureEnabled {
            await loadUITestRetryFixture()
            return
        }
        if Self.isUITestFixtureEnabled {
            applyUITestFixture()
            return
        }
        if reset {
            if items.isEmpty { applyCache() }
            isLoading = true
        }
        errorText = nil
        var nextQuery = query
        nextQuery.refresh = refresh
        do {
            let result = try await store.fetchSessionHistory(matching: nextQuery)
            guard !Task.isCancelled,
                  expectedRevision == nil || expectedRevision == queryRevision else {
                return
            }
            items = result.items
            total = result.total
            hasMore = result.hasMore
            searchMs = result.searchMs
            lastUpdatedAt = Date()
            var merged = Dictionary(uniqueKeysWithValues: cachedCorpus.map { ($0.id, $0) })
            for item in result.items {
                merged[item.id] = item
            }
            cachedCorpus = merged.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(KycodeSessionHistoryCache.maximumItems)
                .map { $0 }
            cachedCorpusAt = lastUpdatedAt
            recentSearches = store.recentSessionHistorySearches()
        } catch {
            errorText = error.localizedDescription
            if items.isEmpty { applyCache() }
        }
        isLoading = false
    }

    @MainActor
    private func loadUITestRetryFixture() async {
        isLoading = true
        errorText = nil
        items = []
        total = 0
        hasMore = false
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        uiTestRetryAttempt += 1
        if uiTestRetryAttempt == 1 {
            errorText = "No se encontró la ruta del historial."
            isLoading = false
        } else {
            applyUITestFixture()
        }
    }

    private func applyUITestFixture() {
        let filtered = KycodeSessionHistorySearch.cachedResults(
            Self.uiTestFixtureItems,
            query: query
        )
        items = filtered
        total = filtered.count
        hasMore = false
        searchMs = 0.2
        lastUpdatedAt = Date()
        errorText = nil
        isLoading = false
    }

    @MainActor
    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        var nextQuery = query
        nextQuery.offset = items.count
        do {
            let result = try await store.fetchSessionHistory(matching: nextQuery)
            let existingIds = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existingIds.contains($0.id) })
            total = result.total
            hasMore = result.hasMore
            searchMs = result.searchMs
        } catch {
            errorText = error.localizedDescription
        }
        isLoadingMore = false
    }

    private func open(_ item: KycodeSessionHistoryItem) {
        guard openingItemId == nil else { return }
        openingItemId = item.id
        errorText = nil
        AppHaptics.shared.play(.conversationSelection)
        Task {
            do {
                if let windowId = try await store.resumeSessionHistoryItem(item) {
                    await MainActor.run {
                        openingItemId = nil
                        onOpenSession(windowId)
                        dismiss()
                    }
                } else {
                    await MainActor.run {
                        openingItemId = nil
                        errorText = "La sesión se está reabriendo en desktop. Deslizá para actualizar en unos segundos."
                    }
                }
            } catch {
                await MainActor.run {
                    openingItemId = nil
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

#if DEBUG
struct SessionHistoryRetryUITestHarness: View {
    @StateObject private var store = KycodeConnectionStore()

    var body: some View {
        KycodeSessionHistoryView { _ in }
            .environmentObject(store)
    }
}
#endif
