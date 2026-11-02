import MapKit
import SwiftUI

struct PhoneLocationView: View {
    @Bindable var model: PhoneLocationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showConnection = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $model.camera) {
                    if let coordinate = model.selected {
                        Marker("选中位置", coordinate: coordinate).tint(.indigo)
                    }
                }
                .mapControls { MapCompass(); MapScaleView() }
                .onTapGesture { point in
                    editing = false
                    if let coordinate = proxy.convert(point, from: .local) { model.select(coordinate) }
                }
                .safeAreaInset(edge: .top, spacing: 0) { searchBar }
                .safeAreaInset(edge: .bottom, spacing: 0) { coordinatePanel }
            }
            .navigationTitle("定位助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showConnection = true } label: {
                        Label("连接", systemImage: model.connectionReady ? "link.circle.fill" : "link.circle")
                    }
                    .accessibilityIdentifier("connection")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editing = false }
                }
            }
            .sheet(isPresented: $showConnection) { ConnectionView(model: model) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await model.foregrounded()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.backgrounded() }
            }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索城市、街道或地点", text: $model.query)
                    .submitLabel(.search)
                    .focused($editing)
                    .onSubmit { editing = false; Task { await model.searchPlaces() } }
                    .accessibilityIdentifier("placeSearch")
                Button {
                    editing = false
                    Task { await model.searchPlaces() }
                } label: {
                    if model.searching { ProgressView() } else { Image(systemName: "arrow.right.circle.fill") }
                }
                .disabled(model.searching || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("搜索地点")
            }
            if let searchError = model.searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }
            if !model.searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.searchResults, id: \.self) { item in
                            Button {
                                model.select(item.location.coordinate, recenter: true)
                                model.searchResults = []
                                editing = false
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.and.ellipse")
                                    Text(item.name ?? "地点").frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.vertical, 10)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight: 170)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var coordinatePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(phaseTitle, systemImage: phaseIcon)
                    .font(.headline)
                    .foregroundStyle(model.needsRecovery && model.phase != .active ? .orange : .primary)
                Spacer()
                if model.busy { ProgressView() }
                if !model.hasPairing {
                    Button("设置连接") { showConnection = true }.font(.subheadline.bold())
                }
            }
            HStack {
                coordinateField("纬度", text: $model.latitudeText, identifier: "latitude")
                coordinateField("经度", text: $model.longitudeText, identifier: "longitude")
                Button { editing = false; model.showInput() } label: {
                    Image(systemName: "scope").font(.title3)
                }.accessibilityLabel("在地图显示输入坐标")
            }
            Picker("输入坐标系", selection: $model.inputSystem) {
                Text("WGS‑84").tag(CoordinateSystem.wgs84)
                Text("GCJ‑02").tag(CoordinateSystem.gcj02)
            }
            .pickerStyle(.segmented)
            Text("地图选点使用 WGS‑84；高德、腾讯提供的坐标选择 GCJ‑02。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("simulationStatus")
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            HStack {
                if model.phase == .awaitingRestore {
                    Button {
                        Task { await model.confirmRestore() }
                    } label: {
                        Label("已确认恢复", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                    .accessibilityIdentifier("confirmRestore")
                } else {
                    Button {
                        editing = false
                        Task { await model.apply() }
                    } label: {
                        Label(model.phase == .active ? "更新位置" : "开始模拟", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(!model.canApply)
                    .accessibilityIdentifier("applyLocation")
                }
                Button {
                    editing = false
                    Task { await model.stop() }
                } label: {
                    Label(model.phase == .awaitingRestore ? "再次停止" : "停止模拟", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!model.canStop)
                .accessibilityIdentifier("stopLocation")
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func coordinateField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .accessibilityIdentifier(identifier)
        }
    }

    private var phaseTitle: String {
        switch model.phase {
        case .idle: model.hasPairing ? "选择模拟位置" : "先连接这台 iPhone"
        case .active: "模拟进行中"
        case .unknown: "需要停止恢复"
        case .awaitingRestore: "等待确认恢复"
        }
    }

    private var phaseIcon: String {
        switch model.phase {
        case .idle: "mappin.circle"
        case .active: "location.circle.fill"
        case .unknown: "exclamationmark.triangle.fill"
        case .awaitingRestore: "clock.badge.checkmark"
        }
    }
}
