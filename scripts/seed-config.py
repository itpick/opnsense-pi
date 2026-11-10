#!/usr/bin/env python3
"""Make a seed config.xml from an OPNsense config (e.g. out/opnsense-pi5.config.xml).

  scripts/seed-config.py DEFAULT.xml OUT.xml [--hostname NAME] [--ssh-key FILE]
                         [--lan IF] [--wan IF]

--ssh-key  enable SSH (root login, key only) with the public key(s) in FILE
--lan/--wan  assign interfaces (e.g. --lan rp1eth0 --wan ue0)

Put OUT.xml on the image's EFI partition as opnsense-pi/config.xml; the boot
hook installs it on the next boot.
"""
import argparse
import base64
import xml.etree.ElementTree as ET


def child(parent, tag):
    node = parent.find(tag)
    if node is None:
        node = ET.SubElement(parent, tag)
    return node


ap = argparse.ArgumentParser()
ap.add_argument("default")
ap.add_argument("out")
ap.add_argument("--hostname")
ap.add_argument("--ssh-key")
ap.add_argument("--lan")
ap.add_argument("--wan")
a = ap.parse_args()

tree = ET.parse(a.default)
system = tree.getroot().find("system")
if a.hostname:
    child(system, "hostname").text = a.hostname
if a.ssh_key:
    keys = open(a.ssh_key).read().strip() + "\n"
    ssh = child(system, "ssh")
    child(ssh, "enabled").text = "enabled"
    child(ssh, "permitrootlogin").text = "1"
    child(ssh, "passwordauth").text = "0"
    root = next(u for u in system.findall("user") if u.findtext("name") == "root")
    child(root, "authorizedkeys").text = base64.b64encode(keys.encode()).decode()
interfaces = tree.getroot().find("interfaces")
for name, dev in (("lan", a.lan), ("wan", a.wan)):
    if dev:
        child(child(interfaces, name), "if").text = dev
tree.write(a.out, encoding="utf-8", xml_declaration=True)
