import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Codable, Identifiable {
    case connections
    case files
    case sessions
    case workflows
    case cronjobs
    case kanban
    case usage
    case skills
    case terminal
    case webchat
    case fleet
    case orchestra
    case memory
    case plans

    var id: String { rawValue }

    static var navigationCases: [AppSection] {
        [.connections] + customizableSidebarSections
    }

    static var customizableSidebarSections: [AppSection] {
        [.sessions, .workflows, .webchat, .cronjobs, .kanban, .files, .fleet, .orchestra, .memory, .plans, .usage, .skills, .terminal]
    }

    var title: String {
        L10n.string(rawTitle)
    }

    private var rawTitle: String {
        switch self {
        case .connections:
            "Settings"
        case .files:
            "Files"
        case .sessions:
            "Sessions"
        case .workflows:
            "Workflows"
        case .cronjobs:
            "Cron Jobs"
        case .kanban:
            "Kanban"
        case .usage:
            "Usage"
        case .skills:
            "Skills"
        case .terminal:
            "Terminal"
        case .webchat:
            "Web Chat"
        case .fleet:
            "Fleet"
        case .orchestra:
            "Orchestra"
        case .memory:
            "Memory"
        case .plans:
            "Plans"
        }
    }

    var systemImage: String {
        switch self {
        case .connections:
            "gearshape"
        case .files:
            "doc.text"
        case .sessions:
            "bubble.left.and.bubble.right"
        case .workflows:
            "bookmark.square"
        case .cronjobs:
            "calendar.badge.clock"
        case .kanban:
            "rectangle.3.group"
        case .usage:
            "chart.bar.xaxis"
        case .skills:
            "book.closed"
        case .terminal:
            "terminal"
        case .webchat:
            "globe"
        case .fleet:
            "square.grid.2x2"
        case .orchestra:
            "brain.head.profile"
        case .memory:
            "memorychip"
        case .plans:
            "checklist"
        }
    }

    var navigationShortcutKey: KeyEquivalent {
        switch self {
        case .connections:
            return "1"
        case .sessions:
            return "3"
        case .workflows:
            return "4"
        case .cronjobs:
            return "5"
        case .kanban:
            return "6"
        case .files:
            return "7"
        case .usage:
            return "8"
        case .skills:
            return "9"
        case .terminal:
            return "0"
        case .webchat:
            return "2"
        case .fleet:
            return "f"
        case .orchestra:
            return "o"
        case .memory:
            return "m"
        case .plans:
            return "p"
        }
    }
}
