#!/usr/bin/env bash
set -eu

command -v python3 >/dev/null || {
    echo "ERROR: python3 is required." >&2
    exit 1
}

exec python3 - "$@" <<'PY_PREPARE'
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile

ROOT = Path.cwd()
BACKUP = ROOT / "preprocess_source_backup"
INCLUDES = ROOT / "scratch/ns3-precheck-sources"

MODELS = {
    "src/wifi/model/ht/ht-frame-exchange-manager.cc": (
        "0ef7fa999dd4f7b0a18cbaa0ff91c5d7456c9a9ed27e7fd9defd69a27f68fb55",
        "5dd1802ba9bc067a9c373a062b1b1feda0a66352a56bdce34a2c06e50b6869b3",
    ),
    "src/wifi/model/qos-txop.cc": (
        "2a9d01374e6f64f2a47722cefbd62c04aaab905cf5a2fed133b60e7313ca4d89",
        "4c2239d80a8e939e2658ee82a9e3066a8a0abac9e7687ce72df206facf3a0295",
    ),
}

SOURCES = {
    "foundation-d1":
        "7976d1e4169b10b142e433639dabe83fe7ca4eded2264a4c41b592e7e92d76fa",
    "foundation-d2":
        "dcd6a03011af574d2c32b5df26f217f9a1b85f2f05217e5503d2b76fd462304f",
    "foundation-d4":
        "df6fab62056c8804704966522020385992c448505c41bdf863063ba63910430d",
}


def fail(message):
    raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def member(archive, name):
    item = archive.getmember(name)
    if not item.isfile():
        fail("Not a regular archive member: " + name)
    return archive.extractfile(item).read()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    old_mode = path.stat().st_mode & 0o777 if path.exists() else 0o644

    fd, temporary = tempfile.mkstemp(
        prefix=".prepare-",
        dir=path.parent,
    )

    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, old_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else "inspect"

    if len(sys.argv) > 2 or action not in {"inspect", "apply", "restore"}:
        fail("Usage: bash ns3_prepare.sh [inspect|apply|restore]")

    if not (ROOT / "ns3").is_file() or not (ROOT / "VERSION").is_file():
        fail("Run from the ns-3 root.")

    if (ROOT / "VERSION").read_text().strip() != "3.46.1":
        fail("Requires ns-3.46.1.")

    current = {}

    for relative, allowed in MODELS.items():
        data = (ROOT / relative).read_bytes()
        value = digest(data)
        print(relative + ": " + value)

        if value not in allowed:
            fail(
                "Unknown model source; no automatic replacement: "
                + relative
            )

        current[relative] = data

    fixed = all(
        digest(current[path]) == values[1]
        for path, values in MODELS.items()
    )

    candidates = [
        ROOT / "validation/foundation-final-results.tar.gz",
        ROOT / "foundation-final-results.tar.gz",
    ]

    package = next(
        (path for path in candidates if path.is_file()),
        None,
    )

    if action == "inspect":
        print(
            "SOURCE_STATE="
            + ("FIXED" if fixed else "ORIGINAL_OR_PARTIAL")
        )
        print(
            "PACKAGE="
            + (str(package) if package else "MISSING")
        )

        ready = all(
            (INCLUDES / (name + ".inc")).is_file()
            and digest(
                (INCLUDES / (name + ".inc")).read_bytes()
            ) == expected
            for name, expected in SOURCES.items()
        )

        print(
            "PRECHECK_SOURCES="
            + ("READY" if ready else "NOT_PREPARED")
        )
        return

    if action == "restore":
        if not fixed:
            fail(
                "Restore requires both current model files "
                "to match the fixed hashes."
            )

        manifest = json.loads(
            (BACKUP / "manifest.json").read_text()
        )
        saved = {}

        for relative, allowed in MODELS.items():
            data = (BACKUP / relative).read_bytes()

            if (
                digest(data) != manifest[relative]
                or digest(data) not in allowed
            ):
                fail("Backup hash mismatch: " + relative)

            saved[relative] = data

        try:
            for relative, data in saved.items():
                write_atomic(ROOT / relative, data)
        except BaseException:
            for relative, data in current.items():
                write_atomic(ROOT / relative, data)
            raise

        print(
            "RESTORED saved source state. "
            "Rebuild before using restored models."
        )
        return

    if package is None:
        fail(
            "Missing foundation-final-results.tar.gz "
            "in validation/ or ns-3 root."
        )

    prefix = "results_foundation_final/"

    with tarfile.open(package, "r:gz") as outer:
        sources = {
            name: member(outer, prefix + name + ".cc")
            for name in SOURCES
        }

        packed = member(
            outer,
            prefix + "blockack-source-3461.tar.gz",
        )

    with tarfile.open(
        fileobj=io.BytesIO(packed),
        mode="r:gz",
    ) as inner:
        models = {
            relative: member(inner, relative)
            for relative in MODELS
        }

    for name, expected in SOURCES.items():
        if digest(sources[name]) != expected:
            fail("Archived C++ hash mismatch: " + name)

        destination = INCLUDES / (name + ".inc")

        if (
            destination.exists()
            and digest(destination.read_bytes()) != expected
        ):
            fail(
                "Existing include differs; retain it and review: "
                + str(destination)
            )

    for relative, allowed in MODELS.items():
        if digest(models[relative]) != allowed[1]:
            fail("Archived model hash mismatch: " + relative)

    if not fixed:
        manifest = {
            relative: digest(data)
            for relative, data in current.items()
        }

        if BACKUP.exists():
            recorded = json.loads(
                (BACKUP / "manifest.json").read_text()
            )

            if recorded != manifest:
                fail(
                    "Existing backup belongs to "
                    "a different initial state."
                )

            for relative, expected in recorded.items():
                if digest(
                    (BACKUP / relative).read_bytes()
                ) != expected:
                    fail(
                        "Existing backup is corrupted: "
                        + relative
                    )
        else:
            with tempfile.TemporaryDirectory(
                prefix=".prepare-backup-",
                dir=ROOT,
            ) as temporary:
                staging = Path(temporary) / "backup"

                for relative, data in current.items():
                    write_atomic(staging / relative, data)

                write_atomic(
                    staging / "manifest.json",
                    json.dumps(
                        manifest,
                        indent=2,
                    ).encode("utf-8"),
                )

                staging.rename(BACKUP)

    try:
        for name, data in sources.items():
            destination = INCLUDES / (name + ".inc")

            if not destination.exists():
                write_atomic(destination, data)

        if not fixed:
            for relative, data in models.items():
                write_atomic(ROOT / relative, data)

        for relative, allowed in MODELS.items():
            if digest(
                (ROOT / relative).read_bytes()
            ) != allowed[1]:
                fail("Final model hash mismatch: " + relative)

    except BaseException:
        if not fixed:
            for relative, data in current.items():
                write_atomic(ROOT / relative, data)
        raise

    print(
        "PRECHECK_SOURCES=READY: "
        "three archived sources retained byte-for-byte."
    )
    print(
        "MODELS="
        + (
            "ALREADY_FIXED; unchanged."
            if fixed
            else "FIXED; backup saved."
        )
    )
    print("No compilation or simulation was performed.")


try:
    main()
except (
    OSError,
    ValueError,
    KeyError,
    RuntimeError,
    tarfile.TarError,
) as error:
    print("ERROR: " + str(error), file=sys.stderr)
    sys.exit(1)
PY_PREPARE