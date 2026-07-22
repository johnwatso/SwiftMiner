import SwiftUI
import TipKit

extension View {
    /// Attaches a TipKit popover only when the user has tips enabled in Settings.
    func minerTip<T: Tip>(_ tip: T) -> some View {
        modifier(MinerTipModifier(tip: tip))
    }
}

private struct MinerTipModifier<T: Tip>: ViewModifier {
    let tip: T
    private var settings: Settings { .shared }

    func body(content: Content) -> some View {
        if settings.tipsEnabled {
            content.popoverTip(tip)
        } else {
            content
        }
    }
}

struct AddMinerTip: Tip {
    var title: Text {
        Text("Add your first miner")
    }

    var message: Text? {
        Text("Each Twitch account becomes a miner that earns drops independently. Add one to get started.")
    }

    var image: Image? {
        Image(systemName: "person.badge.plus")
    }
}

struct PrioritiseGameTip: Tip {
    var title: Text {
        Text("Prioritise a game")
    }

    var message: Text? {
        Text("Pick the games you want SwiftMiner to mine first when their drops are live.")
    }

    var image: Image? {
        Image(systemName: "star.fill")
    }
}

struct DragToReorderTip: Tip {
    @Parameter
    static var prioritisedCount: Int = 0

    var title: Text {
        Text("Drag to reorder")
    }

    var message: Text? {
        Text("Drag prioritised cards left or right to change which game gets mined first.")
    }

    var image: Image? {
        Image(systemName: "arrow.left.and.right")
    }

    var rules: [Rule] {
        #Rule(Self.$prioritisedCount) { $0 >= 2 }
    }
}

struct NicknameMinerTip: Tip {
    static let viewedMinersList = Event(id: "viewedMinersListWithMultiple")

    @Parameter
    static var minerCount: Int = 0

    var title: Text {
        Text("Nickname your miners")
    }

    var message: Text? {
        Text("Right-click a miner to add a nickname — handy when you have several accounts.")
    }

    var image: Image? {
        Image(systemName: "pencil.circle")
    }

    var rules: [Rule] {
        #Rule(Self.$minerCount) { $0 >= 2 }
        #Rule(Self.viewedMinersList) { $0.donations.count >= 3 }
    }
}

struct DropFilterChipsTip: Tip {
    static let viewedDropsList = Event(id: "viewedDropsListForChips")

    var title: Text {
        Text("Combine drop filters")
    }

    var message: Text? {
        Text("Tap multiple chips to combine filters — Live now plus Linked, for example.")
    }

    var image: Image? {
        Image(systemName: "line.3.horizontal.decrease.circle")
    }

    var rules: [Rule] {
        #Rule(Self.viewedDropsList) { $0.donations.count >= 4 }
    }
}

struct MinerFilterTip: Tip {
    static let viewedDropsList = Event(id: "viewedDropsList")

    var title: Text {
        Text("Filter drops by miner")
    }

    var message: Text? {
        Text("Pick a single miner to see only the campaigns it's tracking.")
    }

    var image: Image? {
        Image(systemName: "person.crop.circle.badge.checkmark")
    }

    var rules: [Rule] {
        #Rule(Self.viewedDropsList) { $0.donations.count >= 3 }
    }
}

struct SteamArtworkTip: Tip {
    static let viewedCampaigns = Event(id: "viewedCampaignsForArtwork")

    var title: Text {
        Text("Use Steam artwork")
    }

    var message: Text? {
        Text("Show portrait artwork from Steam for a more polished look. Falls back to Twitch when unavailable.")
    }

    var image: Image? {
        Image(systemName: "photo.on.rectangle.angled")
    }

    var rules: [Rule] {
        #Rule(Self.viewedCampaigns) { $0.donations.count >= 5 }
    }
}
