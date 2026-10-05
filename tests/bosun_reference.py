#!/usr/bin/env python3
"""Compile independent Bosun fixtures from pinned public source, without importing its model.

Only the reviewed pure functions are extracted from AST. This command downloads
source, the template and tokenizer metadata; it never downloads or loads weights.
Run from a sanitized environment with an explicit fresh --cache-dir. The reference
probability field remains null until a separately authorized official CPU run.
"""
from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import importlib.metadata
import json
import platform
import random
import sys
import types
import urllib.request
from pathlib import Path

SOURCE = "2afeaccc760165386c2dd52e78b851b1b53cb752"
ADAPTER = "431b8e1ecc501cdb76c118fe58907a0a004d6fc0"
HF = f"https://huggingface.co/Hanno-Labs/bosun-v3.1-0.6b/resolve/{SOURCE}/"
GH = f"https://raw.githubusercontent.com/Hanno-Labs/jev-compatible-server/{ADAPTER}/src/jev_compatible_server/"
ASSETS = {
    "modeling_bosun.py": (HF + "modeling_bosun.py", "c04ab1c7929d41185d3c80e61ae0088a47a2c66438947f9dcc499b020f2b4cb5"),
    "bosun_adapter.py": (GH + "bosun.py", "23b4f694e06167f83d6512fab3aa2b59fc7f1a7be4a8fd8bd5d089cada5beb18"),
    "encoder_decoder.py": (GH + "encoder_decoder.py", "f064de533eb3edd93c60c643553ee35c15ff30adf9849188a50c50f9aeb1ab8e"),
    "chat_template.jinja": (HF + "tokenizer/chat_template.jinja", "a55ee1b1660128b7098723e0abcd92caa0788061051c62d51cbe87d9cf1974d8"),
    "tokenizer.json": (HF + "tokenizer/tokenizer.json", "7d3acd3a7d8f4f180f5331a87c004402188745c5a719aee456d9cb8cb9b34168"),
    "serving.json": (HF + "serving.json", "16688211da16636715a8ca3784652f9954b2e1fd93513a75e59914626c750e3c"),
}
# Match mistral.rs's locked tokenizer version; binary wheels only. PyPI is the source.
COMPILER_PACKAGES = {
    "tokenizers": {"version": "0.23.2", "wheel": "tokenizers-0.23.2-cp310-abi3-macosx_11_0_arm64.whl", "sha256": "986670e43691469dcee610ea0f846f91a8f84e91fc6f7a48d4c064414c0ec2bf"},
    "Jinja2": {"version": "3.1.6", "wheel": "jinja2-3.1.6-py3-none-any.whl", "sha256": "85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67"},
    "MarkupSafe": {"version": "3.0.4", "wheel": "markupsafe-3.0.4-cp313-cp313-macosx_11_0_arm64.whl", "sha256": "73e77980c7207854f00fc4e71fb1626868d5740ab4012623d55c7a99ad122a72"},
}


def asset(cache: Path, name: str) -> bytes:
    url, expected = ASSETS[name]
    path = cache / name
    if path.exists():
        data = path.read_bytes()
    else:
        # Direct public HTTPS; no proxy discovery, Hub library, token or netrc access.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=60) as response:
            data = response.read(20_000_001)
        if len(data) > 20_000_000:
            raise ValueError(f"oversized source/tokenizer asset: {name}")
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"pinned source/tokenizer checksum mismatch: {name}")
    if not path.exists():
        path.write_bytes(data)
    return data


def pure_functions(source: bytes, names: set[str], namespace: dict) -> None:
    parsed = ast.parse(source.decode("utf-8"))
    functions = [node for node in parsed.body if isinstance(node, ast.FunctionDef) and node.name in names]
    if {node.name for node in functions} != names:
        raise ValueError("pinned source does not contain the requested compiler functions")
    for function in functions:
        if any(isinstance(node, (ast.Import, ast.ImportFrom)) for node in ast.walk(function)):
            raise ValueError("compiler function contains an import")
    module = ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0), *functions], type_ignores=[])
    ast.fix_missing_locations(module)
    exec(compile(module, "pinned-bosun-pure-compiler", "exec"), namespace)


def compiler_namespace(cache: Path) -> dict:
    namespace = {"hashlib": hashlib, "json": json, "random": random,
                 "_DECISION_TYPES": frozenset({"choice", "score", "noul"}), "RuntimeErrorBase": ValueError}
    for name in ("ChoiceQuestion", "ScoreQuestion", "NoulQuestion"):
        namespace[name] = type(name, (types.SimpleNamespace,), {})
    pure_functions(asset(cache, "encoder_decoder.py"), {"render_content"}, namespace)
    pure_functions(asset(cache, "bosun_adapter.py"), {"_candidate", "_candidates", "_row_id"}, namespace)
    pure_functions(asset(cache, "modeling_bosun.py"), {"render_decision_prompt", "_compact_criteria", "_canonical_json"}, namespace)
    return namespace


def protocol_wire(request: dict) -> dict:
    wire = copy.deepcopy(request)
    for question in wire["questions"].values():
        if question["type"] == "noul":
            question.setdefault("criteria", None)
    return wire


def reference_rows(inputs: dict, cache: Path) -> list[dict]:
    from jinja2.sandbox import ImmutableSandboxedEnvironment
    from tokenizers import Tokenizer

    for name, pin in COMPILER_PACKAGES.items():
        if importlib.metadata.version(name) != pin["version"]:
            raise ValueError(f"compiler dependency version differs from frozen pin: {name}")
    namespace = compiler_namespace(cache)
    template = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True).from_string(asset(cache, "chat_template.jinja").decode("utf-8"))
    asset(cache, "tokenizer.json")
    tokenizer = Tokenizer.from_file(str(cache / "tokenizer.json"))
    serving = json.loads(asset(cache, "serving.json"))
    if tokenizer.get_vocab_size(with_added_tokens=True) != 151925:
        raise ValueError("reference tokenizer does not contain the complete Bosun vocabulary")
    for index, token in enumerate(serving["decision_tokens"]):
        if tokenizer.token_to_id(token) != 151669 + index:
            raise ValueError("reference decision token mapping differs from the pin")
    output = []
    for case in inputs["cases"]:
        wire = protocol_wire(case["request"])
        # The Fritz public request uses BTreeMap; its original candidate order is sorted.
        for question_name, question in sorted(wire["questions"].items()):
            kind = question["type"]
            data = copy.deepcopy(question)
            if kind == "choice":
                data["criteria"] = dict(sorted(data["criteria"].items()))
            elif kind == "noul" and data["criteria"] is not None:
                data["criteria"] = types.SimpleNamespace(**data["criteria"])
            question_object = namespace[{"choice": "ChoiceQuestion", "score": "ScoreQuestion", "noul": "NoulQuestion"}[kind]](**data)
            candidates = namespace["_candidates"](question_object)
            proxy = types.SimpleNamespace(model_dump=lambda **kwargs: wire)
            row_id = namespace["_row_id"](proxy, question_name)
            content, order, mapping = namespace["render_decision_prompt"](
                state=wire["state"], instructions=namespace["render_content"](question["instructions"]),
                candidates=candidates, decision_type=kind, decision_tokens=serving["decision_tokens"],
                seed=0, row_id=row_id, prompt_schema=serving["schema_version"])
            prompt = template.render(messages=[{"role": "system", "content": "Choose exactly one supplied decision token. Return only that token. Do not explain the answer."}, {"role": "user", "content": content}], tools=None, add_generation_prompt=True, enable_thinking=False)
            token_ids = tokenizer.encode(prompt, add_special_tokens=True).ids
            output.append({"case_id": case["id"], "question_name": question_name,
                           "request": case["request"], "row_id": row_id, "candidates": candidates,
                           "content": content, "prompt": prompt, "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(),
                           "presentation_order": order, "candidate_to_slot": mapping, "token_ids": token_ids,
                           "probabilities": None, "slot_logits": None})
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, default=Path(__file__).parent / "fixtures/bosun-reference-inputs.json")
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.cache_dir.is_absolute() or not args.cache_dir.is_dir():
        parser.error("--cache-dir must be an existing explicit absolute directory")
    if args.output.exists():
        parser.error("--output must be a new file; previous evidence is never overwritten")
    raw_inputs = args.inputs.read_bytes()
    inputs = json.loads(raw_inputs)
    if inputs["source"]["revision"] != SOURCE or inputs["source"]["typed_mapping_revision"] != ADAPTER:
        parser.error("input source versions differ from the compiler pins")
    document = {"schema": "fritz-bosun-compiler-reference-v1", "status": "compiler/tokenizer reference only; model probabilities unmeasured",
                "inputs_sha256": hashlib.sha256(raw_inputs).hexdigest(), "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "source": {name: {"url": url, "sha256": sha} for name, (url, sha) in ASSETS.items()},
                "compiler_packages": COMPILER_PACKAGES, "python": platform.python_version(),
                "rows": reference_rows(inputs, args.cache_dir)}
    args.output.write_text(json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "rows": len(document["rows"]), "token_counts": [len(row["token_ids"]) for row in document["rows"]], "probabilities": "unmeasured"}))


if __name__ == "__main__":
    main()
