#!/usr/bin/env python3
"""Opt-in supervisor for an already-built Bosun native parity test executable.

No build, download or credentials. Bind the retained native readout to the CPU
reference, compiled source hashes, actual test executable and staged harness.
The compiled test runs under Fritz's build-cache lock in an exclusively owned
child group; bounded transport and cleanup use the frozen pairing driver.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import local_browser_pairing as transport
import bosun_transport as owned_transport

ROOT = Path(__file__).resolve().parents[1]
TEST = "decision::local::bosun::tests::native_f16_matches_official_cpu_reference_without_generating_tokens"
SOURCE_FILES = {"bosun": "src/decision/local/bosun.rs", "local": "src/decision/local.rs",
                "harness": "src/decision/harness.rs", "catalog": "Sources/Fritz/DecisionModels.json"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpu-reference", type=Path, required=True)
    parser.add_argument("--cpu-reference-sha256", required=True)
    parser.add_argument("--compiler-reference", type=Path, default=ROOT / "tests/fixtures/bosun-compiler-reference.json")
    parser.add_argument("--compiler-reference-sha256", required=True)
    parser.add_argument("--test-executable", type=Path, required=True)
    parser.add_argument("--test-executable-sha256", required=True)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--models-dir", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-dirty", choices=("true", "false"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-readout", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    for path, expected in ((args.cpu_reference,args.cpu_reference_sha256),(args.compiler_reference,args.compiler_reference_sha256),(args.test_executable,args.test_executable_sha256)):
        transport.require(path.is_absolute() and transport.file_hash(path)==expected,"A frozen reference or test executable changed")
    cpu = transport.strict_json(args.cpu_reference.read_bytes())
    transport.require(cpu.get("schema")=="fritz-bosun-cpu-reference-v1" and cpu.get("status")=="complete", "Complete official CPU reference required")
    transport.require(cpu.get("compiler_reference_sha256")==args.compiler_reference_sha256,"CPU/compiler reference mismatch")
    transport_protocol=owned_transport.provenance()
    transport.require(cpu.get("transport_protocol")==transport_protocol,"CPU reference transport source or version differs")
    transport.require(cpu.get("driver")==transport.pin(ROOT / "tests/bosun_cpu_reference.py")
                      and cpu.get("generator_sha256")==cpu["driver"]["sha256"],"CPU reference driver source differs")
    binaries=transport.inspect_binaries(args.bin_dir)
    decision=binaries["decision"]
    if args.worker:
        transport.require(args.native_readout is not None and args.native_readout.is_absolute(),"Explicit native readout required")
        env=dict(os.environ)
        env.update({"FRITZ_BOSUN_MODELS_DIR":str(args.models_dir),"FRITZ_BOSUN_CPU_REFERENCE":str(args.cpu_reference),
                    "FRITZ_BOSUN_NATIVE_RECEIPT":str(args.native_readout),"FRITZ_BOSUN_SOURCE_COMMIT":args.source_commit,
                    "FRITZ_BOSUN_SOURCE_DIRTY":args.source_dirty,"FRITZ_BOSUN_STAGED_HARNESS_SHA256":decision["sha256"]})
        # Human Rust test output goes to bounded stderr, leaving NDJSON stdout owned by us.
        command=[sys.executable,str(ROOT / "scripts/build-cache.py"),str(args.test_executable),TEST,"--exact","--ignored","--nocapture"]
        child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=sys.stderr,stderr=sys.stderr,env=env)
        # Outer transport owns and cancels this entire inherited process group.
        exit_code=child.wait(timeout=720)
        if exit_code!=0:
            raise ValueError("Native parity test failed; retain partial native readout")
        native=transport.strict_json(args.native_readout.read_bytes())
        print(json.dumps({"type":"result","result":native},allow_nan=False),flush=True)
        return
    transport.require(args.output.is_absolute() and not args.output.exists(),"Output must be a new absolute receipt")
    if not args.output.parent.exists():args.output.parent.mkdir(mode=0o700)
    transport.require(args.output.parent.stat().st_uid==os.getuid() and not args.output.parent.stat().st_mode & 0o077,"Use an owned 0700 output directory")
    source_hashes={name:transport.file_hash(ROOT / relative) for name,relative in SOURCE_FILES.items()}
    model=transport.inspect_model(ROOT / "Sources/Fritz/DecisionModels.json","bosun-v3.1-0.6b-f16",args.models_dir,decision=True)
    artifacts=[{"file":artifact["file"],"size":artifact["bytes"],"sha256":artifact["actual_sha256"]} for artifact in model["artifacts"]]
    native_path=args.output.parent / "native-readout.json"
    transport.require(not native_path.exists(),"Native readout must be new")
    document={"schema":"fritz-bosun-parity-receipt-v1","status":"running",
              "compiler_reference_sha256":args.compiler_reference_sha256,"cpu_reference_sha256":args.cpu_reference_sha256,
              "runtime_lock_sha256":cpu["runtime_lock_sha256"],"cpu":cpu,"native":None,
              "transport_protocol":transport_protocol,"followup":cpu["followup"],
              "driver":transport.pin(Path(__file__).resolve()),
              "staged_decision_harness":decision,"test_executable":{"path":str(args.test_executable),"sha256":args.test_executable_sha256},
              "source_sha256":source_hashes,"artifacts":artifacts,"generator_sha256":transport.file_hash(Path(__file__))}
    transport.write_json(args.output,document)
    attempt=args.output.parent / "native-transport"
    attempt.mkdir(mode=0o700)
    env={name:os.environ[name] for name in ("PATH","TMPDIR","LANG","LC_ALL","DEVELOPER_DIR") if name in os.environ}
    command=[sys.executable,str(Path(__file__).resolve()),"--cpu-reference",str(args.cpu_reference),"--cpu-reference-sha256",args.cpu_reference_sha256,
             "--compiler-reference",str(args.compiler_reference),"--compiler-reference-sha256",args.compiler_reference_sha256,
             "--test-executable",str(args.test_executable),"--test-executable-sha256",args.test_executable_sha256,
             "--bin-dir",str(args.bin_dir),"--models-dir",str(args.models_dir),"--source-commit",args.source_commit,
             "--source-dirty",args.source_dirty,"--output",str(args.output),"--native-readout",str(native_path),"--worker"]
    try:
        receipt=owned_transport.evaluate_child(command,b"{}",env,attempt,timeout=725)
        document["transport"]=receipt
        cleanup={**receipt["cleanup"],"forced_kill":"SIGKILL" in receipt["cleanup"].get("signals",[])}
        event=receipt.get("terminal")
        native=transport.strict_json(native_path.read_bytes()) if native_path.exists() else None
        document["native"]=native
        if isinstance(native,dict):native["cleanup"]=cleanup
        transport.require(cleanup.get("succeeded") is True and cleanup.get("exit_code")==0 and not cleanup["forced_kill"],"Native child cleanup failed or remains unknown")
        transport.require(not receipt.get("deadline_expired") and not receipt.get("transport_error") and isinstance(event,dict) and event.get("type")=="result","Native transport failed")
        transport.require(isinstance(native,dict) and native.get("status")=="complete" and event.get("result")=={**native,"cleanup":None},"Native readout is incomplete or differs from terminal")
        transport.require(native.get("source_sha256")==source_hashes and native.get("source_commit")==args.source_commit and native.get("source_dirty")== (args.source_dirty=="true"),"Native compiled source differs from frozen invocation")
        transport.require(native.get("binary_sha256")==decision["sha256"] and native.get("test_executable_sha256")==args.test_executable_sha256,"Native binary pins differ")
        transport.require(native.get("artifacts")==artifacts,"Native artifact pins differ")
        transport.require(all(row.get("passed") is True for row in native.get("rows",[])) and len(native["rows"])==len(cpu["rows"]),"Native parity failed")
        document["status"]="complete"
    except BaseException as error:
        document.update(status="failed",error=f"{type(error).__name__}: {error}")
        if isinstance(error,owned_transport.InterruptedAttempt): document["transport"]=error.receipt
        if native_path.exists() and document["native"] is None: document["native"]=transport.strict_json(native_path.read_bytes())
        transport.write_json(args.output,document,replace=True)
        raise
    transport.write_json(args.output,document,replace=True)
    print(json.dumps({"output":str(args.output),"status":"complete","rows":len(document["native"]["rows"])}))


if __name__=="__main__":main()
