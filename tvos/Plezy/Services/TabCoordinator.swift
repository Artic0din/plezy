//
//  TabCoordinator.swift
//  Beacon tvOS
//
//  Manages tab navigation state across the app
//

import SwiftUI
import Combine

/// Tab selection options for main navigation
enum TabSelection: String, CaseIterable, Codable {
    case home = "Home"
    case movies = "Movies"
    case tvShows = "TV Shows"
    case search = "Search"
    case settings = "Settings"

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .movies: return "film.fill"
        case .tvShows: return "tv.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gear"
        }
    }

    var tag: Int {
        switch self {
        case .home: return 0
        case .movies: return 1
        case .tvShows: return 2
        case .search: return 3
        case .settings: return 4
        }
    }
}

/// Coordinates tab selection across the entire app
/// Allows any view to programmatically switch tabs
/// Persists last selected tab to UserDefaults for session continuity
class TabCoordinator: ObservableObject {
    @Published var selectedTab: TabSelection = .home {
        didSet {
            // Persist tab selection
            if let encoded = try? JSONEncoder().encode(selectedTab) {
                UserDefaults.standard.set(encoded, forKey: Self.tabStorageKey)
            }
        }
    }

    private static let tabStorageKey = "beacon_selected_tab"

    /// Shared singleton instance - initialized once at app startup
    static let shared = TabCoordinator()

    private init() {
        // Restore last selected tab from storage
        if let data = UserDefaults.standard.data(forKey: Self.tabStorageKey),
           let savedTab = try? JSONDecoder().decode(TabSelection.self, from: data) {
            self.selectedTab = savedTab
            print("🔵 [TabCoordinator] Initialized with restored tab: \(savedTab.rawValue)")
        } else {
            print("🔵 [TabCoordinator] Initialized with default tab: Home")
        }
    }

    /// Switch to a specific tab
    func select(_ tab: TabSelection) {
        print("🔵 [TabCoordinator] Switching to tab: \(tab.rawValue)")
        selectedTab = tab
    }

    /// Switch to a tab by its string name
    func selectByName(_ name: String) {
        if let tab = TabSelection.allCases.first(where: { $0.rawValue == name }) {
            select(tab)
        } else {
            print("⚠️ [TabCoordinator] Unknown tab name: \(name)")
        }
    }
}
