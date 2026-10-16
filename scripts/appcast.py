#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (stable and beta items in one feed).

Stable items carry no channel; betas carry <sparkle:channel>beta</sparkle:channel>, offered only to
users who enable beta updates. A stable release drops every beta item (their GitHub releases are
deleted). The newest items are kept first, at most MAX_ITEMS.
"""
import argparse
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
MAX_ITEMS = 10


def tag(name):
    return f"{{{SPARKLE}}}{name}"


def empty_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Espazio"
    ET.SubElement(channel, "link").text = "https://github.com/V1rtualAx3/Espazio"
    ET.SubElement(channel, "description").text = "Mises à jour d’Espazio"
    ET.SubElement(channel, "language").text = "fr"
    return ET.ElementTree(rss)


def is_beta(item):
    channel = item.find(tag("channel"))
    return channel is not None and (channel.text or "").strip() == "beta"


def update(path, args):
    tree = ET.parse(path) if path.exists() else empty_feed()
    channel = tree.getroot().find("channel")
    items = channel.findall("item")
    for item in items:
        version = item.find(tag("shortVersionString"))
        stale = version is not None and version.text == args.version
        if stale or (not args.beta and is_beta(item)):
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Espazio {args.version}"
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, tag("version")).text = args.build
    ET.SubElement(item, tag("shortVersionString")).text = args.version
    ET.SubElement(item, tag("minimumSystemVersion")).text = args.minimum_system
    if args.beta:
        ET.SubElement(item, tag("channel")).text = "beta"
    ET.SubElement(item, tag("fullReleaseNotesLink")).text = args.notes_url
    ET.SubElement(item, "description").text = (
        f'<p>Espazio {args.version}. <a href="{args.notes_url}">Notes de version</a></p>')
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/x-apple-diskimage",
        tag("edSignature"): args.signature,
    })

    remaining = channel.findall("item")
    for old in remaining:
        channel.remove(old)
    for kept in [item, *remaining][:MAX_ITEMS]:
        channel.append(kept)

    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--minimum-system", required=True)
    args = parser.parse_args()
    args.beta = "-" in args.version
    update(args.appcast, args)


if __name__ == "__main__":
    sys.exit(main())
