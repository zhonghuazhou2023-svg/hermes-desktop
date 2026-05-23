#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct OverviewView: View {
    @EnvironmentObject private var store: HermesPhoneStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionHeader(connection: store.activeConnection)

                if let overview = store.overview {
                    overviewSection(overview)
                } else {
                    ContentUnavailableView(
                        "No Overview",
                        systemImage: "rectangle.stack",
                        description: Text("Select a host and refresh to inspect the remote Hermes environment.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Overview")
        .task(id: store.activeConnectionID) {
            await store.refreshOverview()
        }
        .refreshable {
            await store.refreshOverview()
        }
    }

    private func overviewSection(_ overview: RemoteDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailCard(title: "Workspace") {
                DetailRow(label: "Remote Home", value: overview.remoteHome)
                DetailRow(label: "Hermes Home", value: overview.hermesHome)
                DetailRow(label: "Active Profile", value: overview.activeProfile.name)
                DetailRow(label: "Session Store", value: overview.sessionStore?.path ?? "Not found")
            }

            DetailCard(title: "Important Paths") {
                DetailRow(label: "USER.md", value: overview.paths.user)
                DetailRow(label: "MEMORY.md", value: overview.paths.memory)
                DetailRow(label: "SOUL.md", value: overview.paths.soul)
                DetailRow(label: "Cron Jobs", value: overview.paths.cronJobs)
            }
        }
    }
}

#endif
