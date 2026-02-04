# rcode

Scientific computing workspace containing Rust libraries for tensor networks, quantum computing, and NP-hard optimization.

## Projects

| Project | Description |
|---------|-------------|
| [omeco](./omeco) | Tensor network contraction order optimization |
| [problem-reductions](./problem-reductions) | NP-hard problem definitions and reductions |
| [yao-rs](./yao-rs) | Quantum circuit description and tensor export |
| [tropical-gemm](./tropical-gemm) | High-performance tropical matrix multiplication |
| [omeinsum-rs](./omeinsum-rs) | Einstein summation for tensor networks |
| [dyad](./dyad) | Quantum chemistry (Unrestricted Hartree-Fock) |
| [tn-mcp-rs](./tn-mcp-rs) | MCP Server for tensor network operations |

## PR Automation

This workspace includes an automated PR processing system using GitHub webhooks.

### Quick Start

```bash
# One-time setup
make setup

# Start services (auto-restart on boot)
make services-start

# Check status
make status
```

### PR Commands

Comment on any PR to trigger automation:

| Command | Action |
|---------|--------|
| `[action]` | Execute the plan file (PLAN.md) |
| `[fix]` | Address review comments |
| `[status]` | Check queue status |

### Make Targets

```bash
make help              # Show all available targets
```

**Setup:**
```bash
make setup             # Full setup (deps + webhook wizard)
make install-deps      # Install Python dependencies only
make webhook-setup     # Run webhook setup wizard
```

**Services (launchd - recommended):**
```bash
make services-install  # Install launchd services
make services-start    # Start all services
make services-stop     # Stop all services
make services-status   # Check service status
```

**Services (manual - for testing):**
```bash
make webhook-start     # Start webhook server (foreground)
make tunnel-start      # Start Cloudflare tunnel (foreground)
make webhook-stop      # Stop webhook server
make tunnel-stop       # Stop tunnel
```

**Monitoring:**
```bash
make status            # Check webhook health and queue
make logs              # Tail all logs
make logs-webhook      # Tail webhook server logs
make logs-tunnel       # Tail tunnel logs
```

**Maintenance:**
```bash
make clean-logs        # Remove log files older than 7 days
make test-webhook      # Test webhook endpoint
```

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Webhook ──► Cloudflare Tunnel ──► Webhook Server ──► Job Queue ──► Claude Worker
                                              │                                │
                                              └──────── Status Comments ◄──────┘
```

See [docs/plans/2026-02-04-pr-webhook-design.md](./docs/plans/2026-02-04-pr-webhook-design.md) for detailed design.

## Configuration

After running `make setup`, edit `.claude/webhook/config.toml`:

```toml
[github]
username = "your-username"      # Only your comments trigger jobs
webhook_secret = "..."          # Generated during setup

[worker]
timeout_minutes = 30            # Max job runtime
max_turns = 100                 # Max Claude API turns
```

## Directory Structure

```
rcode/
├── .claude/
│   ├── webhook/           # Webhook server
│   │   ├── server.py      # FastAPI app + worker
│   │   ├── config.toml    # Configuration
│   │   └── jobs.db        # SQLite job queue
│   ├── scripts/           # Automation scripts
│   ├── skills/            # Claude Code skills
│   ├── launchd/           # macOS service plists
│   └── logs/              # Log files
├── docs/plans/            # Design documents
├── Makefile               # Workspace automation
├── CLAUDE.md              # Claude Code guidance
└── <projects>/            # Individual Rust projects
```

## License

Each subproject has its own license. See individual project directories.
