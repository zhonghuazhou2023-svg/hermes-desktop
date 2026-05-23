#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct CronJobsScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            ForEach(store.cronJobs) { job in
                NavigationLink {
                    CronJobDetailScreen(job: job)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.resolvedName)
                            .font(.headline)
                        Text(job.resolvedScheduleDisplay)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(job.displayState)
                            .font(.caption)
                            .foregroundStyle(job.isActive ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .navigationTitle("Cron Jobs")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            await store.loadCronJobs()
        }
        .refreshable {
            await store.loadCronJobs()
        }
    }
}

struct CronJobDetailScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    let job: CronJob

    var body: some View {
        List {
            DetailCard(title: "Job") {
                DetailRow(label: "Name", value: job.resolvedName)
                DetailRow(label: "State", value: job.displayState)
                DetailRow(label: "Schedule", value: job.resolvedScheduleDisplay)
                if let lastRunAt = job.lastRunAt {
                    DetailRow(label: "Last Run", value: DateFormatters.shortDateTimeString(from: lastRunAt))
                }
                if let nextRunAt = job.nextRunAt {
                    DetailRow(label: "Next Run", value: DateFormatters.shortDateTimeString(from: nextRunAt))
                }
            }

            if let prompt = job.trimmedPrompt {
                DetailCard(title: "Prompt") {
                    Text(prompt)
                        .font(.body)
                }
            }

            Section {
                Button {
                    Task { await store.operateCron(job, kind: .runNow) { service, connection, jobID in
                        try await service.runJobNow(connection: connection, jobID: jobID)
                    } }
                } label: {
                    cronOperationLabel(defaultTitle: "Run Now", kind: .runNow)
                }
                .disabled(isOperatingJob)

                if job.isPaused {
                    Button {
                        Task { await store.operateCron(job, kind: .resume) { service, connection, jobID in
                            try await service.resumeJob(connection: connection, jobID: jobID)
                        } }
                    } label: {
                        cronOperationLabel(defaultTitle: "Resume", kind: .resume)
                    }
                    .disabled(isOperatingJob)
                } else {
                    Button {
                        Task { await store.operateCron(job, kind: .pause) { service, connection, jobID in
                            try await service.pauseJob(connection: connection, jobID: jobID)
                        } }
                    } label: {
                        cronOperationLabel(defaultTitle: "Pause", kind: .pause)
                    }
                    .disabled(isOperatingJob)
                }

                Button(role: .destructive) {
                    Task { await store.operateCron(job, kind: .delete) { service, connection, jobID in
                        try await service.removeJob(connection: connection, jobID: jobID)
                    } }
                } label: {
                    cronOperationLabel(defaultTitle: "Delete", kind: .delete)
                }
                .disabled(isOperatingJob)
            }
        }
        .navigationTitle(job.resolvedName)
    }

    private var activeOperation: CronOperationState? {
        guard store.activeCronOperation?.jobID == job.id else { return nil }
        return store.activeCronOperation
    }

    private var isOperatingJob: Bool {
        activeOperation != nil
    }

    @ViewBuilder
    private func cronOperationLabel(defaultTitle: String, kind: CronOperationKind) -> some View {
        if activeOperation?.kind == kind {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(kind.label)
            }
        } else {
            Text(defaultTitle)
        }
    }
}

#endif
