// Campaign/drop JSON parsing helpers for TwitchAPIClient. Split from
// TwitchAPIClient.swift; same actor, same isolation.
import Foundation

extension TwitchAPIClient {
    // MARK: - Parsing Helpers

    /// Parse an ISO8601 date string, handling both plain and fractional-second formats.
    /// Twitch returns dates in multiple formats: with/without fractional seconds, with Z or +/-HH:MM timezone.
    func parseDate(_ str: String) -> Date? {
        // Try fractional seconds format first (most common for Twitch API)
        if let d = iso8601Fractional.date(from: str) { return d }
        // Try standard internet date format (no fractional seconds)
        if let d = iso8601Internet.date(from: str) { return d }
        // Fallback to basic formatter
        return iso8601Basic.date(from: str)
    }

    func parseCampaigns(from drops: [[String: Any]]) -> [Campaign] {
        return drops.compactMap { campaignDict -> Campaign? in
            guard
                let id = campaignDict["id"] as? String,
                let name = campaignDict["name"] as? String,
                let startAtStr = campaignDict["startAt"] as? String,
                let endAtStr = campaignDict["endAt"] as? String,
                let startAt = parseDate(startAtStr),
                let endAt = parseDate(endAtStr)
            else {
                return nil
            }

            let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
            let game = Self.parseGame(from: gameDict)

            let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
            let status = CampaignStatus(rawValue: statusDict) ?? .active

            let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? []).compactMap { parseDrop(from: $0) }

            return Campaign(
                id: id,
                name: name,
                game: game,
                status: status,
                startDate: startAt,
                endDate: endAt,
                drops: dropsArray,
                channels: []
            )
        }
    }

    func parseDrop(from dropDict: [String: Any]) -> Drop? {
        guard
            let id = dropDict["id"] as? String,
            let name = dropDict["name"] as? String,
            let requiredMinutes = dropDict["requiredMinutesWatched"] as? Int
        else {
            return nil
        }

        let imageUrl = (dropDict["imageURL"] as? String).flatMap { URL(string: $0) }
        let description = dropDict["description"] as? String

        // Parse per-drop active window (drops can have their own window within the campaign window)
        let dropStartDate = (dropDict["startAt"] as? String).flatMap { parseDate($0) }
        let dropEndDate = (dropDict["endAt"] as? String).flatMap { parseDate($0) }

        // Parse precondition drops
        let preconditionDrops = (dropDict["preconditionDrops"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }

        // Parse subscription requirement (0 = none, >0 = number of subs required)
        let requiredSubs = dropDict["requiredSubs"] as? Int ?? 0

        // Parse ALL benefit IDs from benefitEdges — used for fallback claimed detection.
        // Python: for benefit in self.benefits — checks ALL benefit IDs against claimed_benefits.
        var benefitIds: [String] = []
        var reward: Reward? = nil
        if let benefitEdges = dropDict["benefitEdges"] as? [[String: Any]] {
            for edge in benefitEdges {
                guard let benefit = edge["benefit"] as? [String: Any],
                      let benefitId = benefit["id"] as? String else { continue }
                benefitIds.append(benefitId)
                // Use first benefit for display (reward field)
                if reward == nil, let benefitName = benefit["name"] as? String {
                    let benefitImageURL = (benefit["imageAssetURL"] as? String).flatMap { URL(string: $0) }
                    
                    // Parse distribution type (IN_GAME, BADGE, EMOTE)
                    let distributionType = benefit["distributionType"] as? String ?? "IN_GAME"
                    let type = RewardType(rawValue: distributionType) ?? .inGame
                    
                    reward = Reward(id: benefitId, type: type, name: benefitName, description: "", imageURL: benefitImageURL)
                }
            }
        }

        // Read per-drop progress from the `self` field (present in DropCampaignDetails response).
        // Tier 1: authoritative — Twitch returns this for in-progress drops.
        // For fully-claimed drops, Twitch omits `self` entirely; fallback handled in DropsService.mergeInventory.
        var progress: Progress? = nil
        if let selfDict = dropDict["self"] as? [String: Any] {
            let isClaimed = selfDict["isClaimed"] as? Bool ?? false
            let currentMinutes = selfDict["currentMinutesWatched"] as? Int ?? 0
            let dropInstanceId = selfDict["dropInstanceID"] as? String ?? id
            progress = Progress(
                id: dropInstanceId,
                dropId: id,
                dropName: name,
                campaignId: "",
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                isClaimed: isClaimed
            )
        }

        return Drop(
            id: id,
            name: name,
            description: description,
            imageURL: imageUrl ?? reward?.imageURL,
            requiredMinutes: requiredMinutes,
            benefitID: benefitIds.first ?? "",
            reward: reward,
            progress: progress,
            isClaimed: false,
            benefitIds: benefitIds,
            preconditionDrops: preconditionDrops,
            requiredSubs: requiredSubs,
            dropStartDate: dropStartDate,
            dropEndDate: dropEndDate
        )
    }

    /// Parse basic campaign from ViewerDropsDashboard (no drops)
    func parseBasicCampaign(from campaignDict: [String: Any]) -> Campaign {
        let id = campaignDict["id"] as? String ?? ""
        let name = campaignDict["name"] as? String ?? ""
        
        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)
        
        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()
        
        // Extract isAccountConnected from self field
        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false
        
        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: [],
            channels: [],
            isAccountConnected: isAccountConnected
        )
    }
    
    /// Parse detailed campaign from DropCampaignDetails (includes drops)
    func parseDetailedCampaign(from campaignDict: [String: Any]) -> Campaign {
        let id = campaignDict["id"] as? String ?? ""
        let name = campaignDict["name"] as? String ?? ""
        
        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)
        
        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()
        
        let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? [])
            .compactMap { parseDrop(from: $0) }
        
        // Extract isAccountConnected from self field
        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false
        
        // Parse ACL channels from allow.channels (critical for restricted campaigns).
        // Twitch uses multiple channel shapes here: DropCampaignDetails commonly returns
        // login/displayName, while CDL/esports and Inventory responses can return `name`.
        let allowDict = campaignDict["allow"] as? [String: Any] ?? [:]
        let isAllowEnabled = allowDict["isEnabled"] as? Bool
        let channelsArray = parseAllowedChannels(from: allowDict)
        
        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: dropsArray,
            channels: channelsArray,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: isAllowEnabled
        )
    }

    /// Parse a Campaign from an inventory `dropCampaignsInProgress` entry.
    /// The inventory format uses "name" (not "login"/"displayName") for ACL channels.
    /// Returns nil if the campaign's endAt is in the past (genuinely expired).
    func parseCampaignFromInProgressDict(_ campaignDict: [String: Any]) -> Campaign? {
        guard let id = campaignDict["id"] as? String,
              let name = campaignDict["name"] as? String else { return nil }

        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)

        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()

        // Skip genuinely expired campaigns (endAt in the past)
        guard endAt > Date() else { return nil }

        let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? [])
            .compactMap { parseDrop(from: $0) }

        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false

        // Inventory ACL channels often use "name" instead of "login"/"displayName".
        // Use the same tolerant parser as DropCampaignDetails so neither endpoint can
        // silently erase an approved esports channel.
        let allowDict = campaignDict["allow"] as? [String: Any] ?? [:]
        let isAllowEnabled = allowDict["isEnabled"] as? Bool
        let channelsArray = parseAllowedChannels(from: allowDict)

        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: dropsArray,
            channels: channelsArray,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: isAllowEnabled
        )
    }

    /// Parses Twitch's known approved-channel representations without requiring every
    /// optional presentation field. A login/name is enough; numeric IDs are resolved later
    /// by the channel-selection pipeline when Twitch omits them.
    func parseAllowedChannels(from allowDict: [String: Any]) -> [Channel] {
        guard (allowDict["isEnabled"] as? Bool) != false else { return [] }

        return (allowDict["channels"] as? [[String: Any]] ?? []).compactMap { channelDict in
            func nonEmptyString(_ keys: String...) -> String? {
                for key in keys {
                    guard let value = channelDict[key] as? String else { continue }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                return nil
            }

            guard let login = nonEmptyString("login", "name", "displayName") else {
                return nil
            }

            let id = nonEmptyString("id") ?? login
            let displayName = nonEmptyString("displayName", "name", "login") ?? login
            let broadcasterType = nonEmptyString("broadcasterType") ?? ""
            let description = nonEmptyString("description") ?? ""
            let profileImageURL = nonEmptyString("profileImageURL", "profileImageUrl")
                .flatMap(URL.init(string:))

            return Channel(
                id: id,
                login: login,
                displayName: displayName,
                description: description,
                profileImageUrl: profileImageURL,
                broadcasterType: broadcasterType,
                aclBased: true
            )
        }
    }

    /// Parse drop progress from Inventory GQL response.
    /// Actual Twitch structure:
    ///   dropCampaignsInProgress[]: { id: campaignId, timeBasedDrops[]: { id, name, requiredMinutesWatched, self: { currentMinutesWatched, isClaimed, dropInstanceID } } }
    func parseDropProgress(from progressDicts: [[String: Any]]) -> [Progress] {
        var results: [Progress] = []

        for campaignEntry in progressDicts {
            let campaignId = campaignEntry["id"] as? String ?? ""
            let timeBasedDrops = campaignEntry["timeBasedDrops"] as? [[String: Any]] ?? []

            for drop in timeBasedDrops {
                guard
                    let dropId = drop["id"] as? String,
                    let dropName = drop["name"] as? String,
                    let requiredMinutes = drop["requiredMinutesWatched"] as? Int,
                    let selfDict = drop["self"] as? [String: Any]
                else { continue }

                let currentMinutes = selfDict["currentMinutesWatched"] as? Int ?? 0
                let isClaimed = selfDict["isClaimed"] as? Bool ?? false
                let dropInstanceId = selfDict["dropInstanceID"] as? String

                // Twitch can omit dropInstanceID while a drop is still earning. Keep those
                // rows for progress display, but avoid creating a synthetic claim target
                // once a drop is complete.
                if dropInstanceId == nil && currentMinutes >= requiredMinutes {
                    continue
                }

                results.append(Progress(
                    id: dropInstanceId ?? "\(campaignId)_\(dropId)",
                    dropId: dropId,
                    dropName: dropName,
                    campaignId: campaignId,
                    currentMinutes: currentMinutes,
                    requiredMinutes: requiredMinutes,
                    isClaimed: isClaimed
                ))
            }
        }

        return results
    }

    // Legacy single-item parser kept for reference but no longer used by fetchInventory
    func parseDropProgressLegacy(from progressDicts: [[String: Any]]) -> [Progress] {
        return progressDicts.compactMap { dict -> Progress? in
            guard
                let id = dict["id"] as? String,
                let drop = dict["drop"] as? [String: Any],
                let dropId = drop["id"] as? String,
                let dropName = drop["name"] as? String,
                let requiredMinutes = drop["requiredMinutesWatched"] as? Int,
                let campaign = dict["campaign"] as? [String: Any],
                let campaignId = campaign["id"] as? String,
                let progress = dict["progress"] as? [String: Any],
                let currentMinutes = progress["currentMinutesWatched"] as? Int
            else {
                return nil
            }

            let isClaimed = progress["isClaimed"] as? Bool ?? false

            return Progress(
                id: id,
                dropId: dropId,
                dropName: dropName,
                campaignId: campaignId,
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                isClaimed: isClaimed
            )
        }
    }
}
