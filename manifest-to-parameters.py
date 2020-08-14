#!/usr/bin/env python

from __future__ import print_function
import sys
import lxml.etree

f = open(sys.argv[1],'r')
contents = f.read()
f.close()
root = lxml.etree.fromstring(contents)

def convert(p,v):
    if v in [ "True","true" ]:
        v = 1
    elif v in  [ "False","false" ]:
        v = 0
    elif v == None:
        return ""
    return v

# Find our node and dump any labels:
for elm in root.getchildren():
    if elm.tag.endswith("}label"):
        print("%s=%s" % (elm.get("name").upper(),elm.text))
    if elm.tag.endswith("}data_set"):
        for elm2 in elm.getchildren():
            if elm2.tag.endswith("}data_item"):
                p = elm2.get("name")
                v = str(convert(p,elm2.text))
                if v.find(" ") > -1:
                    v = '"' + v + '"'
                print("%s=%s" % (p.split(".")[-1].upper(),v))
    if elm.tag.endswith("}data_item"):
        p = elm.get("name")
        print("%s=%s" % (p.split(".")[-1].upper(),str(convert(p,elm.text))))

sys.exit(0)
