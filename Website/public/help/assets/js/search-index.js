const searchIndex = [
  // Getting Started
  {
    title: "Get Started with SwiftMiner",
    url: "getting-started/",
    category: "Getting Started",
    keywords: "get started download installer setup twitch first launch run install code",
    snippet: "Download and install SwiftMiner, and connect your first Twitch account to begin farming."
  },
  {
    title: "Install SwiftMiner on macOS",
    url: "getting-started/#install-swiftminer",
    category: "Getting Started",
    keywords: "install download application directory security warning block dmg release",
    snippet: "Step-by-step instructions to download, install, and open SwiftMiner on macOS."
  },
  {
    title: "Add your first Twitch account",
    url: "getting-started/#add-your-first-twitch-account",
    category: "Getting Started",
    keywords: "add account link twitch device code activate twitch.tv/activate signin",
    snippet: "Learn how to use the Twitch device-code login flow to authorize SwiftMiner."
  },
  {
    title: "Twitch Drops Miner for Mac",
    url: "twitch-drops-miner-for-mac/",
    category: "Getting Started",
    keywords: "twitch drops miner mac macos native app auto claim watch eligible streams browser tabs without docker multi account squad mining signed notarized sparkle auto update alternative to python scripts",
    snippet: "Learn why SwiftMiner is the best native macOS alternative to Docker/Python miners—featuring Apple notarization, squad mining, and Sparkle auto-updates."
  },
  {
    title: "Auto Claim Twitch Drops on macOS",
    url: "auto-claim-twitch-drops-on-macos/",
    category: "Getting Started",
    keywords: "auto claim twitch drops macos automatic claiming rewards inventory completed drops",
    snippet: "Learn how SwiftMiner automatically claims completed Twitch Drops from macOS."
  },
  {
    title: "Multi-Account Twitch Drops on Mac",
    url: "multi-account-twitch-drops/",
    category: "Getting Started",
    keywords: "multi account twitch drops multiple accounts miners separate sessions priorities mac",
    snippet: "Set up and manage multiple Twitch Drops miners from one Mac."
  },
  {
    title: "Working Twitch Drops Miner for Mac",
    url: "working-twitch-drops-miner/",
    category: "Getting Started",
    keywords: "working twitch drops miner still works maintained current mac automatic claiming channel switching",
    snippet: "What to look for in a maintained Twitch Drops miner and how SwiftMiner handles current Drops campaigns."
  },
  {
    title: "No Docker Required for Twitch Drops Mining",
    url: "twitch-drops-miner-without-docker/",
    category: "Getting Started",
    keywords: "twitch drops miner without docker native mac app no container no compose no server setup battery saver energy efficient silicon m1 m2 m3 m4 intel hypervisor signed notarized",
    snippet: "Run Twitch Drops mining natively on macOS without Docker VM overhead, using a signed app with built-in multi-account support and automatic updates."
  },

  // Main Window
  {
    title: "Using the Main Window",
    url: "main-window/",
    category: "Main Window",
    keywords: "main window navigation sidebar dashboard layout sections tabs overview",
    snippet: "Overview of the primary sections and interface of the SwiftMiner desktop app."
  },
  {
    title: "Overview Dashboard",
    url: "main-window/#overview",
    category: "Main Window",
    keywords: "overview dashboard campaign progress remaining streams speed control panel summary",
    snippet: "Track active campaigns, progress, and running miners from the Overview dashboard."
  },
  {
    title: "Miners Section",
    url: "main-window/#miners",
    category: "Main Window",
    keywords: "miners status channel stream health start stop resume control individual",
    snippet: "Monitor and manage running miners, check stream health, and toggle active sessions."
  },
  {
    title: "Drops Progress",
    url: "main-window/#drops",
    category: "Main Window",
    keywords: "drops progress claimable completed upcoming rewards inventory checklist",
    snippet: "Track in-progress, completed, and upcoming Drops rewards across all accounts."
  },
  {
    title: "Activity Log Feed",
    url: "main-window/#activity-log",
    category: "Main Window",
    keywords: "activity log filter export diagnostics timestamp events claim stream switches error",
    snippet: "Review stream switches, claims, errors, and system status updates in the Activity Log."
  },

  // Settings
  {
    title: "SwiftMiner Settings Guide",
    url: "settings/",
    category: "Settings",
    keywords: "settings guide config preferences menu general accounts mining advanced",
    snippet: "Configure app presence, update channels, logging, and performance options."
  },
  {
    title: "Automatic & Unattended Updates",
    url: "automatic-updates/",
    category: "Settings",
    keywords: "automatic unattended updates sparkle background download install app management permission macos update prompt",
    snippet: "Learn how SwiftMiner checks, downloads, and installs secure updates automatically."
  },
  {
    title: "macOS App Management Permission",
    url: "automatic-updates/#app-management",
    category: "Settings",
    keywords: "app management privacy security permission update replace application authorization sparkle",
    snippet: "Understand why macOS may request App Management permission for unattended SwiftMiner updates."
  },
  {
    title: "General Preferences",
    url: "settings/#general",
    category: "Settings",
    keywords: "general app presence dock menu bar run background start login minimize steam artwork tips",
    snippet: "Manage app launch behavior, Dock / Menu Bar visibility, and visual assets."
  },
  {
    title: "Accounts Settings",
    url: "settings/#accounts",
    category: "Settings",
    keywords: "accounts setting connect reconnect remove delete twitch log out switch account",
    snippet: "Link new Twitch accounts, re-authenticate sessions, and remove accounts."
  },
  {
    title: "Mining Behavior Settings",
    url: "settings/#mining",
    category: "Settings",
    keywords: "mining settings autoclaim auto claim channel points sync state duplicate streams prioritise followed streamers badge emote anti stall anti-stall recovery",
    snippet: "Configure reward claiming, anti-stall recovery, duplicate stream prevention, and stream selection priority."
  },
  {
    title: "Game Rules & Failover Streamers",
    url: "game-rules/",
    category: "Settings",
    keywords: "game rules priorities priority prioritise prioritized exclusions exclude failover backup streamer stalled progress mining strategy smart only selected account global ordering",
    snippet: "Learn how SwiftMiner orders games, applies exclusions, combines account and global priorities, and verifies backup streamers after stalls."
  },
  {
    title: "Configure a Failover Streamer",
    url: "game-rules/#failover-streamers",
    category: "Settings",
    keywords: "failover streamer backup channel twitch login url offline exact campaign stall cooldown ten minutes verify",
    snippet: "Configure a game-specific backup channel and understand when SwiftMiner will—or will not—switch to it."
  },
  {
    title: "Global and Account-Specific Priorities",
    url: "game-rules/#account-priorities",
    category: "Settings",
    keywords: "global personal per account miner priorities use global priorities order duplicates discord web dashboard",
    snippet: "Understand how each miner combines its personal game order with the global priority list."
  },
  {
    title: "Priorities for Operators",
    url: "operator-priorities/",
    category: "Settings",
    keywords: "operator priorities hosting miners for others global personal priority mode strategy instance wide web dashboard swiftbot discord who controls exclusions faq idle miner",
    snippet: "How global and personal priority lists combine when you host miners for other people, plus an operator FAQ."
  },
  {
    title: "Global, Global + Personal, and Personal modes",
    url: "operator-priorities/#priority-modes",
    category: "Settings",
    keywords: "priority mode global personal combined segmented control miners view dashboard default first prioritise duplicates order",
    snippet: "What each priority mode does to a hosted miner's effective game order, with a worked example."
  },
  {
    title: "Why a hosted miner is idle or ignoring a priority",
    url: "operator-priorities/#faq",
    category: "Settings",
    keywords: "operator faq miner idle not mining priority ignored only prioritised empty list needs auth publisher link subscriber only strategy smart",
    snippet: "Operator answers for miners that idle, ignore a priority, or take minutes to switch."
  },
  {
    title: "Excluded Games",
    url: "game-rules/#excluded-games",
    category: "Settings",
    keywords: "exclude excluded games ignore skip all miners precedence priority history cached campaigns",
    snippet: "Exclude a game from mining across every connected account without deleting campaign history."
  },
  {
    title: "Advanced & Logs Config",
    url: "settings/#advanced",
    category: "Settings",
    keywords: "advanced settings log level debug console console show icons animate rows status icons",
    snippet: "Fine-tune diagnostic logging detail, console view, and UI status animations."
  },

  // Web Dashboard
  {
    title: "Web Dashboard Setup",
    url: "web-dashboard/",
    category: "Web Dashboard",
    keywords: "web dashboard remote browser access local port host user password security tunnel oauth twitch client secret",
    snippet: "Access SwiftMiner through a browser, and allow friends to manage their own miners."
  },
  {
    title: "Local Web Dashboard Access",
    url: "web-dashboard/#local-access",
    category: "Web Dashboard",
    keywords: "local access web username password custom port dashboard reach localhost",
    snippet: "Configure local network login credentials and access the browser dashboard."
  },
  {
    title: "Internet Access & Twitch OAuth",
    url: "web-dashboard/#internet-access",
    category: "Web Dashboard",
    keywords: "internet access oauth client id client secret tunnel registration swiftbot remote status sign in",
    snippet: "Configure public internet access using Twitch OAuth and secure tunnels so friends can self-serve."
  },

  // Discord & SwiftBot
  {
    title: "Discord & SwiftBot Integration",
    url: "discord/",
    category: "Discord Help",
    keywords: "discord help swiftbot commands dm setup status integration webhook connect",
    snippet: "Connect SwiftMiner to Discord, check status via commands, and receive Drop alerts."
  },
  {
    title: "Connect Discord Account",
    url: "discord/#connect-discord",
    category: "Discord Help",
    keywords: "connect discord account command miner setup status server dm bot welcome",
    snippet: "Link your Discord account to SwiftMiner by using commands in your server or DMs."
  },
  {
    title: "Connect Twitch via Discord",
    url: "discord/#connect-twitch",
    category: "Discord Help",
    keywords: "connect twitch setup activation code link twitch.tv/activate sign in device",
    snippet: "Use SwiftBot's setup command to link a Twitch account directly from Discord."
  },
  {
    title: "Discord Slash Commands List",
    url: "discord/#slash-commands",
    category: "Discord Help",
    keywords: "slash commands list miner status setup twitch info server commands dm",
    snippet: "Reference for /miner setup, /miner status, and other Discord slash commands."
  },
  {
    title: "SwiftBot DMs & Notifications",
    url: "discord/#dms-notifications",
    category: "Discord Help",
    keywords: "dms notifications alerts drop claimed campaign complete twitch expired session link warning no spam",
    snippet: "Understand which notifications you will (and won't) receive via Discord DMs."
  },

  // Menu Bar Mode
  {
    title: "Menu Bar Mode Guide",
    url: "menu-bar/",
    category: "Menu Bar",
    keywords: "menu bar mode run background closed icon tray control start stop quit export logs diagnostics updates",
    snippet: "Keep SwiftMiner active in the background and control miners from the macOS menu bar."
  },

  // Notifications
  {
    title: "Manage Notifications",
    url: "notifications/",
    category: "Notifications",
    keywords: "notifications enable focus dnd do not disturb alerts claimed complete auth error macos system",
    snippet: "Configure system alerts and troubleshoot blocked or missing notifications."
  },

  // Troubleshooting
  {
    title: "Troubleshooting & FAQs",
    url: "troubleshooting/",
    category: "Troubleshooting",
    keywords: "troubleshooting fix help error needs auth stuck progress logs support debug issues",
    snippet: "Diagnose and resolve login errors, stuck progress, and claiming failures."
  },
  {
    title: "Fix 'Needs Auth' Error",
    url: "troubleshooting/#needs-auth",
    category: "Troubleshooting",
    keywords: "needs auth reconnect twitch activation session expired token expired log out",
    snippet: "How to re-authenticate and restore Twitch connections when authorization expires."
  },
  {
    title: "Resolve Stuck Miners",
    url: "troubleshooting/#miner-stuck",
    category: "Troubleshooting",
    keywords: "stuck progress anti stall active campaign check followed stream recovery stop start",
    snippet: "Steps to recover miners that aren't making progress or have stalled."
  },
  {
    title: "Drops Not Progressing",
    url: "troubleshooting/#drops-not-progressing",
    category: "Troubleshooting",
    keywords: "drops not progressing duplicate viewing streams publisher account link ea riot ubisoft connection browser",
    snippet: "Avoid viewing session conflicts and configure required game publisher account links."
  },
  {
    title: "Twitch Drops Not Progressing on Mac",
    url: "twitch-drops-not-progressing/",
    category: "Troubleshooting",
    keywords: "twitch drops not progressing stuck progress not updating stopped mac swiftminer duplicate viewing account link needs auth",
    snippet: "Focused recovery checklist for stuck Twitch Drops progress in SwiftMiner."
  },
  {
    title: "Export Diagnostic Logs",
    url: "troubleshooting/#export-logs",
    category: "Troubleshooting",
    keywords: "export diagnostic logs support troubleshooting help redacted token files share issues",
    snippet: "How to save and share redacted log files for detailed debugging assistance."
  },

  // Best Practices
  {
    title: "Best Practices & Notes",
    url: "best-practices/",
    category: "Best Practices",
    keywords: "best practices update check duplicate streams publisher link background resources bandwidth",
    snippet: "Tips to maintain maximum farming reliability and optimize system resource usage."
  },

  // Security & Privacy
  {
    title: "Security & Privacy Principles",
    url: "security-privacy/",
    category: "Security & Privacy",
    keywords: "security privacy secure token key keychain encryption credential direct path local twitch code source open",
    snippet: "Learn how SwiftMiner protects your Twitch credentials and operates directly from your Mac."
  },
  {
    title: "Twitch Token Storage (Keychain)",
    url: "security-privacy/#keychain-storage",
    category: "Security & Privacy",
    keywords: "keychain token store security encryption passwords credentials local system apple macos secure",
    snippet: "SwiftMiner stores your Twitch authorization tokens securely in your system macOS Keychain."
  },
  {
    title: "Network Paths & Direct Connections",
    url: "security-privacy/#network-paths",
    category: "Security & Privacy",
    keywords: "network path connect direct twitch api server discord webhooks third party no tracking",
    snippet: "SwiftMiner operates locally on your machine with direct network requests to Twitch. No third-party relays."
  },

  // Reverse Proxy
  {
    title: "Reverse Proxy Setup Guide",
    url: "reverse-proxy/",
    category: "Reverse Proxy",
    keywords: "reverse proxy nginx caddy ssl tls certificates configuration dashboard baseurl port https host headers certs",
    snippet: "Configure a reverse proxy like Nginx or Caddy to safely manage SSL certificates and domain mapping for the Web Dashboard."
  },
  {
    title: "Nginx Proxy Configuration",
    url: "reverse-proxy/#nginx-config",
    category: "Reverse Proxy",
    keywords: "nginx config proxy ssl certificates servername location proxy_pass headers",
    snippet: "Use a standard Nginx virtual host configuration to expose the Web Dashboard over HTTPS."
  },
  {
    title: "Caddy Proxy Configuration",
    url: "reverse-proxy/#caddy-config",
    category: "Reverse Proxy",
    keywords: "caddy caddyfile config reverse_proxy SSL automatic ssl domain",
    snippet: "Set up a simple Caddyfile block for automatic SSL and reverse proxy routing."
  },

  // Under the Hood
  {
    title: "Under the Hood: Technical Architecture",
    url: "under-the-hood/",
    category: "Architecture",
    keywords: "under the hood technical architecture swift concurrency actor tasks async await web server websocket pubsub sqlite network framework framework keychain",
    snippet: "Deep dive into SwiftMiner's underlying architecture, concurrency design, SQLite local caching, and custom web daemon."
  },
  {
    title: "Swift Concurrency Model",
    url: "under-the-hood/#concurrency",
    category: "Architecture",
    keywords: "swift concurrency actor tasks async await mainactor main actor non-blocking ui structured concurrency",
    snippet: "Learn how SwiftMiner uses thread-safe actors and background tasks to handle accounts concurrently."
  },
  {
    title: "Embedded Web Server Engine",
    url: "under-the-hood/#web-server",
    category: "Architecture",
    keywords: "embedded web server network framework tcp socket port daemon lightweight daemon vapor nodejs",
    snippet: "Technical details on how SwiftMiner runs a zero-dependency local web server utilizing Apple's Network.framework."
  }
];
