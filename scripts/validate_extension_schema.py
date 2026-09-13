#!/usr/bin/env python3
"""Validate every checked-in Lima extension manifest against the public schema."""
from pathlib import Path
import json
import sys

try:
    import jsonschema
except ImportError:
    print("jsonschema is required (python3 -m pip install jsonschema)", file=sys.stderr)
    raise

root = Path(__file__).resolve().parents[1]
schema_path = root / "docs/extension-manifest.schema.json"
schema = json.loads(schema_path.read_text())
validator = jsonschema.Draft202012Validator(schema)
roots = [root / name for name in ("Extensions", "StorePackages", "Examples", "docs/starter-extension")]
files = sorted({path for base in roots if base.exists() for path in base.rglob("manifest.json")})
errors = []
for path in files:
    try:
        document = json.loads(path.read_text())
        failures = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
        errors.extend(f"{path.relative_to(root)}: {failure.message}" for failure in failures)
    except Exception as error:
        errors.append(f"{path.relative_to(root)}: {error}")
if errors:
    print("Extension schema validation failed:", file=sys.stderr)
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Validated {len(files)} extension manifest(s) against {schema_path.relative_to(root)}.")
