import FaceCore
import SwiftUI

/// A new version of FaceID in the island: what is new, then the download and the install, or what went wrong. The
/// buttons and the progress bar are drawn by the app, like everything in the island.
struct UpdatePage: View {
    @ObservedObject private var updater = UpdateCenter.shared.updater

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch UpdateCenter.shared.state {
            case let .available(release):
                offer(release)
            case let .downloading(release, progress):
                working(L("Загружаю версию %@", release.version), progress: progress, cancel: true)
            case let .installing(release):
                working(L("Устанавливаю версию %@", release.version), progress: nil, cancel: false)
            case let .failed(failure, release):
                failed(failure, release: release)
            case .checking:
                title(L("Проверяю…"), symbol: "arrow.triangle.2.circlepath", color: .white)
            case .idle, .upToDate:
                title(L("Установлена последняя версия"), symbol: "checkmark.circle.fill", color: Brand.green)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }

    private func offer(_ release: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            title(L("Доступна версия %@", release.version), symbol: "arrow.down.circle.fill", color: Brand.green)
            let summary = Self.summary(of: release.notes, title: release.title)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !updater.canInstallInPlace && !updater.isDevelopmentBuild {
                Text(L("Переместите FaceID в «Программы», чтобы он обновлялся сам"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Button(L("Пропустить")) {
                    updater.skip()
                    Island.shared.hide()
                }
                .appButton(.secondary)
                .help(L("Больше не предлагать эту версию"))
                Spacer(minLength: 0)
                Button(L("Позже")) {
                    updater.dismiss()
                    Island.shared.hide()
                }
                .appButton(.secondary)
                Button(L("Обновить")) { UpdateCenter.shared.install() }
                    .appButton(.primary)
                    .disabled(updater.isDevelopmentBuild)
                    .help(updater.isDevelopmentBuild ? L("В сборке для разработки обновление выключено")
                                                     : L("FaceID скачает новую версию, проверит подпись, заменит себя и перезапустится"))
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func working(_ text: String, progress: Double?, cancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            ProgressBar(value: progress)
            if cancel {
                HStack {
                    Spacer()
                    Button(L("Отменить")) { updater.cancel() }
                        .appButton(.secondary)
                        .controlSize(.small)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    private func failed(_ failure: Updater.Failure, release: Updater.Release?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            title(release == nil ? L("Не удалось проверить обновления") : L("Не удалось обновить"),
                  symbol: "exclamationmark.triangle.fill", color: .orange)
            Text(Self.text(for: failure, developmentBuild: updater.isDevelopmentBuild))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button(L("Закрыть")) {
                    updater.dismiss()
                    Island.shared.hide()
                }
                .appButton(.secondary)
                // After `cannotReplace` the updater keeps the downloaded DMG and opens it in Finder instead of the page.
                Button(failure == .cannotReplace && !updater.isDevelopmentBuild ? L("Открыть DMG") : L("Страница релиза")) {
                    updater.openReleasePage()
                }
                .appButton(.primary)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func title(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
    }

    /// What went wrong, in a sentence or two.
    static func text(for failure: Updater.Failure, developmentBuild: Bool) -> String {
        switch failure {
        case .offline: L("Не удалось связаться с GitHub. Проверьте подключение к интернету")
        case .rateLimited: L("GitHub временно ограничил запросы. Попробуйте через час")
        case .noInstaller: L("В релизе нет установщика FaceID. Новую версию можно поставить вручную со страницы релиза")
        case .download: L("Загрузка прервалась. Попробуйте еще раз")
        case .damaged: L("Загруженный файл поврежден")
        case .notTrusted: L("Подпись новой версии не совпадает с подписью этой копии FaceID, поэтому FaceID ее не ставит")
        case .cannotReplace:
            developmentBuild ? L("Сборка для разработки не обновляется сама")
                             : L("FaceID не может обновить себя в этой папке. Откройте DMG и перетащите FaceID в «Программы»")
        }
    }

    /// The same in a few words, for the settings.
    static func shortText(for failure: Updater.Failure) -> String {
        switch failure {
        case .offline: L("Нет подключения")
        case .rateLimited: L("GitHub просит подождать")
        case .noInstaller: L("В релизе нет установщика")
        case .download: L("Загрузка прервалась")
        case .damaged: L("Файл поврежден")
        case .notTrusted: L("Подпись не совпадает")
        case .cannotReplace: L("Нужно поставить вручную")
        }
    }

    /// The first lines of the release text without headings and Markdown marks, for "what's new".
    static func summary(of notes: String, title: String) -> String {
        let lines = notes.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#") else { return nil }
            while let first = text.first, "*->".contains(first) { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }
        return lines.filter { !$0.isEmpty && $0 != title }.prefix(3).joined(separator: "\n")
    }
}

/// The download's progress: a capsule filling with green, or a light running through it while the length is unknown.
struct ProgressBar: View {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                if let value {
                    Capsule()
                        .fill(Brand.green)
                        .frame(width: max(6, geometry.size.width * min(1, max(0, value))))
                } else {
                    Capsule()
                        .fill(Brand.green.opacity(0.85))
                        .frame(width: geometry.size.width * 0.3)
                        .offset(x: geometry.size.width * phase)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 0.7 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
    }
}

/// The settings row's right side: what the updater is doing and the one button that fits.
struct UpdateStatus: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 6) {
            if let (text, color) = status {
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            switch UpdateCenter.shared.state {
            case .checking, .installing:
                EmptyView()
            case .available:
                Button(L("Обновить")) { UpdateCenter.shared.show() }
                    .appButton(.primary)
                    .fixedSize()
            case .downloading:
                Button(L("Отменить")) { updater.cancel() }
                    .appButton(.secondary)
                    .fixedSize()
            case .failed:
                Button(L("Подробнее")) { UpdateCenter.shared.show() }
                    .appButton(.secondary)
                    .fixedSize()
            case .idle, .upToDate:
                // The button keeps its whole name; the status gives way.
                Button(L("Проверить сейчас")) { UpdateCenter.shared.checkNow() }
                    .appButton(.secondary)
                    .fixedSize()
            }
        }
        .controlSize(.mini)
    }

    private var status: (String, Color)? {
        switch UpdateCenter.shared.state {
        case .idle: updater.isDevelopmentBuild ? (L("Для разработки"), .white.opacity(0.45)) : nil
        case .checking: (L("Проверяю…"), .white.opacity(0.6))
        case .upToDate: (L("Последняя"), .white.opacity(0.6))
        case let .available(release): (L("Доступна %@", release.version), Brand.green)
        case let .downloading(_, progress): ("\(L("Загружаю")) \(Int((progress * 100).rounded()))%", .white.opacity(0.7))
        case .installing: (L("Устанавливаю…"), .white.opacity(0.7))
        case let .failed(failure, _): (UpdatePage.shortText(for: failure), .orange)
        }
    }
}
