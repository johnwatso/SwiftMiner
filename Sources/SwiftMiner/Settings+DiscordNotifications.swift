import Foundation

// Which SwiftBot Discord DMs a miner may send.
//
// Important notifications default ON — these relate to account recovery and action required.
// Activity notifications default OFF — these are informational and can be noisy.
//
// Split out of Settings.swift, which had grown past the point where one file could be read.

extension Settings {
    // MARK: - Discord DM Notification Preferences

    // MARK: - Discord DM Notification Preferences
    //
    // Important notifications default ON — these relate to account recovery and action required.
    // Activity notifications default OFF — these are informational and can be noisy.

    public var dmCampaignCompletedEnabled: Bool {
        get {
            access(keyPath: \.dmCampaignCompletedEnabled)
            return Self.read("dmCampaignCompletedEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmCampaignCompletedEnabled) {
                Self.write("dmCampaignCompletedEnabled", newValue)
            }
        }
    }

    public var dmConnectionExpiredEnabled: Bool {
        get {
            access(keyPath: \.dmConnectionExpiredEnabled)
            return Self.read("dmConnectionExpiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmConnectionExpiredEnabled) {
                Self.write("dmConnectionExpiredEnabled", newValue)
            }
        }
    }

    public var dmWelcomeBackEnabled: Bool {
        get {
            access(keyPath: \.dmWelcomeBackEnabled)
            return Self.read("dmWelcomeBackEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmWelcomeBackEnabled) {
                Self.write("dmWelcomeBackEnabled", newValue)
            }
        }
    }

    public var dmLinkRequiredEnabled: Bool {
        get {
            access(keyPath: \.dmLinkRequiredEnabled)
            return Self.read("dmLinkRequiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmLinkRequiredEnabled) {
                Self.write("dmLinkRequiredEnabled", newValue)
            }
        }
    }

    public var dmCampaignDetectedEnabled: Bool {
        get {
            access(keyPath: \.dmCampaignDetectedEnabled)
            return Self.read("dmCampaignDetectedEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmCampaignDetectedEnabled) {
                Self.write("dmCampaignDetectedEnabled", newValue)
            }
        }
    }

    public var dmAccountActionRequiredEnabled: Bool {
        get {
            access(keyPath: \.dmAccountActionRequiredEnabled)
            return Self.read("dmAccountActionRequiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmAccountActionRequiredEnabled) {
                Self.write("dmAccountActionRequiredEnabled", newValue)
            }
        }
    }

    public var quietHoursEnabled: Bool {
        get {
            access(keyPath: \.quietHoursEnabled)
            return Self.read("quietHoursEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.quietHoursEnabled) {
                Self.write("quietHoursEnabled", newValue)
            }
        }
    }

    public var quietHoursStartMinute: Int {
        get {
            access(keyPath: \.quietHoursStartMinute)
            return Self.read("quietHoursStartMinute", default: 22 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursStartMinute) {
                Self.write("quietHoursStartMinute", newValue)
            }
        }
    }

    public var quietHoursEndMinute: Int {
        get {
            access(keyPath: \.quietHoursEndMinute)
            return Self.read("quietHoursEndMinute", default: 7 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursEndMinute) {
                Self.write("quietHoursEndMinute", newValue)
            }
        }
    }
}
