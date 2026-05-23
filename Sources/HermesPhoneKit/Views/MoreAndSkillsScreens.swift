#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct MoreScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        List {
            Section("Workspace") {
                NavigationLink {
                    ConnectionsScreen()
                } label: {
                    Label("Connections", systemImage: "network")
                }

                NavigationLink {
                    SkillsScreen()
                } label: {
                    Label("Skills", systemImage: "book.closed")
                }

                NavigationLink {
                    CronJobsScreen()
                } label: {
                    Label("Cron Jobs", systemImage: "calendar.badge.clock")
                }
            }
        }
        .navigationTitle("More")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.refreshOverview()
        }
    }
}

struct SkillsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var query = ""

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip(compact: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if store.isLoadingSkills && store.skills.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading skills...")
                        Spacer()
                    }
                }
            } else if filteredSkills.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Skills",
                        systemImage: "book.closed",
                        description: Text(store.skillsError ?? "Enabled Hermes skills for this host will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section("Enabled Skills") {
                    ForEach(filteredSkills) { skill in
                        NavigationLink {
                            SkillDetailScreen(summary: skill)
                        } label: {
                            SkillSummaryRow(skill: skill)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .searchable(text: $query, prompt: "Search skills")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.loadSkills()
        }
        .refreshable {
            await store.loadSkills()
        }
    }

    private var filteredSkills: [SkillSummary] {
        store.skills.filter { $0.matchesSearch(query) }
    }
}

struct SkillSummaryRow: View {
    let skill: SkillSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.resolvedName)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(skill.resolvedCategory)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let description = skill.trimmedDescription {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            SkillMetadataFlow(item: skill)
        }
        .padding(.vertical, 4)
    }
}

struct SkillDetailScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    let summary: SkillSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.isLoadingSkillDetail && store.selectedSkillDetail?.id != summary.id {
                    HStack {
                        Spacer()
                        ProgressView("Loading skill...")
                        Spacer()
                    }
                    .padding(.top, 32)
                } else if let detail = store.selectedSkillDetail, detail.id == summary.id {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(detail.resolvedName)
                            .font(.title2.weight(.semibold))
                        if let description = detail.trimmedDescription {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        SkillMetadataFlow(item: detail)
                    }

                    Divider()

                    Text(renderedMarkdown(detail.markdownContent))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        "Skill Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(store.skillsError ?? "Reload this skill from the active host.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle(summary.resolvedName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: summary.id) {
            await store.loadSkillDetail(summary: summary)
        }
        .refreshable {
            await store.loadSkillDetail(summary: summary)
        }
    }

    private func renderedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

struct SkillMetadataFlow<Item: SkillCatalogItem>: View {
    let item: Item

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                SkillChip(item.resolvedCategory)
                ForEach(item.platforms, id: \.self) { platform in
                    SkillChip(platform)
                }
                ForEach(item.tags, id: \.self) { tag in
                    SkillChip(tag)
                }
                ForEach(item.featureBadges) { badge in
                    SkillChip(badge.title)
                }
            }
        }
    }
}

struct SkillChip: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

#endif
