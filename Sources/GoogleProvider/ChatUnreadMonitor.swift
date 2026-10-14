import EspazioCore
import Foundation

/// Tracks the user's unread Google Chat conversations, as the Chat app does: a space is unread
/// when its last activity is newer than the user's own read state (updated by every Chat client,
/// and by the user's own messages, which are therefore never reported).
///
/// Cost per round: one `spaces.list`, plus a read state and a message list for each space whose
/// activity changed (bounded per round), plus a periodic re-check of unread spaces so a
/// conversation read elsewhere disappears. The user's Chat notification settings are honored:
/// muted conversations (or notifications off) are ignored, "For you" ones are listed without a
/// pop-up.
public actor ChatUnreadMonitor {
    public struct Snapshot: Sendable, Equatable {
        /// Most recent first.
        public var unread: [ChatUnread]
        /// Conversations that received unread messages since the previous round (empty until the
        /// initial scan is complete, so launching never replays old messages).
        public var fresh: [ChatUnread]
    }

    private let service: GoogleChatService
    private let people: GooglePeopleService?
    /// Spaces inactive for longer than this at launch are not scanned.
    private let horizon: TimeInterval
    private let checksPerRound: Int
    private let recheckEvery: Int

    /// Activity time of each space when it was last checked.
    private var checked: [String: Date] = [:]
    private var unread: [String: ChatUnread] = [:]
    private var names: [String: String] = [:]
    private var settings: [String: (value: GoogleChatService.NotificationSetting, fetched: Date)] = [:]
    private let settingsLifetime: TimeInterval = 600
    private var peopleRetryAt = Date.distantPast
    private var cutoff: Date?
    private var primed = false
    private var round = 0

    public init(
        service: GoogleChatService, people: GooglePeopleService?, horizon: TimeInterval = 7 * 86400,
        checksPerRound: Int = 6, recheckEvery: Int = 6
    ) {
        self.service = service
        self.people = people
        self.horizon = horizon
        self.checksPerRound = checksPerRound
        self.recheckEvery = recheckEvery
    }

    public func sync(now: Date = Date()) async throws -> Snapshot {
        round += 1
        let cutoff = self.cutoff ?? now.addingTimeInterval(-horizon)
        self.cutoff = cutoff
        let spaces = try await service.listSpaces(limit: 100)
        let recheckUnread = round % recheckEvery == 0

        var due: [GoogleChatService.SpaceActivity] = []
        for activity in spaces {
            guard let active = activity.lastActive else { continue }
            let changed = active > (checked[activity.space.id] ?? cutoff)
            if changed || (recheckUnread && unread[activity.space.id] != nil) { due.append(activity) }
        }
        due.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }

        let before = unread
        for activity in due.prefix(checksPerRound) {
            try await check(activity, now: now)
        }
        // Spaces that vanished (left, deleted) are no longer unread.
        let present = Set(spaces.map(\.space.id))
        unread = unread.filter { present.contains($0.key) }
        await resolveNames(now: now)

        let completed = due.count <= checksPerRound
        var fresh: [ChatUnread] = []
        if primed {
            for item in unread.values where item.notifies {
                let known = Set(before[item.id]?.messages.map(\.id) ?? [])
                if item.messages.contains(where: { !known.contains($0.id) }) { fresh.append(item) }
            }
        }
        if completed { primed = true }
        return Snapshot(unread: Self.sorted(unread.values), fresh: Self.sorted(fresh))
    }

    /// The user opened the conversation: hide it until new activity.
    public func markSeen(spaceID: String) {
        unread[spaceID] = nil
    }

    private func check(_ activity: GoogleChatService.SpaceActivity, now: Date) async throws {
        let space = activity.space
        guard let active = activity.lastActive else { return }
        let lastRead = try await service.lastReadTime(spaceID: space.id)
        let setting = (lastRead.map { active > $0 } ?? true) ? try await notificationSetting(space.id, now: now) : .default
        if let lastRead, active <= lastRead {
            unread[space.id] = nil
        } else if setting.isSilenced {
            unread[space.id] = nil
        } else {
            let messages = try await service.listMessages(spaceID: space.id, after: lastRead, limit: 10)
                .filter { message in lastRead.map { (message.createTime ?? .distantFuture) > $0 } ?? true }
                .filter { !$0.text.isEmpty }
            unread[space.id] = messages.isEmpty ? nil : ChatUnread(space: space, messages: messages, notifies: setting.notifies)
        }
        checked[space.id] = active
    }

    private func notificationSetting(_ spaceID: String, now: Date) async throws -> GoogleChatService.NotificationSetting {
        if let cached = settings[spaceID], now.timeIntervalSince(cached.fetched) < settingsLifetime { return cached.value }
        let value: GoogleChatService.NotificationSetting
        do {
            value = try await service.notificationSetting(spaceID: spaceID)
        } catch GoogleAPIError.notFound {
            value = .default
        }
        settings[spaceID] = (value, now)
        return value
    }

    private func resolveNames(now: Date) async {
        guard let people, now >= peopleRetryAt else { apply(); return }
        let missing = unread.values.flatMap(\.messages).compactMap(\.senderID).filter { names[$0] == nil }
        if !missing.isEmpty {
            do {
                let found = try await people.displayNames(forChatUsers: missing)
                names.merge(found) { _, new in new }
                // Unknown to the directory (external users): don't ask again every round.
                for id in missing where names[id] == nil { names[id] = "" }
            } catch {
                // People API disabled or not granted: keep generic names, retry later.
                peopleRetryAt = now.addingTimeInterval(3600)
            }
        }
        apply()
    }

    private func apply() {
        for (id, item) in unread {
            var item = item
            for index in item.messages.indices {
                if let senderID = item.messages[index].senderID, let name = names[senderID], !name.isEmpty {
                    item.messages[index].sender = name
                }
            }
            unread[id] = item
        }
    }

    static func sorted<S: Sequence>(_ items: S) -> [ChatUnread] where S.Element == ChatUnread {
        items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
