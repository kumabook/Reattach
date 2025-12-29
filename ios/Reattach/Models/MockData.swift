//
//  MockData.swift
//  Reattach
//

import Foundation

enum MockData {
    static let sessions: [Session] = [
        Session(
            name: "dev",
            attached: true,
            windows: [
                Window(
                    index: 0,
                    name: "claude",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "dev:0.0", currentPath: "/Users/demo/projects/myapp")
                    ]
                ),
                Window(
                    index: 1,
                    name: "vim",
                    active: false,
                    panes: [
                        Pane(index: 0, active: true, target: "dev:1.0", currentPath: "/Users/demo/projects/myapp/src")
                    ]
                ),
                Window(
                    index: 2,
                    name: "server",
                    active: false,
                    panes: [
                        Pane(index: 0, active: true, target: "dev:2.0", currentPath: "/Users/demo/projects/myapp"),
                        Pane(index: 1, active: false, target: "dev:2.1", currentPath: "/Users/demo/projects/myapp/logs")
                    ]
                )
            ]
        ),
        Session(
            name: "tools",
            attached: false,
            windows: [
                Window(
                    index: 0,
                    name: "htop",
                    active: true,
                    panes: [
                        Pane(index: 0, active: true, target: "tools:0.0", currentPath: "/Users/demo")
                    ]
                ),
                Window(
                    index: 1,
                    name: "docker",
                    active: false,
                    panes: [
                        Pane(index: 0, active: true, target: "tools:1.0", currentPath: "/Users/demo/docker")
                    ]
                )
            ]
        )
    ]

    static func output(for target: String) -> String {
        switch target {
        case "dev:0.0":
            return claudeOutput
        case "dev:1.0":
            return vimOutput
        case "dev:2.0":
            return serverOutput
        case "dev:2.1":
            return logsOutput
        case "tools:0.0":
            return htopOutput
        case "tools:1.0":
            return dockerOutput
        default:
            return "$ "
        }
    }

    private static let claudeOutput = """
╭─────────────────────────────────────────────────────────────────╮
│ ✻ Welcome to Claude Code!                                       │
│                                                                 │
│   /help for help, /status for your current setup               │
│                                                                 │
│   cwd: /Users/demo/projects/myapp                              │
╰─────────────────────────────────────────────────────────────────╯

> Help me understand this codebase

I'll analyze the codebase structure for you.

Looking at the project, this appears to be a Swift iOS application with
the following structure:

  myapp/
  ├── Sources/
  │   ├── App/
  │   ├── Models/
  │   ├── Views/
  │   └── Services/
  ├── Tests/
  └── Package.swift

The main components are:
• App - Application entry point and configuration
• Models - Data structures and business logic
• Views - SwiftUI views for the UI
• Services - API and networking layer

Would you like me to dive deeper into any specific area?

>
"""

    private static let vimOutput = """
  1 import SwiftUI
  2
  3 struct ContentView: View {
  4     @State private var items: [Item] = []
  5     @State private var isLoading = false
  6
  7     var body: some View {
  8         NavigationStack {
  9             List(items) { item in
 10                 ItemRow(item: item)
 11             }
 12             .navigationTitle("Items")
 13             .task {
 14                 await loadItems()
 15             }
 16         }
 17     }
 18
 19     private func loadItems() async {
 20         isLoading = true
 21         items = await API.shared.fetchItems()
 22         isLoading = false
 23     }
 24 }
~
~
~
"ContentView.swift" 24L, 512B
"""

    private static let serverOutput = """
$ npm run dev

> myapp@1.0.0 dev
> next dev

  ▲ Next.js 14.0.4
  - Local:        http://localhost:3000
  - Environments: .env.local

 ✓ Ready in 1.2s
 ○ Compiling / ...
 ✓ Compiled / in 856ms (287 modules)
 GET / 200 in 45ms
 GET /api/items 200 in 12ms
 GET /api/items 200 in 8ms
"""

    private static let logsOutput = """
$ tail -f app.log

[2024-01-15 10:23:45] INFO  Server started on port 3000
[2024-01-15 10:23:46] INFO  Database connected
[2024-01-15 10:24:01] INFO  GET /api/items - 200 (12ms)
[2024-01-15 10:24:15] INFO  GET /api/items - 200 (8ms)
[2024-01-15 10:24:32] INFO  POST /api/items - 201 (45ms)
[2024-01-15 10:25:01] INFO  GET /api/items - 200 (10ms)
[2024-01-15 10:25:45] WARN  Rate limit approaching for IP 192.168.1.100
[2024-01-15 10:26:12] INFO  GET /api/items/42 - 200 (5ms)
"""

    private static let htopOutput = """
  1  [|||||||||||||||||||                    45.2%]   Tasks: 156, 423 thr; 2 running
  2  [|||||||||                              22.1%]   Load average: 1.23 0.98 0.87
  3  [||||||||||||||                         35.8%]   Uptime: 5 days, 12:34:56
  4  [|||||||                                18.4%]
  Mem[|||||||||||||||||||||||||        4.2G/16.0G]
  Swp[                                   0K/2.00G]

    PID USER      PRI  NI  VIRT   RES   SHR S CPU%  MEM%   TIME+  Command
  12345 demo       20   0 2048M  512M  128M S 12.3   3.2  1:23.45 node server.js
  12346 demo       20   0 1024M  256M   64M S  8.1   1.6  0:45.12 npm run watch
  12347 demo       20   0  512M  128M   32M S  2.4   0.8  0:12.34 tail -f app.log
      1 root       20   0  128M   12M    8M S  0.0   0.1  0:05.67 /sbin/init
    456 root       20   0   64M    8M    4M S  0.0   0.0  0:02.34 /usr/sbin/sshd
"""

    private static let dockerOutput = """
$ docker ps

CONTAINER ID   IMAGE          COMMAND                  STATUS          PORTS                    NAMES
a1b2c3d4e5f6   postgres:15    "docker-entrypoint.s…"   Up 2 hours      0.0.0.0:5432->5432/tcp   myapp-db
b2c3d4e5f6a7   redis:7        "docker-entrypoint.s…"   Up 2 hours      0.0.0.0:6379->6379/tcp   myapp-cache
c3d4e5f6a7b8   nginx:latest   "/docker-entrypoint.…"   Up 2 hours      0.0.0.0:80->80/tcp       myapp-proxy

$
"""
}
