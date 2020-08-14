#
# Copyright (c) 2008-2013 University of Utah and the Flux Group.
# 
# {{{GENIPUBLIC-LICENSE
# 
# GENI Public License
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and/or hardware specification (the "Work") to
# deal in the Work without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Work, and to permit persons to whom the Work
# is furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Work.
# 
# THE WORK IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE WORK OR THE USE OR OTHER DEALINGS
# IN THE WORK.
# 
# }}}
#

import six
try:
    from urlparse import urlsplit, urlunsplit
    from urllib import splitport
    import xmlrpclib
    import httplib
except:
    from urllib.parse import urlsplit, urlunsplit
    from urllib.request import splitport
    import xmlrpc.client as xmlrpclib
    import http.client as httplib
import os
import getopt
import sys
import time
import traceback
import ssl
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID
from cryptography.x509.oid import ExtensionOID

# Debugging output.
debug           = 0
impotent        = 0

HOME            = os.environ["HOME"]
# Path to my certificate
CERTIFICATE     = HOME + "/.ssl/encrypted.pem"
# Got tired of typing this over and over so I stuck it in a file.
PASSPHRASEFILE  = HOME + "/.ssl/password"
passphrase      = ""

CONFIGFILE      = ".protogeni-config.py"
GLOBALCONF      = HOME + "/" + CONFIGFILE
LOCALCONF       = CONFIGFILE
EXTRACONF       = None
SLICENAME       = "mytestslice"
REQARGS         = None
CMURI           = None
SAURI           = None
DELETE          = 0

selfcredentialfile = None
slicecredentialfile = None
admincredentialfile = None
speaksforcredential = None

if "DEFAULTAUTHENTICATE" not in globals():
    DEFAULTAUTHENTICATE=1

authenticate=DEFAULTAUTHENTICATE

verify = False
cacertificate = None

myprint = six.print_

if "Usage" not in dir():
    def Usage():
        myprint("usage: " + sys.argv[ 0 ] + " [option...]")
        myprint("Options:")
        BaseOptions()
        pass
    pass

def BaseOptions():
    myprint("""
    -a file, --admincredentials=file    read admin credentials from file
    -A, --authenticated                 authenticate client
    -c file, --credentials=file         read self-credentials from file
                                            [default: query from SA]
    -d, --debug                         be verbose about XML methods invoked
    -f file, --certificate=file         read SSL certificate from file
                                            [default: ~/.ssl/encrypted.pem]
    -h, --help                          show options and usage
    -l uri, --sa=uri                    specify uri of slice authority
                                            [default: local]
    -m uri, --cm=uri                    specify uri of component manager
                                            [default: local]""")
    if "ACCEPTSLICENAME" in globals():
        myprint("""    -n name, --slicename=name           specify human-readable name of slice
                                            [default: mytestslice]""")
        pass
    myprint("""    -p file, --passphrase=file          read passphrase from file
                                            [default: ~/.ssl/password]
    -r file, --read-commands=file       specify additional configuration file
    -s file, --slicecredentials=file    read slice credentials from file
                                            [default: query from SA]
    -S file, --speaksfor=file           read speaksfor credential from file
    -U, --unauthenticated               do not authenticate client
        --verify                        enable server verification
        --cacertificate=file            read CA certificate from file""")
    pass

try:
    opts, REQARGS = getopt.gnu_getopt( sys.argv[ 1: ], "a:Ac:df:hl:m:n:p:r:s:S:U",
                                       [ "admincredentials=", "authenticated",
                                         "credentials=", "debug",
                                         "certificate=", "help", "sa=", "cm=",
                                         "slicename=", "passphrase=",
                                         "read-commands=", "slicecredentials=",
                                         "speaksfor=", "unauthenticated",
                                         "delete", "verify", "cacertificate=" ] )

except getopt.GetoptError:
    myprint(str(sys.exc_info()[1]),file=sys.stderr)
    Usage()
    sys.exit( 1 )

args = REQARGS

if "PROTOGENI_CERTIFICATE" in os.environ:
    CERTIFICATE = os.environ[ "PROTOGENI_CERTIFICATE" ]
if "PROTOGENI_PASSPHRASE" in os.environ:
    PASSPHRASEFILE = os.environ[ "PROTOGENI_PASSPHRASE" ]

for opt, arg in opts:
    if opt in ( "-a", "--admincredentials" ):
        admincredentialfile = arg
    elif opt in ( "-A", "--authenticated" ):
        authenticate=1
    elif opt in ( "-c", "--credentials" ):
        selfcredentialfile = arg
    elif opt in ( "-d", "--debug" ):
        debug = 1
    elif opt in ( "-f", "--certificate" ):
        CERTIFICATE = arg
    elif opt in ( "-h", "--help" ):
        Usage()
        sys.exit( 0 )
    elif opt in ( "-l", "--sa" ):
        SAURI = arg
        if SAURI[-2:] == "cm":
            SAURI = SAURI[:-3]
    elif opt in ( "-m", "--cm" ):
        CMURI = arg
        if CMURI[-2:] == "cm":
            CMURI = CMURI[:-3]
        elif CMURI[-4:] == "cmv2":
            CMURI = CMURI[:-5]
            pass
        pass
    elif opt in ( "-n", "--slicename" ):
        SLICENAME = arg
    elif opt in ( "-p", "--passphrase" ):
        PASSPHRASEFILE = arg
    elif opt in ( "-r", "--read-commands" ):
        EXTRACONF = arg
    elif opt in ( "-s", "--slicecredentials" ):
        slicecredentialfile = arg
    elif opt in ( "-S", "--speaksfor" ):
        f = open(arg)
        speaksforcredential = f.read()
        f.close()
    elif opt in ( "-U", "--unauthenticated" ):
        authenticate=0
    elif opt in ( "--delete" ):
        DELETE = 1
    elif opt in ( "--verify" ):
        verify = True
    elif opt in ("--cacertificate"):
        cacertificate = arg

# try to load a cert even if we're not planning to authenticate, since we
# can use it to construct default authority locations
certdata = None
try:
    fd = open(CERTIFICATE)
    certdata = fd.read()
    fd.close()
except IOError:
    myprint('Error reading certificate file %s: %s' % (CERTIFICATE,sys.exc_info()[1].strerror))
cert = None
try:
    cert = x509.load_pem_x509_certificate(six.b(certdata),default_backend())
except Exception:
    myprint('Error loading certificate: %s' % (str(sys.exc_info()[1])))

if verify and cacertificate is not None:
    if not os.access(cacertificate, os.R_OK):
        myprint("CA Certificate cannot be accessed: " + cacertificate)
        sys.exit(-1);

# XMLRPC server: use www.emulab.net for the clearinghouse.
XMLRPC_SERVER   = { "ch" : "www.emulab.net", "sr" : "www.emulab.net" }
SERVER_PATH = { "ch" : ":12369/protogeni/xmlrpc/",
                "sr" : ":12370/protogeni/pubxmlrpc/" }

try:
    descriptors = cert.extensions.get_extension_for_oid(
        ExtensionOID.AUTHORITY_INFORMATION_ACCESS).value
    url = None
    for d in descriptors:
        if d.access_method.dotted_string == '2.25.305821105408246119474742976030998643995':
            url = d.access_location.value
            break
    if url:
        url = url.rstrip()
        # strip trailing sa
        if url.endswith('/sa') > 0:
            url = url[:-2]
        scheme, netloc, path, query, fragment = urlsplit(url)
        host,port = splitport(netloc)
        XMLRPC_SERVER["default"] = host
        if port:
            path = ":" + port + path
        SERVER_PATH["default"] = path
except Exception:
    if debug:
        myprint("Warning: error getting authInfoAccess extension value:")
        traceback.print_exc()
    pass

if "default" not in XMLRPC_SERVER:
    XMLRPC_SERVER["default"] = cert.issuer.get_attributes_for_oid(
        NameOID.COMMON_NAME)[0].value
    SERVER_PATH ["default"] = ":443/protogeni/xmlrpc/"
pass

if os.path.exists( GLOBALCONF ):
    execfile( GLOBALCONF )
if os.path.exists( LOCALCONF ):
    execfile( LOCALCONF )
if EXTRACONF and os.path.exists( EXTRACONF ):
    execfile( EXTRACONF )

if "sa" in XMLRPC_SERVER:
    HOSTNAME = XMLRPC_SERVER[ "sa" ]
else:
    HOSTNAME = XMLRPC_SERVER[ "default" ]
DOMAIN   = HOSTNAME[HOSTNAME.find('.')+1:]
SLICEURN = "urn:publicid:IDN+" + DOMAIN + "+slice+" + SLICENAME

# If the passphrase file exists, read it:
passphrase = None
if os.path.exists(PASSPHRASEFILE):
    try:
        passphrase = open(PASSPHRASEFILE).readline()
        passphrase = passphrase.strip()
        if passphrase == '':
            myprint('Passphrase file empty; you may be prompted')
            passphrase = None
    except IOError:
        myprint('Error reading passphrase file %s: %s' % (
            PASSPHRASEFILE,sys.exc_info()[1].strerror))
else:
    if debug:
        myprint('Passphrase file %s does not exist' % (PASSPHRASEFILE))

def Fatal(message):
    myprint(message,file=sys.stderr)
    sys.exit(1)

def geni_am_response_handler(method, method_args):
    """Handles the GENI AM responses, which are different from the
    ProtoGENI responses. ProtoGENI always returns a dict with three
    keys (code, value, and output. GENI AM operations return the
    value, or an XML RPC Fault if there was a problem.
    """
    return apply(method, method_args)

def geni_sr_response_handler(method, method_args):
    """Handles the GENI SR responses, which are different from the
    ProtoGENI responses. ProtoGENI always returns a dict with three
    keys (code, value, and output). GENI SR operations return the
    value, or an XML RPC Fault if there was a problem.
    """
    return apply(method, method_args)

#
# Call the rpc server.
#
def do_method(module, method, params, URI=None, quiet=False, version=None,
              response_handler=None):
    #
    # Add speaksforcredential for credentials list.
    #
    if "credentials" in params and speaksforcredential:
        if 1 or type(params["credentials"]) is tuple:
            params["credentials"] = list(params["credentials"])
            pass
        params["credentials"].append(speaksforcredential);
        pass
    
    if URI == None and CMURI and (module == "cm" or module == "cmv2"):
        URI = CMURI
    elif URI == None and SAURI and module == "sa":
        URI = SAURI

    if URI == None:
        if module in XMLRPC_SERVER:
            addr = XMLRPC_SERVER[ module ]
        else:
            addr = XMLRPC_SERVER[ "default" ]

        if module in SERVER_PATH:
            path = SERVER_PATH[ module ]
        else:
            path = SERVER_PATH[ "default" ]

        URI = "https://" + addr + path + module
    elif module:
        URI = URI + "/" + module
        pass

    if version:
        URI = URI + "/" + version
        pass

    url = urlsplit(URI, "https")

    if debug:
        myprint(str( url ) + " " + method)

    if url.scheme == "https":
        if authenticate and not cert:
            if not quiet:
                myprint("error: missing emulab certificate: " + CERTIFICATE,file=sys.stderr)
            return (-1, None)

        port = url.port if url.port else 443

        ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
        if authenticate:
            ctx.load_cert_chain(CERTIFICATE,password=passphrase)
        if not verify:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        else:
            if cacertificate:
                ctx.load_verify_locations(cafile=cacertificate)
            ctx.verify_mode = ssl.CERT_REQUIRED

        server = httplib.HTTPSConnection( url.hostname, port, context = ctx )
    elif url.scheme == "http":
        port = url.port if url.port else 80
        server = httplib.HTTPConnection( url.hostname, port )
        
    if response_handler:
        # If a response handler was passed, use it and return the result.
        # This is the case when running the GENI AM.
        def am_helper( server, path, body ):
            server.request( "POST", path, body )
            return xmlrpclib.loads( server.getresponse().read() )[ 0 ][ 0 ]
            
        return response_handler( ( lambda *x: am_helper( server, url.path, xmlrpclib.dumps( x, method ) ) ), params )

    #
    # Make the call. 
    #
    while True:
        try:
            server.request( "POST", url.path, xmlrpclib.dumps( (params,), method ) )
            response = server.getresponse()
            if response.status == 503:
                if not quiet:
                    myprint("Will try again in a moment. Be patient!",file=sys.stderr)
                time.sleep(5.0)
                continue
            elif response.status != 200:
                if not quiet:
                    myprint(str(response.status) + " " + response.reason,file=sys.stderr)
                return (-1,None)
            response = xmlrpclib.loads( response.read() )[ 0 ][ 0 ]
            break
        except httplib.HTTPException:
            if not quiet: myprint(sys.exc_info()[1],file=sys.stderr)
            return (-1, None)
        except xmlrpclib.Fault:
            e = sys.exc_info()[1]
            if e.faultCode == 503:
                myprint(e.faultString + " Retrying\n",file=sys.stderr)
                time.sleep(5.0)
                continue;
            if not quiet: myprint(e.faultString,file=sys.stderr)
            return (-1, None)
        except ssl.CertificateError:
            e = sys.exc_info()[1]
            if not quiet:
                myprint("Warning: possible certificate host name mismatch.",file=sys.stderr)
                myprint("Please consult:",file=sys.stderr)
                myprint("    http://www.protogeni.net/trac/protogeni/wiki/HostNameMismatch",file=sys.stderr)
                myprint("for recommended solutions.",file=sys.stderr)
                myprint(e,file=sys.stderr)
                pass
            return (-1, None)

    #
    # Parse the Response, which is a Dictionary. See EmulabResponse in the
    # emulabclient.py module. The XML standard converts classes to a plain
    # Dictionary, hence the code below. 
    # 
    if response[ "code" ] and len(response["output"]):
        if not quiet: myprint(response["output"] + ":",file=sys.stderr)
        pass

    rval = response["code"]

    #
    # If the code indicates failure, look for a "value". Use that as the
    # return value instead of the code. 
    # 
    if rval:
        if response["value"]:
            rval = response["value"]
            pass
        pass
    return (rval, response)

def get_self_credential():
    if selfcredentialfile:
        f = open( selfcredentialfile )
        c = f.read()
        f.close()
        return c
    params = {}
    rval,response = do_method_retry("sa", "GetCredential", params)
    if rval:
        Fatal("Could not get my credential")
        pass
    return response["value"]

def do_method_retry(suffix, method, params):
  count = 200;
  rval, response = do_method(suffix, method, params)
  while count > 0 and response and response["code"] == 14:
      count = count - 1
      myprint(" Will try again in a few seconds\n")
      time.sleep(5.0)
      rval, response = do_method(suffix, method, params)
  return (rval, response)

def resolve_slice( name, selfcredential ):
    if slicecredentialfile:
        myslice = {}
        myslice["urn"] = SLICEURN
        return myslice
    params = {}
    params["credential"] = mycredential
    params["type"]       = "Slice"
    if name.startswith("urn:"):
        params["urn"]       = name
    else:
        params["hrn"]       = name
        pass
    
    while True:
        rval,response = do_method_retry("sa", "Resolve", params)
        if rval:
            Fatal("Slice does not exist");
            pass
        else:
            break
        pass
    return response["value"]

def get_slice_credential( slice, selfcredential ):
    if slicecredentialfile:
        f = open( slicecredentialfile )
        c = f.read()
        f.close()
        return c

    params = {}
    params["credential"] = selfcredential
    params["type"]       = "Slice"
    if "urn" in slice:
        params["urn"]       = slice["urn"]
    else:
        params["uuid"]      = slice["uuid"]
        pass

    while True:
        rval,response = do_method_retry("sa", "GetCredential", params)
        if rval:
            Fatal("Could not get Slice credential")
            pass
        else:
            break
        pass
    return response["value"]
