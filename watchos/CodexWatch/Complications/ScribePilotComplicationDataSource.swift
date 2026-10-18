import ClockKit
import SwiftUI

enum ScribePilotComplication {
    static let openIdentifier = "ScribePilot.Open"
    static let recordIdentifier = "ScribePilot.Record"
    static let openActivityType = "com.zachwyatt.codexwatch.open"
    static let recordActivityType = "com.zachwyatt.codexwatch.record"
    static let voiceIdentifier = "ScribePilot.Voice"
    static let voiceActivityType = "com.zachwyatt.codexwatch.voice"

    static let supportedFamilies: [CLKComplicationFamily] = [
        .graphicCircular,
        .graphicRectangular,
        .graphicCorner,
        .graphicExtraLarge,
    ]

    static func activity(type: String, title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.title = title
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        return activity
    }
}

@MainActor
final class ScribePilotComplicationDataSource: NSObject, CLKComplicationDataSource {
    func getComplicationDescriptors(
        handler: @escaping ([CLKComplicationDescriptor]) -> Void
    ) {
        let record = CLKComplicationDescriptor(
            identifier: ScribePilotComplication.recordIdentifier,
            displayName: "Record Meeting",
            supportedFamilies: ScribePilotComplication.supportedFamilies,
            userActivity: ScribePilotComplication.activity(
                type: ScribePilotComplication.recordActivityType,
                title: "Record Meeting"
            )
        )
        let open = CLKComplicationDescriptor(
            identifier: ScribePilotComplication.openIdentifier,
            displayName: "Open Scribe Pilot",
            supportedFamilies: ScribePilotComplication.supportedFamilies,
            userActivity: ScribePilotComplication.activity(
                type: ScribePilotComplication.openActivityType,
                title: "Open Scribe Pilot"
            )
        )
        var descriptors = [record, open]
        descriptors.append(CLKComplicationDescriptor(identifier: ScribePilotComplication.voiceIdentifier,
            displayName: "Talk to Assistant", supportedFamilies: ScribePilotComplication.supportedFamilies,
            userActivity: ScribePilotComplication.activity(type: ScribePilotComplication.voiceActivityType, title: "Talk to Assistant")))
        if let cache = VoiceDescriptorCache.read(), cache.owner == RecordingQueueStore.shared.accountID, cache.configuration.enabled {
            for assistant in cache.configuration.assistants {
                let activity = ScribePilotComplication.activity(type: ScribePilotComplication.voiceActivityType, title: "Talk to \(assistant.name)")
                activity.userInfo = ["assistant_id": assistant.id, "owner_id": cache.owner]
                descriptors.append(CLKComplicationDescriptor(identifier: ScribePilotComplication.voiceIdentifier + "." + assistant.id,
                    displayName: "Talk to \(assistant.name)", supportedFamilies: ScribePilotComplication.supportedFamilies, userActivity: activity))
            }
        }
        handler(descriptors)
    }

    func handleSharedComplicationDescriptors(_ complicationDescriptors: [CLKComplicationDescriptor]) {}

    func getCurrentTimelineEntry(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void
    ) {
        guard let template = template(for: complication) else {
            handler(nil)
            return
        }
        handler(CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template))
    }

    func getLocalizableSampleTemplate(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTemplate?) -> Void
    ) {
        handler(template(for: complication))
    }

    func getPrivacyBehavior(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void
    ) {
        handler(.showOnLockScreen)
    }

    private func template(for complication: CLKComplication) -> CLKComplicationTemplate? {
        let startsRecording = complication.identifier == ScribePilotComplication.recordIdentifier
        let talks = complication.identifier.hasPrefix(ScribePilotComplication.voiceIdentifier)

        switch complication.family {
        case .graphicCircular:
            return CLKComplicationTemplateGraphicCircularView(
                ScribePilotCircularComplication(startsRecording: startsRecording, talks: talks)
            )
        case .graphicRectangular:
            return CLKComplicationTemplateGraphicRectangularFullView(
                ScribePilotRectangularComplication(startsRecording: startsRecording, talks: talks)
            )
        case .graphicCorner:
            return CLKComplicationTemplateGraphicCornerCircularView(
                ScribePilotCircularComplication(startsRecording: startsRecording, talks: talks)
            )
        case .graphicExtraLarge:
            return CLKComplicationTemplateGraphicExtraLargeCircularView(
                ScribePilotCircularComplication(startsRecording: startsRecording, talks: talks)
            )
        default:
            return nil
        }
    }
}

private struct ScribePilotCircularComplication: View {
    let startsRecording: Bool
    var talks = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.04, green: 0.20, blue: 0.21))
            Image(systemName: talks ? "waveform" : (startsRecording ? "record.circle.fill" : "mic.fill"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.25, green: 0.82, blue: 0.78))
        }
    }
}

private struct ScribePilotRectangularComplication: View {
    let startsRecording: Bool
    var talks = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: talks ? "waveform" : (startsRecording ? "record.circle.fill" : "mic.fill"))
                .font(.title2)
                .foregroundStyle(Color(red: 0.25, green: 0.82, blue: 0.78))
            VStack(alignment: .leading, spacing: 1) {
                Text(talks ? "ASSISTANT" : (startsRecording ? "MEETING" : "SCRIBE PILOT"))
                    .font(.caption2.weight(.bold))
                Text(talks ? "Tap to talk" : (startsRecording ? "Tap to start" : "Tap to open"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }
}
