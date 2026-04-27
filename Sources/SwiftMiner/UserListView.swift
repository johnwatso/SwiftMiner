import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// A view that lists all registered users and their linked accounts.
struct UserListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var selectedStatus: MinerUser.UserStatus? = nil
    
    var filteredUsers: [MinerUser] {
        var users = navigation.registeredUsers
        
        if let selectedStatus {
            users = users.filter { $0.status == selectedStatus }
        }
        
        if !searchText.isEmpty {
            users = users.filter { $0.discordId.contains(searchText) }
        }
        
        return users
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                
                statusFilter
                
                if filteredUsers.isEmpty {
                    emptyState
                } else {
                    userList
                }
            }
            .padding(24)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Discord ID")
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registered Users")
                .font(.title2.weight(.bold))
            
            Text("Manage Discord users registered in the system and view their linked Twitch accounts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusFilter: some View {
        HStack(spacing: 8) {
            FilterChip(title: "All", isSelected: selectedStatus == nil) {
                selectedStatus = nil
            }
            
            ForEach(MinerUser.UserStatus.allCases, id: \.self) { status in
                FilterChip(title: status.rawValue.capitalized, isSelected: selectedStatus == status) {
                    selectedStatus = status
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            let hasSearch = !searchText.isEmpty || selectedStatus != nil
            
            Image(systemName: hasSearch ? "person.text.rectangle" : "person.2.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            
            Text(hasSearch ? "No matching users" : "No users registered")
                .font(.headline)
            
            Text(hasSearch 
                 ? "Try adjusting your search or filters."
                 : "Manual user registration or account assignment will create users here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .glassCard()
    }

    private var userList: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredUsers) { user in
                UserRowView(user: user)
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        await navigation.refreshRegisteredUsers()
        isRefreshing = false
    }
}

private struct UserRowView: View {
    let user: MinerUser
    @Environment(NavigationModel.self) private var navigation
    @State private var accounts: [Account] = []
    @State private var isLoadingAccounts = false
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(user.discordId)
                        .font(.headline.monospaced())
                    
                    HStack {
                        UserStatusBadge(status: user.status)
                        Text("Joined \(user.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            
            if isExpanded {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    if isLoadingAccounts {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if accounts.isEmpty {
                        Text("No linked accounts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .italic()
                            .padding(.vertical, 8)
                    } else {
                        ForEach(accounts) { account in
                            HStack {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Text("@\(account.username)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(account.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.1))
            }
        }
        .glassCard()
        .task(id: isExpanded) {
            if isExpanded && accounts.isEmpty {
                isLoadingAccounts = true
                accounts = await navigation.adminLinkingService.getAccounts(for: user.discordId)
                isLoadingAccounts = false
            }
        }
    }
}

private struct UserStatusBadge: View {
    let status: MinerUser.UserStatus
    
    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.2))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }
    
    private var backgroundColor: Color {
        switch status {
        case .active: return .green
        case .registered: return .blue
        case .suspended: return .red
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    UserListView()
        .environment(NavigationModel(clientId: "preview"))
}
