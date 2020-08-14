#!/usr/bin/env python

from __future__ import print_function
from future.utils import iteritems
import sys
import lxml.etree

iface_link_map = {}
link_members = {}
node_ifaces = {}
link_netmasks = {}
allifaces = {}

f = open(sys.argv[1],'r')
contents = f.read()
f.close()
root = lxml.etree.fromstring(contents)

mycluster = None
if len(sys.argv) > 2:
    mycluster = sys.argv[2]

# Find all the links:
for elm in root.getchildren():
    if not elm.tag.endswith("}link"):
        continue
    name = elm.get("client_id")
    ifacerefs = []
    cluster = None
    for elm2 in elm.getchildren():
        if elm2.tag.endswith("}interface_ref"):
            ifacename = elm2.get("client_id")
            ifacerefs.append(ifacename)
        if elm2.tag.endswith("}label") and elm2.get("name") == "cluster":
            cluster = elm2.text
    if not mycluster or not cluster or mycluster == cluster:
        for ifacename in ifacerefs:
            iface_link_map[ifacename] = name
        link_members[name] = ifacerefs

# Find all the node interfaces
for elm in root.getchildren():
    if not elm.tag.endswith("}node"):
        continue
    name = elm.get("client_id")
    ifaces = {}
    cluster = None
    for elm2 in elm.getchildren():
        if elm2.tag.endswith("}interface"):
            ifacename = elm2.get("client_id")
            for elm3 in elm2.getchildren():
                if not elm3.tag.endswith("}ip"):
                    continue
                if not elm3.get("type") == 'ipv4':
                    continue
                addrtuple = (elm3.get("address"),elm3.get("netmask"))
                ifaces[ifacename] = addrtuple
                allifaces[ifacename] = addrtuple
                break
        if elm2.tag.endswith("}label") and elm2.get("name") == "cluster":
            cluster = elm2.text
    if not mycluster or not cluster or mycluster == cluster:
        for (k,v) in iteritems(ifaces):
            allifaces[k] = v
        node_ifaces[name] = ifaces

# Dump the nodes a la topomap
print("# nodes: vname,links")
for n in node_ifaces.keys():
    for (i,(addr,mask)) in iteritems(node_ifaces[n]):
        print("%s,%s:%s" % (n,iface_link_map[i],addr))

# Dump the links a la topomap -- but with fixed cost of 1
print("# lans: vname,mask,cost")
for m in link_members.keys():
    ifref = link_members[m][0]
    (ip,mask) = allifaces[ifref]
    print("%s,%s,1" % (m,mask))

sys.exit(0)
