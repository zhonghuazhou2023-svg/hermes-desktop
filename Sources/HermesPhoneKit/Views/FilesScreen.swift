#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct FilesScreen: View {
    @EnvironmentObject private var store: HermesPhoneStore
    @State private var browsePath = ""

    var body: some View {
        List {
            Section {
                ActiveWorkspaceStrip(compact: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Canonical Files") {
                ForEach(store.canonicalFileReferences) { reference in
                    Button {
                        Task { await store.openCanonicalFile(reference) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.title)
                            Text(reference.remotePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Pinned Files & Folders") {
                if store.bookmarkedWorkspaceFileGroups.isEmpty {
                    Text("Pin remote files or folders from the browser below to keep them within easy reach.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.bookmarkedWorkspaceFileGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.directoryPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            ForEach(group.references) { reference in
                                Button {
                                    Task { await store.openWorkspaceFileReference(reference) }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: reference.systemImage)
                                            .foregroundStyle(reference.opensDirectory ? .yellow : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(reference.title)
                                            Text(reference.remotePath)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if let bookmarkID = reference.bookmarkID {
                                        Button(role: .destructive) {
                                            store.removeWorkspaceFileBookmark(id: bookmarkID)
                                        } label: {
                                            Label("Unpin", systemImage: "pin.slash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Browse") {
                TextField("Remote path", text: $browsePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open Directory") {
                    Task { await store.browseDirectory(path: browsePath) }
                }
            }

            if store.isLoadingFiles && store.directoryListing == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading files...")
                        Spacer()
                    }
                }
            } else if let listing = store.directoryListing {
                Section(listing.displayPath) {
                    if let parent = listing.parentDisplayPath {
                        Button(".. (\(parent))") {
                            Task { await store.browseDirectory(path: listing.parentPath) }
                        }
                    }

                    ForEach(listing.entries) { entry in
                        Button {
                            Task { await store.openDirectoryEntry(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: entry.kind == .directory ? "folder" : "doc.text")
                                        .foregroundStyle(entry.kind == .directory ? .yellow : .secondary)
                                    Text(entry.name)
                                }
                                Text(entry.displayPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let targetKind = entry.bookmarkTargetKind, entry.canBookmark {
                                if store.isWorkspaceFileBookmarked(remotePath: entry.displayPath) {
                                    Button {
                                        store.removeWorkspaceFileBookmark(remotePath: entry.displayPath)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash")
                                    }
                                    .tint(.secondary)
                                } else {
                                    Button {
                                        _ = store.addWorkspaceFileBookmark(
                                            remotePath: entry.displayPath,
                                            title: entry.name,
                                            targetKind: targetKind
                                        )
                                    } label: {
                                        Label("Pin", systemImage: "pin")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
        .task(id: store.activeWorkspaceScopeFingerprint) {
            browsePath = store.overview?.hermesHome ?? store.activeConnection?.remoteHermesHomePath ?? "~/.hermes"
            await store.browseDirectory(path: browsePath)
        }
        .refreshable {
            await store.browseDirectory(path: browsePath)
        }
    }
}

#endif
