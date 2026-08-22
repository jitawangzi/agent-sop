# Agent-SOP

> **The Enterprise AI Agent Governance & Execution Engine**  
> *Deterministic Guardrails, Cryptographic Gates, and Lifecycle OS for AI Coding Agents*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell: 7+](https://img.shields.io/badge/PowerShell-7.0%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Harness: Claude Code | Antigravity | Cursor | Copilot](https://img.shields.io/badge/Harness-Claude%20Code%20|%20Antigravity%20|%20Cursor%20|%20Copilot-green.svg)](#supported-harnesses)
[![Tests: 100% Pass](https://img.shields.io/badge/Tests-15%2F15%20PASS-brightgreen.svg)](#testing--verification)

---

## 📖 Overview

**Agent-SOP** is an industrial-grade governance platform and runtime engine designed for autonomous AI coding agents (Claude Code, Antigravity, Cursor, GitHub Copilot, etc.).

While generative AI models are probabilistic, enterprise software engineering demands **100% determinism, security, and strict quality gates**. Agent-SOP bridges this gap by wrapping autonomous AI agents in an operating-system-level physical sandbox with cryptographic verification, transactional multi-agent locks, and structured software development standard operating procedures.

---

## ⚡ Core Innovations & Features

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        Agent-SOP Architecture                          │
│                                                                        │
│  [ Claude Code ]    [ Antigravity ]    [ Cursor ]    [ Copilot ]       │
│        │                  │                 │             │            │
│        └──────────────────┼─────────────────┴─────────────┘            │
│                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ PreToolUse Hook & AST Safety Layer (Physical Interception)       │  │
│  │  - Path normalization (prevents traversal & symlink escapes)     │  │
│  │  - Active Owner lease check & Short-lived CommandGrant (TTL)     │  │
│  └─────────────────────────────────┬────────────────────────────────┘  │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Deterministic Verification & State Engine (Schema 1.1)           │  │
│  │  - 01 Requirement Gate (SHA-256 Anti-Tamper)                     │  │
│  │  - 06 Design Contract Gate (Machine Audit via design-reviewer)   │  │
│  │  - 05 Executable Test Coverage Matrix (Machine-Checkable)        │  │
│  │  - Two-Phase Commit Transaction Coordinator (2PC Journals)       │  │
│  └─────────────────────────────────┬────────────────────────────────┘  │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Target Workspace (SVN Working Copies / Git Monorepo / Isolations)│  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### 1. 🛡️ OS-Level Physical PreToolUse Hook Guard
- **No Un-Leased Writes**: Any attempt by an AI agent to modify source code without an `ACTIVE` claimed owner lease is **physically intercepted and rejected** at the OS hook layer (`guard-production-edit.ps1`).
- **AST Intent Validation**: Command and file mutation intents are parsed using native PowerShell Abstract Syntax Trees (AST) and normalized canonical paths, preventing path traversal or injection bypasses.

### 2. 🔐 Cryptographic SHA-256 Anti-Drift Gates
- **Requirement & Design Immutability**: Specifications (`01_server_rules.md` and `06_design_contract.md`) are cryptographically hashed upon human approval.
- **Anti-Tampering**: If an AI agent attempts to alter acceptance criteria to disguise a flawed implementation, the SHA-256 verification immediately fails and triggers a workflow circuit breaker.

### 3. 🔒 Multi-Harness Transactional Locking (Schema 1.1)
- **Two-Phase Commit (2PC)**: Session, owner, and command-grant mutations use ordered file locking (`Session -> Owner -> Grant`) and atomic crash-safe journal logging (`workflow-transaction.ps1`).
- **Idempotence & Self-Healing**: Direct terminal invocations automatically bootstrap short-lived grants without losing transactional audit trails.

### 4. ⚡ Execution Intensity Tiers (T-Tiers)
Avoids massive token waste for trivial changes:
- **T3 (Full Governance)**: Brainstorming $\rightarrow$ Requirement Gate $\rightarrow$ Design Audit $\rightarrow$ Writing Plans $\rightarrow$ TDD Subagents $\rightarrow$ Dual Logic/Implementation Audits $\rightarrow$ Final Code Review $\rightarrow$ Completion Gate.
- **T2 (Fast Patch)**: Claim ownership $\rightarrow$ Edit $\rightarrow$ Compile $\rightarrow$ Targeted Tests $\rightarrow$ Deliver.
- **T1 (Emergency Rush)**: Minimal compile verification with fallback guard.
- **FastTrack**: 1-step zero-gate execution for pure configuration values or documentation wording.

### 5. 🏢 Enterprise Hybrid VCS & Parallel Runtime Isolation
- Native support for **SVN Working Copies** and **Git Submodules**.
- Dynamic allocation of isolated feature runtime ports, directory bases, and test instances for concurrent multi-agent development (`feature-runtime.ps1`).

---

## 🚀 Quick Start

### 1. Integration into Any Existing Project

To introduce Agent-SOP into any existing repository (Java, Go, C++, Python, Rust, Frontend, etc.):

#### Option A: Git Submodule (Recommended for Git Repositories)
```bash
# In your project root:
git submodule add https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
```

#### Option B: Standalone Clone (For SVN or Non-Git Repositories)
```powershell
# In your project root:
git clone https://github.com/jitawangzi/agent-sop.git .ai-sop
pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 -Mode Auto -Action Install
```

> **Note**: The installer automatically generates the unified `ai-sop.ps1` entry point, IDE hooks (`.agents/`, `.claude/`, `.cursor/`, `.github/`), and initial governance projections in your project root.

### 2. Environment Self-Check

```powershell
pwsh -NoProfile -File ./ai-sop.ps1 Doctor
```

### 3. Start Developing with Any AI Agent

Simply instruct your AI coding assistant (Claude Code / Antigravity / Cursor):

```text
Develop new feature ShopBuyLimit under .ai-workspace/specs/features/ShopBuyLimit/
```

Agent-SOP will automatically claim ownership, guide requirement exploration, enforce dual approval gates, orchestrate TDD, and perform completion verification.

---

## 🛠️ Supported Harnesses

| Harness / Tool | Tier Access | Workflow Controller | Notes |
|---|:---:|:---:|---|
| **Claude Code** | `STRICT` (Full T3) | Superpowers | Native PreToolUse hook integration |
| **Antigravity** | `STRICT` (Full T3) | Superpowers | Multi-agent subagent orchestration |
| **Cursor** | `STRICT` (Full T3) | Superpowers | Hook & rules projection |
| **GitHub Copilot** | `STRICT` (Full T3) | Superpowers | Task / Subagent bridge |
| **Pi / Minimal CLI**| `BLOCKED` (T2 only)| Native Prompt | Auto-graceful degradation to T2 patch |

---

## 🧪 Testing & Verification

Agent-SOP includes a comprehensive, self-contained automated test suite covering state machines, AST security, concurrency locks, and transaction journals:

```powershell
pwsh -NoProfile -File ./scripts/run-all-tests.ps1
```

```text
Running 15 test suite(s) from ./scripts/tests (serial)
ai-sop-installer.tests                     PASS
doc-script-contract.tests                  PASS
e2e-t2-smoke.tests                         PASS
feature-runtime.tests                      PASS
guard-production-edit.tests                PASS
harness-capability.tests                   PASS
hook-dedup.tests                           PASS
hook-dispatcher.tests                      PASS
hook-event-normalizer.tests                PASS
run-all-tests.tests                        PASS
workflow-command-grant.tests               PASS
workflow-owner.tests                       PASS
workflow-session.tests                     PASS
workflow-state.tests                       PASS
workflow-transaction.tests                 PASS
-----------------------------------------------
15/15 test suites passed (100% GREEN)
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
