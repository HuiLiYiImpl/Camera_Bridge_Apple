import Foundation
import UserNotifications

/// Local-notification bridge for download status and retry actions.
///
/// Call `requestAuthorization()` during app setup, then use the task's stable
/// string identifier for every progress, completion, and failure update. Reusing
/// the identifier replaces the previous notification for that download.
final class NotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    static let retryActionIdentifier = "com.huiliyi.CameraBridge.download.retry"
    static let retryRequestedNotification = Notification.Name(
        "com.huiliyi.CameraBridge.download.retryRequested"
    )
    static let taskIDUserInfoKey = "downloadTaskID"

    private static let failureCategoryIdentifier = "com.huiliyi.CameraBridge.download.failed"
    private static let notificationThreadIdentifier = "com.huiliyi.CameraBridge.downloads"
    private static let notificationIdentifierPrefix = "com.huiliyi.CameraBridge.download."

    private let center: UNUserNotificationCenter

    override convenience init() {
        self.init(center: .current())
    }

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// Requests alert, badge, and sound permission. A `false` result means the
    /// user declined; thrown errors indicate that the request itself failed.
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Posts or replaces a passive progress notification for one download.
    func updateDownloadProgress(
        taskID: String,
        fileName: String,
        downloadedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double?,
        remainingSeconds: TimeInterval?
    ) async throws {
        let downloaded = max(downloadedBytes, 0)
        let total = max(totalBytes, 0)
        let fraction = total > 0 ? min(max(Double(downloaded) / Double(total), 0), 1) : 0
        let percentage = Int((fraction * 100).rounded())

        let content = baseContent(taskID: taskID)
        content.title = "正在下载 \(fileName)"
        content.subtitle = total > 0 ? "\(percentage)%" : "正在传输"
        content.body = progressBody(
            downloadedBytes: downloaded,
            totalBytes: total,
            bytesPerSecond: bytesPerSecond,
            remainingSeconds: remainingSeconds
        )
        content.interruptionLevel = .passive
        try await replaceNotification(taskID: taskID, content: content)
    }

    /// Replaces progress with a completion notification.
    func notifyDownloadCompleted(
        taskID: String,
        fileName: String,
        totalBytes: Int64? = nil
    ) async throws {
        let content = baseContent(taskID: taskID)
        content.title = "下载完成"
        if let totalBytes, totalBytes > 0 {
            content.body = "\(fileName) · \(formatBytes(totalBytes))"
        } else {
            content.body = fileName
        }
        content.sound = .default
        content.interruptionLevel = .active
        try await replaceNotification(taskID: taskID, content: content)
    }

    /// Replaces progress with a failure notification carrying a foreground
    /// Retry action. The original task identifier remains in `userInfo`.
    func notifyDownloadFailed(
        taskID: String,
        fileName: String,
        errorMessage: String
    ) async throws {
        let content = baseContent(taskID: taskID)
        content.title = "下载失败"
        content.subtitle = fileName
        content.body = errorMessage
        content.categoryIdentifier = Self.failureCategoryIdentifier
        content.sound = .default
        content.interruptionLevel = .active
        try await replaceNotification(taskID: taskID, content: content)
    }

    func removeDownloadNotification(taskID: String) {
        let identifier = notificationIdentifier(for: taskID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Extracts the download task identifier from a notification response.
    static func taskID(from response: UNNotificationResponse) -> String? {
        taskID(from: response.notification.request.content.userInfo)
    }

    static func taskID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let taskID = userInfo[taskIDUserInfoKey] as? String, !taskID.isEmpty else {
            return nil
        }
        return taskID
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.retryActionIdentifier,
              let taskID = Self.taskID(from: response) else { return }
        NotificationCenter.default.post(
            name: Self.retryRequestedNotification,
            object: self,
            userInfo: [Self.taskIDUserInfoKey: taskID]
        )
    }

    // MARK: - Private helpers

    private func registerCategories() {
        let retry = UNNotificationAction(
            identifier: Self.retryActionIdentifier,
            title: "重试",
            options: [.foreground]
        )
        let failed = UNNotificationCategory(
            identifier: Self.failureCategoryIdentifier,
            actions: [retry],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([failed])
    }

    private func baseContent(taskID: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = Self.notificationThreadIdentifier
        content.userInfo = [Self.taskIDUserInfoKey: taskID]
        return content
    }

    private func replaceNotification(
        taskID: String,
        content: UNNotificationContent
    ) async throws {
        let identifier = notificationIdentifier(for: taskID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    private func notificationIdentifier(for taskID: String) -> String {
        Self.notificationIdentifierPrefix + taskID
    }

    private func progressBody(
        downloadedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double?,
        remainingSeconds: TimeInterval?
    ) -> String {
        var components: [String] = []
        if totalBytes > 0 {
            components.append("\(formatBytes(downloadedBytes)) / \(formatBytes(totalBytes))")
        } else {
            components.append(formatBytes(downloadedBytes))
        }
        if let bytesPerSecond, bytesPerSecond > 0, bytesPerSecond.isFinite {
            components.append("\(formatBytes(Int64(bytesPerSecond.rounded()))) / 秒")
        }
        if let remainingSeconds, remainingSeconds >= 0, remainingSeconds.isFinite {
            components.append("剩余 \(formatDuration(remainingSeconds))")
        }
        return components.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds.rounded()), 0)
        if value < 60 { return "\(value) 秒" }
        let minutes = value / 60
        let remainingSeconds = value % 60
        if minutes < 60 { return "\(minutes) 分 \(remainingSeconds) 秒" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours) 小时 \(remainingMinutes) 分"
    }
}
