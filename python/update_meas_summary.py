#!/usr/bin/env python

# Get number of missing OBJECTIDs from nsc_instcal_combine_update_meas.py logs for each exposures

import os
import sys
import numpy as np
import time
from dlnpyutils import utils as dln, db
from astropy.table import Table
from astropy.io import fits
import sqlite3
import socket
from argparse import ArgumentParser
import logging
from glob import glob
import subprocess
import healpy as hp

def get_missingids(exposure):
    """ Get the number of missing IDs from the log files."""

    t00 = time.time()
    hostname = socket.gethostname()
    host = hostname.split('.')[0]

    iddir = '/data0/dnidever/nsc/instcal/v3/idstr/'
    version = 'v3'

    # Load the exposures table
    print('Loading exposure table')
    expcat = fits.getdata('/net/dl2/dnidever/nsc/instcal/'+version+'/lists/nsc_v3_exposure_table.fits.gz',1)

    # Make sure it's a list
    if type(exposure) is str: exposure=[exposure]

    # Match exposures to exposure catalog
    eind1,eind2 = dln.match(expcat['EXPOSURE'],exposure)
    
    nexp = len(exposure)
    outstr = np.zeros(nexp,np.dtype([('exposure',(np.str,100)),('nmissing',int)]))
    outstr['exposure'] = exposure
    outstr['nmissing'] = -1

    # Loop over files
    for i in range(nexp):
        t0 = time.time()
        exp = expcat['EXPOSURE'][eind1[i]]
        print(str(i+1)+' '+exp)

        instcode = expcat['INSTRUMENT'][eind1[i]]
        dateobs = expcat['DATEOBS'][eind1[i]]
        night = dateobs[0:4]+dateobs[5:7]+dateobs[8:10]
        expdir = '/net/dl2/dnidever/nsc/instcal/'+version+'/'+instcode+'/'+night+'/'+exp
        logfile = glob(expdir+'/'+exp+'_measure_update.????????????.log')
        nlogfile = len(logfile)
        # No logfile
        if nlogfile==0:
            print('No logfile')
            continue
        # more than 1 logfile, get the latest one
        if nlogfile>1:
            mtime = [os.path.getmtime(f) for f in logfile]
            si = np.argsort(mtime)[::-1]
            logfile = logfile[si[0]]
        else:
            logfile = logfile[0]
        # Read in logfile
        lines = dln.readlines(logfile)
        badind = dln.grep(lines,'WARNING:',index=True)
        nbadind = len(badind)
        # Some missing objectids
        if nbadind>0:
            badline = lines[badind[0]]
            lo = badline.find('WARNING:')
            hi = badline.find('measurements')
            nmissing = int(badline[lo+9:hi-1])
            print('  '+str(nmissing)+' missing')
            outstr['nmissing'][i] = nmissing
        else:
            outstr['nmissing'][i] = 0

    return outstr


if __name__ == "__main__":
    parser = ArgumentParser(description='Get missing objectids in exposures')
    parser.add_argument('exposure', type=str, nargs=1, help='Exposure name')
    parser.add_argument('outfile', type=str, nargs=1, help='Output filename')
    #parser.add_argument('-r','--redo', action='store_true', help='Redo this exposure')
    args = parser.parse_args()

    hostname = socket.gethostname()
    host = hostname.split('.')[0]
    exposure = args.exposure[0]
    outfile = args.outfile[0]
    #redo = args.redo

    # Input is a list
    if exposure[0]=='@':
        listfile = exposure[1:]
        if os.path.exists(listfile): 
            exposure = dln.readlines(listfile)
        else:
            print(listfile+' NOT FOUND')
            sys.exit()

    # Update the measurement files
    outstr = get_missingids(exposure)

    # Save the output
    print('Writing output to '+outfile)
    Table(outstr).write(outfile,overwrite=True)
