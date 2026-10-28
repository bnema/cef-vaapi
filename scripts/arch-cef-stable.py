#!/usr/bin/env python3
"""Resolve the Arch extra stable version and its packaging Git tag."""
import json
import re
import urllib.request


def metadata(package):
    version = str(package["pkgver"])
    release = str(package["pkgrel"])
    epoch = package.get("epoch", 0)
    tag = f"{version}-{release}"
    if epoch:
        tag = f"{epoch}:{tag}"
    if not re.fullmatch(r"[0-9][0-9A-Za-z.+:_-]*", tag):
        raise ValueError("Invalid Arch packaging tag")
    return f"pkgver={version}\npkgrel={release}\nref={tag}"


if __name__ == "__main__":
    with urllib.request.urlopen(
        "https://archlinux.org/packages/extra/x86_64/cef/json/", timeout=30
    ) as response:
        print(metadata(json.load(response)))
