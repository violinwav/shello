import Accessibility
import Foundation

/// How urgently VoiceOver speaks an announcement.
typealias AnnouncementPriority = AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute
    .AnnouncementPriority

/// Tells VoiceOver something the user cannot see happen, such as a row that disappears after a
/// delete, or a list that a search leaves empty.
/// - Parameter priority: `.high` is not cut off by the screen change it describes; `.low` waits until
///   VoiceOver has read what the user did, such as a typed character or a tapped chip.
func announce(_ message: String, priority: AnnouncementPriority = .high) {
    var text = AttributedString(message)
    text.accessibilitySpeechAnnouncementPriority = priority
    AccessibilityNotification.Announcement(text).post()
}
