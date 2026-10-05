#!/usr/bin/env python3
"""Opt-in official CPU probability reference; consumes pre-frozen compiler inputs.

Never installs packages, downloads weights, discovers model locations or reads keys.
Both the source package and its pinned Qwen base must already exist in explicitly
provided directories/cache. Freeze --runtime-lock before invoking this command.
Each reference case gets one owned CPU child, a 120-second deadline, no retry and
a partial receipt on failure. This is parity evidence, not a quality benchmark.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import sys
import time
from pathlib import Path

import local_browser_pairing as transport
import bosun_transport as owned_transport

PACKAGES = ("torch", "transformers", "peft", "tokenizers", "safetensors", "huggingface-hub", "accelerate")
FOLLOWUP_SHA256 = 'e38226f7018dd2657ef2f259ea97570896c607b3942337a6e77313f3b1a9610f'
INITIAL_FAILURE_SHA256 = '509a8875a0672a376d25168b85911933fdf316a7546361d1b8d8b95195a9497c'
ORIGINAL_LOCK_SHA256 = '98a4e5f427f0d1ee2a022e7af827a9bdc9cf0449ff73b6452704353079b269fd'
CORRECTED_LOCK_SHA256 = '5c3eae1d51577ccdb8db0dfaef5cf0c0eeb7e60d1f0a785e936e91186c8151a8'


def file_hash(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1_048_576), b""):
            value.update(block)
    return value.hexdigest()


def validate_runtime(lock: dict, plan: dict) -> None:
    if lock.get("schema") != "fritz-bosun-cpu-runtime-lock-v1":
        raise ValueError("runtime lock must be independently frozen before any model call")
    if sys.version.split()[0] != plan.get("python") or plan.get("python") != lock.get("python"):
        raise ValueError("actual reference interpreter differs from frozen plan or lock")
    if any(lock["packages"].get(name) != plan["packages"][name] for name in PACKAGES):
        raise ValueError("runtime versions differ from the pre-inference model plan")
    if not lock.get("wheels"):
        raise ValueError("runtime lock must retain every resolved binary wheel size/SHA")
    for name, version in lock["packages"].items():
        if importlib.metadata.version(name) != version:
            raise ValueError(f"installed CPU reference version differs from lock: {name}")


def verify_models(args, plan: dict) -> None:
    base = args.cache_dir / "models--Qwen--Qwen3-0.6B" / "snapshots" / plan["base_revision"]
    for directory, files in ((args.source_dir, plan["source_files"]), (base, plan["base_files"])):
        for artifact in files:
            path = directory / artifact["file"]
            if path.stat().st_size != artifact["size"] or file_hash(path) != artifact["sha256"]:
                raise ValueError(f"official CPU model artifact size/checksum differs: {artifact['file']}")


def worker(args, row: dict, plan: dict) -> dict:
    # No Hub library is imported before this explicit offline configuration.
    os.environ.update({"HF_HOME": str(args.cache_dir), "HF_TOKEN_PATH": str(args.cache_dir / "unused-token"),
                       "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "TRANSFORMERS_OFFLINE": "1"})
    if (args.cache_dir / "unused-token").exists():
        raise ValueError("explicit reference cache contains an unexpected credential file")
    verify_models(args, plan)
    # These imports and all model calls are restricted to the separately authorized CPU stage.
    import torch
    from transformers import AutoModelForCausalLM

    torch.set_num_threads(4)
    model = AutoModelForCausalLM.from_pretrained(
        str(args.source_dir), local_files_only=True, trust_remote_code=True,
        token=False, cache_dir=str(args.cache_dir), torch_dtype=torch.float32,
        attn_implementation="eager")
    model.to("cpu")
    model.eval()
    result = model.predict(state=row["request"]["state"],
                           instructions=json.loads(row["content"])["question"]["instructions"],
                           candidates=row["candidates"],
                           decision_type=row["request"]["questions"][row["question_name"]]["type"],
                           seed=0, row_id=row["row_id"])
    tokens = model.tokenizer(result["prompt"], truncation=False)["input_ids"]
    if result["prompt"] != row["prompt"] or tokens != row["token_ids"] or result["candidate_to_slot"] != row["candidate_to_slot"]:
        raise ValueError("official loaded model's prompt/token/slot contract differs from frozen compiler reference")
    first = next(model.model.parameters())
    if first.device.type != "cpu" or first.dtype != torch.float32:
        raise ValueError("CPU reference unexpectedly used another device or weight dtype")
    probabilities = result["probabilities"]
    if len(probabilities) != len(row["candidates"]) or any(not math.isfinite(p) or p < 0 for p in probabilities) or math.fsum(probabilities) <= 0:
        raise ValueError("official CPU reference returned an invalid probability distribution")
    return {"case_id": row["case_id"], "question_name": row["question_name"],
            "request": row["request"],
            "content": result["content"], "prompt": result["prompt"], "token_ids": tokens,
            "candidate_to_slot": result["candidate_to_slot"], "slot_logits": result["slot_logits"],
            "slot_probabilities": result["slot_probabilities"], "probabilities": result["probabilities"]}


def save(path: Path, document: dict) -> None:
    transport.write_json(path, document, replace=path.exists())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler-reference", type=Path, default=Path(__file__).parent / "fixtures/bosun-compiler-reference.json")
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--runtime-lock", type=Path, required=True)
    parser.add_argument("--runtime-plan", type=Path, default=Path(__file__).parent / "fixtures/bosun-cpu-runtime-plan.json")
    parser.add_argument("--runtime-plan-sha256", required=True)
    parser.add_argument("--runtime-lock-sha256", required=True)
    parser.add_argument("--compiler-reference-sha256", required=True)
    parser.add_argument("--cleanup-followup", type=Path, required=True)
    parser.add_argument("--cleanup-followup-sha256", required=True)
    parser.add_argument("--initial-failure", type=Path, required=True)
    parser.add_argument("--initial-failure-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--worker-index", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    for path in (args.source_dir, args.cache_dir):
        if not path.is_absolute() or not path.is_dir():
            parser.error("source and cache directories must be explicit existing absolute paths")
    for path, expected in ((args.runtime_plan, args.runtime_plan_sha256), (args.runtime_lock, args.runtime_lock_sha256), (args.compiler_reference, args.compiler_reference_sha256)):
        if file_hash(path) != expected:
            parser.error("a frozen reference/runtime input changed")
    followup = {"preregistration": transport.pin(args.cleanup_followup),
                "initial_failure": transport.pin(args.initial_failure)}
    if (followup["preregistration"]["sha256"] != args.cleanup_followup_sha256
        or args.cleanup_followup_sha256 != FOLLOWUP_SHA256
        or followup["initial_failure"]["sha256"] != args.initial_failure_sha256
        or args.initial_failure_sha256 != INITIAL_FAILURE_SHA256
        or args.runtime_lock_sha256 != CORRECTED_LOCK_SHA256):
        parser.error("the separate corrected cohort must retain its frozen follow-up, initial failure and corrected lock")
    initial = transport.strict_json(args.initial_failure.read_bytes())
    if initial.get("status") != "failed":
        parser.error("the initial failed reference must remain failed")
    transport_protocol = owned_transport.provenance()
    lock = transport.strict_json(args.runtime_lock.read_bytes())
    plan = transport.strict_json(args.runtime_plan.read_bytes())
    if lock.get("original_lock_sha256") != ORIGINAL_LOCK_SHA256 or lock.get("preparer_python") != "3.14.7":
        parser.error("corrected lock must retain original lock and metadata-preparer provenance")
    validate_runtime(lock, plan)
    raw_compiler = args.compiler_reference.read_bytes()
    compiler = transport.strict_json(raw_compiler)
    if compiler["schema"] != "fritz-bosun-compiler-reference-v1" or any(row["probabilities"] is not None for row in compiler["rows"]):
        parser.error("require the pre-inference compiler/tokenizer reference")
    if args.worker_index is not None:
        result = worker(args, compiler["rows"][args.worker_index], plan)
        print(json.dumps({"type":"result","result":result}, ensure_ascii=False, allow_nan=False), flush=True)
        return
    if not args.output.is_absolute() or args.output.exists():
        parser.error("output must be new; previous reference attempts are retained")
    if not args.output.parent.exists():
        args.output.parent.mkdir(mode=0o700)
    if args.output.parent.stat().st_mode & 0o077 or args.output.parent.stat().st_uid != os.getuid():
        parser.error("output must belong to this user in an explicit 0700 directory")
    # A new output freezes runtime/version/input provenance before the first owned model child.
    document = {"schema": "fritz-bosun-cpu-reference-v1", "status": "running", "rows": [], "attempts": [],
                "compiler_reference_sha256": hashlib.sha256(raw_compiler).hexdigest(),
                "transport_protocol": transport_protocol, "followup": followup,
                "driver": transport.pin(Path(__file__).resolve()),
                "reference_interpreter": {"version": sys.version.split()[0],
                    "executable": transport.pin(Path(sys.executable).resolve(), executable=True)},
                "runtime_lock": lock, "runtime_lock_sha256": file_hash(args.runtime_lock),
                "generator_sha256": file_hash(Path(__file__)), "runtime_plan_sha256": file_hash(args.runtime_plan),
                "source_revision": plan["source_revision"], "base_revision": plan["base_revision"],
                "source_files": plan["source_files"], "base_files": plan["base_files"],
                "settings": {"device": "cpu", "dtype": "float32", "attention": "eager", "threads": 4,
                             "attempts_per_case": 1, "child_deadline_seconds": 120, "generation": False}}
    save(args.output, document)
    try:
        verify_models(args, plan)
    except BaseException as error:
        document.update(status="failed",error=f"{type(error).__name__}: {error}")
        save(args.output,document)
        raise
    env = {name: os.environ[name] for name in ("PATH", "TMPDIR", "LANG", "LC_ALL") if name in os.environ}
    env.update({"HF_HOME": str(args.cache_dir), "HF_TOKEN_PATH": str(args.cache_dir / "unused-token"),
                "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "TRANSFORMERS_OFFLINE": "1", "NETRC": "/dev/null"})
    for index, row in enumerate(compiler["rows"]):
        started = time.monotonic()
        attempt = {"case_id": row["case_id"], "status": "running"}
        document["attempts"].append(attempt)
        save(args.output, document)
        command = [sys.executable, str(Path(__file__).resolve()), "--compiler-reference", str(args.compiler_reference.resolve()),
                   "--source-dir", str(args.source_dir), "--cache-dir", str(args.cache_dir), "--runtime-lock", str(args.runtime_lock.resolve()),
                   "--runtime-plan", str(args.runtime_plan.resolve()),
                   "--runtime-plan-sha256", args.runtime_plan_sha256,
                   "--runtime-lock-sha256", args.runtime_lock_sha256,
                   "--compiler-reference-sha256", args.compiler_reference_sha256,
                   "--cleanup-followup", str(args.cleanup_followup),
                   "--cleanup-followup-sha256", args.cleanup_followup_sha256,
                   "--initial-failure", str(args.initial_failure),
                   "--initial-failure-sha256", args.initial_failure_sha256,
                   "--output", str(args.output.resolve()), "--worker-index", str(index)]
        attempt_directory = args.output.parent / f"attempt-{index+1:02d}"
        attempt_directory.mkdir(mode=0o700)
        try:
            receipt = owned_transport.evaluate_child(command,b"{}",env,attempt_directory,timeout=120)
            cleanup = receipt["cleanup"]
            attempt.update(transport=receipt,cleanup={**cleanup,"forced_kill":"SIGKILL" in cleanup.get("signals",[])})
            if cleanup.get("succeeded") is not True or cleanup.get("exit_code") != 0 or attempt["cleanup"]["forced_kill"] or receipt.get("transport_error") or receipt.get("deadline_expired"):
                raise ValueError("official CPU reference child failed or cleanup is unknown")
            event = receipt.get("terminal")
            if not isinstance(event,dict) or event.get("type") != "result" or not isinstance(event.get("result"),dict):
                raise ValueError("official CPU reference returned an invalid terminal")
            result = event["result"]
            document["rows"].append(result)
            attempt["status"] = "complete"
        except BaseException as error:
            if isinstance(error,owned_transport.InterruptedAttempt):
                receipt=error.receipt
                cleanup=receipt["cleanup"]
                attempt.update(transport=receipt,cleanup={**cleanup,"forced_kill":"SIGKILL" in cleanup.get("signals",[])})
            attempt.update({"status": "failed", "error": f"{type(error).__name__}: {error}", "elapsed_seconds": time.monotonic()-started})
            document["status"] = "failed"
            save(args.output, document)
            raise
        attempt["elapsed_seconds"] = time.monotonic()-started
        save(args.output, document)
    document["status"] = "complete"
    save(args.output, document)
    print(json.dumps({"output": str(args.output), "rows": len(document["rows"]), "status": "complete"}))


if __name__ == "__main__":
    main()
