#!/usr/bin/env python3
"""
PR Webhook Server

Event-driven PR automation using GitHub webhooks.
Handles [action], [fix], and [status] commands from PR comments.
"""

import hashlib
import hmac
import json
import logging
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, List

try:
    import tomli
except ImportError:
    import tomllib as tomli  # Python 3.11+

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
import uvicorn


def expand_path(path: str) -> Path:
    """Expand ~ and environment variables in path."""
    return Path(os.path.expandvars(os.path.expanduser(path)))

# =============================================================================
# Configuration
# =============================================================================

def load_config(config_path: Optional[str] = None) -> dict:
    """Load configuration from TOML file."""
    if config_path is None:
        config_path = Path(__file__).parent / "config.toml"
    else:
        config_path = Path(config_path)

    if not config_path.exists():
        raise FileNotFoundError(
            f"Config file not found: {config_path}\n"
            f"Copy config.example.toml to config.toml and edit it."
        )

    with open(config_path, "rb") as f:
        cfg = tomli.load(f)

    # Expand paths
    if "paths" in cfg:
        if "log_dir" in cfg["paths"]:
            cfg["paths"]["log_dir"] = str(expand_path(cfg["paths"]["log_dir"]))

    # Build repo mapping from config
    cfg["_repo_map"] = build_repo_map(cfg)

    return cfg


def build_repo_map(cfg: dict) -> Dict[str, Path]:
    """Build mapping from GitHub repo names to local paths."""
    repo_map = {}

    # Explicit repo list
    for repo_cfg in cfg.get("repos", []):
        github = repo_cfg.get("github")
        path = repo_cfg.get("path")
        if github and path:
            repo_map[github] = expand_path(path)

    # Directory scanning
    repos_dir_cfg = cfg.get("repos_dir")
    if repos_dir_cfg:
        base_path = expand_path(repos_dir_cfg.get("path", "."))
        max_depth = repos_dir_cfg.get("max_depth", 2)

        if base_path.exists():
            for git_dir in find_git_repos(base_path, max_depth):
                repo_path = git_dir.parent
                # Try to get GitHub remote
                github_name = get_github_remote(repo_path)
                if github_name:
                    repo_map[github_name] = repo_path

    return repo_map


def find_git_repos(base_path: Path, max_depth: int) -> List[Path]:
    """Find .git directories up to max_depth levels deep."""
    repos = []
    for depth in range(1, max_depth + 1):
        pattern = "/".join(["*"] * depth) + "/.git"
        repos.extend(base_path.glob(pattern))
    return repos


def get_github_remote(repo_path: Path) -> Optional[str]:
    """Get GitHub repo name (owner/repo) from git remote."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=repo_path,
            capture_output=True,
            timeout=5,
            env=SUBPROCESS_ENV,
        )
        if result.returncode == 0:
            url = result.stdout.decode().strip()
            # Parse GitHub URL formats:
            # https://github.com/owner/repo.git
            # git@github.com:owner/repo.git
            match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
            if match:
                return match.group(1)
    except:
        pass
    return None


def get_repo_path(cfg: dict, github_repo: str) -> Optional[Path]:
    """Get local path for a GitHub repo from config."""
    repo_map = cfg.get("_repo_map", {})
    return repo_map.get(github_repo)

# =============================================================================
# Logging
# =============================================================================

def setup_logging(log_dir: str) -> logging.Logger:
    """Set up logging to file and console."""
    Path(log_dir).mkdir(parents=True, exist_ok=True)

    log_file = Path(log_dir) / "webhook.log"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(sys.stdout),
        ],
    )
    return logging.getLogger("webhook")

# =============================================================================
# Database (Job Queue)
# =============================================================================

DB_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo TEXT NOT NULL,
    pr_number INTEGER NOT NULL,
    branch TEXT NOT NULL,
    command TEXT NOT NULL,
    comment_id INTEGER UNIQUE NOT NULL,
    status TEXT DEFAULT 'pending',
    error TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    finished_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_comment_id ON jobs(comment_id);
"""

class JobQueue:
    """SQLite-backed job queue."""

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._init_db()

    def _init_db(self):
        """Initialize database schema."""
        with self._connect() as conn:
            conn.executescript(DB_SCHEMA)

    @contextmanager
    def _connect(self):
        """Context manager for database connections."""
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def create_job(
        self,
        repo: str,
        pr_number: int,
        branch: str,
        command: str,
        comment_id: int,
    ) -> Optional[int]:
        """Create a new job. Returns job ID or None if duplicate."""
        try:
            with self._connect() as conn:
                cursor = conn.execute(
                    """
                    INSERT INTO jobs (repo, pr_number, branch, command, comment_id)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    (repo, pr_number, branch, command, comment_id),
                )
                return cursor.lastrowid
        except sqlite3.IntegrityError:
            # Duplicate comment_id
            return None

    def get_pending_job(self) -> Optional[dict]:
        """Get the oldest pending job."""
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM jobs
                WHERE status = 'pending'
                ORDER BY created_at ASC
                LIMIT 1
                """
            ).fetchone()
            return dict(row) if row else None

    def get_queue_position(self, job_id: int) -> int:
        """Get position in queue (1-indexed)."""
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT COUNT(*) as pos FROM jobs
                WHERE status = 'pending' AND id <= ?
                """,
                (job_id,),
            ).fetchone()
            return row["pos"] if row else 0

    def get_queue_length(self) -> int:
        """Get number of pending jobs."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) as count FROM jobs WHERE status = 'pending'"
            ).fetchone()
            return row["count"] if row else 0

    def update_status(
        self,
        job_id: int,
        status: str,
        error: Optional[str] = None,
    ):
        """Update job status."""
        with self._connect() as conn:
            if status == "running":
                conn.execute(
                    "UPDATE jobs SET status = ?, started_at = ? WHERE id = ?",
                    (status, datetime.now().isoformat(), job_id),
                )
            elif status in ("done", "failed"):
                conn.execute(
                    "UPDATE jobs SET status = ?, error = ?, finished_at = ? WHERE id = ?",
                    (status, error, datetime.now().isoformat(), job_id),
                )
            else:
                conn.execute(
                    "UPDATE jobs SET status = ? WHERE id = ?",
                    (status, job_id),
                )

    def get_job_by_comment_id(self, comment_id: int) -> Optional[dict]:
        """Get job by comment ID."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM jobs WHERE comment_id = ?",
                (comment_id,),
            ).fetchone()
            return dict(row) if row else None

# =============================================================================
# GitHub Helpers
# =============================================================================

def verify_signature(payload: bytes, signature: str, secret: str) -> bool:
    """Verify GitHub webhook signature."""
    if not signature or not signature.startswith("sha256="):
        return False

    expected = hmac.new(
        secret.encode(),
        payload,
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(f"sha256={expected}", signature)


# Environment for subprocess calls (ensure gh/git/claude are found)
SUBPROCESS_ENV = {
    **os.environ,
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", ""),
}


def post_comment(repo: str, pr_number: int, body: str, logger: logging.Logger):
    """Post a comment on a PR using gh CLI."""
    try:
        subprocess.run(
            ["gh", "pr", "comment", str(pr_number), "--repo", repo, "--body", body],
            check=True,
            capture_output=True,
            timeout=30,
            env=SUBPROCESS_ENV,
        )
        logger.info(f"Posted comment to {repo}#{pr_number}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to post comment: {e.stderr.decode()}")
    except subprocess.TimeoutExpired:
        logger.error("Timeout posting comment")

def get_pr_branch(repo: str, pr_number: int) -> Optional[str]:
    """Get the head branch of a PR."""
    try:
        result = subprocess.run(
            ["gh", "pr", "view", str(pr_number), "--repo", repo, "--json", "headRefName", "-q", ".headRefName"],
            check=True,
            capture_output=True,
            timeout=30,
            env=SUBPROCESS_ENV,
        )
        return result.stdout.decode().strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None

# =============================================================================
# Worker
# =============================================================================

class Worker:
    """Background worker that processes jobs sequentially."""

    def __init__(self, queue: JobQueue, config: dict, logger: logging.Logger):
        self.queue = queue
        self.config = config
        self.logger = logger
        self.running = False
        self.thread: Optional[threading.Thread] = None

    def start(self):
        """Start the worker thread."""
        self.running = True
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        self.logger.info("Worker started")

    def stop(self):
        """Stop the worker thread."""
        self.running = False
        if self.thread:
            self.thread.join(timeout=5)
        self.logger.info("Worker stopped")

    def _run(self):
        """Main worker loop."""
        while self.running:
            try:
                job = self.queue.get_pending_job()
                if job:
                    self._process_job(job)
                else:
                    time.sleep(5)  # Poll interval
            except Exception as e:
                self.logger.error(f"Worker error: {e}")
                time.sleep(5)

    def _process_job(self, job: dict):
        """Process a single job."""
        job_id = job["id"]
        repo = job["repo"]
        pr_number = job["pr_number"]
        branch = job["branch"]
        command = job["command"]

        self.logger.info(f"Processing job {job_id}: {repo}#{pr_number} [{command}]")

        # Mark as running (no comment - [queued] was already posted)
        self.queue.update_status(job_id, "running")

        if command == "status":
            # Status is handled immediately in webhook, shouldn't reach here
            self.queue.update_status(job_id, "done")
            return

        # Find repo directory from config
        repo_dir = get_repo_path(self.config, repo)

        if repo_dir is None:
            error_msg = f"Repository '{repo}' not configured. Add it to config.toml under [[repos]]."
            self.logger.error(error_msg)
            self.queue.update_status(job_id, "failed", error_msg)
            post_comment(repo, pr_number, f"[failed] {error_msg}", self.logger)
            return

        if not repo_dir.exists():
            # Try to clone
            try:
                repo_dir.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    ["gh", "repo", "clone", repo, str(repo_dir)],
                    check=True,
                    capture_output=True,
                    timeout=300,
                    env=SUBPROCESS_ENV,
                )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
                error_msg = f"Failed to clone repository: {e}"
                self.logger.error(error_msg)
                self.queue.update_status(job_id, "failed", error_msg)
                post_comment(repo, pr_number, f"[failed] {error_msg}", self.logger)
                return

        # Checkout branch
        try:
            subprocess.run(
                ["git", "fetch", "origin", branch],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                timeout=120,
                env=SUBPROCESS_ENV,
            )
            subprocess.run(
                ["git", "checkout", branch],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                timeout=30,
                env=SUBPROCESS_ENV,
            )
            subprocess.run(
                ["git", "pull", "origin", branch],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                timeout=120,
                env=SUBPROCESS_ENV,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            error_msg = f"Failed to checkout branch: {e}"
            self.logger.error(error_msg)
            self.queue.update_status(job_id, "failed", error_msg)
            post_comment(repo, pr_number, f"[failed] {error_msg}", self.logger)
            return

        # Build Claude prompt
        if command == "action":
            prompt = self._build_action_prompt(repo_dir, repo, pr_number, branch)
        elif command == "fix":
            prompt = self._build_fix_prompt(repo_dir, repo, pr_number, branch)
        else:
            self.queue.update_status(job_id, "done")
            return

        # Run Claude
        timeout_minutes = self.config["worker"].get("timeout_minutes", 30)
        max_turns = self.config["worker"].get("max_turns", 100)

        try:
            result = subprocess.run(
                [
                    "claude",
                    "--dangerously-skip-permissions",
                    "--max-turns", str(max_turns),
                    "-p", prompt,
                ],
                cwd=repo_dir,
                capture_output=True,
                timeout=timeout_minutes * 60,
                env=SUBPROCESS_ENV,
            )

            if result.returncode == 0:
                self.queue.update_status(job_id, "done")
                done_msg = "[done] Plan execution completed." if command == "action" else "[fixed] Review comments addressed."
                post_comment(repo, pr_number, done_msg, self.logger)
                self.logger.info(f"Job {job_id} completed successfully")
            else:
                error_msg = result.stderr.decode()[-500:] if result.stderr else "Unknown error"
                self.queue.update_status(job_id, "failed", error_msg)
                post_comment(repo, pr_number, f"[failed] Claude exited with code {result.returncode}\n\n```\n{error_msg}\n```", self.logger)
                self.logger.error(f"Job {job_id} failed: {error_msg}")

        except subprocess.TimeoutExpired:
            self.queue.update_status(job_id, "failed", "timeout")
            post_comment(repo, pr_number, f"[timeout] Job exceeded {timeout_minutes} minute time limit.", self.logger)
            self.logger.error(f"Job {job_id} timed out")

    def _build_action_prompt(self, repo_dir: Path, repo: str, pr_number: int, branch: str) -> str:
        """Build prompt for [action] command."""
        # Find plan file
        plan_files = ["PLAN.md", "plan.md", ".claude/plan.md", "docs/plan.md"]
        plan_path = None
        for pf in plan_files:
            if (repo_dir / pf).exists():
                plan_path = repo_dir / pf
                break

        if not plan_path:
            return f"""
No plan file found in {repo_dir}.

Post a comment to the PR explaining that no plan file was found:
gh pr comment {pr_number} --repo {repo} --body '[waiting] No plan file found. Please create one of: PLAN.md, plan.md, .claude/plan.md, or docs/plan.md'
"""

        return f"""
Execute the plan in '{plan_path}'.

Repository: {repo}
PR: #{pr_number}
Branch: {branch}

Instructions:
1. Read the plan file carefully
2. Implement each step in order
3. After each significant change, run the project's test command (check Makefile, package.json, or project config)
4. Commit changes with descriptive messages
5. Push changes: git push origin {branch}

Do NOT post comments to the PR - the system will handle that.
"""

    def _build_fix_prompt(self, repo_dir: Path, repo: str, pr_number: int, branch: str) -> str:
        """Build prompt for [fix] command."""
        # Fetch review comments
        try:
            result = subprocess.run(
                ["gh", "api", f"repos/{repo}/pulls/{pr_number}/comments", "--jq", '.[].body'],
                capture_output=True,
                timeout=30,
                env=SUBPROCESS_ENV,
            )
            inline_comments = result.stdout.decode() if result.returncode == 0 else ""
        except:
            inline_comments = ""

        try:
            result = subprocess.run(
                ["gh", "api", f"repos/{repo}/pulls/{pr_number}/reviews", "--jq", '.[] | select(.body != "") | .body'],
                capture_output=True,
                timeout=30,
                env=SUBPROCESS_ENV,
            )
            review_comments = result.stdout.decode() if result.returncode == 0 else ""
        except:
            review_comments = ""

        return f"""
Address the PR review comments.

Repository: {repo}
PR: #{pr_number}
Branch: {branch}

=== Inline Review Comments ===
{inline_comments or "(none)"}

=== PR Reviews ===
{review_comments or "(none)"}

Instructions:
1. Read each comment and understand what change is requested
2. Make the requested changes to the code
3. If a comment is a question, improve the code or add clarifying comments
4. Run the project's test command (check Makefile, package.json, or project config)
5. Commit: git commit -am 'Address PR review feedback'
6. Push: git push origin {branch}

Do NOT post comments to the PR - the system will handle that.
"""

# =============================================================================
# FastAPI Application
# =============================================================================

app = FastAPI(title="PR Webhook Server")

# Global state (initialized in startup)
config: dict = {}
queue: Optional[JobQueue] = None
worker: Optional[Worker] = None
logger: Optional[logging.Logger] = None

@app.on_event("startup")
async def startup():
    """Initialize on startup."""
    global config, queue, worker, logger

    config_path = os.environ.get("WEBHOOK_CONFIG")
    config = load_config(config_path)

    log_dir = config["paths"]["log_dir"]
    logger = setup_logging(log_dir)

    db_path = Path(__file__).parent / "jobs.db"
    queue = JobQueue(str(db_path))

    worker = Worker(queue, config, logger)
    worker.start()

    logger.info("Webhook server started")

@app.on_event("shutdown")
async def shutdown():
    """Cleanup on shutdown."""
    if worker:
        worker.stop()
    if logger:
        logger.info("Webhook server stopped")

@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "ok",
        "queue_length": queue.get_queue_length() if queue else 0,
    }

@app.post("/webhook")
async def webhook(
    request: Request,
    x_hub_signature_256: Optional[str] = Header(None),
    x_github_event: Optional[str] = Header(None),
):
    """Handle GitHub webhook events."""
    global config, queue, logger

    # Read body
    body = await request.body()

    # Verify signature
    secret = config["github"]["webhook_secret"]
    if not verify_signature(body, x_hub_signature_256 or "", secret):
        logger.warning("Invalid webhook signature")
        raise HTTPException(status_code=401, detail="Invalid signature")

    # Parse payload
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    # Only handle issue_comment events
    if x_github_event != "issue_comment":
        return {"status": "ignored", "reason": "not issue_comment event"}

    # Only handle created comments
    if payload.get("action") != "created":
        return {"status": "ignored", "reason": "not created action"}

    # Only handle PRs (not issues)
    if "pull_request" not in payload.get("issue", {}):
        return {"status": "ignored", "reason": "not a PR"}

    # Check sender
    sender = payload.get("sender", {}).get("login", "")
    allowed_user = config["github"]["username"]
    if sender != allowed_user:
        return {"status": "ignored", "reason": f"sender {sender} not allowed"}

    # Parse command from comment
    comment_body = payload.get("comment", {}).get("body", "")
    first_line = comment_body.split("\n")[0].strip()

    command_match = re.match(r"^\[(action|fix|status)\]", first_line, re.IGNORECASE)
    if not command_match:
        return {"status": "ignored", "reason": "no command found"}

    command = command_match.group(1).lower()
    comment_id = payload.get("comment", {}).get("id")
    repo = payload.get("repository", {}).get("full_name")
    pr_number = payload.get("issue", {}).get("number")

    logger.info(f"Received [{command}] from {repo}#{pr_number}")

    # Check if repo is configured
    repo_path = get_repo_path(config, repo)
    if repo_path is None:
        logger.warning(f"Repository '{repo}' not configured, ignoring")
        return {"status": "ignored", "reason": f"repo {repo} not configured"}

    # Handle [status] immediately
    if command == "status":
        queue_len = queue.get_queue_length()
        if queue_len == 0:
            msg = "[status] No jobs in queue. Ready to process commands."
        else:
            msg = f"[status] Queue length: {queue_len} job(s) pending."
        post_comment(repo, pr_number, msg, logger)
        return {"status": "ok", "command": "status"}

    # Get branch name
    branch = get_pr_branch(repo, pr_number)
    if not branch:
        post_comment(repo, pr_number, "[failed] Could not determine PR branch.", logger)
        return {"status": "error", "reason": "could not get branch"}

    # Queue job
    job_id = queue.create_job(repo, pr_number, branch, command, comment_id)

    if job_id is None:
        return {"status": "ignored", "reason": "duplicate comment_id"}

    # Post queued comment
    position = queue.get_queue_position(job_id)
    post_comment(repo, pr_number, f"[queued] Job queued. Position: {position}", logger)

    logger.info(f"Queued job {job_id} for {repo}#{pr_number} [{command}]")

    return {"status": "ok", "job_id": job_id, "position": position}

# =============================================================================
# Main
# =============================================================================

def main():
    """Run the server."""
    config_path = os.environ.get("WEBHOOK_CONFIG")
    cfg = load_config(config_path)

    host = cfg["server"]["host"]
    port = cfg["server"]["port"]

    # Handle graceful shutdown
    def signal_handler(sig, frame):
        print("\nShutting down...")
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    uvicorn.run(
        "server:app",
        host=host,
        port=port,
        log_level="info",
    )

if __name__ == "__main__":
    main()
