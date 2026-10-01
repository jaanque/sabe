import SwiftUI
import Foundation
import UIKit
import CoreImage
import Combine
import SafariServices

// MARK: - App Entry / Root View
struct ContentView: View {
    @State private var store = MovieStore()
    @State private var incomingSharedMovie: Movie? = nil
    @State private var showShareSuccessToast: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                HomeView(store: store)
                    .tabItem {
                        Label("Inicio", systemImage: "house")
                    }

                DiscoverView()
                    .tabItem {
                        Label("Descubrir", systemImage: "sparkles")
                    }
            }
            .tint(.black)

            // MARK: - Toast Banner de Película Reconocida (TikTok / Share Extension)
            if showShareSuccessToast, let movie = incomingSharedMovie {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: movie.posterURL)) { phase in
                        if let img = phase.image {
                            img
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(.quaternary)
                                .aspectRatio(2/3, contentMode: .fill)
                        }
                    }
                    .frame(width: 38, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                            Text("Detectada desde TikTok")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                        }

                        Text(movie.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("Añadida a tu librería • \(movie.displayDuration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .zIndex(999)
            }
        }
        .onOpenURL { url in
            handleIncomingSharedURL(url)
        }
    }

    private func handleIncomingSharedURL(_ url: URL) {
        var sharedString = url.absoluteString

        // Extraer parámetro de query si viene como sabe://share?url=... o sabe://add?link=...
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let queryItems = components.queryItems {
            if let targetItem = queryItems.first(where: { $0.name == "url" || $0.name == "link" || $0.name == "text" })?.value {
                sharedString = targetItem
            }
        }

        let movie = Movie.recognizeMovieFromSharedText(sharedString)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            store.addMovie(movie)
            incomingSharedMovie = movie
            showShareSuccessToast = true
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Ocultar automáticamente tras 4.5 segundos
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            withAnimation(.spring) {
                showShareSuccessToast = false
            }
        }
    }
}

// MARK: - Library Filters
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Todo"
    case unwatched = "Por ver"
    case watched = "Vistas"
    case favorites = "Favoritos"
    case unfavorited = "Sin favoritos"
    case collections = "Colecciones"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "eye.slash"
        case .watched: return "checkmark.circle"
        case .favorites: return "heart.fill"
        case .unfavorited: return "heart.slash"
        case .collections: return "folder"
        }
    }
}

// MARK: - Library Sort Options
enum SortOption: String, CaseIterable, Identifiable {
    case recent = "Añadidas recientemente"
    case titleAZ = "Título (A-Z)"
    case titleZA = "Título (Z-A)"
    case yearNewest = "Año (Más recientes)"
    case yearOldest = "Año (Más antiguas)"
    case rating = "Mejor valoradas"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .recent: return "clock"
        case .titleAZ: return "arrow.up.and.down.text.horizontal"
        case .titleZA: return "textformat"
        case .yearNewest: return "calendar.badge.clock"
        case .yearOldest: return "calendar"
        case .rating: return "star.fill"
        }
    }
}

// MARK: - Home View
struct HomeView: View {
    @Bindable var store: MovieStore = MovieStore()
    @State private var searchText = ""
    @State private var editingCollectionID: UUID?
    @FocusState private var isCollectionFocused: Bool
    @State private var showingSettingsSheet = false
    @State private var showingAddContentSheet = false
    @State private var initialAddTab: AddContentType = .link

    // Filtro y ordenación activos
    @State private var selectedFilter: LibraryFilter = .all
    @State private var selectedSort: SortOption = .recent

    // Estado para abrir la hoja de reacción de emojis
    @State private var movieForReaction: Movie?

    // Modo de selección en masa
    @State private var isSelectionMode = false
    @State private var selectedMovieIDs: Set<UUID> = []
    @State private var showingBulkDeleteDialog = false

    // Estados para pedir consentimiento al eliminar individuales
    @State private var collectionToDelete: MovieCollection?

    // IDs de todas las películas que ya están dentro de alguna colección
    private var allCollectionMovieIDs: Set<UUID> {
        Set(store.collections.flatMap { $0.movieIDs })
    }

    // Películas disponibles en la librería (excluye las que están en colecciones)
    private var availableMovies: [Movie] {
        store.movies.filter { !allCollectionMovieIDs.contains($0.id) }
    }

    var filteredCollections: [MovieCollection] {
        if selectedFilter != .all && selectedFilter != .collections {
            return []
        }
        if searchText.isEmpty {
            return store.collections
        } else {
            return store.collections.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var filteredMovies: [Movie] {
        if selectedFilter == .collections {
            return []
        }

        var baseList = availableMovies
        switch selectedFilter {
        case .all:
            baseList = availableMovies
        case .unwatched:
            baseList = store.movies.filter { !$0.isWatched }
        case .watched:
            baseList = store.movies.filter { $0.isWatched }
        case .favorites:
            baseList = store.movies.filter { $0.isFavorite }
        case .unfavorited:
            baseList = store.movies.filter { !$0.isFavorite }
        case .collections:
            baseList = []
        }

        if !searchText.isEmpty {
            baseList = baseList.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }

        switch selectedSort {
        case .recent:
            return baseList
        case .titleAZ:
            return baseList.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return baseList.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .yearNewest:
            return baseList.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearOldest:
            return baseList.sorted { ($0.year ?? 9999) < ($1.year ?? 9999) }
        case .rating:
            return baseList.sorted { $0.displayRating > $1.displayRating }
        }
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .all: return "Sin películas"
        case .unwatched: return "Sin pendientes"
        case .watched: return "Sin películas vistas"
        case .favorites: return "Sin favoritos"
        case .unfavorited: return "Sin películas"
        case .collections: return "Sin colecciones"
        }
    }

    private var emptyStateMessage: String {
        switch selectedFilter {
        case .all: return "Tu librería está vacía. Añade películas desde Descubrir o con el botón +."
        case .unwatched: return "Has visto todas las películas de tu librería."
        case .watched: return "Aún no has marcado ninguna película como vista."
        case .favorites: return "No tienes películas en favoritos."
        case .unfavorited: return "Todas tus películas están en favoritos."
        case .collections: return "Pulsa + para crear una nueva colección."
        }
    }

    private var emptyStateIcon: String {
        switch selectedFilter {
        case .all: return "film.stack"
        case .unwatched: return "eye.slash"
        case .watched: return "checkmark.circle"
        case .favorites: return "heart.slash"
        case .unfavorited: return "heart"
        case .collections: return "folder"
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 18)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                    if filteredMovies.isEmpty && filteredCollections.isEmpty {
                        if searchText.isEmpty {
                            ContentUnavailableView {
                                Label(emptyStateTitle, systemImage: emptyStateIcon)
                            } description: {
                                Text(emptyStateMessage)
                            }
                            .padding(.top, 60)
                        } else {
                            ContentUnavailableView.search(text: searchText)
                                .padding(.top, 60)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 26) {
                            // 1. Colecciones en la librería (portada visual en cuadrícula 2x2)
                            ForEach(filteredCollections) { collection in
                                NavigationLink {
                                    CollectionDetailView(collection: collection, store: store)
                                } label: {
                                    CollectionPosterView(
                                        collection: collection,
                                        allMovies: store.movies,
                                        isEditing: editingCollectionID == collection.id,
                                        isFocused: $isCollectionFocused,
                                        onStartEditing: {
                                            editingCollectionID = collection.id
                                            isCollectionFocused = true
                                        },
                                        onUpdateName: { newName in
                                            store.updateCollectionName(id: collection.id, name: newName)
                                            editingCollectionID = nil
                                            isCollectionFocused = false
                                        },
                                        onDelete: {
                                            collectionToDelete = collection
                                        },
                                        onDropMovie: { movieID in
                                            withAnimation(.spring) {
                                                store.addMovie(movieID, toCollection: collection.id)
                                            }
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .opacity(isSelectionMode ? 0.35 : 1.0)
                                .allowsHitTesting(!isSelectionMode)
                            }

                            // 2. Películas de la librería (las que no están en ninguna colección)
                            ForEach(filteredMovies) { movie in
                                if isSelectionMode {
                                    MoviePosterView(
                                        movie: movie,
                                        isSelectionMode: true,
                                        isSelected: selectedMovieIDs.contains(movie.id)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if selectedMovieIDs.contains(movie.id) {
                                            selectedMovieIDs.remove(movie.id)
                                        } else {
                                            selectedMovieIDs.insert(movie.id)
                                        }
                                    }
                                } else {
                                    NavigationLink {
                                        MovieDetailView(movie: movie, store: store)
                                    } label: {
                                        MoviePosterView(movie: movie)
                                    }
                                    .buttonStyle(.plain)
                                    .draggable(movie.id.uuidString)
                                    .contextMenu {
                                        Button {
                                            withAnimation(.spring) {
                                                store.toggleFavorite(for: movie.id)
                                            }
                                        } label: {
                                            Label(movie.isFavorite ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: movie.isFavorite ? "heart.slash" : "heart")
                                        }

                                        Button {
                                            let willBeWatched = !movie.isWatched
                                            withAnimation(.spring) {
                                                store.toggleWatched(for: movie.id)
                                            }
                                            if willBeWatched {
                                                movieForReaction = movie
                                            }
                                        } label: {
                                            Label(movie.isWatched ? "Marcar como pendiente" : "Marcar como vista", systemImage: movie.isWatched ? "eye.slash" : "eye")
                                        }

                                        Divider()

                                        ShareLink(
                                            item: "Te recomiendo ver: \(movie.title)",
                                            subject: Text(movie.title),
                                            message: Text("Te recomiendo ver esta película: \(movie.title)")
                                        ) {
                                            Label("Compartir", systemImage: "square.and.arrow.up")
                                        }

                                        if !store.collections.isEmpty {
                                            Menu {
                                                ForEach(store.collections) { col in
                                                    Button {
                                                        withAnimation(.spring) {
                                                            store.addMovie(movie.id, toCollection: col.id)
                                                        }
                                                    } label: {
                                                        Label(col.name, systemImage: "folder")
                                                    }
                                                }
                                            } label: {
                                                Label("Añadir a colección", systemImage: "folder.badge.plus")
                                            }
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            withAnimation(.spring) {
                                                selectedMovieIDs = [movie.id]
                                                isSelectionMode = true
                                            }
                                        } label: {
                                            Label("Eliminar de la librería", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            .refreshable {
                store.loadMovies()
                store.loadCollections()
            }
            .searchable(text: $searchText, prompt: "Buscar películas")
            .confirmationDialog(
                "¿Eliminar colección?",
                isPresented: Binding(
                    get: { collectionToDelete != nil },
                    set: { if !$0 { collectionToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: collectionToDelete
            ) { col in
                Button("Eliminar colección", role: .destructive) {
                    withAnimation(.spring) {
                        store.deleteCollection(id: col.id)
                    }
                }
                Button("Cancelar", role: .cancel) { }
            } message: { col in
                Text("Las películas de \"\(col.name)\" volverán a estar disponibles en tu librería.")
            }
            .confirmationDialog(
                selectedMovieIDs.count == 1 ? "¿Eliminar película?" : "¿Eliminar \(selectedMovieIDs.count) películas?",
                isPresented: $showingBulkDeleteDialog,
                titleVisibility: .visible
            ) {
                Button(
                    selectedMovieIDs.count == 1 ? "Eliminar de la librería" : "Eliminar de la librería (\(selectedMovieIDs.count))",
                    role: .destructive
                ) {
                    withAnimation(.spring) {
                        store.deleteMovies(ids: selectedMovieIDs)
                        selectedMovieIDs.removeAll()
                        isSelectionMode = false
                    }
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text(selectedMovieIDs.count == 1 ? "Esta acción eliminará la película de tu librería." : "Esta acción eliminará de forma definitiva las películas seleccionadas de tu librería.")
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    HStack {
                        Text(selectedMovieIDs.isEmpty ? "Selecciona películas" : "\(selectedMovieIDs.count) seleccionada\(selectedMovieIDs.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(role: .destructive) {
                            showingBulkDeleteDialog = true
                        } label: {
                            Label(selectedMovieIDs.count <= 1 ? "Eliminar" : "Eliminar (\(selectedMovieIDs.count))", systemImage: "trash")
                                .fontWeight(.semibold)
                        }
                        .disabled(selectedMovieIDs.isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelectionMode)
            .toolbar {
                if isSelectionMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selectedMovieIDs.count == filteredMovies.count ? "Deseleccionar todo" : "Seleccionar todo") {
                            if selectedMovieIDs.count == filteredMovies.count {
                                selectedMovieIDs.removeAll()
                            } else {
                                selectedMovieIDs = Set(filteredMovies.map { $0.id })
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Listo") {
                            withAnimation {
                                isSelectionMode = false
                                selectedMovieIDs.removeAll()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            Menu {
                                Section("Ordenar por") {
                                    ForEach(SortOption.allCases) { sort in
                                        Button {
                                            withAnimation {
                                                selectedSort = sort
                                            }
                                        } label: {
                                            HStack {
                                                Label(sort.rawValue, systemImage: sort.systemImage)
                                                if selectedSort == sort {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                Section("Filtrar por") {
                                    ForEach(LibraryFilter.allCases) { filter in
                                        Button {
                                            withAnimation {
                                                selectedFilter = filter
                                            }
                                        } label: {
                                            HStack {
                                                Label(filter.rawValue, systemImage: filter.systemImage)
                                                if selectedFilter == filter {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                if selectedFilter != .all || selectedSort != .recent {
                                    Divider()
                                    Button(role: .destructive) {
                                        withAnimation {
                                            selectedFilter = .all
                                            selectedSort = .recent
                                        }
                                    } label: {
                                        Label("Restablecer orden y filtros", systemImage: "arrow.counterclockwise")
                                    }
                                }
                            } label: {
                                Image(systemName: (selectedFilter == .all && selectedSort == .recent) ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            }

                            Menu {
                                Button {
                                    initialAddTab = .link
                                    showingAddContentSheet = true
                                } label: {
                                    Label("Pegar enlace (Redes sociales)", systemImage: "link")
                                }

                                Button {
                                    initialAddTab = .manual
                                    showingAddContentSheet = true
                                } label: {
                                    Label("Añadir manualmente", systemImage: "square.and.pencil")
                                }

                                Divider()

                                Button {
                                    withAnimation(.spring) {
                                        let newCollection = store.createCollection()
                                        editingCollectionID = newCollection.id
                                        isCollectionFocused = true
                                    }
                                } label: {
                                    Label("Añadir colección", systemImage: "folder.badge.plus")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }

                            Button(action: {
                                showingSettingsSheet = true
                            }) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView(store: store)
            }
            .sheet(isPresented: $showingAddContentSheet) {
                AddContentView(store: store, selectedTab: initialAddTab)
            }
            .sheet(item: $movieForReaction) { movie in
                MovieReactionSheet(movie: movie, store: store)
            }
        }
    }
}

// MARK: - Add Content Type
enum AddContentType: String, CaseIterable, Identifiable {
    case link = "Pegar enlace"
    case manual = "Añadir manualmente"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .link: return "link"
        case .manual: return "square.and.pencil"
        }
    }
}

// MARK: - Add Content View (Pegar enlace o añadir manualmente)
struct AddContentView: View {
    @Environment(\.dismiss) private var dismiss
    let store: MovieStore
    @State var selectedTab: AddContentType = .link

    // Tab 1: Pegar enlace
    @State private var linkURLText: String = ""
    @State private var isAnalyzingLink: Bool = false
    @State private var detectedMovie: Movie? = nil
    @State private var linkAnalysisError: String? = nil

    // Tab 2: Manual
    @State private var manualTitle: String = ""
    @State private var manualYearText: String = ""
    @State private var manualGenre: String = "Acción"
    @State private var manualDirector: String = ""
    @State private var manualDuration: String = ""
    @State private var manualRating: Double = 8.0
    @State private var manualOverview: String = ""
    @State private var manualCastText: String = ""
    @State private var manualPosterURL: String = ""
    @State private var manualTrailerURL: String = ""
    @State private var manualIsWatched: Bool = false
    @State private var manualIsFavorite: Bool = false

    private let availableGenres = [
        "Acción", "Aventura", "Ciencia Ficción", "Comedia", "Drama",
        "Terror", "Thriller", "Romance", "Animación", "Fantasía",
        "Crimen", "Misterio", "Documental"
    ]

    private let presetPosters = [
        "https://image.tmdb.org/t/p/w780/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
        "https://image.tmdb.org/t/p/w780/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
        "https://image.tmdb.org/t/p/w780/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg",
        "https://image.tmdb.org/t/p/w780/gKkl37BQuKTanygYQG1pyYgLVgf.jpg",
        "https://image.tmdb.org/t/p/w780/34m2tygAYBGqA9MXKhRDtzYd4MR.jpg",
        "https://image.tmdb.org/t/p/w780/t6HIqrRAclMCA60NsSmeqe9RmNV.jpg"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tipo de añadido", selection: $selectedTab) {
                    ForEach(AddContentType.allCases) { type in
                        Label(type.rawValue, systemImage: type.systemImage).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()

                if selectedTab == .link {
                    linkFormView
                } else {
                    manualFormView
                }
            }
            .navigationTitle("Añadir contenido")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Subviews & Logic for Link Tab
    private var linkFormView: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Info Banner
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles.tv")
                        .font(.title2)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detección de redes sociales y web")
                            .font(.subheadline.weight(.semibold))
                        Text("Pega un enlace de TikTok, Instagram, YouTube, X (Twitter), Letterboxd o IMDb para identificar la película automáticamente.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Input Box
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enlace de red social o web")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)

                        TextField("https://...", text: $linkURLText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline)

                        if !linkURLText.isEmpty {
                            Button {
                                linkURLText = ""
                                detectedMovie = nil
                                linkAnalysisError = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            if let paste = UIPasteboard.general.string, !paste.isEmpty {
                                linkURLText = paste
                                analyzeLink(paste)
                            }
                        } label: {
                            Text("Pegar")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Analyze button
                Button {
                    analyzeLink(linkURLText)
                } label: {
                    HStack {
                        if isAnalyzingLink {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isAnalyzingLink ? "Identificando película..." : "Identificar película")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(linkURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Color.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                }
                .disabled(linkURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzingLink)

                if let error = linkAnalysisError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Detected Movie Preview Card
                if let movie = detectedMovie {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Película detectada")
                            .font(.headline)

                        HStack(alignment: .top, spacing: 14) {
                            AsyncImage(url: URL(string: movie.posterURL)) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(2/3, contentMode: .fill)
                                } else {
                                    Rectangle().fill(.quaternary).aspectRatio(2/3, contentMode: .fill)
                                        .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                                }
                            }
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(movie.title)
                                    .font(.headline)
                                    .lineLimit(2)

                                HStack(spacing: 4) {
                                    if let year = movie.year {
                                        Text("\(year)")
                                        Text("•")
                                    }
                                    Text(movie.genre ?? "Cine")
                                    Text("•")
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Text(String(format: "%.1f", movie.displayRating))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Text(movie.displayOverview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            store.addMovie(movie)
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Añadir a mi librería")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Subviews & Logic for Manual Tab
    private var manualFormView: some View {
        Form {
            Section(header: Text("Información Principal")) {
                TextField("Título de la película *", text: $manualTitle)

                TextField("Año de estreno (ej: 2024)", text: $manualYearText)
                    .keyboardType(.numberPad)

                Picker("Género", selection: $manualGenre) {
                    ForEach(availableGenres, id: \.self) { genre in
                        Text(genre).tag(genre)
                    }
                }
            }

            Section(header: Text("Detalles y Equipo")) {
                TextField("Director", text: $manualDirector)
                TextField("Duración (ej: 2h 15m)", text: $manualDuration)

                HStack {
                    Text("Puntuación")
                    Spacer()
                    Text(String(format: "%.1f ★", manualRating))
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
                Slider(value: $manualRating, in: 1.0...10.0, step: 0.1)
                    .tint(.orange)

                TextField("Reparto (separado por comas)", text: $manualCastText)
            }

            Section(header: Text("Sinopsis")) {
                TextEditor(text: $manualOverview)
                    .frame(minHeight: 80)
            }

            Section(header: Text("Carátula y Multimedia")) {
                TextField("URL del póster (opcional)", text: $manualPosterURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presetPosters, id: \.self) { poster in
                            Button {
                                manualPosterURL = poster
                            } label: {
                                AsyncImage(url: URL(string: poster)) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(2/3, contentMode: .fill)
                                    } else {
                                        Rectangle().fill(.quaternary)
                                    }
                                }
                                .frame(width: 50, height: 75)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(manualPosterURL == poster ? Color.blue : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                TextField("URL del tráiler oficial (opcional)", text: $manualTrailerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(header: Text("Estado inicial")) {
                Toggle("Marcar como vista", isOn: $manualIsWatched)
                Toggle("Añadir a favoritos", isOn: $manualIsFavorite)
            }

            Section {
                Button {
                    saveManualMovie()
                } label: {
                    HStack {
                        Spacer()
                        Text("Guardar película")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func analyzeLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isAnalyzingLink = true
        linkAnalysisError = nil
        detectedMovie = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isAnalyzingLink = false
            let lower = trimmed.lowercased()

            if lower.contains("dune") {
                detectedMovie = Movie(
                    title: "Dune: Parte Dos",
                    posterURL: "https://image.tmdb.org/t/p/w780/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
                    genre: "Sci-Fi",
                    year: 2024,
                    overview: "Paul Atreides se une a Chani y a los Fremen mientras busca venganza contra los conspiradores que destruyeron a su familia.",
                    director: "Denis Villeneuve",
                    duration: "2h 46m",
                    rating: 8.6,
                    cast: ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson"],
                    trailerURL: "https://www.youtube.com/results?search_query=dune+parte+dos+trailer"
                )
            } else if lower.contains("oppenheimer") {
                detectedMovie = Movie(
                    title: "Oppenheimer",
                    posterURL: "https://image.tmdb.org/t/p/w780/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
                    genre: "Drama",
                    year: 2023,
                    overview: "La historia del científico estadounidense J. Robert Oppenheimer y su papel en el desarrollo de la bomba atómica.",
                    director: "Christopher Nolan",
                    duration: "3h 00m",
                    rating: 8.9,
                    cast: ["Cillian Murphy", "Emily Blunt", "Matt Damon"],
                    trailerURL: "https://www.youtube.com/results?search_query=oppenheimer+trailer"
                )
            } else if lower.contains("gladiator") {
                detectedMovie = Movie(
                    title: "Gladiator II",
                    posterURL: "https://image.tmdb.org/t/p/w780/2cxhvwyEwRlysAmRH4iodkvo0z5.jpg",
                    genre: "Acción",
                    year: 2024,
                    overview: "Años después de presenciar la muerte del admirado héroe Máximo a manos de su tío, Lucio debe entrar en el Coliseo.",
                    director: "Ridley Scott",
                    duration: "2h 28m",
                    rating: 7.8,
                    cast: ["Paul Mescal", "Pedro Pascal", "Denzel Washington"]
                )
            } else if lower.contains("interstellar") {
                detectedMovie = Movie(
                    title: "Interstellar",
                    posterURL: "https://image.tmdb.org/t/p/w780/gKkl37BQuKTanygYQG1pyYgLVgf.jpg",
                    genre: "Sci-Fi",
                    year: 2014,
                    overview: "Un grupo de científicos y exploradores emprenden un viaje a través de un agujero de gusano para salvar a la humanidad.",
                    director: "Christopher Nolan",
                    duration: "2h 49m",
                    rating: 8.7,
                    cast: ["Matthew McConaughey", "Anne Hathaway", "Jessica Chastain"]
                )
            } else {
                var extractedTitle = "Nueva película descubierta"
                if let url = URL(string: trimmed), let lastPathComponent = url.pathComponents.last, !lastPathComponent.isEmpty {
                    let cleaned = lastPathComponent
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                    if cleaned.count > 2 && !cleaned.contains(".Php") && !cleaned.contains(".Html") {
                        extractedTitle = cleaned
                    }
                }

                detectedMovie = Movie(
                    title: extractedTitle,
                    posterURL: presetPosters.randomElement() ?? "https://image.tmdb.org/t/p/w780/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
                    genre: "Cine",
                    year: Calendar.current.component(.year, from: Date()),
                    overview: "Película añadida e identificada mediante enlace de redes sociales (\(trimmed)).",
                    director: "Director cinematográfico",
                    duration: "2h 00m",
                    rating: 8.0,
                    cast: ["Reparto principal"],
                    trailerURL: trimmed
                )
            }
        }
    }

    private func saveManualMovie() {
        let title = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let year = Int(manualYearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let poster = manualPosterURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (presetPosters.randomElement() ?? "https://image.tmdb.org/t/p/w780/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg")
            : manualPosterURL

        let castList = manualCastText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let newMovie = Movie(
            title: title,
            posterURL: poster,
            genre: manualGenre,
            year: year,
            overview: manualOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualOverview,
            director: manualDirector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualDirector,
            duration: manualDuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualDuration,
            rating: manualRating,
            cast: castList.isEmpty ? nil : castList,
            isFavorite: manualIsFavorite,
            isWatched: manualIsWatched,
            trailerURL: manualTrailerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : manualTrailerURL
        )

        store.addMovie(newMovie)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        dismiss()
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: MovieStore

    @State private var showingImportSheet = false
    @State private var showingDeleteAllAlert = false
    @State private var confirmationText = ""
    @State private var importText = ""
    @State private var importErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // 1. Copia de seguridad y Datos
                Section(header: Text("Copia de seguridad y Datos")) {
                    if let backupJSON = store.exportBackupJSON() {
                        ShareLink(
                            item: backupJSON,
                            subject: Text("Copia de seguridad Sabe"),
                            message: Text("Copia de seguridad de mis películas y colecciones de Sabe.")
                        ) {
                            Label("Exportar copia de seguridad (JSON)", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            UIPasteboard.general.string = backupJSON
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            Label("Copiar JSON al portapapeles", systemImage: "doc.on.doc")
                        }
                    }

                    Button {
                        importText = ""
                        importErrorMessage = nil
                        showingImportSheet = true
                    } label: {
                        Label("Restaurar copia de seguridad", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        confirmationText = ""
                        showingDeleteAllAlert = true
                    } label: {
                        Label("Eliminar todo", systemImage: "trash")
                    }
                }

                // 2. Ayuda y FAQs
                Section(header: Text("Ayuda y Preguntas frecuentes")) {
                    NavigationLink {
                        FAQView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Guía de uso y FAQs")
                                    .font(.body)
                                Text("Cómo añadir contenido, crear colecciones, gestionar películas y más")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }

                // 3. Información
                Section(header: Text("Información")) {
                    HStack {
                        Text("Versión")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Aplicación")
                        Spacer()
                        Text("Sabe")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Pega el texto JSON de tu copia de seguridad para restaurar todas tus películas y colecciones.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $importText)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color(.separator), lineWidth: 1)
                            )
                            .frame(minHeight: 180)

                        if let error = importErrorMessage {
                            Text(error)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }

                        Button {
                            if let paste = UIPasteboard.general.string, !paste.isEmpty {
                                importText = paste
                            }
                        } label: {
                            Label("Pegar del portapapeles", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.medium))
                        }

                        Spacer()
                    }
                    .padding(20)
                    .navigationTitle("Restaurar datos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancelar") { showingImportSheet = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Restaurar") {
                                if store.importBackupJSON(importText) {
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                    showingImportSheet = false
                                } else {
                                    importErrorMessage = "El formato JSON no es válido. Comprueba el texto e inténtalo de nuevo."
                                }
                            }
                            .fontWeight(.semibold)
                            .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("¿Eliminar todo?", isPresented: $showingDeleteAllAlert) {
                TextField("Escribe \"confirmar\"", text: $confirmationText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Eliminar todo", role: .destructive) {
                    if confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "confirmar" {
                        withAnimation {
                            store.deleteAllData()
                            confirmationText = ""
                        }
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                }

                Button("Cancelar", role: .cancel) {
                    confirmationText = ""
                }
            } message: {
                Text("Esta acción eliminará de forma permanente e irrecuperable todas tus películas y colecciones. Para continuar, escribe \"confirmar\".")
            }
        }
    }
}

// MARK: - FAQ / Guía de uso View
struct FAQView: View {
    @State private var searchText = ""

    struct FAQItem: Identifiable {
        let id = UUID()
        let question: String
        let summary: String
        let steps: [String]
        let icon: String
        let category: String
    }

    private let faqs: [FAQItem] = [
        // Añadir contenido
        FAQItem(
            question: "¿Cómo añado películas a mi librería?",
            summary: "Añade nuevos títulos a tu catálogo de forma rápida.",
            steps: [
                "Toca el icono «+» en la esquina superior derecha de la pantalla principal.",
                "Selecciona «Añadir contenido».",
                "Completa los detalles de la película o impórtala a tu catálogo."
            ],
            icon: "plus.circle.fill",
            category: "Contenido"
        ),
        // Colecciones
        FAQItem(
            question: "¿Cómo creo una nueva colección?",
            summary: "Agrupa tus películas por temática, director, género o sagas.",
            steps: [
                "Toca el icono «+» en la barra superior.",
                "Selecciona «Añadir colección».",
                "Escribe el nombre que desees para la nueva colección y pulsa Retorno."
            ],
            icon: "folder.badge.plus",
            category: "Colecciones"
        ),
        FAQItem(
            question: "¿Cómo meto películas dentro de una colección?",
            summary: "Organiza tus películas en las colecciones que hayas creado.",
            steps: [
                "Método 1 (Menú): Mantén pulsada cualquier película en la librería y selecciona «Añadir a colección», luego elige la colección deseada.",
                "Método 2 (Arrastrar): Arrastra la carátula de una película y suéltala directamente encima de la colección."
            ],
            icon: "folder.badge.plus",
            category: "Colecciones"
        ),
        FAQItem(
            question: "¿Cómo saco películas de una colección?",
            summary: "Saca películas de una carpeta sin borrarlas de tu librería.",
            steps: [
                "Abre la colección donde está la película.",
                "Mantén pulsada la carátula y pulsa «Sacar de la colección».",
                "Si quieres sacar más películas a la vez, tócalas para marcarlas.",
                "Pulsa el botón «Sacar de la colección» en la barra flotante inferior.",
                "Las películas volverán a estar visibles en tu librería principal sin perderse."
            ],
            icon: "folder.badge.minus",
            category: "Colecciones"
        ),
        FAQItem(
            question: "¿Cómo renombro o elimino una colección?",
            summary: "Gestiona los nombres y carpetas de tus colecciones.",
            steps: [
                "Entra en la colección correspondiente.",
                "Toca el menú de opciones (icono de tres puntos «...») en la esquina superior derecha.",
                "Elige «Renombrar colección» o «Eliminar colección».",
                "Nota: Al eliminar una colección, sus películas NO se borran; quedan seguras en tu librería."
            ],
            icon: "ellipsis.circle",
            category: "Colecciones"
        ),
        // Eliminación y selección
        FAQItem(
            question: "¿Cómo elimino películas en masa?",
            summary: "Borra varias películas de tu librería de una sola vez.",
            steps: [
                "Mantén pulsada la carátula de cualquier película y selecciona «Eliminar de la librería» (o «Eliminar...»).",
                "Toca las demás películas que también quieras eliminar para seleccionarlas.",
                "Usa «Seleccionar todo» en la esquina superior izquierda si deseas marcar todo el catálogo.",
                "Pulsa «Eliminar (N)» en la barra flotante inferior y confirma la eliminación definitiva."
            ],
            icon: "trash.fill",
            category: "Gestión y Selección"
        ),
        // Filtros y Búsqueda
        FAQItem(
            question: "¿Cómo uso los filtros y la búsqueda?",
            summary: "Encuentra al instante cualquier título o colección.",
            steps: [
                "Filtros rápidos: Usa el selector superior («Todo», «Películas», «Colecciones») para ver solo lo que necesitas.",
                "Búsqueda en tiempo real: Escribe en la barra de búsqueda para filtrar títulos al instante tanto en la librería como dentro de una colección."
            ],
            icon: "line.3.horizontal.decrease.circle.fill",
            category: "Búsqueda y Filtros"
        ),
        // Compartir
        FAQItem(
            question: "¿Cómo comparto o recomiendo una película?",
            summary: "Envía recomendaciones de películas o colecciones a tus amigos.",
            steps: [
                "Película: Mantén pulsada su carátula y pulsa «Compartir».",
                "Colección: Entra en la colección, toca el menú de tres puntos «...» y selecciona «Compartir colección»."
            ],
            icon: "square.and.arrow.up.fill",
            category: "Compartir"
        )
    ]

    var filteredFAQs: [FAQItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return faqs
        }
        return faqs.filter { item in
            item.question.localizedCaseInsensitiveContains(searchText) ||
            item.summary.localizedCaseInsensitiveContains(searchText) ||
            item.steps.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) ||
            item.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var categories: [String] {
        Array(Set(filteredFAQs.map { $0.category })).sorted()
    }

    var body: some View {
        List {
            if filteredFAQs.isEmpty {
                ContentUnavailableView(
                    "Sin resultados",
                    systemImage: "magnifyingglass",
                    description: Text("No se encontraron temas de ayuda para \"\(searchText)\".")
                )
            } else {
                ForEach(categories, id: \.self) { category in
                    Section(header: Text(category)) {
                        ForEach(filteredFAQs.filter { $0.category == category }) { item in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(item.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)

                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("\(index + 1).")
                                                    .font(.footnote.weight(.semibold))
                                                    .foregroundStyle(.tint)
                                                    .frame(width: 18, alignment: .leading)

                                                Text(step)
                                                    .font(.footnote)
                                                    .foregroundStyle(.primary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .padding(.leading, 4)
                            } label: {
                                Label {
                                    Text(item.question)
                                        .font(.subheadline.weight(.medium))
                                } icon: {
                                    Image(systemName: item.icon)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Guía y FAQs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar dudas o guías...")
    }
}

// MARK: - Collection Detail View (Vista detallada de una colección)
struct CollectionDetailView: View {
    let collection: MovieCollection
    let store: MovieStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showingRenameAlert = false
    @State private var showingDeleteCollectionDialog = false
    @State private var newNameText = ""
    @State private var movieForReaction: Movie?

    enum SelectionAction {
        case removeFromCollection
        case delete
    }

    // Modo de selección en masa dentro de la colección
    @State private var selectionAction: SelectionAction? = nil
    @State private var selectedMovieIDs: Set<UUID> = []
    @State private var showingBulkRemoveDialog = false
    @State private var showingBulkDeleteDialog = false

    private var isSelectionMode: Bool {
        selectionAction != nil
    }

    var currentCollection: MovieCollection? {
        store.collections.first(where: { $0.id == collection.id })
    }

    var collectionMovies: [Movie] {
        guard let current = currentCollection else { return [] }
        let movies = current.movieIDs.compactMap { id in
            store.movies.first(where: { $0.id == id })
        }
        if searchText.isEmpty {
            return movies
        } else {
            return movies.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 18)
    ]

    var body: some View {
        ScrollView {
            if collectionMovies.isEmpty {
                ContentUnavailableView {
                    Label("Colección vacía", systemImage: "folder")
                } description: {
                    Text("Arrastra películas a esta colección o mantén pulsada una película en la librería para añadirla.")
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(collectionMovies) { movie in
                        if isSelectionMode {
                            MoviePosterView(
                                movie: movie,
                                isSelectionMode: true,
                                isSelected: selectedMovieIDs.contains(movie.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedMovieIDs.contains(movie.id) {
                                    selectedMovieIDs.remove(movie.id)
                                } else {
                                    selectedMovieIDs.insert(movie.id)
                                }
                            }
                        } else {
                            NavigationLink {
                                MovieDetailView(movie: movie, store: store)
                            } label: {
                                MoviePosterView(movie: movie)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    withAnimation(.spring) {
                                        store.toggleFavorite(for: movie.id)
                                    }
                                } label: {
                                    Label(movie.isFavorite ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: movie.isFavorite ? "heart.slash" : "heart")
                                }

                                Button {
                                    let willBeWatched = !movie.isWatched
                                    withAnimation(.spring) {
                                        store.toggleWatched(for: movie.id)
                                    }
                                    if willBeWatched {
                                        movieForReaction = movie
                                    }
                                } label: {
                                    Label(movie.isWatched ? "Marcar como pendiente" : "Marcar como vista", systemImage: movie.isWatched ? "eye.slash" : "eye")
                                }

                                Divider()

                                ShareLink(
                                    item: "Te recomiendo ver: \(movie.title)",
                                    subject: Text(movie.title),
                                    message: Text("Te recomiendo ver esta película: \(movie.title)")
                                ) {
                                    Label("Compartir", systemImage: "square.and.arrow.up")
                                }

                                Divider()

                                Button {
                                    withAnimation(.spring) {
                                        selectedMovieIDs = [movie.id]
                                        selectionAction = .removeFromCollection
                                    }
                                } label: {
                                    Label("Sacar de la colección", systemImage: "folder.badge.minus")
                                }

                                Button(role: .destructive) {
                                    withAnimation(.spring) {
                                        selectedMovieIDs = [movie.id]
                                        selectionAction = .delete
                                    }
                                } label: {
                                    Label("Eliminar...", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(currentCollection?.name ?? collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar en \(currentCollection?.name ?? collection.name)")
        .confirmationDialog(
            "¿Eliminar \"\(currentCollection?.name ?? collection.name)\"?",
            isPresented: $showingDeleteCollectionDialog,
            titleVisibility: .visible
        ) {
            Button("Eliminar colección", role: .destructive) {
                withAnimation(.spring) {
                    store.deleteCollection(id: collection.id)
                    dismiss()
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Las películas de esta colección volverán a mostrarse en tu librería principal.")
        }
        .confirmationDialog(
            selectedMovieIDs.count == 1 ? "¿Sacar película de la colección?" : "¿Sacar \(selectedMovieIDs.count) películas de la colección?",
            isPresented: $showingBulkRemoveDialog,
            titleVisibility: .visible
        ) {
            Button(
                selectedMovieIDs.count == 1 ? "Sacar de la colección" : "Sacar de la colección (\(selectedMovieIDs.count))"
            ) {
                withAnimation(.spring) {
                    store.removeMovies(ids: selectedMovieIDs, fromCollection: collection.id)
                    selectedMovieIDs.removeAll()
                    selectionAction = nil
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Estas películas volverán a estar disponibles en tu librería principal.")
        }
        .confirmationDialog(
            selectedMovieIDs.count == 1 ? "¿Eliminar película?" : "¿Eliminar \(selectedMovieIDs.count) películas?",
            isPresented: $showingBulkDeleteDialog,
            titleVisibility: .visible
        ) {
            Button(
                selectedMovieIDs.count == 1 ? "Eliminar de la librería" : "Eliminar de la librería (\(selectedMovieIDs.count))",
                role: .destructive
            ) {
                withAnimation(.spring) {
                    store.deleteMovies(ids: selectedMovieIDs)
                    selectedMovieIDs.removeAll()
                    selectionAction = nil
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Esta acción eliminará definitivamente estas películas de toda tu aplicación.")
        }
        .safeAreaInset(edge: .bottom) {
            if let action = selectionAction {
                HStack {
                    Text(selectedMovieIDs.isEmpty ? "Selecciona películas" : "\(selectedMovieIDs.count) seleccionada\(selectedMovieIDs.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if action == .removeFromCollection {
                        Button {
                            showingBulkRemoveDialog = true
                        } label: {
                            Label(selectedMovieIDs.count <= 1 ? "Sacar de la colección" : "Sacar (\(selectedMovieIDs.count))", systemImage: "folder.badge.minus")
                                .fontWeight(.semibold)
                        }
                        .disabled(selectedMovieIDs.isEmpty)
                    } else if action == .delete {
                        Button(role: .destructive) {
                            showingBulkDeleteDialog = true
                        } label: {
                            Label(selectedMovieIDs.count <= 1 ? "Eliminar" : "Eliminar (\(selectedMovieIDs.count))", systemImage: "trash")
                                .fontWeight(.semibold)
                        }
                        .disabled(selectedMovieIDs.isEmpty)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelectionMode)
        .toolbar {
            if isSelectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedMovieIDs.count == collectionMovies.count ? "Deseleccionar todo" : "Seleccionar todo") {
                        if selectedMovieIDs.count == collectionMovies.count {
                            selectedMovieIDs.removeAll()
                        } else {
                            selectedMovieIDs = Set(collectionMovies.map { $0.id })
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        withAnimation {
                            selectionAction = nil
                            selectedMovieIDs.removeAll()
                        }
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newNameText = currentCollection?.name ?? collection.name
                            showingRenameAlert = true
                        } label: {
                            Label("Renombrar colección", systemImage: "pencil")
                        }

                        ShareLink(
                            item: "Echa un vistazo a mi colección \"\(currentCollection?.name ?? collection.name)\" en Sabe.",
                            subject: Text(currentCollection?.name ?? collection.name)
                        ) {
                            Label("Compartir colección", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingDeleteCollectionDialog = true
                        } label: {
                            Label("Eliminar colección", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Renombrar colección", isPresented: $showingRenameAlert) {
            TextField("Nombre de la colección", text: $newNameText)
            Button("Cancelar", role: .cancel) { }
            Button("Guardar") {
                store.updateCollectionName(id: collection.id, name: newNameText)
            }
        }
        .sheet(item: $movieForReaction) { movie in
            MovieReactionSheet(movie: movie, store: store)
        }
    }
}

// MARK: - Collection Cover Component (Simple & Modern)
struct CollectionPosterView: View {
    let collection: MovieCollection
    let allMovies: [Movie]
    let isEditing: Bool
    var isFocused: FocusState<Bool>.Binding
    let onStartEditing: () -> Void
    let onUpdateName: (String) -> Void
    let onDelete: () -> Void
    let onDropMovie: (UUID) -> Void

    @State private var isTargeted = false
    @State private var nameDraft = ""

    // Portadas de películas de esta colección (hasta 4 para la cuadrícula)
    var coverPosterURLs: [String] {
        let matching = collection.movieIDs.compactMap { id in
            allMovies.first(where: { $0.id == id })?.posterURL
        }
        return Array(matching.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Contenedor de portada (2:3 idéntico al de las películas)
            Color.clear
                .aspectRatio(2/3, contentMode: .fill)
                .overlay {
                    if coverPosterURLs.isEmpty {
                        // Estado vacío: diseño simple, limpio y moderno
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .overlay {
                                Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(isTargeted ? .primary : .tertiary)
                            }
                    } else if coverPosterURLs.count == 1 {
                        // 1 película: carátula completa
                        AsyncPosterCard(url: coverPosterURLs[0])
                    } else {
                        // 2 a 4 películas: cuadrícula limpia tipo collage moderno
                        GeometryReader { geo in
                            let gap: CGFloat = 1.5
                            let w = (geo.size.width - gap) / 2
                            let h = (geo.size.height - gap) / 2

                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    tile(index: 0, width: w, height: h)
                                    tile(index: 1, width: w, height: h)
                                }
                                HStack(spacing: gap) {
                                    tile(index: 2, width: w, height: h)
                                    tile(index: 3, width: w, height: h)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isTargeted ? Color.primary : Color.clear, lineWidth: 2)
                )
                .scaleEffect(isTargeted ? 1.03 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
                .dropDestination(for: String.self) { items, _ in
                    guard let idString = items.first, let movieID = UUID(uuidString: idString) else { return false }
                    withAnimation(.spring) {
                        onDropMovie(movieID)
                    }
                    return true
                } isTargeted: { targeted in
                    isTargeted = targeted
                }

            // Título de la colección
            if isEditing {
                TextField("Nombre", text: $nameDraft)
                    .font(.subheadline.weight(.medium))
                    .focused(isFocused)
                    .onAppear {
                        nameDraft = collection.name
                    }
                    .onSubmit {
                        onUpdateName(nameDraft)
                    }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(collection.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button {
                nameDraft = collection.name
                onStartEditing()
            } label: {
                Label("Renombrar", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Eliminar colección", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func tile(index: Int, width: CGFloat, height: CGFloat) -> some View {
        if index < coverPosterURLs.count {
            AsyncImage(url: URL(string: coverPosterURLs[index])) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                case .failure, .empty:
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .frame(width: width, height: height)
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: width, height: height)
        }
    }
}

// MARK: - Mini Cover Tile for 2x2 Grid
struct MiniCoverTile: View {
    let url: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            case .failure, .empty:
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemBackground))
                    .frame(width: width, height: height)
            @unknown default:
                EmptyView()
            }
        }
    }
}

// MARK: - Poster Card Helper
struct AsyncPosterCard: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
            case .failure:
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(2/3, contentMode: .fill)
                    .overlay {
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            case .empty:
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(2/3, contentMode: .fill)
            @unknown default:
                EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Flow Layout for Multi-Line Tag Wrapping
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Streaming Platform Model
struct StreamingPlatform: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    let type: String
    let quality: String
    let appURL: String
}

// MARK: - Color & Image Utilities
extension UIImage {
    var dominantColor: UIColor? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(x: inputImage.extent.origin.x,
                                    y: inputImage.extent.origin.y,
                                    z: inputImage.extent.size.width,
                                    w: inputImage.extent.size.height)

        guard let filter = CIFilter(name: "CIAreaAverage",
                                   parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]),
              let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        return UIColor(red: CGFloat(bitmap[0]) / 255.0,
                       green: CGFloat(bitmap[1]) / 255.0,
                       blue: CGFloat(bitmap[2]) / 255.0,
                       alpha: CGFloat(bitmap[3]) / 255.0)
    }
}

extension UIColor {
    func adjustedForButton() -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            let tunedSaturation = max(saturation, 0.45)
            let tunedBrightness = max(min(brightness, 0.65), 0.35)
            return Color(hue: Double(hue), saturation: Double(tunedSaturation), brightness: Double(tunedBrightness), opacity: 1.0)
        }
        return Color(self)
    }
}

// MARK: - Movie Detail View (Vista detallada de la película)
struct MovieDetailView: View {
    let movie: Movie
    let store: MovieStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteDialog = false
    @State private var showingPlatformsSheet = false
    @State private var showingReactionSheet = false
    @State private var showingTrailer = false
    @State private var dominantColor: Color = Color.blue

    var currentMovie: Movie? {
        store.movies.first(where: { $0.id == movie.id })
    }

    var parentCollections: [MovieCollection] {
        store.collections.filter { $0.movieIDs.contains(movie.id) }
    }

    var similarMovies: [Movie] {
        guard let currentGenre = movie.genre, !currentGenre.isEmpty else { return [] }
        return store.movies.filter { other in
            other.id != movie.id && (
                other.genre?.localizedCaseInsensitiveContains(currentGenre) == true ||
                currentGenre.localizedCaseInsensitiveContains(other.genre ?? "")
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Póster Central con Aura Ambiental del color predominante
                VStack(spacing: 18) {
                    ZStack {
                        // 1. Aura con el color predominante del póster (Expandida y elevada)
                        AsyncImage(url: URL(string: movie.posterURL)) { phase in
                            if let image = phase.image {
                                ZStack {
                                    // Gran halo ambiental expandido
                                    image
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: 220, height: 330)
                                        .blur(radius: 58)
                                        .opacity(0.65)
                                        .scaleEffect(1.35)
                                        .offset(y: -4)

                                    // Resplandor difuminado medio
                                    image
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: 190, height: 285)
                                        .blur(radius: 35)
                                        .opacity(0.70)
                                        .scaleEffect(1.15)
                                        .offset(y: 0)
                                }
                            }
                        }

                        // 2. Póster frontal nítido
                        AsyncImage(url: URL(string: movie.posterURL)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(2/3, contentMode: .fill)
                            case .failure:
                                Rectangle()
                                    .fill(.quaternary)
                                    .aspectRatio(2/3, contentMode: .fill)
                                    .overlay {
                                        Image(systemName: "film")
                                            .font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                    }
                            case .empty:
                                Rectangle()
                                    .fill(.quaternary)
                                    .aspectRatio(2/3, contentMode: .fill)
                                    .overlay {
                                        ProgressView()
                                    }
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(width: 170, height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                    }
                    .padding(.top, 14)

                    // Título y Metadatos centrados
                    VStack(spacing: 8) {
                        Text(movie.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        HStack(spacing: 6) {
                            if let year = movie.year {
                                Text("\(year)")
                                Text("•")
                            }

                            Text(movie.displayDuration)

                            if let genre = movie.genre {
                                Text("•")
                                Text(genre)
                            }

                            Text("•")

                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(String(format: "%.1f", movie.displayRating))
                                    .fontWeight(.semibold)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Barra de Acciones Principales (Un botón por fila)
                VStack(spacing: 10) {
                    // 1. Botón Ver tráiler oficial
                    Button {
                        showingTrailer = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.subheadline.weight(.medium))
                            Text("Ver tráiler oficial")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // 2. Botón Ver en plataforma
                    Button {
                        showingPlatformsSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.tv")
                                .font(.subheadline.weight(.medium))
                            Text("Ver en plataforma")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // 3. Botón Colección
                    Menu {
                        if store.collections.isEmpty {
                            Text("No hay colecciones creadas")
                        } else {
                            ForEach(store.collections) { col in
                                let isInCollection = col.movieIDs.contains(movie.id)
                                Button {
                                    withAnimation(.spring) {
                                        if isInCollection {
                                            store.removeMovie(movie.id, fromCollection: col.id)
                                        } else {
                                            store.addMovie(movie.id, toCollection: col.id)
                                        }
                                    }
                                } label: {
                                    Label(
                                        col.name,
                                        systemImage: isInCollection ? "checkmark.circle.fill" : "folder"
                                    )
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: parentCollections.isEmpty ? "folder.badge.plus" : "folder.fill")
                                .font(.subheadline.weight(.medium))
                            Text(parentCollections.isEmpty ? "Añadir a una colección" : parentCollections.map { $0.name }.joined(separator: ", "))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // 4. Botón Marcar como Vista / Pendiente
                    let isWatched = currentMovie?.isWatched ?? movie.isWatched
                    Button {
                        let wasWatched = isWatched
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.toggleWatched(for: movie.id)
                        }
                        if !wasWatched {
                            showingReactionSheet = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isWatched ? "checkmark.circle.fill" : "eye")
                                .font(.subheadline.weight(.semibold))
                            Text(isWatched ? "Marcada como vista" : "Marcar como vista")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isWatched ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            isWatched ? dominantColor : Color(uiColor: .secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }

                    // 5. Si está marcada como vista, mostrar botón de valoración con emojis
                    if isWatched {
                        Button {
                            showingReactionSheet = true
                        } label: {
                            HStack(spacing: 8) {
                                if let reaction = currentMovie?.userReaction {
                                    Text(reaction)
                                        .font(.title3)
                                    Text("Tu valoración: \(reaction)")
                                        .font(.subheadline.weight(.medium))
                                } else {
                                    Text("🤔")
                                        .font(.title3)
                                    Text("¿Qué te pareció?")
                                        .font(.subheadline.weight(.medium))
                                }
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color(uiColor: .secondarySystemFill).opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)

                // MARK: - Bloque de Sinopsis
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sinopsis")
                        .font(.headline)

                    Text(movie.displayOverview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20)

                // MARK: - Equipo y Reparto con Hileras Automáticas
                VStack(alignment: .leading, spacing: 14) {
                    Text("Equipo y Reparto")
                        .font(.headline)

                    VStack(spacing: 12) {
                        HStack {
                            Text("Director")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(movie.displayDirector)
                                .fontWeight(.medium)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Reparto")
                                .foregroundStyle(.secondary)

                            FlowLayout(spacing: 8) {
                                ForEach(movie.displayCast, id: \.self) { actor in
                                    Text(actor)
                                        .font(.footnote.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20)

                // MARK: - Películas similares recomendadas
                if !similarMovies.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Películas similares")
                            .font(.headline)
                            .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(similarMovies) { simMovie in
                                    NavigationLink {
                                        MovieDetailView(movie: simMovie, store: store)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AsyncImage(url: URL(string: simMovie.posterURL)) { phase in
                                                switch phase {
                                                case .success(let img):
                                                    img
                                                        .resizable()
                                                        .aspectRatio(2/3, contentMode: .fill)
                                                case .failure:
                                                    Rectangle()
                                                        .fill(.quaternary)
                                                        .aspectRatio(2/3, contentMode: .fill)
                                                        .overlay {
                                                            Image(systemName: "film")
                                                                .foregroundStyle(.secondary)
                                                        }
                                                default:
                                                    Rectangle()
                                                        .fill(.quaternary)
                                                        .aspectRatio(2/3, contentMode: .fill)
                                                        .overlay {
                                                            ProgressView()
                                                        }
                                                }
                                            }
                                            .frame(width: 105, height: 155)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                                            Text(simMovie.title)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .frame(width: 105, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .padding(.bottom, 36)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring) {
                            store.toggleFavorite(for: movie.id)
                        }
                    } label: {
                        Image(systemName: (currentMovie?.isFavorite ?? movie.isFavorite) ? "heart.fill" : "heart")
                            .font(.body)
                            .foregroundStyle((currentMovie?.isFavorite ?? movie.isFavorite) ? .pink : .primary)
                    }

                    Menu {
                        Button {
                            withAnimation(.spring) {
                                store.toggleFavorite(for: movie.id)
                            }
                        } label: {
                            Label((currentMovie?.isFavorite ?? movie.isFavorite) ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: (currentMovie?.isFavorite ?? movie.isFavorite) ? "heart.slash" : "heart")
                        }

                        Button {
                            withAnimation(.spring) {
                                store.toggleWatched(for: movie.id)
                            }
                        } label: {
                            Label((currentMovie?.isWatched ?? movie.isWatched) ? "Marcar como pendiente" : "Marcar como vista", systemImage: (currentMovie?.isWatched ?? movie.isWatched) ? "eye.slash" : "eye")
                        }

                        Divider()

                        ShareLink(
                            item: "Te recomiendo ver \"\(movie.title)\"",
                            subject: Text(movie.title),
                            message: Text("Te recomiendo ver esta película: \(movie.title)")
                        ) {
                            Label("Compartir película", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingDeleteDialog = true
                        } label: {
                            Label("Eliminar de la librería", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .task(id: movie.posterURL) {
            if let url = URL(string: movie.posterURL) {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let uiImage = UIImage(data: data),
                   let uiColor = uiImage.dominantColor {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        dominantColor = uiColor.adjustedForButton()
                    }
                }
            }
        }
        .sheet(isPresented: $showingPlatformsSheet) {
            StreamingPlatformsSheet(movie: movie)
        }
        .sheet(isPresented: $showingReactionSheet) {
            MovieReactionSheet(movie: movie, store: store)
        }
        .sheet(isPresented: $showingTrailer) {
            if let trailerURL = URL(string: movie.displayTrailerURL) {
                SafariView(url: trailerURL)
                    .ignoresSafeArea()
            }
        }
        .confirmationDialog(
            "¿Eliminar \"\(movie.title)\"?",
            isPresented: $showingDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("Eliminar de la librería", role: .destructive) {
                withAnimation(.spring) {
                    store.deleteMovie(id: movie.id)
                    dismiss()
                }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Esta acción eliminará de forma definitiva esta película de tu librería y de cualquier colección.")
        }
    }
}

// MARK: - Safari View Representable
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let safariVC = SFSafariViewController(url: url, configuration: configuration)
        safariVC.preferredControlTintColor = .systemBlue
        return safariVC
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Movie Reaction Sheet
struct MovieReactionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    let store: MovieStore

    private struct EmojiReaction: Identifiable {
        let id: String
        let emoji: String
        let label: String
    }

    private let reactions: [EmojiReaction] = [
        EmojiReaction(id: "masterpiece", emoji: "🤩", label: "Obra maestra"),
        EmojiReaction(id: "loved", emoji: "😍", label: "Me encantó"),
        EmojiReaction(id: "good", emoji: "😊", label: "Muy buena"),
        EmojiReaction(id: "entertaining", emoji: "🙂", label: "Entretenida"),
        EmojiReaction(id: "mindblown", emoji: "🤯", label: "Increíble"),
        EmojiReaction(id: "emotional", emoji: "😢", label: "Emotiva"),
        EmojiReaction(id: "scary", emoji: "😱", label: "Tensa / Miedo"),
        EmojiReaction(id: "meh", emoji: "🥱", label: "Aburrida"),
        EmojiReaction(id: "bad", emoji: "🤮", label: "Mala"),
        EmojiReaction(id: "terrible", emoji: "💩", label: "Pésima")
    ]

    @State private var selectedReaction: String?
    @State private var hasAppeared = false

    var currentMovie: Movie? {
        store.movies.first(where: { $0.id == movie.id })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // Título y Película
                VStack(spacing: 3) {
                    Text("¿Qué te ha parecido?")
                        .font(.headline.weight(.bold))
                    Text(movie.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 10)

                // Carrusel horizontal de emojis con animación dinámica de scroll
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(reactions.enumerated()), id: \.element.id) { index, item in
                            let isSelected = (selectedReaction ?? currentMovie?.userReaction) == item.emoji
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    if isSelected {
                                        selectedReaction = nil
                                        store.setReaction(for: movie.id, reaction: nil)
                                    } else {
                                        selectedReaction = item.emoji
                                        store.setReaction(for: movie.id, reaction: item.emoji)
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    dismiss()
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Text(item.emoji)
                                        .font(.system(size: 38))
                                        .scaleEffect(isSelected ? 1.2 : 1.0)
                                        .animation(.spring(response: 0.25), value: isSelected)

                                    Text(item.label)
                                        .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                        ? Color.primary.opacity(0.12)
                                        : Color(uiColor: .secondarySystemFill).opacity(0.4)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.82)
                                    .opacity(phase.isIdentity ? 1.0 : 0.55)
                                    .rotation3DEffect(
                                        .degrees(phase.value * -14),
                                        axis: (x: 0, y: 1, z: 0)
                                    )
                                    .offset(y: phase.isIdentity ? 0 : 5)
                            }
                            .scaleEffect(hasAppeared ? 1.0 : 0.6)
                            .opacity(hasAppeared ? 1.0 : 0.0)
                            .animation(
                                .spring(response: 0.4, dampingFraction: 0.75).delay(Double(index) * 0.03),
                                value: hasAppeared
                            )
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .scrollTargetBehavior(.viewAligned)

                Spacer(minLength: 0)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(235)])
        .presentationDragIndicator(.visible)
        .onAppear {
            selectedReaction = currentMovie?.userReaction
            withAnimation {
                hasAppeared = true
            }
        }
    }
}

// MARK: - Streaming Platforms Sheet
struct StreamingPlatformsSheet: View {
    let movie: Movie
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var platforms: [StreamingPlatform] {
        [
            StreamingPlatform(
                name: "Apple TV+",
                icon: "appletv.fill",
                color: .black,
                type: "Suscripción",
                quality: "4K HDR",
                appURL: "https://tv.apple.com/search?term=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            StreamingPlatform(
                name: "Prime Video",
                icon: "play.tv.fill",
                color: Color.blue.opacity(0.8),
                type: "Suscripción",
                quality: "4K UHD",
                appURL: "https://www.primevideo.com/search?phrase=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            StreamingPlatform(
                name: "Netflix",
                icon: "film.stack.fill",
                color: .red,
                type: "Suscripción",
                quality: "HD",
                appURL: "https://www.netflix.com/search?q=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            StreamingPlatform(
                name: "Max",
                icon: "sparkles.tv.fill",
                color: Color.indigo,
                type: "Suscripción",
                quality: "4K Dolby Vision",
                appURL: "https://www.max.com/search?q=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            StreamingPlatform(
                name: "Disney+",
                icon: "wand.and.stars",
                color: Color.cyan,
                type: "Suscripción",
                quality: "4K IMAX Enhanced",
                appURL: "https://www.disneyplus.com/search?q=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ),
            StreamingPlatform(
                name: "Filmin",
                icon: "film.fill",
                color: Color.teal,
                type: "Alquiler / Suscripción",
                quality: "HD",
                appURL: "https://www.filmin.es/buscar?q=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            )
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Disponible en streaming")) {
                    ForEach(platforms) { platform in
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(platform.color.gradient)
                                    .frame(width: 42, height: 42)

                                Image(systemName: platform.icon)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(platform.name)
                                    .font(.subheadline.weight(.semibold))

                                HStack(spacing: 6) {
                                    Text(platform.type)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text("•")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Text(platform.quality)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                if let url = URL(string: platform.appURL) {
                                    openURL(url)
                                }
                            } label: {
                                Text("Ver")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Buscar en la web")) {
                    Link(destination: URL(string: "https://www.justwatch.com/es/buscar?q=\(movie.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                        HStack {
                            Label("Ver todas las opciones en JustWatch", systemImage: "magnifyingglass")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("¿Dónde ver?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Movie Poster Component
struct MoviePosterView: View {
    let movie: Movie
    var isSelectionMode: Bool = false
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: movie.posterURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay {
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                case .empty:
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay {
                            ProgressView()
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if !isSelectionMode && movie.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.pink)
                        .padding(5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.blue : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                } else if movie.isWatched {
                    HStack(spacing: 3) {
                        if let reaction = movie.userReaction {
                            Text(reaction)
                                .font(.system(size: 11))
                        }
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(5)
                    .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Text(movie.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
    }
}

// MARK: - Discover View
struct DiscoverView: View {
    @State private var isShaking = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.primary)
                .rotationEffect(.degrees(isShaking ? 5 : -5))
                .animation(
                    isShaking ? .easeInOut(duration: 0.16).repeatForever(autoreverses: true) : .default,
                    value: isShaking
                )
                .onAppear {
                    isShaking = true
                }
                .onDisappear {
                    isShaking = false
                }

            Text("Agita para descubrir una película")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Collection Model
struct MovieCollection: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var movieIDs: [UUID]

    init(id: UUID = UUID(), name: String = "Nueva colección", movieIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.movieIDs = movieIDs
    }
}

// MARK: - Local Persistence Store
@Observable
final class MovieStore {
    var movies: [Movie] = []
    var collections: [MovieCollection] = []

    private let moviesKey = "SavedMoviesList_v1"
    private let collectionsKey = "SavedCollectionsList_v1"
    private let appGroupSuiteName = "group.com.sabe.app"

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
    }

    init() {
        loadMovies()
        loadCollections()
    }

    func loadMovies() {
        if let data = sharedDefaults.data(forKey: moviesKey),
           let decoded = try? JSONDecoder().decode([Movie].self, from: data) {
            self.movies = decoded
        } else {
            self.movies = Movie.sampleMovies
            saveMovies()
        }
    }

    func saveMovies() {
        guard let encoded = try? JSONEncoder().encode(movies) else { return }
        sharedDefaults.set(encoded, forKey: moviesKey)
    }

    func loadCollections() {
        if let data = sharedDefaults.data(forKey: collectionsKey),
           let decoded = try? JSONDecoder().decode([MovieCollection].self, from: data) {
            self.collections = decoded
        }
    }

    func saveCollections() {
        guard let encoded = try? JSONEncoder().encode(collections) else { return }
        sharedDefaults.set(encoded, forKey: collectionsKey)
    }

    @discardableResult
    func createCollection(name: String = "Nueva colección") -> MovieCollection {
        let newCollection = MovieCollection(name: name)
        collections.insert(newCollection, at: 0)
        saveCollections()
        return newCollection
    }

    func updateCollectionName(id: UUID, name: String) {
        if let index = collections.firstIndex(where: { $0.id == id }) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            collections[index].name = trimmed.isEmpty ? "Colección" : trimmed
            saveCollections()
        }
    }

    func addMovie(_ movieID: UUID, toCollection collectionID: UUID) {
        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            if !collections[index].movieIDs.contains(movieID) {
                collections[index].movieIDs.append(movieID)
                saveCollections()
            }
        }
    }

    func removeMovie(_ movieID: UUID, fromCollection collectionID: UUID) {
        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[index].movieIDs.removeAll { $0 == movieID }
            saveCollections()
        }
    }

    func removeMovies(ids: Set<UUID>, fromCollection collectionID: UUID) {
        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[index].movieIDs.removeAll { ids.contains($0) }
            saveCollections()
        }
    }

    func deleteCollection(id: UUID) {
        collections.removeAll { $0.id == id }
        saveCollections()
    }

    func addMovie(title: String, posterURL: String) {
        let newMovie = Movie(title: title, posterURL: posterURL)
        movies.insert(newMovie, at: 0)
        saveMovies()
    }

    func addMovie(_ movie: Movie) {
        movies.insert(movie, at: 0)
        saveMovies()
    }

    func deleteMovie(id: UUID) {
        movies.removeAll { $0.id == id }
        // Also remove from any collections
        for index in collections.indices {
            collections[index].movieIDs.removeAll { $0 == id }
        }
        saveMovies()
        saveCollections()
    }

    func deleteMovies(ids: Set<UUID>) {
        movies.removeAll { ids.contains($0.id) }
        // Also remove from any collections
        for index in collections.indices {
            collections[index].movieIDs.removeAll { ids.contains($0) }
        }
        saveMovies()
        saveCollections()
    }

    func toggleFavorite(for movieID: UUID) {
        if let index = movies.firstIndex(where: { $0.id == movieID }) {
            movies[index].isFavorite.toggle()
            saveMovies()
        }
    }

    func toggleWatched(for movieID: UUID) {
        if let index = movies.firstIndex(where: { $0.id == movieID }) {
            movies[index].isWatched.toggle()
            saveMovies()
        }
    }

    func setReaction(for movieID: UUID, reaction: String?) {
        if let index = movies.firstIndex(where: { $0.id == movieID }) {
            movies[index].userReaction = reaction
            saveMovies()
        }
    }

    // MARK: - Backup & Restore
    func exportBackupJSON() -> String? {
        let backup = MovieBackupData(
            exportDate: Date(),
            version: "1.0",
            movies: movies,
            collections: collections
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(backup) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func importBackupJSON(_ jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else { return false }
        let decoder = JSONDecoder()
        if let backup = try? decoder.decode(MovieBackupData.self, from: data) {
            self.movies = backup.movies
            self.collections = backup.collections
            saveMovies()
            saveCollections()
            return true
        }
        if let directMovies = try? decoder.decode([Movie].self, from: data) {
            self.movies = directMovies
            saveMovies()
            return true
        }
        return false
    }

    func deleteAllData() {
        self.movies = []
        self.collections = []
        saveMovies()
        saveCollections()
    }

    func resetToSampleData() {
        self.movies = Movie.sampleMovies
        self.collections = []
        saveMovies()
        saveCollections()
    }
}

// MARK: - Movie Backup Data Model
struct MovieBackupData: Codable {
    let exportDate: Date
    let version: String
    let movies: [Movie]
    let collections: [MovieCollection]
}

// MARK: - Movie Model & Sample Data
struct Movie: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let posterURL: String
    var genre: String?
    var year: Int?
    var overview: String?
    var director: String?
    var duration: String?
    var rating: Double?
    var cast: [String]?
    var isFavorite: Bool = false
    var isWatched: Bool = false
    var userReaction: String? = nil
    var trailerURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, posterURL, genre, year, overview, director, duration, rating, cast, isFavorite, isWatched, userReaction, trailerURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        posterURL = try container.decode(String.self, forKey: .posterURL)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        director = try container.decodeIfPresent(String.self, forKey: .director)
        duration = try container.decodeIfPresent(String.self, forKey: .duration)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        cast = try container.decodeIfPresent([String].self, forKey: .cast)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isWatched = try container.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
        userReaction = try container.decodeIfPresent(String.self, forKey: .userReaction)
        trailerURL = try container.decodeIfPresent(String.self, forKey: .trailerURL)
    }

    init(
        id: UUID = UUID(),
        title: String,
        posterURL: String,
        genre: String? = nil,
        year: Int? = nil,
        overview: String? = nil,
        director: String? = nil,
        duration: String? = nil,
        rating: Double? = nil,
        cast: [String]? = nil,
        isFavorite: Bool = false,
        isWatched: Bool = false,
        userReaction: String? = nil,
        trailerURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.posterURL = posterURL
        self.genre = genre
        self.year = year
        self.overview = overview
        self.director = director
        self.duration = duration
        self.rating = rating
        self.cast = cast
        self.isFavorite = isFavorite
        self.isWatched = isWatched
        self.userReaction = userReaction
        self.trailerURL = trailerURL
    }

    var displayOverview: String {
        if let overview, !overview.isEmpty { return overview }
        return "Una cautivadora obra cinematográfica aclamada por la crítica que profundiza en emociones intensas con una narrativa magistral y actuaciones memorables."
    }

    var displayDirector: String {
        director ?? "Director aclamado"
    }

    var displayDuration: String {
        duration ?? "2h 15m"
    }

    var displayRating: Double {
        rating ?? 8.4
    }

    var displayCast: [String] {
        if let cast, !cast.isEmpty { return cast }
        return ["Reparto estelar", "Actores principales", "Elenco destacado"]
    }

    var displayTrailerURL: String {
        if let trailerURL, !trailerURL.isEmpty {
            return trailerURL
        }
        let query = "\(title) trailer oficial".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "https://www.youtube.com/results?search_query=\(query)"
    }

    // MARK: - Smart Movie Recognition from TikTok & Social Links
    static func recognizeMovieFromSharedText(_ text: String) -> Movie {
        let lower = text.lowercased()

        if lower.contains("dune") {
            return Movie(
                title: "Dune: Parte Dos",
                posterURL: "https://image.tmdb.org/t/p/w780/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg",
                genre: "Sci-Fi",
                year: 2024,
                overview: "Paul Atreides se une a Chani y a los Fremen mientras busca venganza contra los conspiradores que destruyeron a su familia.",
                director: "Denis Villeneuve",
                duration: "2h 46m",
                rating: 8.6,
                cast: ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson", "Javier Bardem"],
                trailerURL: "https://www.youtube.com/results?search_query=dune+parte+dos+trailer"
            )
        } else if lower.contains("oppenheimer") {
            return Movie(
                title: "Oppenheimer",
                posterURL: "https://image.tmdb.org/t/p/w780/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
                genre: "Drama",
                year: 2023,
                overview: "La historia del físico J. Robert Oppenheimer y su liderazgo en el Proyecto Manhattan, que llevó a la creación de la primera bomba atómica.",
                director: "Christopher Nolan",
                duration: "3h 00m",
                rating: 8.9,
                cast: ["Cillian Murphy", "Emily Blunt", "Matt Damon", "Robert Downey Jr."],
                trailerURL: "https://www.youtube.com/results?search_query=oppenheimer+trailer"
            )
        } else if lower.contains("gladiator") {
            return Movie(
                title: "Gladiator II",
                posterURL: "https://image.tmdb.org/t/p/w780/2cxhvwyEwRlysAmRH4iodkvo0z5.jpg",
                genre: "Acción",
                year: 2024,
                overview: "Años después de presenciar la muerte del admirado héroe Máximo a manos de su tío, Lucio debe entrar en el Coliseo.",
                director: "Ridley Scott",
                duration: "2h 28m",
                rating: 7.8,
                cast: ["Paul Mescal", "Pedro Pascal", "Denzel Washington"]
            )
        } else if lower.contains("interstellar") {
            return Movie(
                title: "Interstellar",
                posterURL: "https://image.tmdb.org/t/p/w780/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg",
                genre: "Sci-Fi",
                year: 2014,
                overview: "Un grupo de científicos y exploradores emprenden un viaje a través de un agujero de gusano para salvar a la humanidad.",
                director: "Christopher Nolan",
                duration: "2h 49m",
                rating: 8.7,
                cast: ["Matthew McConaughey", "Anne Hathaway", "Jessica Chastain"]
            )
        } else if lower.contains("batman") || lower.contains("dark knight") {
            return Movie(
                title: "The Dark Knight",
                posterURL: "https://image.tmdb.org/t/p/w780/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
                genre: "Acción",
                year: 2008,
                overview: "Batman debe aceptar una de las mayores pruebas psicológicas y físicas de su capacidad para luchar contra la injusticia.",
                director: "Christopher Nolan",
                duration: "2h 32m",
                rating: 9.0,
                cast: ["Christian Bale", "Heath Ledger", "Aaron Eckhart"]
            )
        } else if lower.contains("whiplash") {
            return Movie(
                title: "Whiplash",
                posterURL: "https://image.tmdb.org/t/p/w780/7fn624j5lj3xTme2SgiLCeuedmO.jpg",
                genre: "Drama",
                year: 2014,
                overview: "Un joven y talentoso batería de jazz se matricula en un prestigioso conservatorio de música donde sus sueños de grandeza son guiados por un despiadado instructor.",
                director: "Damien Chazelle",
                duration: "1h 46m",
                rating: 8.5,
                cast: ["Miles Teller", "J.K. Simmons", "Paul Reiser"]
            )
        } else {
            var extractedTitle = "Película detectada en TikTok"
            if let url = URL(string: text), let last = url.pathComponents.last, !last.isEmpty {
                let cleaned = last
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                if cleaned.count > 2 && !cleaned.contains(".Php") && !cleaned.contains(".Html") && !cleaned.contains("Video") {
                    extractedTitle = cleaned
                }
            }

            return Movie(
                title: extractedTitle,
                posterURL: "https://image.tmdb.org/t/p/w780/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
                genre: "Cine",
                year: Calendar.current.component(.year, from: Date()),
                overview: "Película identificada y agregada de forma automática desde un vídeo compartido de TikTok.",
                director: "Director cinematográfico",
                duration: "2h 10m",
                rating: 8.2,
                cast: ["Reparto principal"],
                trailerURL: text
            )
        }
    }

    static let sampleMovies: [Movie] = {
        let baseList: [(title: String, path: String, genre: String, year: Int, dir: String, dur: String, rat: Double, cast: [String], ov: String)] = [
            (
                "Inception",
                "/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
                "Sci-Fi",
                2010,
                "Christopher Nolan",
                "2h 28m",
                8.8,
                ["Leonardo DiCaprio", "Joseph Gordon-Levitt", "Elliot Page", "Tom Hardy"],
                "Dom Cobb es un ladrón experto en el arte de la extracción: robar secretos del subconsciente durante el sueño. Ahora se le ofrece la oportunidad de redimirse con una tarea inversa: la 'incepción', implantar una idea en la mente."
            ),
            (
                "Interstellar",
                "/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg",
                "Sci-Fi",
                2014,
                "Christopher Nolan",
                "2h 49m",
                8.7,
                ["Matthew McConaughey", "Anne Hathaway", "Jessica Chastain", "Michael Caine"],
                "Al ver que el fin de la Tierra se acerca, un grupo de exploradores espaciales emprende la misión más importante de la historia: viajar más allá de nuestra galaxia para descubrir si la humanidad tiene un futuro entre las estrellas."
            ),
            (
                "Oppenheimer",
                "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
                "Drama",
                2023,
                "Christopher Nolan",
                "3h 00m",
                8.9,
                ["Cillian Murphy", "Emily Blunt", "Matt Damon", "Robert Downey Jr."],
                "La historia épica del físico J. Robert Oppenheimer y su liderazgo en el Proyecto Manhattan, que llevó a la creación de la primera bomba atómica y cambió para siempre el destino del mundo."
            ),
            (
                "Dune: Part Two",
                "/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg",
                "Sci-Fi",
                2024,
                "Denis Villeneuve",
                "2h 46m",
                8.6,
                ["Timothée Chalamet", "Zendaya", "Rebecca Ferguson", "Javier Bardem"],
                "Paul Atreides se une a Chani y a los Fremen mientras busca venganza contra los conspiradores que destruyeron a su familia, enfrentando una difícil elección entre el amor de su vida y el destino del universo."
            ),
            (
                "The Dark Knight",
                "/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
                "Acción",
                2008,
                "Christopher Nolan",
                "2h 32m",
                9.0,
                ["Christian Bale", "Heath Ledger", "Aaron Eckhart", "Michael Caine"],
                "Batman se propone desmantelar las organizaciones criminales restantes en Gotham, pero pronto se encuentra presa de un caos impredecible desatado por una mente criminal conocida como el Joker."
            ),
            (
                "Blade Runner 2049",
                "/gajva2L0rPYkEWjzgFlBXCAVBE5.jpg",
                "Sci-Fi",
                2017,
                "Denis Villeneuve",
                "2h 44m",
                8.0,
                ["Ryan Gosling", "Harrison Ford", "Ana de Armas", "Sylvia Hoeks"],
                "El oficial K, un nuevo blade runner de LAPD, descubre un secreto enterrado que tiene el potencial de sumergir a la sociedad en el caos, llevándolo a buscar al legendario Rick Deckard."
            ),
            (
                "Pulp Fiction",
                "/d5iIlFn5s0ImszYzBPb8JPIfbXD.jpg",
                "Thriller",
                1994,
                "Quentin Tarantino",
                "2h 34m",
                8.9,
                ["John Travolta", "Uma Thurman", "Samuel L. Jackson", "Bruce Willis"],
                "Las vidas de dos sicarios de la mafia, un boxeador en declive, la esposa de un gángster y una pareja de bandidos se entrelazan de manera violenta e hilarante en Los Ángeles."
            ),
            (
                "Fight Club",
                "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
                "Drama",
                1999,
                "David Fincher",
                "2h 19m",
                8.8,
                ["Brad Pitt", "Edward Norton", "Helena Bonham Carter", "Meat Loaf"],
                "Un empleado de oficina con insomnio y un excéntrico vendedor de jabón fundan un club de lucha clandestino que evoluciona rápidamente hacia un movimiento antisistema incontrolable."
            ),
            (
                "The Matrix",
                "/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg",
                "Sci-Fi",
                1999,
                "Lana Wachowski, Lilly Wachowski",
                "2h 16m",
                8.7,
                ["Keanu Reeves", "Laurence Fishburne", "Carrie-Anne Moss", "Hugo Weaving"],
                "Un programador de computadoras descubre a través de misteriosos rebeldes que su vida cotidiana es una simulación elaborada construida por máquinas inteligentes que dominan el mundo."
            ),
            (
                "Forrest Gump",
                "/arw2vcBveWOVZr6pxd9XTd1TdQa.jpg",
                "Drama",
                1994,
                "Robert Zemeckis",
                "2h 22m",
                8.8,
                ["Tom Hanks", "Robin Wright", "Gary Sinise", "Sally Field"],
                "La vida de Forrest Gump, un hombre con un coeficiente intelectual bajo pero un corazón inmenso, coincide con algunos de los acontecimientos más importantes del siglo XX en Estados Unidos."
            ),
            (
                "The Godfather",
                "/3bhkrj58Vtu7enYsRolD1fZdja1.jpg",
                "Drama",
                1972,
                "Francis Ford Coppola",
                "2h 55m",
                9.2,
                ["Marlon Brando", "Al Pacino", "James Caan", "Robert Duvall"],
                "El patriarca de una dinastía del crimen organizado transfiere el control de su imperio clandestino a su reacio hijo menor."
            ),
            (
                "Spirited Away",
                "/39wmItIWsg5sZMyRUHLkWBcuVCM.jpg",
                "Animación",
                2001,
                "Hayao Miyazaki",
                "2h 05m",
                8.6,
                ["Rumi Hiiragi", "Miyu Irino", "Mari Natsuki"],
                "Durante la mudanza de su familia a los suburbios, una niña de 10 años se adentra en un mundo gobernado por dioses, brujas y espíritus, donde los humanos se transforman en bestias."
            ),
            (
                "Parasite",
                "/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg",
                "Thriller",
                2019,
                "Bong Joon-ho",
                "2h 12m",
                8.5,
                ["Song Kang-ho", "Lee Sun-kyun", "Cho Yeo-jeong", "Choi Woo-shik"],
                "La codicia y la discriminación de clase amenazan la recién formada relación simbiótica entre la adinerada familia Park y el indigente clan Kim."
            ),
            (
                "Whiplash",
                "/7fn624j5lj3xTme2SgiLCeuedmO.jpg",
                "Drama",
                2014,
                "Damien Chazelle",
                "1h 47m",
                8.5,
                ["Miles Teller", "J.K. Simmons", "Paul Reiser"],
                "Un prometedor joven baterista se matricula en un exigente conservatorio de música donde sus sueños son guiados por un despiadado instructor dispuesto a todo para alcanzar la perfección."
            ),
            (
                "Spider-Man: Across the Spider-Verse",
                "/8Vt6mWEReuy4Of61Lnj5Xj704m8.jpg",
                "Animación",
                2023,
                "Joaquim Dos Santos, Kemp Powers",
                "2h 20m",
                8.7,
                ["Shameik Moore", "Hailee Steinfeld", "Oscar Isaac", "Daniel Kaluuya"],
                "Miles Morales es catapultado a través del Multiverso, donde se encuentra con un equipo de Spider-People encargados de proteger su propia existencia y redefine lo que significa ser un héroe."
            ),
            (
                "Coco",
                "/gGEsBPAijhVUFoiNpgZXqRVWJt2.jpg",
                "Animación",
                2017,
                "Lee Unkrich, Adrian Molina",
                "1h 45m",
                8.4,
                ["Anthony Gonzalez", "Gael García Bernal", "Benjamin Bratt"],
                "El aspirante a músico Miguel se adentra en la mágica Tierra de los Muertos para descubrir el misterio tras el legado y la música de sus antepasados."
            ),
            (
                "WALL·E",
                "/hbhFnRzzgcoF5hk9z9Vpx9VnTC0.jpg",
                "Animación",
                2008,
                "Andrew Stanton",
                "1h 38m",
                8.4,
                ["Ben Burtt", "Elissa Knight", "Jeff Garlin"],
                "En un futuro lejano, un pequeño robot recolector de basura se embarca inadvertidamente en un viaje espacial que decidirá el destino de la humanidad."
            )
        ]

        var list: [Movie] = []
        for i in 0..<100 {
            let base = baseList[i % baseList.count]
            let suffix = i >= baseList.count ? " (\(i / baseList.count + 1))" : ""
            list.append(Movie(
                title: base.title + suffix,
                posterURL: "https://image.tmdb.org/t/p/w500" + base.path,
                genre: base.genre,
                year: base.year,
                overview: base.ov,
                director: base.dir,
                duration: base.dur,
                rating: base.rat,
                cast: base.cast
            ))
        }
        return list
    }()
}

#Preview {
    ContentView()
}
