#!/usr/bin/env python3
"""LLM evaluation runner for zsh-aisuggestions.

Sends test cases through the running sidecar via Unix socket,
evaluates responses using key-fragment matching, and reports
failures with per-category match rates.

Usage:
    python3 -m tests.eval_llm                          # Run all 80 cases
    python3 -m tests.eval_llm --category rewrite_simple  # One category
    python3 -m tests.eval_llm --case 21                  # Single case
    python3 -m tests.eval_llm --verbose                  # Show all cases
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

# Ensure project root is on the path
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from tests.test_cases import ALL_CASES, CATEGORIES, CATEGORY_LABELS


# ─── Sidecar Communication ──────────────────────────────────────────────────

def get_socket_path():
    # type: () -> str
    uid = os.getuid()
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime_dir, "zsh-aisuggestions-%d.sock" % uid)


def send_request(socket_path, request_dict):
    # type: (str, dict) -> dict
    """Send a JSON request to the sidecar via Unix socket and return the response."""
    payload = json.dumps(request_dict).encode("utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(15)
        sock.connect(socket_path)
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode("utf-8"))
    finally:
        sock.close()


def check_sidecar(socket_path):
    # type: (str) -> bool
    """Check if the sidecar is reachable."""
    if not os.path.exists(socket_path):
        return False
    try:
        resp = send_request(socket_path, {"type": "health"})
        return resp.get("status") == "ok"
    except Exception:
        return False


def start_sidecar(socket_path):
    # type: (str) -> bool
    """Start the sidecar and wait for it to be ready."""
    print("Starting sidecar...")
    # Find python
    python_cmd = sys.executable
    proc = subprocess.Popen(
        [python_cmd, "-m", "sidecar"],
        cwd=PROJECT_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(60):
        if check_sidecar(socket_path):
            print("Sidecar ready (pid=%d)" % proc.pid)
            return True
        time.sleep(0.2)
    print("ERROR: Sidecar failed to start after 12s")
    proc.kill()
    return False


# ─── Evaluation Logic ────────────────────────────────────────────────────────

def extract_insertion(suggestion, original_buffer, cursor_pos):
    # type: (str, str, int) -> Optional[str]
    """Simulate the plugin's prefix/suffix diff to extract ghost text insertion.

    Returns the insertion string, or None if the diff failed (LLM broke
    prefix or suffix).
    """
    prefix = original_buffer[:cursor_pos]
    suffix = original_buffer[cursor_pos:]

    if not suggestion.startswith(prefix):
        return None  # prefix not preserved

    after_prefix = suggestion[len(prefix):]
    if suffix:
        if after_prefix.endswith(suffix):
            insertion = after_prefix[:-len(suffix)]
        else:
            return None  # suffix not preserved
    else:
        # No suffix (cursor at end) — everything after prefix is the insertion
        insertion = after_prefix

    return insertion


def evaluate_case(suggestion, case, verbose=False):
    # type: (str, dict, bool) -> Tuple[bool, str]
    """Evaluate a single suggestion against the case criteria.

    Returns (passed, reason).
    """
    if not suggestion:
        return False, "empty suggestion"

    suggestion_lower = suggestion.lower()

    # For complete mode, verify the insertion can be extracted
    if case["trigger_mode"] == "complete":
        insertion = extract_insertion(suggestion, case["buffer"], case["cursor_position"])
        if insertion is None:
            return False, "prefix/suffix not preserved by LLM"
        if insertion == "":
            return False, "no insertion (LLM returned input unchanged)"

    # Check forbidden fragments
    for frag in case.get("forbidden_fragments", []):
        if frag.lower() in suggestion_lower:
            return False, "contains forbidden: %s" % frag

    # Check required fragments
    for frag in case.get("required_fragments", []):
        if isinstance(frag, tuple):
            # Any of these must match
            if not any(f.lower() in suggestion_lower for f in frag):
                return False, "missing one of: (%s)" % ", ".join(frag)
        else:
            if frag.lower() not in suggestion_lower:
                return False, "missing: %s" % frag

    return True, "ok"


# ─── Runner ──────────────────────────────────────────────────────────────────

def build_sidecar_request(case):
    # type: (dict) -> dict
    """Build the JSON request to send to the sidecar."""
    return {
        "type": "suggest",
        "trigger_mode": case["trigger_mode"],
        "buffer": case["buffer"],
        "cursor_position": case["cursor_position"],
        "context": case["context"],
    }


def run_evaluation(cases, socket_path, verbose=False):
    # type: (List[dict], str, bool) -> List[dict]
    """Run all test cases and return results."""
    results = []
    total = len(cases)

    for i, case in enumerate(cases):
        case_id = case["id"]
        desc = case["description"]

        # Progress indicator
        sys.stdout.write("\r  Running %d/%d (case #%d)..." % (i + 1, total, case_id))
        sys.stdout.flush()

        request = build_sidecar_request(case)
        try:
            response = send_request(socket_path, request)
            suggestion = response.get("suggestion", "")
        except Exception as e:
            suggestion = ""
            response = {"error": str(e)}

        passed, reason = evaluate_case(suggestion, case, verbose)

        result = {
            "case": case,
            "suggestion": suggestion,
            "passed": passed,
            "reason": reason,
            "response": response,
        }
        results.append(result)

        # Small delay to avoid rate limiting
        time.sleep(0.3)

    sys.stdout.write("\r" + " " * 60 + "\r")
    sys.stdout.flush()
    return results


def print_results(results, verbose=False):
    # type: (List[dict], bool) -> None
    """Print evaluation results — failures only by default, all if verbose."""

    # Group by category
    by_category = {}  # type: Dict[str, List[dict]]
    for r in results:
        cat = r["case"]["category"]
        by_category.setdefault(cat, []).append(r)

    # Print failures (or all if verbose)
    failures = [r for r in results if not r["passed"]]
    if failures or verbose:
        print()
        print("=" * 70)
        if verbose:
            print("  ALL CASES")
        else:
            print("  FAILED CASES (%d)" % len(failures))
        print("=" * 70)
        print()

        for r in results:
            if not verbose and r["passed"]:
                continue

            case = r["case"]
            status = "PASS" if r["passed"] else "FAIL"
            print("[%s] #%-3d %s | %s" % (status, case["id"], case["category"], case["description"]))
            print("  Buffer:     %s" % case["buffer"])
            if case["trigger_mode"] == "complete":
                print("  Cursor:     %d (after: %r)" % (
                    case["cursor_position"],
                    case["buffer"][:case["cursor_position"]]))
            print("  Suggestion: %s" % (r["suggestion"] or "(empty)"))
            if not r["passed"]:
                print("  Reason:     %s" % r["reason"])
            # Show insertion for complete mode
            if case["trigger_mode"] == "complete" and r["suggestion"]:
                ins = extract_insertion(r["suggestion"], case["buffer"], case["cursor_position"])
                if ins is not None:
                    print("  Insertion:  %r" % ins)
            print()

    # Summary
    print("=" * 70)
    print("  SUMMARY")
    print("=" * 70)

    cat_order = ["rewrite_simple", "rewrite_complex", "rewrite_context",
                 "complete_end", "complete_mid"]
    total_pass = 0
    total_count = 0

    for cat in cat_order:
        cat_results = by_category.get(cat, [])
        if not cat_results:
            continue
        passed = sum(1 for r in cat_results if r["passed"])
        count = len(cat_results)
        total_pass += passed
        total_count += count
        pct = 100.0 * passed / count if count > 0 else 0
        label = CATEGORY_LABELS.get(cat, cat)
        print("  %-20s %2d/%2d (%5.1f%%)" % (label, passed, count, pct))

    print("  " + "-" * 40)
    pct = 100.0 * total_pass / total_count if total_count > 0 else 0
    print("  %-20s %2d/%2d (%5.1f%%)" % ("Overall", total_pass, total_count, pct))
    print("=" * 70)


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="LLM evaluation for zsh-aisuggestions")
    parser.add_argument("--category", type=str, default=None,
                        help="Run only a specific category")
    parser.add_argument("--case", type=int, default=None,
                        help="Run only a specific case by ID")
    parser.add_argument("--verbose", action="store_true",
                        help="Show all cases, not just failures")
    args = parser.parse_args()

    # Select cases
    if args.case is not None:
        cases = [c for c in ALL_CASES if c["id"] == args.case]
        if not cases:
            print("ERROR: No case with id=%d" % args.case)
            sys.exit(1)
    elif args.category is not None:
        cases = CATEGORIES.get(args.category, [])
        if not cases:
            print("ERROR: Unknown category %r. Available: %s" % (
                args.category, ", ".join(CATEGORIES.keys())))
            sys.exit(1)
    else:
        cases = ALL_CASES

    print("zsh-aisuggestions LLM Evaluation")
    print("  Cases: %d" % len(cases))

    # Ensure sidecar is running
    socket_path = get_socket_path()
    if not check_sidecar(socket_path):
        if not start_sidecar(socket_path):
            sys.exit(1)
    else:
        print("  Sidecar: connected")

    # Get model info
    try:
        health = send_request(socket_path, {"type": "health"})
        print("  Model: %s" % health.get("model", "unknown"))
        print("  API: %s" % health.get("api_base_url", "unknown"))
    except Exception:
        pass

    print()
    print("Running evaluation...")

    results = run_evaluation(cases, socket_path, args.verbose)
    print_results(results, args.verbose)


if __name__ == "__main__":
    main()
