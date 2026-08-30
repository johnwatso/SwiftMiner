// Shared campaign card state, artwork, and inspector components.
import SwiftUI
import SwiftMinerCore
import AppKit
import CoreImage
import CryptoKit

enum CampaignCardState: String {
    case blocked
    case active
    case inProgress
    case claimable
    case ready
    case waiting
    case claimed
    case expired
    case idle

    var priority: Int {
        switch self {
        case .blocked: return 0
        case .active: return 1
        case .claimable: return 2
        case .inProgress: return 3
        case .ready: return 4
        case .waiting: return 5
        case .idle: return 6
        case .claimed: return 7
        case .expired: return 8
        }
    }

    var title: String {
        switch self {
        case .blocked: return "Needs Setup"
        case .active: return "Mining Active"
        case .inProgress: return "Mining Active"
        case .claimable: return "Claiming Rewards"
        case .ready: return "Up to Date"
        case .waiting: return "Looking for Streams"
        case .claimed: return "Completed"
        case .expired: return "Ended"
        case .idle: return "Ready to Mine"
        }
    }

    var symbol: String {
        switch self {
        case .blocked: return "exclamationmark.triangle.fill"
        case .active: return "dot.radiowaves.left.and.right"
        case .inProgress: return "dot.radiowaves.left.and.right"
        case .claimable: return "gift.fill"
        case .ready: return "checkmark.circle.fill"
        case .waiting: return "antenna.radiowaves.left.and.right"
        case .claimed: return "checkmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .idle: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: return .orange
        case .active: return .green
        case .inProgress: return .blue
        case .claimable: return .secondary
        case .ready: return .green
        case .waiting: return .secondary
        case .claimed: return .green
        case .expired: return .orange
        case .idle: return .green
        }
    }

    var borderTint: Color {
        switch self {
        case .blocked:
            return .orange.opacity(0.36)
        case .active:
            return .green.opacity(0.28)
        case .claimable:
            return .white.opacity(0.12)
        case .inProgress:
            return .blue.opacity(0.20)
        case .ready, .waiting:
            return .white.opacity(0.12)
        case .claimed:
            return .green.opacity(0.14)
        case .expired:
            return .orange.opacity(0.22)
        case .idle:
            return .white.opacity(0.12)
        }
        
    }
}

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let systemImage: String
    var isMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMuted ? .tertiary : .secondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isMuted ? .secondary : .primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(isMuted ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial.opacity(isMuted ? 0.78 : 0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(isMuted ? 0.08 : 0.14), lineWidth: 1)
        }
        .opacity(isMuted ? 0.82 : 1)
    }
}

struct CampaignMinerInspectorPopover: View {
    let gameName: String
    let miners: [AccountState]
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "personalhotspot")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(gameName)
                    .font(.headline.weight(.semibold))
            }
            .padding(.bottom, 2)

            if miners.isEmpty {
                Text("No actionable miners")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(miners) { account in
                        HStack(spacing: 8) {
                            Group {
                                if isClaimedButNotLinked(account) {
                                    // Green tick, orange question badge: claimed,
                                    // but the game account isn't linked yet.
                                    Image(systemName: "checkmark.circle.badge.questionmark.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.orange, .green)
                                } else {
                                    AnimatedStatusIcon(
                                        symbol: statusIcon(for: account.miningStatus),
                                        color: statusColor(for: account.miningStatus),
                                        size: 13,
                                        weight: .bold
                                    )
                                }
                            }
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 18)
                            .help(isClaimedButNotLinked(account)
                                ? "Claimed, but this game isn't linked on Twitch — the reward won't reach the game until it is."
                                : statusLabel(for: account.miningStatus))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(navigation.minerManager.displayName(forAccountId: account.accountId, fallback: account.username))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                
                                Text(statusLabel(for: account))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            if let progress = account.progressFraction, progress > 0 && progress < 0.995 {
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private func statusIcon(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining: return "bolt.circle.fill"
        case .claimed: return "checkmark.circle.fill"
        case .claimedUnlinked: return "checkmark.circle.badge.questionmark.fill"
        case .ready, .idle: return "pause.circle.fill"
        case .blocked: return SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
        case .needsAuth: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for status: AccountMiningStatus) -> Color {
        switch status {
        case .mining:
            return .green
        case .claimed, .claimedUnlinked:
            return .green
        case .ready, .idle:
            return .secondary
        case .blocked:
            return .orange
        case .needsAuth:
            return .red
        }
    }

    private func statusLabel(for account: AccountState) -> String {
        if isClaimedButNotLinked(account) {
            return "Claimed · not linked"
        }
        return statusLabel(for: account.miningStatus)
    }

    private func statusLabel(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining:
            return "Watching"
        case .claimed:
            return "Claimed"
        case .claimedUnlinked:
            return "Claimed · not linked"
        case .ready, .idle:
            return "Waiting"
        case .blocked:
            return "Unlinked"
        case .needsAuth:
            return "Error"
        }
    }

    private func isClaimedButNotLinked(_ account: AccountState) -> Bool {
        account.miningStatus == .claimedUnlinked
            || (account.miningStatus == .blocked && (account.claimedDropCount > 0 || (account.progressFraction ?? 0) >= 0.995))
    }
}

/// Memory- and disk-backed cache shared by campaign artwork in Drops, Overview,
/// and the miner detail UI. Hashing the full URL keeps different sources and image
/// sizes isolated; Settings' Clear and Redownload action explicitly invalidates it.
actor CampaignArtworkCache {
    static let shared = CampaignArtworkCache()

    private static let defaultDiskByteLimit: Int64 = 256 * 1_024 * 1_024
    private static let defaultDiskFileLimit = 600
    private static let defaultBudgetCheckWriteInterval = 25

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let cacheDirectory: URL?
    private let session: URLSession
    private let diskByteLimit: Int64
    private let diskFileLimit: Int
    private let budgetCheckWriteInterval: Int
    private var hasAppliedDiskBudget = false

    /// Cached files written since the last budget sweep. Pruning enumerates the whole
    /// folder, so it runs once per launch and then only every `budgetCheckWriteInterval`
    /// writes rather than after each of the hundreds of artwork downloads a cold start makes.
    private var writesSinceBudgetCheck = 0

    init(
        cacheDirectory: URL? = nil,
        session: URLSession = .shared,
        diskByteLimit: Int64 = CampaignArtworkCache.defaultDiskByteLimit,
        diskFileLimit: Int = CampaignArtworkCache.defaultDiskFileLimit,
        budgetCheckWriteInterval: Int = CampaignArtworkCache.defaultBudgetCheckWriteInterval
    ) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/CampaignArtwork", isDirectory: true)
        self.session = session
        self.diskByteLimit = diskByteLimit
        self.diskFileLimit = diskFileLimit
        self.budgetCheckWriteInterval = max(1, budgetCheckWriteInterval)
        memory.countLimit = 96
        memory.totalCostLimit = 192 * 1_024 * 1_024
    }

    func image(for url: URL) async -> NSImage? {
        applyDiskBudgetIfNeeded()
        let key = Self.key(for: url)

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else { return nil }
            storeInMemory(image, key: key)
            return image
        }

        if let localURL = cacheDirectory?.appendingPathComponent(key),
           FileManager.default.fileExists(atPath: localURL.path) {
            // Cache keys intentionally have no filename extension. Decode from
            // bytes so ImageIO sniffs the actual format instead of receiving a
            // misleading `public.data` type hint from the extensionless URL.
            if let data = try? Data(contentsOf: localURL),
               let image = NSImage(data: data) {
                storeInMemory(image, key: key, cost: data.count)
                return image
            }
            // A partial or invalid image should never become a permanent miss.
            try? FileManager.default.removeItem(at: localURL)
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            await self?.download(url: url, key: key)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func clearCache() {
        memory.removeAllObjects()
        if let cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private func download(url: URL, key: String) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let image = NSImage(data: data) else {
            return nil
        }

        if let localURL = cacheDirectory?.appendingPathComponent(key) {
            try? FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try data.write(to: localURL, options: .atomic)
                applyDiskBudgetAfterWrite()
            } catch {
                Logger.artwork.warning("Could not cache campaign artwork: \(error.localizedDescription)")
            }
        }
        storeInMemory(image, key: key, cost: data.count)
        return image
    }

    private func applyDiskBudgetIfNeeded() {
        guard !hasAppliedDiskBudget else { return }
        hasAppliedDiskBudget = true
        applyDiskBudget()
    }

    private func applyDiskBudgetAfterWrite() {
        writesSinceBudgetCheck += 1
        guard writesSinceBudgetCheck >= budgetCheckWriteInterval else { return }
        applyDiskBudget()
    }

    private func applyDiskBudget() {
        writesSinceBudgetCheck = 0
        guard let cacheDirectory else { return }
        let result = DiskCacheBudget.prune(
            directory: cacheDirectory,
            maximumBytes: diskByteLimit,
            maximumFileCount: diskFileLimit
        )
        if result.removedFiles > 0 {
            Logger.artwork.info("Pruned \(result.removedFiles) campaign artwork cache file(s), freeing \(result.removedBytes) bytes")
        }
    }

    private func storeInMemory(_ image: NSImage, key: String, cost: Int? = nil) {
        let estimatedCost = image.representations.first.map {
            max(1, $0.pixelsWide * $0.pixelsHigh * 4)
        } ?? 1
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: max(cost ?? 0, estimatedCost)
        )
    }

    private static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct LoadedCampaignArtwork {
    let url: URL
    let image: NSImage
}

struct CampaignCardArtwork: View {
    let url: URL?
    @State private var loadedArtwork: LoadedCampaignArtwork?

    private var resolvedURL: URL? {
        url?.highResolutionArtworkURL
    }

    private var displayedImage: NSImage? {
        guard loadedArtwork?.url == resolvedURL else { return nil }
        return loadedArtwork?.image
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                placeholder

                if let displayedImage {
                    Image(nsImage: displayedImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: resolvedURL) {
            guard let resolvedURL else {
                loadedArtwork = nil
                return
            }

            let image = await CampaignArtworkCache.shared.image(for: resolvedURL)
            guard !Task.isCancelled else { return }
            guard let image else {
                loadedArtwork = nil
                return
            }

            loadedArtwork = LoadedCampaignArtwork(url: resolvedURL, image: image)
        }
    }

    private var placeholder: some View {
        Color(nsColor: .controlBackgroundColor)
    }
}

struct CampaignArtworkIcon: View {
    let url: URL?

    var body: some View {
        CampaignCardArtwork(url: url)
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

actor CampaignArtworkTintSampler {
    static let shared = CampaignArtworkTintSampler()

    private static let ciContext = CIContext()
    private let artworkCache: CampaignArtworkCache
    private var cache: [URL: ArtworkRGB] = [:]
    private var cacheOrder: [URL] = []
    private var inFlight: [URL: Task<ArtworkRGB?, Never>] = [:]
    private let cacheLimit = 256

    init(artworkCache: CampaignArtworkCache = .shared) {
        self.artworkCache = artworkCache
    }

    func tintColor(from artworkURL: URL?) async -> Color? {
        guard let artworkURL else { return nil }

        if let cached = cache[artworkURL] {
            return cached.color
        }

        if let existingTask = inFlight[artworkURL] {
            return await existingTask.value?.color
        }

        let resolvedURL = artworkURL.highResolutionArtworkURL
        let task = Task<ArtworkRGB?, Never> { [artworkCache] in
            guard let image = await artworkCache.image(for: resolvedURL) else { return nil }
            return Self.extractDominantColor(from: image)?.softenedForGlass
        }
        inFlight[artworkURL] = task

        let extracted = await task.value
        inFlight[artworkURL] = nil

        if let extracted {
            cache[artworkURL] = extracted
            cacheOrder.append(artworkURL)
            if cacheOrder.count > cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }

        return extracted?.color
    }

    private static func extractDominantColor(from image: NSImage) -> ArtworkRGB? {
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return ArtworkRGB(
            red: Double(pixel[0]) / 255.0,
            green: Double(pixel[1]) / 255.0,
            blue: Double(pixel[2]) / 255.0
        )
    }
}

@inline(__always) private func clamp01(_ val: Double) -> Double {
    min(max(val, 0.0), 1.0)
}

struct ArtworkRGB: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: clamp01(red), green: clamp01(green), blue: clamp01(blue))
    }

    var softenedForGlass: ArtworkRGB {
        let rWeight = red * 0.299
        let gWeight = green * 0.587
        let bWeight = blue * 0.114
        let luminance = clamp01(rWeight + gWeight + bWeight)
        
        let desaturation: Double = 0.38
        let whiteMix: Double = 0.22

        let rSoft = red * (1.0 - desaturation)
        let gSoft = green * (1.0 - desaturation)
        let bSoft = blue * (1.0 - desaturation)
        
        let lumSoft = luminance * desaturation

        let softenedRed = clamp01(rSoft + lumSoft)
        let softenedGreen = clamp01(gSoft + lumSoft)
        let softenedBlue = clamp01(bSoft + lumSoft)

        let finalRed = (softenedRed * (1.0 - whiteMix)) + whiteMix
        let finalGreen = (softenedGreen * (1.0 - whiteMix)) + whiteMix
        let finalBlue = (softenedBlue * (1.0 - whiteMix)) + whiteMix

        return ArtworkRGB(
            red: clamp01(finalRed),
            green: clamp01(finalGreen),
            blue: clamp01(finalBlue)
        )
    }
}

extension GameAggregateState {
    var asCampaignCardState: CampaignCardState {
        switch self {
        case .actionRequired:
            return .blocked
        case .inProgress:
            return .inProgress
        case .ready:
            return .ready
        case .completed:
            return .claimed
        case .unavailable:
            return .expired
        }
    }
    
    var tint: Color {
        switch self {
        case .actionRequired: return .orange
        case .inProgress: return .green
        case .ready: return .secondary
        case .completed: return .green
        case .unavailable: return .orange
        }
    }
}

extension URL {
    var highResolutionArtworkURL: URL {
        let replacements: [(String, String)] = [
            ("{width}", "1200"),
            ("{height}", "1600"),
            ("%7Bwidth%7D", "1200"),
            ("%7Bheight%7D", "1600")
        ]

        let resolved = replacements.reduce(absoluteString) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }

        return URL(string: resolved) ?? self
    }
}
