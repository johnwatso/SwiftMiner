import SwiftUI
import SwiftMinerCore
import AppKit

/// The miner activity section of Overview.
extension OverviewView {
    // MARK: - Miner Activity

    var minerActivitySection: some View {
        let miners = displayedMiners

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionHeading("Miner Activity")

                Button {
                    isMinerStatusLegendPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Explain miner card statuses")
                .popover(isPresented: $isMinerStatusLegendPresented, arrowEdge: .top) {
                    MinerStatusLegendPopover()
                }

                Spacer()

                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a Twitch account")
            }

            if miners.isEmpty {
                MaterialEmptyStatePanel(
                    "No Twitch accounts connected",
                    systemImage: "person.badge.plus",
                    description: "Add an account to see what each miner is mining now."
                ) {
                    Button {
                        navigation.showAddAccountSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: minerActivityColumns, spacing: 14) {
                    ForEach(miners) { miner in
                        MinerActivityCard(miner: miner, prominence: .compact, onSelect: {
                            navigation.selectedMinerId = miner.id
                            navigation.selectedItem = .miners
                        })
                    }
                }
            }
        }
    }

    /// Wide enough that a card stays readable, narrow enough that five miners sit on
    /// one row at a typical Overview width. Miners have no meaningful order, so the
    /// grid wraps beyond that rather than scrolling.
    private var minerActivityColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 244), spacing: 14, alignment: .top)]
    }

    var activeCampaignCount: Int {
        let now = Date()
        return campaigns
            .filter { campaign in
                campaign.isAccountConnected
                    && campaign.startDate <= now
                    && campaign.endDate > now
                    && !campaign.isCompleted
                    && campaign.overviewRemainingRewardCount > 0
            }
            .count
    }
}
