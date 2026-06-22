// Page Tab Navigation
function switchTab(tabId) {
  const tabs = ['overview', 'sandbox', 'history'];
  tabs.forEach(t => {
    const el = document.getElementById(`tab-${t}`);
    const nav = document.getElementById(`nav-${t}`);
    if (t === tabId) {
      el.classList.remove('hidden');
      el.classList.add('block');
      nav.className = "w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-semibold transition-all duration-200 bg-purple-950/40 text-brand-emerald border-l-2 border-brand-emerald";
    } else {
      el.classList.remove('block');
      el.classList.add('hidden');
      nav.className = "w-full flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-semibold transition-all duration-200 text-slate-400 hover:text-white hover:bg-slate-900";
    }
  });

  // Update Page Title in Header
  const titles = {
    overview: 'Dashboard Overview',
    sandbox: 'Agent Sandbox',
    history: 'Run History'
  };
  document.getElementById('page-title').textContent = titles[tabId] || 'Dashboard';
}

// Mock Run History Archive
let runsHistory = [
  {
    id: "run-9842",
    taskName: "Fix database connection leak",
    model: "Balanced Agent",
    dateTime: "2026-06-19 14:15:32",
    tokens: 42500,
    cost: 0.128,
    duration: 38,
    status: "success",
    logs: [
      "[INFO] Starting Agent Task: Fix database connection leak",
      "[THINK] Scanning workspace for database instances.",
      "[TOOL_CALL] grep_search: SQLiteManager",
      "[RESPONSE] Found definition in SQLiteManager.swift",
      "[THINK] Inspected connection pooling; connection in transaction was not closed under error path.",
      "[TOOL_CALL] replace_file_content: SQLiteManager.swift",
      "[RESPONSE] File updated successfully.",
      "[INFO] Initiating verification phase...",
      "[TOOL_CALL] run_command: xcodebuild test",
      "[RESPONSE] Test Suite passed with 0 failures.",
      "[SUCCESS] Task completed successfully. Connection leak resolved."
    ],
    dag: [
      { id: "init", label: "Initialize Workspace", status: "success" },
      { id: "find", label: "Find Connection Leak", status: "success", parent: "init" },
      { id: "patch", label: "Apply Code Patch", status: "success", parent: "find" },
      { id: "test", label: "Run Integration Tests", status: "success", parent: "patch" }
    ],
    artifacts: [
      { name: "implementation_plan.md", size: "1.4 KB", content: "# Implementation Plan\n\n1. Locate SQLite connection leak.\n2. Add defer block to close DB statement.\n3. Run tests." },
      { name: "SQLiteManager.swift.diff", size: "852 B", content: "@@ -45,5 +45,6 @@\n+ defer {\n+     sqlite3_finalize(statement)\n+ }" }
    ]
  },
  {
    id: "run-9841",
    taskName: "Deploy webhook notification router",
    model: "GPT-4o Mini",
    dateTime: "2026-06-19 13:42:10",
    tokens: 89000,
    cost: 0.053,
    duration: 22,
    status: "success",
    logs: [
      "[INFO] Starting Agent Task: Deploy webhook notification router",
      "[THINK] Analyzing existing webhook configurations.",
      "[TOOL_CALL] read_file: WebDashboardConfig.swift",
      "[RESPONSE] Config retrieved successfully.",
      "[TOOL_CALL] replace_file_content: WebDashboardRoutes.swift",
      "[RESPONSE] Added endpoint '/oauth/swiftbot/callback'.",
      "[SUCCESS] Deployment complete."
    ],
    dag: [
      { id: "init", label: "Read Config", status: "success" },
      { id: "deploy", label: "Add Router Endpoints", status: "success", parent: "init" }
    ],
    artifacts: [
      { name: "WebDashboardRoutes.swift.diff", size: "2.1 KB", content: "@@ -56,6 +56,12 @@\n+ router.register(\"/oauth/swiftbot/callback\") { ... }" }
    ]
  },
  {
    id: "run-9840",
    taskName: "Refactor legacy telemetry queue",
    model: "o1 Pro",
    dateTime: "2026-06-19 12:05:44",
    tokens: 284000,
    cost: 1.84,
    duration: 118,
    status: "failed",
    logs: [
      "[INFO] Starting Agent Task: Refactor legacy telemetry queue",
      "[THINK] High-reasoning model planning memory queue replacement.",
      "[TOOL_CALL] read_file: TelemetryQueue.swift",
      "[RESPONSE] Retrieve 450 lines of telemetry buffer logic.",
      "[THINK] Decided to rewrite queue with Actor-isolated Swift 6 concurrent queue.",
      "[TOOL_CALL] write_file: TelemetryQueue.swift",
      "[RESPONSE] File rewritten.",
      "[TOOL_CALL] run_command: xcodebuild build",
      "[RESPONSE] Error: compile failed - TaskPriority is unavailable in this context.",
      "[THINK] Attempted auto-repair but ran out of time steps.",
      "[ERROR] Task failed due to build configuration issues."
    ],
    dag: [
      { id: "init", label: "Analyze Telemetry", status: "success" },
      { id: "rewrite", label: "Actor Queue Rewrite", status: "success", parent: "init" },
      { id: "build", label: "Verify Compiler Compatibility", status: "failed", parent: "rewrite" }
    ],
    artifacts: [
      { name: "TelemetryQueue.swift", size: "8.2 KB", content: "actor TelemetryQueue {\n  private var buffer: [Event] = []\n}" }
    ]
  }
];

// Initialize Charts
let tokenChart, costChart;

function initCharts() {
  const tokenCtx = document.getElementById('tokenTrendChart').getContext('2d');
  const costCtx = document.getElementById('costBreakdownChart').getContext('2d');

  tokenChart = new Chart(tokenCtx, {
    type: 'line',
    data: {
      labels: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Today'],
      datasets: [
        {
          label: 'Tokens (k)',
          data: [1200, 1500, 950, 1800, 2200, 1600, 2450],
          borderColor: '#9333ea',
          backgroundColor: 'rgba(147, 51, 234, 0.05)',
          fill: true,
          tension: 0.4
        },
        {
          label: 'Cost ($)',
          data: [12, 15, 8.5, 22, 34, 18, 29.5],
          borderColor: '#10b981',
          backgroundColor: 'rgba(16, 185, 129, 0.05)',
          fill: true,
          tension: 0.4,
          yAxisID: 'y1'
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        y: {
          grid: { color: 'rgba(255,255,255,0.05)' },
          ticks: { color: '#94a3b8' }
        },
        y1: {
          position: 'right',
          grid: { drawOnChartArea: false },
          ticks: { color: '#94a3b8' }
        },
        x: {
          grid: { color: 'rgba(255,255,255,0.05)' },
          ticks: { color: '#94a3b8' }
        }
      },
      plugins: {
        legend: { display: false }
      }
    }
  });

  // Cost Breakdown Pie/Doughnut Chart
  costChart = new Chart(costCtx, {
    type: 'doughnut',
    data: {
      labels: ['Balanced Agent', 'GPT-4o Mini', 'o1 Pro'],
      datasets: [{
        data: [78.4, 21.6, 42.8],
        backgroundColor: ['#9333ea', '#3b82f6', '#10b981'],
        borderWidth: 0
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          position: 'bottom',
          labels: { color: '#94a3b8', boxWidth: 12 }
        }
      }
    }
  });
}

// Render Runs Lists
function renderRunsLists() {
  const overviewTbody = document.getElementById('overview-runs-tbody');
  const historyTbody = document.getElementById('history-runs-tbody');
  
  if (overviewTbody) overviewTbody.innerHTML = '';
  if (historyTbody) historyTbody.innerHTML = '';

  // Calculate totals
  let totalCost = 0;
  runsHistory.forEach(r => totalCost += r.cost);
  
  document.getElementById('header-total-cost').textContent = `$${totalCost.toFixed(2)}`;
  document.getElementById('overview-total-cost').textContent = `$${totalCost.toFixed(2)}`;

  runsHistory.forEach((run, idx) => {
    // Determine status badge
    let badgeClass = run.status === 'success' ? 'bg-emerald-500/10 text-brand-emerald border-brand-emerald/20' : 'bg-red-500/10 text-red-400 border-red-500/20';
    if (run.status === 'running') badgeClass = 'bg-blue-500/10 text-blue-400 border-blue-500/20 animate-pulse';

    const rowHTML = `
      <tr class="hover:bg-slate-900/40 transition-colors border-b border-slate-900/60">
        <td class="py-4 px-4 font-mono text-xs text-slate-400">${run.id}</td>
        <td class="py-4 px-4 font-semibold text-white">${run.taskName}</td>
        <td class="py-4 px-4 text-slate-300 text-xs">${run.model}</td>
        ${historyTbody ? `<td class="py-4 px-4 text-slate-400 text-xs">${run.dateTime}</td>` : ''}
        <td class="py-4 px-4 text-slate-300 font-mono text-xs">${run.tokens.toLocaleString()}</td>
        <td class="py-4 px-4 text-slate-300 font-mono text-xs">$${run.cost.toFixed(3)}</td>
        <td class="py-4 px-4 text-slate-300 text-xs">${run.duration}s</td>
        <td class="py-4 px-4">
          <span class="px-2.5 py-0.5 text-xs font-semibold rounded-full border ${badgeClass}">
            ${run.status}
          </span>
        </td>
        ${historyTbody ? `
          <td class="py-4 px-4">
            <button onclick="loadHistoricalRunToSandbox('${run.id}')" class="text-brand-purple hover:text-white font-bold text-xs hover:underline flex items-center gap-1">
              <i class="fa-solid fa-folder-open"></i> Load
            </button>
          </td>` : ''}
      </tr>
    `;

    // Only render top 3 in overview
    if (overviewTbody && idx < 3) {
      overviewTbody.innerHTML += rowHTML;
    }

    if (historyTbody) {
      historyTbody.innerHTML += rowHTML;
    }
  });
}

// Load historical run into sandbox view to check its DAG and terminal output
function loadHistoricalRunToSandbox(runId) {
  const run = runsHistory.find(r => r.id === runId);
  if (!run) return;

  switchTab('sandbox');

  // Draw static historical DAG
  drawDAG(run.dag);

  // Load terminal console
  const consoleEl = document.getElementById('terminal-console');
  consoleEl.innerHTML = '';
  run.logs.forEach(log => {
    appendTerminalLine(log);
  });

  // Load artifacts
  renderArtifactsList(run.artifacts);

  document.getElementById('terminal-status').textContent = `Historical: ${run.id}`;
}

// Filter Run History
function applyHistoryFilters() {
  const searchVal = document.getElementById('history-search').value.toLowerCase();
  const statusFilter = document.getElementById('history-filter-status').value;
  const historyTbody = document.getElementById('history-runs-tbody');
  
  historyTbody.innerHTML = '';

  runsHistory.forEach(run => {
    const matchesSearch = run.taskName.toLowerCase().includes(searchVal) || run.model.toLowerCase().includes(searchVal);
    const matchesStatus = statusFilter === 'all' || run.status === statusFilter;

    if (matchesSearch && matchesStatus) {
      let badgeClass = run.status === 'success' ? 'bg-emerald-500/10 text-brand-emerald border-brand-emerald/20' : 'bg-red-500/10 text-red-400 border-red-500/20';
      if (run.status === 'running') badgeClass = 'bg-blue-500/10 text-blue-400 border-blue-500/20 animate-pulse';

      historyTbody.innerHTML += `
        <tr class="hover:bg-slate-900/40 transition-colors border-b border-slate-900/60">
          <td class="py-4 px-4 font-mono text-xs text-slate-400">${run.id}</td>
          <td class="py-4 px-4 font-semibold text-white">${run.taskName}</td>
          <td class="py-4 px-4 text-slate-300 text-xs">${run.model}</td>
          <td class="py-4 px-4 text-slate-400 text-xs">${run.dateTime}</td>
          <td class="py-4 px-4 text-slate-300 font-mono text-xs">${run.tokens.toLocaleString()}</td>
          <td class="py-4 px-4 text-slate-300 font-mono text-xs">$${run.cost.toFixed(3)}</td>
          <td class="py-4 px-4 text-slate-300 text-xs">${run.duration}s</td>
          <td class="py-4 px-4">
            <span class="px-2.5 py-0.5 text-xs font-semibold rounded-full border ${badgeClass}">
              ${run.status}
            </span>
          </td>
          <td class="py-4 px-4">
            <button onclick="loadHistoricalRunToSandbox('${run.id}')" class="text-brand-purple hover:text-white font-bold text-xs hover:underline flex items-center gap-1">
              <i class="fa-solid fa-folder-open"></i> Load
            </button>
          </td>
        </tr>
      `;
    }
  });
}

// DAG Graph Renderer
function drawDAG(nodes) {
  const dagContainer = document.getElementById('dag-container');
  dagContainer.innerHTML = '';

  if (nodes.length === 0) {
    dagContainer.innerHTML = `
      <div class="text-slate-500 flex flex-col items-center gap-3">
        <i class="fa-solid fa-circle-nodes text-4xl animate-pulse"></i>
        <span>Ready to trigger agent execution.</span>
      </div>`;
    return;
  }

  // Build structure layout based on parent-child relations
  const levels = {};
  const nodeMap = {};

  nodes.forEach(n => {
    nodeMap[n.id] = n;
    n.children = [];
  });

  nodes.forEach(n => {
    if (n.parent && nodeMap[n.parent]) {
      nodeMap[n.parent].children.push(n);
    }
  });

  // Assign depth levels
  function assignLevel(node, lvl) {
    if (!levels[lvl]) levels[lvl] = [];
    if (!levels[lvl].includes(node)) {
      levels[lvl].push(node);
    }
    node.children.forEach(c => assignLevel(c, lvl + 1));
  }

  // Find root nodes
  const roots = nodes.filter(n => !n.parent);
  roots.forEach(r => assignLevel(r, 0));

  const maxLvl = Math.max(...Object.keys(levels).map(Number));

  // Render nodes as a flex/grid layout
  const flexContainer = document.createElement('div');
  flexContainer.className = "flex flex-col gap-12 items-center w-full max-w-2xl relative z-10 py-4";

  // Create SVG layer for lines
  const svgOverlay = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svgOverlay.setAttribute("class", "absolute inset-0 w-full h-full pointer-events-none z-0");
  dagContainer.appendChild(svgOverlay);
  dagContainer.appendChild(flexContainer);

  const renderedElements = {};

  for (let l = 0; l <= maxLvl; l++) {
    const row = document.createElement('div');
    row.className = "flex gap-8 justify-center w-full";
    flexContainer.appendChild(row);

    (levels[l] || []).forEach(node => {
      const nodeEl = document.createElement('div');
      
      let statusColor = "bg-slate-900 border-slate-800 text-slate-400";
      if (node.status === 'running') {
        statusColor = "bg-blue-950/40 border-blue-500/80 text-blue-300 ring-2 ring-blue-500/30 animate-pulse";
      } else if (node.status === 'success') {
        statusColor = "bg-emerald-950/20 border-brand-emerald text-emerald-300 shadow-md shadow-emerald-950/50";
      } else if (node.status === 'failed') {
        statusColor = "bg-red-950/40 border-red-500 text-red-300";
      }

      nodeEl.className = `dag-node px-4 py-2.5 rounded-xl border text-xs font-semibold flex items-center gap-2 select-none shadow-lg ${statusColor}`;
      
      let icon = '<i class="fa-regular fa-circle text-[10px]"></i>';
      if (node.status === 'running') icon = '<i class="fa-solid fa-circle-notch animate-spin text-blue-400"></i>';
      if (node.status === 'success') icon = '<i class="fa-solid fa-circle-check text-brand-emerald"></i>';
      if (node.status === 'failed') icon = '<i class="fa-solid fa-circle-xmark text-red-500"></i>';

      nodeEl.innerHTML = `${icon} ${node.label}`;
      row.appendChild(nodeEl);
      renderedElements[node.id] = nodeEl;
    });
  }

  // Draw connection lines after DOM rendering
  setTimeout(() => {
    const containerRect = dagContainer.getBoundingClientRect();
    svgOverlay.innerHTML = '';

    nodes.forEach(node => {
      if (node.parent && renderedElements[node.parent] && renderedElements[node.id]) {
        const parentRect = renderedElements[node.parent].getBoundingClientRect();
        const childRect = renderedElements[node.id].getBoundingClientRect();

        const x1 = parentRect.left + parentRect.width / 2 - containerRect.left;
        const y1 = parentRect.bottom - containerRect.top;
        const x2 = childRect.left + childRect.width / 2 - containerRect.left;
        const y2 = childRect.top - containerRect.top;

        const line = document.createElementNS("http://www.w3.org/2000/svg", "path");
        // Draw elegant curve
        const d = `M ${x1} ${y1} C ${x1} ${(y1 + y2) / 2}, ${x2} ${(y1 + y2) / 2}, ${x2} ${y2}`;
        line.setAttribute("d", d);
        
        let strokeColor = "rgba(255, 255, 255, 0.08)";
        if (node.status === 'success') strokeColor = "#10b981";
        if (node.status === 'running') strokeColor = "#3b82f6";
        if (node.status === 'failed') strokeColor = "#ef4444";

        line.setAttribute("stroke", strokeColor);
        line.setAttribute("stroke-width", node.status === 'running' ? "2" : "1.5");
        line.setAttribute("fill", "none");
        
        if (node.status === 'running') {
          line.setAttribute("class", "dag-connection-line");
        }
        
        svgOverlay.appendChild(line);
      }
    });
  }, 100);
}

// Append logs line-by-line to Console
function appendTerminalLine(text) {
  const consoleEl = document.getElementById('terminal-console');
  
  // Clear placeholder on first line
  if (consoleEl.children.length === 1 && consoleEl.children[0].classList.contains('text-slate-500')) {
    consoleEl.innerHTML = '';
  }

  const lineEl = document.createElement('div');
  
  // Highlighting key tags
  let lineContent = text
    .replace('[INFO]', '<span class="text-blue-400 font-bold">[INFO]</span>')
    .replace('[THINK]', '<span class="text-purple-400 font-bold">[THINK]</span>')
    .replace('[TOOL_CALL]', '<span class="text-yellow-500 font-bold">[TOOL]</span>')
    .replace('[RESPONSE]', '<span class="text-slate-400">[RESP]</span>')
    .replace('[SUCCESS]', '<span class="text-brand-emerald font-bold">[SUCCESS]</span>')
    .replace('[ERROR]', '<span class="text-red-400 font-bold">[ERROR]</span>');

  lineEl.innerHTML = lineContent;
  consoleEl.appendChild(lineEl);
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

// Render generated artifacts
function renderArtifactsList(artifacts) {
  const drawer = document.getElementById('artifacts-list');
  drawer.innerHTML = '';

  if (artifacts.length === 0) {
    drawer.innerHTML = '<div class="text-xs text-slate-500 italic p-3 text-center">No files generated yet.</div>';
    return;
  }

  artifacts.forEach(art => {
    const card = document.createElement('div');
    card.onclick = () => openArtifactModal(art);
    card.className = "flex items-center justify-between p-2.5 rounded-xl bg-slate-900 border border-slate-850 hover:border-brand-purple cursor-pointer transition-all duration-200";
    card.innerHTML = `
      <div class="flex items-center gap-2.5 min-w-0">
        <i class="fa-solid fa-file-lines text-slate-400"></i>
        <div class="truncate">
          <p class="text-xs font-semibold text-slate-200 truncate">${art.name}</p>
          <span class="text-[9px] text-slate-500">${art.size}</span>
        </div>
      </div>
      <i class="fa-solid fa-chevron-right text-[10px] text-slate-600"></i>
    `;
    drawer.appendChild(card);
  });
}

// Modal management
function openArtifactModal(artifact) {
  document.getElementById('modal-filename').innerHTML = `<i class="fa-solid fa-file-lines text-brand-purple"></i> ${artifact.name}`;
  document.getElementById('modal-filesize').textContent = `Size: ${artifact.size}`;
  document.getElementById('modal-content').textContent = artifact.content;
  document.getElementById('artifact-modal').classList.remove('hidden');
}

function closeModal() {
  document.getElementById('artifact-modal').classList.add('hidden');
}

// Sandbox Simulation Engine
const SIMULATION_TEMPLATES = {
  simple: {
    title: "Fix database connection leak",
    dag: [
      { id: "init", label: "Initialize Workspace", status: "pending" },
      { id: "find", label: "Find Connection Leak", status: "pending", parent: "init" },
      { id: "patch", label: "Apply Code Patch", status: "pending", parent: "find" },
      { id: "test", label: "Run Integration Tests", status: "pending", parent: "patch" }
    ],
    steps: [
      {
        node: "init",
        status: "running",
        log: "[INFO] Initializing workspace analysis of SwiftMiner DB module.",
        artifact: null
      },
      {
        node: "init",
        status: "success",
        log: "[THINK] Workspace active. Found 12 source files in SwiftMinerCore.",
        artifact: null
      },
      {
        node: "find",
        status: "running",
        log: "[TOOL_CALL] grep_search: SQLiteManager.swift",
        artifact: null
      },
      {
        node: "find",
        status: "success",
        log: "[RESPONSE] SQLiteManager.swift contains unclosed sqlite3_stmt pointers in transaction handlers.",
        artifact: { name: "investigation_report.md", size: "900 B", content: "# Telemetry DB Analysis\n\n- Statement leak at line 144.\n- Connection pool is saturated." }
      },
      {
        node: "patch",
        status: "running",
        log: "[TOOL_CALL] replace_file_content: SQLiteManager.swift",
        artifact: null
      },
      {
        node: "patch",
        status: "success",
        log: "[RESPONSE] Code replacement succeeded. Added statement finalize calls.",
        artifact: { name: "sqlite_patch.diff", size: "450 B", content: "@@ -142,5 +142,6 @@\n+ sqlite3_finalize(stmt)" }
      },
      {
        node: "test",
        status: "running",
        log: "[TOOL_CALL] run_command: xcodebuild test",
        artifact: null
      },
      {
        node: "test",
        status: "success",
        log: "[SUCCESS] All unit tests completed. 277 tests passed.",
        artifact: null
      }
    ]
  },
  moderate: {
    title: "Add Discord webhook integration",
    dag: [
      { id: "init", label: "Analyze Webhook Config", status: "pending" },
      { id: "plan", label: "Draft Integration Plan", status: "pending", parent: "init" },
      { id: "create", label: "Create WebhookClient", status: "pending", parent: "plan" },
      { id: "routes", label: "Add Router Endpoints", status: "pending", parent: "create" },
      { id: "verify", label: "Verify Integration", status: "pending", parent: "routes" }
    ],
    steps: [
      {
        node: "init",
        status: "running",
        log: "[INFO] Commencing webhook integration feature.",
        artifact: null
      },
      {
        node: "init",
        status: "success",
        log: "[THINK] Inspecting configuration structure in WebDashboardConfig.swift.",
        artifact: null
      },
      {
        node: "plan",
        status: "running",
        log: "[THINK] Draft implementation plan for endpoint routing.",
        artifact: null
      },
      {
        node: "plan",
        status: "success",
        log: "[SUCCESS] Drafted plan.",
        artifact: { name: "implementation_plan.md", size: "1.2 KB", content: "# Webhook Router Integration\n\n1. Setup route callbacks.\n2. Handle secure query authentication." }
      },
      {
        node: "create",
        status: "running",
        log: "[TOOL_CALL] write_to_file: WebhookClient.swift",
        artifact: null
      },
      {
        node: "create",
        status: "success",
        log: "[RESPONSE] WebhookClient.swift created successfully.",
        artifact: { name: "WebhookClient.swift", size: "3.4 KB", content: "struct WebhookClient {\n  func postMessage(_ msg: String) {}\n}" }
      },
      {
        node: "routes",
        status: "running",
        log: "[TOOL_CALL] replace_file_content: WebDashboardRoutes.swift",
        artifact: null
      },
      {
        node: "routes",
        status: "success",
        log: "[RESPONSE] Injected webhook routes and handler methods.",
        artifact: null
      },
      {
        node: "verify",
        status: "running",
        log: "[TOOL_CALL] run_command: xcodebuild test",
        artifact: null
      },
      {
        node: "verify",
        status: "success",
        log: "[SUCCESS] Target test suite passed.",
        artifact: null
      }
    ]
  },
  complex: {
    title: "Implement SQLite engine state persistence",
    dag: [
      { id: "init", label: "Analyze Memory Cache", status: "pending" },
      { id: "research", label: "Research DB Schema", status: "pending", parent: "init" },
      { id: "plan", label: "Architecture Spec", status: "pending", parent: "research" },
      { id: "schema", label: "Schema Migrations", status: "pending", parent: "plan" },
      { id: "code", label: "Write Serializer Engine", status: "pending", parent: "schema" },
      { id: "warn", label: "Refine Concurrency", status: "pending", parent: "code" },
      { id: "verify", label: "Run Integration Suite", status: "pending", parent: "warn" }
    ],
    steps: [
      {
        node: "init",
        status: "running",
        log: "[INFO] Initializing SQLite persistence layer redesign.",
        artifact: null
      },
      {
        node: "init",
        status: "success",
        log: "[THINK] Profiling current state cache memory limits.",
        artifact: null
      },
      {
        node: "research",
        status: "running",
        log: "[TOOL_CALL] grep_search: SQLite db schema configurations",
        artifact: null
      },
      {
        node: "research",
        status: "success",
        log: "[RESPONSE] Retrieved existing tables and schema layout.",
        artifact: null
      },
      {
        node: "plan",
        status: "running",
        log: "[THINK] Preparing architecture specification plan.",
        artifact: null
      },
      {
        node: "plan",
        status: "success",
        log: "[SUCCESS] Specifications draft completed.",
        artifact: { name: "persistence_spec.md", size: "3.2 KB", content: "# SQLite Persistence Spec\n\n- Thread-safe serialization\n- Backup file safety queues" }
      },
      {
        node: "schema",
        status: "running",
        log: "[TOOL_CALL] replace_file_content: SchemaMigrations.swift",
        artifact: null
      },
      {
        node: "schema",
        status: "success",
        log: "[RESPONSE] Schema migrations updated successfully.",
        artifact: null
      },
      {
        node: "code",
        status: "running",
        log: "[TOOL_CALL] write_to_file: TelemetrySerializer.swift",
        artifact: null
      },
      {
        node: "code",
        status: "success",
        log: "[RESPONSE] TelemetrySerializer implementation created.",
        artifact: { name: "TelemetrySerializer.swift", size: "6.8 KB", content: "class TelemetrySerializer {\n  func serialize(state: State) {}\n}" }
      },
      {
        node: "warn",
        status: "running",
        log: "[TOOL_CALL] run_command: xcodebuild build",
        artifact: null
      },
      {
        node: "warn",
        status: "success",
        log: "[RESPONSE] Found 2 strict concurrency warnings. Fixing actor isolation boundaries.",
        artifact: null
      },
      {
        node: "verify",
        status: "running",
        log: "[TOOL_CALL] run_command: xcodebuild test",
        artifact: null
      },
      {
        node: "verify",
        status: "success",
        log: "[SUCCESS] All unit and performance integration tests succeeded.",
        artifact: null
      }
    ]
  }
};

let isSimulating = false;

function startSandboxSimulation() {
  if (isSimulating) return;

  const model = document.getElementById('config-model').value;
  const speed = document.getElementById('config-speed').value;
  const complexity = document.getElementById('config-complexity').value;
  const webSearch = document.getElementById('config-websearch').checked;

  const template = JSON.parse(JSON.stringify(SIMULATION_TEMPLATES[complexity]));
  
  // Set UI state
  isSimulating = true;
  document.getElementById('btn-run-sandbox').disabled = true;
  document.getElementById('btn-run-sandbox').classList.add('opacity-50', 'cursor-not-allowed');
  document.getElementById('terminal-status').textContent = 'Running...';
  
  // Clear terminal and artifacts list
  document.getElementById('terminal-console').innerHTML = '';
  document.getElementById('artifacts-list').innerHTML = '';

  // Setup speed delays
  let delay = 800;
  if (speed === 'fast') delay = 50;
  if (speed === 'realtime') delay = 2200;

  let currentStep = 0;
  const activeNodes = template.dag;
  const generatedArtifacts = [];

  // Update initial DAG to pending state
  drawDAG(activeNodes);

  // Add search tool log step if webSearch is enabled
  if (webSearch) {
    template.steps.splice(2, 0, {
      node: "init",
      status: "running",
      log: "[TOOL_CALL] search_web: swift concurrency actor models",
      artifact: null
    }, {
      node: "init",
      status: "success",
      log: "[RESPONSE] Retrieved articles on actor-isolated data architectures.",
      artifact: null
    });
  }

  function runNextStep() {
    if (currentStep >= template.steps.length) {
      // Completed!
      isSimulating = false;
      document.getElementById('btn-run-sandbox').disabled = false;
      document.getElementById('btn-run-sandbox').classList.remove('opacity-50', 'cursor-not-allowed');
      document.getElementById('terminal-status').textContent = 'Completed';

      // Update all nodes of DAG to success
      activeNodes.forEach(n => {
        if (n.status !== 'failed') n.status = 'success';
      });
      drawDAG(activeNodes);

      // Save run to archive
      const newRunId = `run-${Math.floor(1000 + Math.random() * 9000)}`;
      const totalTokens = Math.floor(25000 + Math.random() * 150000);
      const isSuccess = activeNodes.every(n => n.status !== 'failed');
      const calculatedCost = (totalTokens / 1000) * (model === 'gpt-4o-mini' ? 0.00015 : model === 'o1-pro' ? 0.015 : 0.003);

      const savedRun = {
        id: newRunId,
        taskName: template.title,
        model: model === 'gpt-4o-mini' ? 'GPT-4o Mini' : model === 'o1-pro' ? 'o1 Pro' : 'Balanced Agent',
        dateTime: new Date().toISOString().replace('T', ' ').substring(0, 19),
        tokens: totalTokens,
        cost: calculatedCost,
        duration: Math.floor((template.steps.length * delay) / 1000),
        status: isSuccess ? "success" : "failed",
        logs: template.steps.map(s => s.log),
        dag: activeNodes,
        artifacts: generatedArtifacts
      };

      runsHistory.unshift(savedRun);
      renderRunsLists();

      // Redraw charts with new data points
      updateCharts(totalTokens, calculatedCost);
      return;
    }

    const step = template.steps[currentStep];
    
    // Update node status
    const targetNode = activeNodes.find(n => n.id === step.node);
    if (targetNode) {
      targetNode.status = step.status;
      drawDAG(activeNodes);
    }

    // Append log line
    appendTerminalLine(step.log);

    // Save artifact if present
    if (step.artifact) {
      generatedArtifacts.push(step.artifact);
      renderArtifactsList(generatedArtifacts);
    }

    currentStep++;
    setTimeout(runNextStep, delay);
  }

  setTimeout(runNextStep, delay);
}

// Update Chart Trends
function updateCharts(tokens, cost) {
  // Append new mock point
  tokenChart.data.datasets[0].data.push(Math.round(tokens / 1000));
  tokenChart.data.datasets[1].data.push(cost);
  tokenChart.data.labels.push(new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
  
  if (tokenChart.data.datasets[0].data.length > 8) {
    tokenChart.data.datasets[0].data.shift();
    tokenChart.data.datasets[1].data.shift();
    tokenChart.data.labels.shift();
  }

  tokenChart.update();
}

// Initial Boot
window.onload = () => {
  initCharts();
  renderRunsLists();
};
