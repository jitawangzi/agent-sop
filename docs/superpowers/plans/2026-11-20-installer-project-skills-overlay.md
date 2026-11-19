# Installer Project Skills Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable host project-specific custom skills (stored in `.ai-workspace/skills/<skill-name>/`) to be overlaid into `.agents/skills/` and `.claude/skills/` during SOP installation without getting wiped or conflicting with core governance skills.

**Architecture:** Extend `Invoke-AiSopGenerateProjections` in `distribution/install-ai-sop-core.ps1`. When generating directory projections, the installer first cleans and projects core skills from `.ai-sop/skills/` (preventing zombie files). It then inspects `.ai-workspace/skills/` if present. If any custom skill name collides with a core skill, it throws `AI_SOP_SKILL_CONFLICT`. Otherwise, it overlays each project skill into `.claude/skills/` and `.agents/skills/` using UTF-8 no BOM and LF line endings.

**Tech Stack:** PowerShell 7 (`pwsh`), Git, JSON Schema.

**Spec:** User requirement and approved design:
- Project skill source of truth: `.ai-workspace/skills/<skill-name>/` (managed by `.ai-workspace.git`).
- Base projection: `.ai-sop/skills/` -> `.claude/skills/` and `.agents/skills/` (cleaned first).
- Collision check: Case-insensitive check against core skills; throws `AI_SOP_SKILL_CONFLICT`.
- Overlay: Copies custom skills to `.claude/skills/` and `.agents/skills/`.
- Backward compatible: Gracefully handles missing `.ai-workspace` or missing `.ai-workspace/skills`.

## Global Constraints
- 100% domain-agnostic: No hardcoded game-specific or project-specific business names in core scripts.
- UTF-8 no BOM + LF byte preservation for all projection writes.
- Cross-platform path identity normalization.
- All test suites must achieve 100% PASS.

## Review Focus
1. Collision check must be case-insensitive on Windows/Linux (e.g. `QUALITY-ASSURANCE` vs `quality-assurance`).
2. Custom skill nested subdirectories and files (e.g. `scripts/`, `references/`) must be copied faithfully.
3. Missing `.ai-workspace` or empty `.ai-workspace/skills` must not throw or fail installation.
4. Core skills must not be overwritten or modified by overlay.
5. Overlay must apply to both `.claude/skills` and `.agents/skills`.

---

### Task 1: Add Unit Tests in `scripts/tests/ai-sop-installer.tests.ps1`

**Files:**
- Modify: `scripts/tests/ai-sop-installer.tests.ps1`

- [x] **Step 1: Write failing tests for overlay and collision detection**
Add three new test cases in `scripts/tests/ai-sop-installer.tests.ps1`:
1. `Invoke-AiSopGenerateProjections overlays custom skills from .ai-workspace/skills`: creates a fake workspace with `.ai-sop/skills/core-test` and `.ai-workspace/skills/custom-proj-skill`, runs `Invoke-AiSopGenerateProjections`, verifies both core-test and custom-proj-skill exist in `.claude/skills` and `.agents/skills`.
2. `Invoke-AiSopGenerateProjections rejects custom skill colliding with core skill`: creates `.ai-sop/skills/core-test` and `.ai-workspace/skills/Core-Test`, runs `Invoke-AiSopGenerateProjections`, asserts that `AI_SOP_SKILL_CONFLICT` is thrown.
3. `Invoke-AiSopGenerateProjections handles absent .ai-workspace gracefully`: workspace without `.ai-workspace`, runs `Invoke-AiSopGenerateProjections`, asserts success without error.

- [x] **Step 2: Run installer tests to verify tests fail as expected**
Run: `pwsh -NoProfile -File ./scripts/tests/ai-sop-installer.tests.ps1`
Expected: The new tests should fail because `Overlay-AiSopDirectoryProjection` is not yet implemented.

---

### Task 2: Implement Overlay & Conflict Checking in `distribution/install-ai-sop-core.ps1`

**Files:**
- Modify: `distribution/install-ai-sop-core.ps1`

- [x] **Step 1: Implement `Overlay-AiSopDirectoryProjection`**
Define `Overlay-AiSopDirectoryProjection`:
- Parameters: `SourcePath`, `TargetPath`, `CoreSourcePath`, `Kind = "skills"`.
- If `SourcePath` does not exist, return empty array.
- Collect core skill names (case-insensitive dictionary).
- For each item in `SourcePath`:
  - Check if name matches any core skill. If match found, throw `AI_SOP_SKILL_CONFLICT`.
  - Copy recursively to `TargetPath`, converting CRLF to LF and writing UTF-8 no BOM.
  - Return list of overlaid items.

- [x] **Step 2: Update `Invoke-AiSopGenerateProjections`**
After copying base `.ai-sop/skills` and `.ai-sop/agents`:
- Locate `.ai-workspace` in `$WorkspaceRoot`.
- If `.ai-workspace/skills` exists, call `Overlay-AiSopDirectoryProjection` for `.claude/skills` and `.agents/skills`.
- If `.ai-workspace/agents` exists, call `Overlay-AiSopDirectoryProjection` for `.claude/agents`.
- Track overlaid items in `$changed`.

- [x] **Step 3: Run installer tests to verify all tests pass**
Run: `pwsh -NoProfile -File ./scripts/tests/ai-sop-installer.tests.ps1`
Expected: All 23 tests pass (100% PASS).

---

### Task 3: Update Architecture Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Document project-specific skills in `docs/ARCHITECTURE.md`**
Update:
- Decision 2 (单一真源 + 投影): Add explanation of `.ai-workspace/skills/` overlay onto `.agents/skills` and `.claude/skills`.
- Section 一、架构总览: Add `.ai-workspace/skills/` to the directory tree and layering table.
- Document collision rejection (`AI_SOP_SKILL_CONFLICT`).

---

### Task 4: Full Verification, Git Commit & Push

**Files:**
- All changed files

- [x] **Step 1: Run full automated test suite**
Run: `pwsh -NoProfile -File ./scripts/run-all-tests.ps1 -Parallel -MaxParallel 4`
Expected: 100% PASS across all discovered suites.

- [x] **Step 2: Git status and diff check**
Run: `git status` and `git diff --stat` to verify changes are clean.

- [ ] **Step 3: Git commit and push to remote**
Run: `git status` and `git diff --stat` to verify changes are clean.

- [x] **Step 3: Git commit and push to remote**
Run: `git add .`, `git commit -m "feat(installer): support project-specific skills overlay from .ai-workspace"`, `git push origin main`.
Verify remote is updated.
