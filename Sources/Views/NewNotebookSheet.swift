import SwiftUI

struct NewNotebookSheet: View {
    @ObservedObject var vault: VaultManager
    let targetFolder: String
    let onCreated: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = "Untitled Notebook"
    @State private var selectedCoverID: Int = 0
    @State private var selectedTemplate: PaperTemplate = .lined
    @State private var errorMsg: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Notebook Title") {
                    TextField("e.g. Lecture Notes, Organic Chemistry...", text: $title)
                }

                Section("Cover Color") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(HobonichiEngine.notebookPalettes) { pal in
                                Button {
                                    selectedCoverID = pal.id
                                } label: {
                                    Circle()
                                        .fill(Color(pal.bgColor))
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle().stroke(selectedCoverID == pal.id ? Color.blue : Color.white.opacity(0.25), lineWidth: selectedCoverID == pal.id ? 3 : 1.5)
                                        )
                                        .scaleEffect(selectedCoverID == pal.id ? 1.1 : 1.0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Paper Template") {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(PaperTemplate.allCases) { tpl in
                            Text(tpl.title).tag(tpl)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !errorMsg.isEmpty {
                    Section {
                        Text(errorMsg).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        do {
                            let res = try vault.createNotebook(
                                title: title,
                                template: selectedTemplate,
                                coverID: selectedCoverID,
                                inFolder: targetFolder
                            )
                            dismiss()
                            onCreated(res.url, res.relPath)
                        } catch {
                            errorMsg = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct NewHobonichiSheet: View {
    @ObservedObject var vault: VaultManager
    let targetFolder: String
    let onCreated: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = "\(Calendar.current.component(.year, from: Date())) Hobonichi Techo Weeks"
    @State private var selectedCoverID: Int = 100
    @State private var startMode: String = "month"
    @State private var initialWeeks: Int = 12
    @State private var errorMsg: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Journal Title") {
                    TextField("e.g. 2026 Hobonichi Weeks", text: $title)
                }

                Section("Hobonichi Cover Fabric") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(HobonichiEngine.hoboPalettes) { pal in
                                Button {
                                    selectedCoverID = pal.id
                                } label: {
                                    VStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(pal.bgColor))
                                            .frame(width: 34, height: 34)
                                            .overlay(
                                                Circle().stroke(selectedCoverID == pal.id ? Color.orange : Color.white.opacity(0.25), lineWidth: selectedCoverID == pal.id ? 3 : 1.5)
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Starting Point") {
                    Picker("Start From", selection: $startMode) {
                        Text("This Week").tag("week")
                        Text("This Month").tag("month")
                        Text("Jan 1 (Full Year)").tag("year")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: startMode) { newVal in
                        if newVal == "year" { initialWeeks = 52 }
                    }
                }

                Section(
                    header: Text("Initial Weeks (Expandable Anytime)"),
                    footer: Text("Includes Page 1 Year-at-a-Glance & Glossary Index, Monthly Calendar spreads, Monday–Sunday Weekly + 3.55mm Graph spreads, and Back Notes — 100% compatible with Obsidian Pencil Ink.")
                ) {
                    Picker("Initial Weeks", selection: $initialWeeks) {
                        Text("4 Wks").tag(4)
                        Text("12 Wks").tag(12)
                        Text("26 Wks").tag(26)
                        Text("52 Wks").tag(52)
                    }
                    .pickerStyle(.segmented)
                }

                if !errorMsg.isEmpty {
                    Section {
                        Text(errorMsg).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Hobonichi Journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        do {
                            let res = try vault.createHobonichiJournal(
                                title: title,
                                coverID: selectedCoverID,
                                startMode: startMode,
                                initialWeeks: initialWeeks,
                                inFolder: targetFolder
                            )
                            dismiss()
                            onCreated(res.url, res.relPath)
                        } catch {
                            errorMsg = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
