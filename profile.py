#!/usr/bin/env python

import geni.portal as portal
import geni.rspec.pg as RSpec
import geni.rspec.igext as IG
# Emulab specific extensions.
import geni.rspec.emulab as emulab
from lxml import etree as ET
import crypt
import random
import os.path
import sys

TBCMD = "sudo mkdir -p /root/setup && (if [ -d /local/repository ]; then sudo -H /local/repository/setup-driver.sh 2>&1 | sudo tee /root/setup/setup-driver.log; else sudo -H /tmp/setup/setup-driver.sh 2>&1 | sudo tee /root/setup/setup-driver.log; fi)"

#
# For now, disable the testbed's root ssh key service until we can remove ours.
# It seems to race (rarely) with our startup scripts.
#
disableTestbedRootKeys = True

#
# Create our in-memory model of the RSpec -- the resources we're going
# to request in our experiment, and their configuration.
#
rspec = RSpec.Request()

#
# This geni-lib script is designed to run in the CloudLab Portal.
#
pc = portal.Context()

#
# Define some parameters.
#
pc.defineParameter(
    "nodeCount","Number of Nodes",
    portal.ParameterType.INTEGER,3,
    longDescription="Number of nodes in your k8s cluster.  Should be either 1, or >= 3.")
#pc.defineParameter(
#    "k8sInstaller","Kubernetes Install",
#    portal.ParameterType.STRING,"default",
#    [("default","default"),("kubeadm","kubeadm"),("kubespray","kubespray")],
#    longDescription="")
pc.defineParameter(
    "nodeType","Hardware Type",
    portal.ParameterType.NODETYPE,"",
    longDescription="A specific hardware type to use for each node.  Cloudlab clusters all have machines of specific types.  When you set this field to a value that is a specific hardware type, you will only be able to instantiate this profile on clusters with machines of that type.  If unset, when you instantiate the profile, the resulting experiment may have machines of any available type allocated.")
pc.defineParameter(
    "linkSpeed","Experiment Link Speed",
    portal.ParameterType.INTEGER,0,
    [(0,"Any"),(1000000,"1Gb/s"),(10000000,"10Gb/s")],
    longDescription="A specific link speed to use for each link/LAN.  All experiment network interfaces will request this speed.")
pc.defineParameter(
    "diskImage","Disk Image",
    portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU18-64-STD",
    advanced=True,
    longDescription="An image URN or URL that every node will run.")
pc.defineParameter(
    "multiplexLans", "Multiplex Networks",
    portal.ParameterType.BOOLEAN,False,
    longDescription="Multiplex any networks over physical interfaces using VLANs.  Some physical machines have only a single experiment network interface, so if you want multiple links/LANs, you have to enable multiplexing.  Currently, if you select this option.",
    advanced=True)
pc.defineParameter(
    "sslCertType","SSL Certificate Type",
    portal.ParameterType.STRING,"self",
    [("none","None"),("self","Self-Signed"),("letsencrypt","Let's Encrypt")],
    advanced=True,
    longDescription="Choose an SSL Certificate strategy.  By default, we generate self-signed certificates, and only use them for a reverse web proxy to allow secure remote access to the Kubernetes Dashboard.  However, you may choose `None` if you prefer to arrange remote access differently (e.g. ssh port forwarding).  You may also choose to use Let's Encrypt certificates whose trust root is accepted by all modern browsers.")
pc.defineParameter(
    "sslCertConfig","SSL Certificate Configuration",
    portal.ParameterType.STRING,"proxy",
    [("proxy","Web Proxy")],
    advanced=True,
    longDescription="Choose where you want the SSL certificates deployed.  Currently the only option is for them to be configured as part of the web proxy to the dashboard.")

#
# Get any input parameter values that will override our defaults.
#
params = pc.bindParameters()

#
# Give the library a chance to return nice JSON-formatted exception(s) and/or
# warnings; this might sys.exit().
#
pc.verifyParameters()

detailedParamAutoDocs = ''
for param in pc._parameterOrder:
    if not pc._parameters.has_key(param):
        continue
    detailedParamAutoDocs += \
      """
  - *%s*

    %s
    (default value: *%s*)
      """ % (pc._parameters[param]['description'],pc._parameters[param]['longDescription'],pc._parameters[param]['defaultValue'])
    pass

tourDescription = \
  "This profile creates a kubernetes cluster.  When you click the Instantiate button, you'll be presented with a list of parameters that you can change to control what your k8s cluster will look like; **carefully** read the parameter documentation on that page (or in the Instructions) to understand the various features available to you."

tourInstructions = \
  """
### Basic Instructions
Once your experiment nodes have booted, and this profile's configuration scripts have finished configuring k8s inside your experiment, you'll be able to visit [the Kubernetes Dashboard WWW interface](https://{host-node-0}:6443/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!/login) (approx. 10-15 minutes).

Your k8s admin and instance VM password is randomly-generated by Cloudlab, and it is: `{password-adminPass}` . When logging in to the Dashboard, use the `admin` user.

The dashboard will not be available immediately.  There are multiple ways to determine if the scripts have finished:
  - First, you can watch the experiment status page: the overall State will say \"booted (startup services are still running)\" to indicate that the nodes have booted up, but the setup scripts are still running.
  - Second, the Topology View will show you, for each node, the status of the startup command on each node (the startup command kicks off the setup scripts on each node).  Once the startup command has finished on each node, the overall State field will change to \"ready\".  If any of the startup scripts fail, you can mouse over the failed node in the topology viewer for the status code.
  - Third, the profile configuration scripts also send you two emails: once to notify you that controller setup has started, and a second to notify you that setup has completed.  Once you receive the second email, you can login to the Openstack Dashboard and begin your work.
  - Finally, you can view [the profile setup script logfiles](http://{host-node-0}:7999/) as the setup scripts run.  Use the `admin` username and the random password above.

**NOTE:** If the web interface rejects your password or gives another error, the scripts might simply need more time. Wait a few minutes and try again.  If you don't receive any email notifications, you can SSH to the `node-0` node, become root, and check the primary setup script's logfile (/root/setup/setup-driver.log).  If near the bottom there's a line that includes 'Your CORD instance has completed setup'), the scripts have finished, and it's safe to login to the dashboard.

If you need to run `kubectl` or `helm`, you'll find authentication credentials in /root/setup/admin-openrc.sh on `node-0`).

The profile's setup scripts are automatically installed on each node in `/local/repository` .  They execute as `root`, and keep state and downloaded files in `/root/setup/`.  More importantly, they write copious logfiles in that directory; so if you think there's a problem with the configuration, you could take a quick look through these logs on the `node-0` node.


### Detailed Parameter Documentation
%s
""" % (detailedParamAutoDocs,)

#
# Setup the Tour info with the above description and instructions.
#  
tour = IG.Tour()
tour.Description(IG.Tour.TEXT,tourDescription)
tour.Instructions(IG.Tour.MARKDOWN,tourInstructions)
rspec.addTour(tour)

mgmtlan = None
datalans = []

datalan = RSpec.LAN("datalan-1")
if params.linkSpeed > 0:
    datalan.bandwidth = int(params.linkSpeed)
if params.multiplexLans:
    datalan.link_multiplexing = True
    datalan.best_effort = True
    # Need this cause LAN() sets the link type to lan, not sure why.
    datalan.type = "vlan"
datalans.append(datalan)

nodes = dict({})

for i in range(0,params.nodeCount):
    nodename = "node-%d" % (i,)
    node = RSpec.RawPC(nodename)
    if params.nodeType:
        node.hardware_type = params.nodeType
    if params.diskImage:
        node.disk_image = params.diskImage
    j = 0
    for datalan in datalans:
        iface = node.addInterface("if%d" % (j,))
        datalan.addInterface(iface)
        j += 1
    if TBCMD is not None:
        node.addService(RSpec.Execute(shell="sh",command=TBCMD))
    if disableTestbedRootKeys:
        node.installRootKeys(False, False)
    nodes[nodename] = node

for nname in nodes.keys():
    rspec.addResource(nodes[nname])
if mgmtlan:
    rspec.addResource(mgmtlan)
for datalan in datalans:
    rspec.addResource(datalan)

#
# Add our parameters to the request so we can get their values to our nodes.
# The nodes download the manifest(s), and the setup scripts read the parameter
# values when they run.
#
class Parameters(RSpec.Resource):
    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/johnsond/1}"
        paramXML = "%sparameter" % (ns,)
        
        el = ET.SubElement(root,"%sprofile_parameters" % (ns,))

        param = ET.SubElement(el,paramXML)
        param.text = 'HEAD="node-0"'
        param = ET.SubElement(el,paramXML)
        if mgmtlan:
            param.text = 'MGMTLAN="%s"' % (mgmtlan.client_id)
        else:
            param.text = 'MGMTLAN="%s"' % (datalans[0].client_id)
        param = ET.SubElement(el,paramXML)
        param.text = 'DATALANS="%s"' % (' '.join(map(lambda(lan): lan.client_id,datalans)))

        return el
    pass

parameters = Parameters()
rspec.addResource(parameters)

class EmulabEncrypt(RSpec.Resource):
    def _write(self, root):
        ns = "{http://www.protogeni.net/resources/rspec/ext/emulab/1}"
        el = ET.SubElement(root,"%spassword" % (ns,),attrib={'name':'adminPass'})

adminPassResource = EmulabEncrypt()
rspec.addResource(adminPassResource)

pc.printRequestRSpec(rspec)
