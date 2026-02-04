# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workspace Overview

This is a Rust-based scientific computing workspace containing 7 interconnected projects for tensor networks, quantum computing, NP-hard optimization, and numerical algorithms. All projects are Rust libraries (Edition 2021) with optional Python bindings via PyO3/Maturin.

## Projects

| Project | Purpose | Python Bindings |
|---------|---------|-----------------|
| `omeco` | Tensor network contraction order optimization | Yes |
| `problem-reductions` | NP-hard problem definitions and reductions | No |
| `yao-rs` | Quantum circuit description and tensor export | Yes |
| `tropical-gemm` | High-performance tropical matrix multiplication (SIMD/CUDA) | Yes |
| `omeinsum-rs` | Einstein summation for tensor networks | No |
| `dyad` | Quantum chemistry (Unrestricted Hartree-Fock) | No |
| `tn-mcp-rs` | MCP Server for tensor network operations | Python-native |

## Common Commands

All projects use Make for build automation with consistent targets:

```bash
make build              # Build workspace (debug)
make build-release      # Build in release mode
make test               # Run all tests
make clippy             # Lint (warnings = errors)
make fmt                # Format code
make fmt-check          # Check formatting
make check-all          # fmt-check + clippy + test (run before commits)
make doc                # Build and open rustdoc
make build-book         # Build mdBook documentation
make serve-book         # Serve mdBook at localhost:3000
```

For Python bindings (where applicable):
```bash
make python-dev         # Build and install locally
make python-test        # Run pytest
```

## Dependency Graph

```
tn-mcp-rs (Python + Rust)
    └── yao-rs
        └── omeco

omeinsum-rs
    ├── omeco (contraction order)
    └── tropical-gemm (optional, tropical algebras)

dyad (standalone)
problem-reductions (standalone)
```

## Project-Specific Guidelines

### omeco
- **CRITICAL: Must stay aligned with [OMEinsumContractionOrders.jl](https://github.com/TensorBFS/OMEinsumContractionOrders.jl)**
- Check Julia implementation at `~/.julia/dev/OMEinsumContractionOrders/` before changes
- Tests marked "ALIGNED WITH JULIA" must not be modified without explicit instruction
- Run comparative benchmarks to verify alignment
- See `omeco/.claude/CLAUDE.md` for full guidelines

### problem-reductions
- Every reduction requires a closed-loop test (create → reduce → solve → extract → verify)
- Use `#[reduction(...)]` macro for automatic inventory registration
- Coverage must exceed 95%
- Run `make export-graph` after adding reductions
- See `problem-reductions/.claude/CLAUDE.md` and `.claude/rules/` for patterns

### tropical-gemm
- Supports SIMD (AVX-512, AVX2, SSE4.1, NEON) and CUDA backends
- Three semirings: MaxPlus, MinPlus, MaxMul
- PyTorch integration available

### yao-rs
- Port from [Yao.jl](https://github.com/QuantumBFS/Yao.jl)
- Edition 2024

## Code Conventions

- No panics/unwraps in production code (tests only)
- All public items must have doc comments with examples
- Clippy warnings treated as errors (`-D warnings`)
- Use `thiserror` for error types
- Generic parameters preferred over concrete types
- Serde for serialization (JSON support standard)

## Testing

- Rust: inline `#[test]` modules + `/tests` directories
- Python: pytest via `maturin develop`
- Benchmarks: criterion for Rust, comparative scripts with Julia implementations
- Coverage tools: cargo-llvm-cov, tarpaulin

## Automation

### PR Webhook System (Recommended)

Event-driven PR automation using GitHub webhooks. More reliable than polling.

**Setup:**
```bash
.claude/scripts/setup-webhook.sh
```

**Commands (as PR comments):**

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md) |
| `[fix]` | Address review comments |
| `[status]` | Check queue status |

**Status comments (bot responses):**

| Status | Meaning |
|--------|---------|
| `[queued]` | Job added to queue |
| `[executing]` | Plan execution started |
| `[done]` | Completed successfully |
| `[failed]` | Error with details |
| `[timeout]` | Exceeded time limit |

**Architecture:** GitHub Webhook → Cloudflare Tunnel → FastAPI Server → SQLite Queue → Claude Worker

See `docs/plans/2026-02-04-pr-webhook-design.md` for details.

### Legacy: Polling-based Scripts

```bash
# One-shot (cron)
.claude/scripts/pr-cron.sh /path/to/workspace

# Daemon mode
.claude/scripts/pr-monitor.sh --workspace . --interval 1800
```
