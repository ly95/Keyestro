#!/usr/bin/env python3
"""Generate a minimal SPDX 2.3 JSON SBOM from the pinned SwiftPM graph."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import uuid


PROJECT_ROOT = Path(__file__).resolve().parent.parent
RESOLVED_PATH = PROJECT_ROOT / "Package.resolved"
ALLOWED_DEPENDENCIES = {
    "sparkle": {
        "location": "https://github.com/sparkle-project/Sparkle",
        "version": "2.9.5",
        "revision": "79bc9e872948e47877e76f194cb0c8e0412b0b90",
    }
}


def pinned_dependencies() -> list[dict[str, str]]:
    resolved = json.loads(RESOLVED_PATH.read_text(encoding="utf-8"))
    dependencies: list[dict[str, str]] = []
    for pin in resolved.get("pins", []):
        identity = pin.get("identity")
        state = pin.get("state", {})
        actual = {
            "location": pin.get("location"),
            "version": state.get("version"),
            "revision": state.get("revision"),
        }
        expected = ALLOWED_DEPENDENCIES.get(identity)
        if expected != actual:
            raise ValueError(f"unreviewed or stale dependency pin: {identity}: {actual}")
        dependencies.append({"identity": identity, **actual})
    if set(ALLOWED_DEPENDENCIES) != {dependency["identity"] for dependency in dependencies}:
        raise ValueError("the reviewed dependency allowlist does not match Package.resolved")
    return dependencies


def spdx_document(version: str, build: str) -> dict[str, object]:
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+-]{0,63}", version):
        raise ValueError("version is not a valid release identifier")
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.-]{0,63}", build):
        raise ValueError("build is not a valid release identifier")
    dependencies = pinned_dependencies()
    packages: list[dict[str, object]] = [
        {
            "name": "Keyestro",
            "SPDXID": "SPDXRef-Package-Keyestro",
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "Apache-2.0",
            "licenseDeclared": "Apache-2.0",
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": "APPLICATION",
        }
    ]
    relationships: list[dict[str, str]] = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-Keyestro",
        }
    ]
    for dependency in dependencies:
        identifier = f"SPDXRef-Package-{dependency['identity'].title()}"
        packages.append(
            {
                "name": dependency["identity"],
                "SPDXID": identifier,
                "versionInfo": dependency["version"],
                "downloadLocation": dependency["location"],
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": (
                            f"pkg:github/sparkle-project/Sparkle@{dependency['version']}"
                            f"?vcs_url=git%2B{dependency['location']}%40{dependency['revision']}"
                        ),
                    }
                ],
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-Package-Keyestro",
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": identifier,
            }
        )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Keyestro-{version}-{build}",
        "documentNamespace": f"https://keyestro.app/spdx/{version}/{build}/{uuid.uuid4()}",
        "creationInfo": {
            "created": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "creators": ["Tool: Keyestro scripts/generate-sbom.py"],
        },
        "packages": packages,
        "relationships": relationships,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--build", default="1")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    try:
        document = spdx_document(arguments.version, arguments.build)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SBOM generation failed: {error}", file=sys.stderr)
        return 1
    encoded = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if arguments.check:
        print(f"Reviewed dependency pins verified ({len(document['packages']) - 1} dependency).")
        return 0
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
