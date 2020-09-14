#!/usr/bin/env python

from __future__ import print_function
import sys
import lxml.etree

f = open(sys.argv[1],'r')
contents = f.read()
f.close()
root = lxml.etree.fromstring(contents)

mycluster = None
if len(sys.argv) > 2:
    mycluster = sys.argv[2]

# Find all the public IP addresses:
for elm in root.getchildren():
    if not elm.tag.endswith("}routable_pool"):
        continue
    name = elm.get("client_id")
    if mycluster and not name.endswith("-%s" % (mycluster,)):
        continue
    for elm2 in elm.getchildren():
        if elm2.tag.endswith("}ipv4"):
            print("%s/%s" % (elm2.get("address"),elm2.get("netmask")))

sys.exit(0)
