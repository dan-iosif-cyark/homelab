#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Enforce this repo's Compose conventions, beyond what dclint covers.

Usage: scripts/compose-policy.py [<stack>/compose.yaml | <stack>/.env.template]...
With no arguments, every stack is checked.
"""

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

# Deliberate exceptions, as {"<stack>/<service>": {"<rule>", ...}}. Every entry
# needs a comment saying why.
EXCEPTIONS: dict[str, set[str]] = {
    # Published on ghcr.io only.
    "3_downloads/shelfmark": {"docker-hub"},
    # LazyLibrarian has no versioned releases, only commit builds that
    # Renovate can't order; it follows the digest of `latest` instead.
    "3_downloads/lazylibrarian": {"pinned-image"},
    # Plex clients on the LAN, and Plex's remote access, connect to Plex's own
    # port rather than going through Traefik.
    "4_media/plex": {"routed-ports"},
}

# Image prefixes allowed outside Docker Hub for every stack. Their updates wait
# for approval on the Dependency Dashboard (renovate.json5).
OTHER_REGISTRIES = {
    # hotio's images, preferred where they exist, are published on ghcr.io only.
    "ghcr.io/hotio/",
}

PINNED_IMAGE = re.compile(r"^(?P<name>[^@\s:]+(?::\d+)?/?[^@\s:]*):(?P<tag>[^@\s:]+)@sha256:[0-9a-f]{64}$")
FLOATING_TAGS = {"latest", "stable", "edge", "nightly", "dev", "beta", "canary", "lts", "develop", "main", "master"}
SOCKET_PROXY_IMAGES = {"tecnativa/docker-socket-proxy"}
ENV_REF = re.compile(r"(?<!\$)\$\{?([A-Za-z_][A-Za-z0-9_]*)")
SECRET_KEY = re.compile(r"(TOKEN|PASSWORD|PASS|SECRET|KEY|SALT|CREDENTIALS?)(_|$)")


def split_image(image_name: str) -> tuple[str, str]:
    """Split an image name into (registry, repository)."""
    first, _, rest = image_name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        return first, rest
    return "docker.io", image_name


def is_true(value) -> bool:
    return str(value).lower() == "true"


def labels_of(service: dict) -> dict:
    labels = service.get("labels") or {}
    if isinstance(labels, list):
        return dict(item.split("=", 1) if "=" in item else (item, "") for item in labels)
    return labels


def read_template(path: Path) -> dict[str, str]:
    entries = {}
    if not path.exists():
        return entries
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            entries[key.strip()] = value.strip()
    return entries


def check_stack(stack: Path) -> list[str]:
    compose_path = stack / "compose.yaml"
    template_path = stack / ".env.template"
    rel = compose_path.relative_to(ROOT)
    errors = []

    def fail(service: str | None, rule: str, message: str) -> None:
        if service and rule in EXCEPTIONS.get(f"{stack.name}/{service}", set()):
            return
        where = f"{rel} [{service}]" if service else str(rel)
        errors.append(f"{where}: {message} ({rule})")

    compose = yaml.safe_load(compose_path.read_text()) or {}

    # The project name, not the folder, decides container and network names,
    # so it must not change when a stack is renumbered.
    project = stack.name.split("_", 1)[-1]
    if compose.get("name") != project:
        fail(None, "project-name", f"set the project name to {project!r}, the folder name without its number")

    for name, service in (compose.get("services") or {}).items():
        image = str(service.get("image", ""))
        match = PINNED_IMAGE.match(image)
        if not match:
            fail(name, "pinned-image", f"image {image!r} must be pinned as <image>:<version>@sha256:<digest>")
        else:
            if match["tag"] in FLOATING_TAGS:
                fail(name, "pinned-image", f"tag {match['tag']!r} is floating; pin a version")
            # Renovate can only enforce minimumReleaseAge where the registry
            # reports a release timestamp, which today is Docker Hub alone.
            if split_image(match["name"])[0] != "docker.io" and not match["name"].startswith(tuple(OTHER_REGISTRIES)):
                fail(
                    name,
                    "docker-hub",
                    "pull from Docker Hub if the image is published there, so Renovate can enforce the release-age delay",
                )

        if "restart" not in service:
            fail(name, "restart", "set a restart policy")

        if is_true(service.get("privileged")):
            fail(name, "privileged", "privileged containers are not allowed")

        if service.get("network_mode") == "host":
            fail(name, "host-network", "host networking bypasses network segregation")

        repository = split_image(match["name"] if match else image)[1]
        for volume in service.get("volumes") or []:
            source = volume.split(":", 1)[0] if isinstance(volume, str) else str(volume.get("source", ""))
            if source.endswith("docker.sock") and repository not in SOCKET_PROXY_IMAGES:
                fail(name, "docker-socket", "reach Docker through socket-proxy, not the raw socket")

        if is_true(labels_of(service).get("traefik.enable")) and service.get("ports"):
            fail(name, "routed-ports", "services routed through Traefik must not publish ports")

    template = read_template(template_path)
    referenced = set(ENV_REF.findall(compose_path.read_text()))
    for var in sorted(referenced - template.keys()):
        fail(None, "env-declared", f"${{{var}}} is used but not declared in .env.template")

    for key, value in template.items():
        if SECRET_KEY.search(key) and not value.startswith("op://"):
            fail(None, "env-secret", f"{key} looks like a secret; its value must be an op:// reference")

    return errors


def main(argv: list[str]) -> int:
    if argv:
        stacks = {(ROOT / arg).resolve().parent for arg in argv}
    else:
        stacks = {path.parent for path in ROOT.glob("*/compose.yaml")}

    errors = [error for stack in sorted(stacks) if (stack / "compose.yaml").exists() for error in check_stack(stack)]
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
