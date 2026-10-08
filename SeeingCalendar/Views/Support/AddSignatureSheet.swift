import PencilKit
import SwiftUI
import UIKit

/// 添加签名弹窗（看齐 iOS 备忘录 / 标记签名管理规范）
struct AddSignatureSheet: View {
    let onCommit: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var isCreatingNew = false
    @State private var savedSignatures: [SavedSignature] = []
    @State private var canvasView = PKCanvasView()
    @State private var signatureColorHex: String = "#000000"

    struct SavedSignature: Identifiable, Codable {
        let id: UUID
        let date: Date
        let fileName: String
    }

    private var signaturesDirectory: URL {
        AppPaths.cacheRoot.appendingPathComponent("signatures", isDirectory: true)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCreatingNew || savedSignatures.isEmpty {
                    newSignatureView
                } else {
                    savedSignatureListView
                }
            }
            .navigationTitle(isCreatingNew ? "新建签名" : "选择签名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isCreatingNew && !savedSignatures.isEmpty {
                        Button("返回") { isCreatingNew = false }
                    } else {
                        Button("取消") { dismiss() }
                    }
                }
                if isCreatingNew || savedSignatures.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            commitNewSignature()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                ensureDirectory()
                loadSavedSignatures()
                if savedSignatures.isEmpty {
                    isCreatingNew = true
                }
            }
        }
    }

    // MARK: - 签名绘制画板

    private var newSignatureView: some View {
        VStack(spacing: 16) {
            Text("请在下方横线上使用手指或 Apple Pencil 签名")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)

                // 签名基线
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1.5)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 50)
                }

                SignatureCanvasRepresentable(canvasView: $canvasView, colorHex: signatureColorHex)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .frame(height: 260)
            .padding(.horizontal)

            HStack {
                Button("清除") {
                    canvasView.drawing = PKDrawing()
                }
                .foregroundStyle(.red)

                Spacer()

                HStack(spacing: 12) {
                    ForEach(["#000000", "#007AFF", "#FF3B30"], id: \.self) { hex in
                        Button {
                            signatureColorHex = hex
                            updateTool()
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(signatureColorHex == hex ? Color.primary : .clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.vertical)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - 已存签名列表

    private var savedSignatureListView: some View {
        List {
            Section("已保存的签名") {
                ForEach(savedSignatures) { sig in
                    let url = signaturesDirectory.appendingPathComponent(sig.fileName)
                    if let image = UIImage(contentsOfFile: url.path) {
                        Button {
                            if let data = image.pngData() {
                                onCommit(data)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 50)
                                    .padding(.vertical, 4)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteSignatures)
            }

            Section {
                Button {
                    isCreatingNew = true
                    canvasView.drawing = PKDrawing()
                } label: {
                    Label("添加新签名", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - 存储与提交

    private func updateTool() {
        let color = UIColor(hex: signatureColorHex) ?? .black
        canvasView.tool = PKInkingTool(.pen, color: color, width: 4.5)
    }

    private func commitNewSignature() {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { return }

        var bounds = drawing.bounds
        // 防止空边或细线过窄
        if bounds.width < 10 || bounds.height < 10 {
            bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        }
        let padding: CGFloat = 16
        let renderRect = bounds.insetBy(dx: -padding, dy: -padding)

        let image = drawing.image(from: renderRect, scale: 2.0)
        guard let data = image.pngData() else { return }

        // 保存到已存签名
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let fileURL = signaturesDirectory.appendingPathComponent(fileName)
        try? data.write(to: fileURL)

        var list = savedSignatures
        list.insert(SavedSignature(id: id, date: Date(), fileName: fileName), at: 0)
        saveSignatureList(list)

        onCommit(data)
        dismiss()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: signaturesDirectory, withIntermediateDirectories: true)
    }

    private func loadSavedSignatures() {
        let metaURL = signaturesDirectory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let list = try? JSONDecoder().decode([SavedSignature].self, from: data) else {
            savedSignatures = []
            return
        }
        savedSignatures = list
    }

    private func saveSignatureList(_ list: [SavedSignature]) {
        savedSignatures = list
        let metaURL = signaturesDirectory.appendingPathComponent("meta.json")
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: metaURL)
        }
    }

    private func deleteSignatures(at offsets: IndexSet) {
        var list = savedSignatures
        for index in offsets {
            let sig = list[index]
            let fileURL = signaturesDirectory.appendingPathComponent(sig.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        list.remove(atOffsets: offsets)
        saveSignatureList(list)
    }
}

private struct SignatureCanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let colorHex: String

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        let color = UIColor(hex: colorHex) ?? .black
        canvasView.tool = PKInkingTool(.pen, color: color, width: 4.5)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        let color = UIColor(hex: colorHex) ?? .black
        uiView.tool = PKInkingTool(.pen, color: color, width: 4.5)
    }
}
