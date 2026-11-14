// GPL-3.0. StageView and SignalBus adapted from the user-provided BitChord
// 1.0.2-kr-proxy.24 AudioPipelineSheet.swift. Measurements come from Vitrine.
import SwiftUI
import UIKit

private struct SGPipelineRow: Hashable { let label: String; let value: String }
private struct SGPipelineStage {
    let title: String
    let symbol: String
    let rows: [SGPipelineRow]
    init(_ value: [String: Any]) {
        title = value["title"] as? String ?? "—"
        symbol = value["symbol"] as? String ?? "circle"
        rows = (value["rows"] as? [[String: String]] ?? []).map {
            SGPipelineRow(label: $0["label"] ?? "", value: $0["value"] ?? "—")
        }
    }
}

@objc(SGAudioPipelineHost)
@MainActor final class SGAudioPipelineHost: NSObject {
    @objc(controllerWithProvider:close:)
    static func controller(provider: @escaping () -> NSDictionary, close: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: SGPipelineView(provider: provider, close: close))
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        return host
    }
}

private struct SGPipelineView: View {
    let provider: () -> NSDictionary
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let snapshot = provider() as? [String: Any] ?? [:]
            let stages = (snapshot["stages"] as? [[String: Any]] ?? []).map(SGPipelineStage.init)
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("Audio Pipeline").font(.headline).foregroundStyle(.white)
                    Text(snapshot["statsLine"] as? String ?? "—").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }.multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 19)
                Divider().overlay(Color.white.opacity(0.12))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                            StageView(stage: stage, index: index, isLast: index == stages.count - 1,
                                      flowing: (snapshot["playing"] as? Bool ?? false) && !reduceMotion, count: stages.count)
                        }
                        Text(snapshot["diagnostic"] as? String ?? "").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                }
                Divider().overlay(Color.white.opacity(0.12))
                Button(action: close) {
                    Text("Done").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("pipeline.done")
            }.background(Color.black)
        }
    }
}

private struct StageView: View {
    let stage: SGPipelineStage
    let index: Int
    let isLast: Bool
    let flowing: Bool
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: stage.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(Color(white: 0.075)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                if !isLast {
                    SignalBus(segment: index, segments: count - 1, flowing: flowing)
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(minHeight: 23)
                    .accessibilityAddTraits(.isHeader)
                ForEach(stage.rows, id: \.self) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 12)
                        Text(row.value)
                            .foregroundStyle(.white.opacity(0.92))
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
    }
}

/// The line between two stage nodes, with the pulse passing through it in turn: one sweep down
/// the whole chain every 2.4 s, each segment taking its share.
private struct SignalBus: View {
    let segment: Int
    let segments: Int
    let flowing: Bool

    var body: some View {
        TimelineView(.animation(paused: !flowing)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                let span = 0.85 / Double(max(segments, 1))
                let local = (phase - Double(segment) * span) / span
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(flowing ? 0.28 : 0.18))
                        .frame(width: 2)
                        .frame(maxWidth: .infinity)
                    if flowing, local >= 0, local <= 1 {
                        let y = proxy.size.height * local
                        LinearGradient(colors: [.clear, .white.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                            .frame(width: 2.5, height: 38)
                            .offset(y: y - 38)
                            .frame(maxWidth: .infinity)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 4, height: 4)
                            .shadow(color: .white.opacity(0.7), radius: 4)
                            .offset(y: y - 2)
                    }
                }
                .frame(height: proxy.size.height, alignment: .top)
                .clipped()
            }
        }
        .accessibilityHidden(true)
    }
}

