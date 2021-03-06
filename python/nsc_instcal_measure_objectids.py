#!/usr/bin/env python

# Update the measurement catalog with the objectID

import os
import sys
import numpy as np
import time
import healpy as hp
from astropy.io import fits
from astropy.table import Table
from dlnpyutils import utils as dln
import shutil
import sqlite3
from glob import glob
import socket
from argparse import ArgumentParser
import logging
import subprocess

def querydb(dbfile,table='meas',cols='rowid,*',where=None):
    """ Query database table """
    sqlite3.register_adapter(np.int16, int)
    sqlite3.register_adapter(np.int64, int)
    sqlite3.register_adapter(np.float64, float)
    sqlite3.register_adapter(np.float32, float)
    db = sqlite3.connect(dbfile, detect_types=sqlite3.PARSE_DECLTYPES|sqlite3.PARSE_COLNAMES)
    cur = db.cursor()
    cmd = 'SELECT '+cols+' FROM '+table
    if where is not None: cmd += ' WHERE '+where
    cur.execute(cmd)
    data = cur.fetchall()
    db.close()

    # Return results
    return data


def readidstrdb(dbfile,where=None):
    """ Get data from IDSTR database"""
    data = querydb(dbfile,table='idstr',cols='rowid,measid,exposure,objectid',where=where)
    # Put in catalog
    #dtype_idstr = np.dtype([('measid',np.str,200),('exposure',np.str,200),('objectid',np.str,200),('objectindex',int)])
    dtype_idstr = np.dtype([('rowid',int),('measid',np.str,200),('exposure',np.str,200),('objectid',np.str,200)])
    cat = np.zeros(len(data),dtype=dtype_idstr)
    cat[...] = data
    del data
    return cat

def measurement_info(pix):

    t0 = time.time()
    hostname = socket.gethostname()
    host = hostname.split('.')[0]

    # Get version number from exposure directory
    #lo = expdir.find('nsc/instcal/')
    #dum = expdir[lo+12:]
    #version = dum[0:dum.find('/')]
    version = 'v3'
    cmbdir = '/net/dl2/dnidever/nsc/instcal/'+version+'/'
    #edir = '/net/dl1/users/dnidever/nsc/instcal/'+version+'/'
    #nside = 128

    #expstr = fits.getdata('/net/dl2/dnidever/nsc/instcal/'+version+'/lists/nsc_'+version+'_exposures.fits.gz',1)
    # too much many columns, just need full path and base
    metadb = '/net/dl2/dnidever/nsc/instcal/'+version+'/lists/nsc_meta.db'
    data = querydb(metadb,'exposure','expdir')
    data = [a[0] for a in data]
    expdir = np.char.array(data)
    expdir = expdir.rstrip('/')
    base = [os.path.basename(e) for e in expdir]
    base = np.char.array(base)

    # If we put the output files in a PIX_idstr/ subdirectory then I wouldn't need to
    # know all of this exposure path information

    dbfile = cmbdir+'combine/'+str(int(pix)//1000)+'/'+str(pix)+'_idstr.db'    
    print(dbfile)

    # Deal with sub-pixels!!

    # Get the row count
    db = sqlite3.connect(dbfile, detect_types=sqlite3.PARSE_DECLTYPES|sqlite3.PARSE_COLNAMES)
    cur = db.cursor()
    cur.execute('select count(rowid) from idstr')
    data = cur.fetchall()
    db.close()
    nrows = data[0][0]
    print(str(nrows)+' rows')

    print('Loading the data')
    idstr = readidstrdb(dbfile)
    # Need to do this in chunks if there are too many rows
    

    # Get unique exposures
    exposure = np.char.array(idstr['exposure'])
    expindex = dln.create_index(exposure)
    nexp = len(expindex['value'])
    print(str(nexp)+' exposures')

    # Get absolute paths
    ind1,ind2 = dln.match(base,expindex['value'])
    expdirs = np.zeros(nexp,(np.str,200))
    expdirs[ind2] = expdir[ind1]

    # Convert /dl1 to /dl2
    expdirs = np.char.array(expdirs).replace('/dl1/users/dnidever/','/dl2/dnidever/')

    # Loop through the exposures and write out their information
    for e in range(nexp):
        exposure1 = expindex['value'][e]
        eind = expindex['index'][expindex['lo'][e]:expindex['hi'][e]+1]
        idstr1 = idstr[eind]
        nidstr1 = len(idstr1)
        # Just need measid,objectid, and only the width that we need
        mlen = np.max([len(m) for m in idstr1['measid']])
        olen = np.max([len(o) for o in idstr1['objectid']])
        dt = np.dtype([('measid',np.str,mlen),('objectid',np.str,olen)])
        new = np.zeros(nidstr1,dtype=dt)
        new['measid'] = idstr1['measid']
        new['objectid'] = idstr1['objectid']
        print(str(e+1)+' '+exposure1+' '+str(nidstr1))

        # Put these files in expdir/idstr/ subdirectory!!

        # Write it out
        outfile = expdirs[e]+'/'+exposure1+'_objectid_list.fits'
        #outfile = expdirs[e]+'/'+exposure1+'_objectid_list.npy'
        print('  Writing '+outfile)
        #if os.path.exists(outfile): os.remove(outfile)
        #np.save(outfile,new)   # not any faster
        Table(new).write(outfile,overwrite=True)

    print('dt = '+str(time.time()-t0)+' sec.')

    import pdb; pdb.set_trace()
    

    # Check if output file already exists
    #base = os.path.basename(expdir)

    ## Log file
    ##------------------
    ## format is nsc_combine_main.DATETIME.log
    #ltime = time.localtime()
    ## time.struct_time(tm_year=2019, tm_mon=7, tm_mday=22, tm_hour=0, tm_min=30, tm_sec=20, tm_wday=0, tm_yday=203, tm_isdst=1)                                                   
    #smonth = str(ltime[1])
    #if ltime[1]<10: smonth = '0'+smonth
    #sday = str(ltime[2])
    #if ltime[2]<10: sday = '0'+sday
    #syear = str(ltime[0])[2:]
    #shour = str(ltime[3])
    #if ltime[3]<10: shour='0'+shour
    #sminute = str(ltime[4])
    #if ltime[4]<10: sminute='0'+sminute
    #ssecond = str(int(ltime[5]))
    #if ltime[5]<10: ssecond='0'+ssecond
    #logtime = smonth+sday+syear+shour+sminute+ssecond
    #logfile = expdir+'/'+base+'_measure_update.'+logtime+'.log'
    #if os.path.exists(logfile): os.remove(logfile)

    ## Set up logging to screen and logfile                                                                                                                                         
    #logFormatter = logging.Formatter("%(asctime)s [%(levelname)-5.5s]  %(message)s")
    #rootLogger = logging.getLogger()
    #fileHandler = logging.FileHandler(logfile)
    #fileHandler.setFormatter(logFormatter)
    #rootLogger.addHandler(fileHandler)
    #consoleHandler = logging.StreamHandler()
    #consoleHandler.setFormatter(logFormatter)
    #rootLogger.addHandler(consoleHandler)
    #rootLogger.setLevel(logging.NOTSET)

    #rootLogger.info('Adding objectID for measurement catalogs for exposure = '+base)
    #rootLogger.info("expdir = "+expdir)
    #rootLogger.info("host = "+host)
    #rootLogger.info(" ")

    #  Load the exposure and metadata files
    metafile = expdir+'/'+base+'_meta.fits'
    meta = Table.read(metafile,1)
    nmeta = len(meta)
    chstr = Table.read(metafile,2)
    rootLogger.info('KLUDGE!!!  Changing /dl1 filenames to /dl2 filenames')
    cols = ['EXPDIR','FILENAME','MEASFILE']
    for c in cols:
        f = np.char.array(chstr[c]).decode()
        f = np.char.array(f).replace('/dl1/users/dnidever/','/dl2/dnidever/')
        chstr[c] = f
    nchips = len(chstr)

    measdtype = np.dtype([('MEASID', 'S50'), ('OBJECTID', 'S50'), ('EXPOSURE', 'S50'), ('CCDNUM', '>i2'), ('FILTER', 'S2'), ('MJD', '>f8'), ('X', '>f4'),
                          ('Y', '>f4'), ('RA', '>f8'), ('RAERR', '>f4'), ('DEC', '>f8'), ('DECERR', '>f4'), ('MAG_AUTO', '>f4'), ('MAGERR_AUTO', '>f4'),
                          ('MAG_APER1', '>f4'), ('MAGERR_APER1', '>f4'), ('MAG_APER2', '>f4'), ('MAGERR_APER2', '>f4'), ('MAG_APER4', '>f4'),
                          ('MAGERR_APER4', '>f4'), ('MAG_APER8', '>f4'), ('MAGERR_APER8', '>f4'), ('KRON_RADIUS', '>f4'), ('ASEMI', '>f4'), ('ASEMIERR', '>f4'),
                          ('BSEMI', '>f4'), ('BSEMIERR', '>f4'), ('THETA', '>f4'), ('THETAERR', '>f4'), ('FWHM', '>f4'), ('FLAGS', '>i2'), ('CLASS_STAR', '>f4')])

    # Load and concatenate the meas catalogs
    chstr['MEAS_INDEX'] = 0   # keep track of where each chip catalog starts
    count = 0
    meas = Table(data=np.zeros(int(np.sum(chstr['NMEAS'])),dtype=measdtype))
    rootLogger.info('Loading and concatenating the chip measurement catalogs')
    for i in range(nchips):
        meas1 = Table.read(chstr['MEASFILE'][i].strip(),1)   # load chip meas catalog
        nmeas1 = len(meas1)
        meas[count:count+nmeas1] = meas1
        chstr['MEAS_INDEX'][i] = count
        count += nmeas1
    measid = np.char.array(meas['MEASID']).strip().decode()
    nmeas = len(meas)
    rootLogger.info(str(nmeas)+' measurements')

    # Get the OBJECTID from the combined healpix file IDSTR structure
    #  remove any sources that weren't used

    # Figure out which healpix this figure overlaps
    pix = hp.ang2pix(nside,meas['RA'],meas['DEC'],lonlat=True)
    upix = np.unique(pix)
    npix = len(upix)
    rootLogger.info(str(npix)+' HEALPix to query')

    # Loop over the HEALPix pixels
    ntotmatch = 0
    idstr_dtype = np.dtype([('measid',np.str,200),('objectid',np.str,200),('pix',int)])
    idstr = np.zeros(nmeas,dtype=idstr_dtype)
    cnt = 0
    for i in range(npix):
        fitsfile = cmbdir+'combine/'+str(int(upix[i])//1000)+'/'+str(upix[i])+'.fits.gz'
        dbfile = cmbdir+'combine/'+str(int(upix[i])//1000)+'/'+str(upix[i])+'_idstr.db'
        if os.path.exists(dbfile):
            # Read meas id information from idstr database for this expoure
            #data = querydb(dbfile,table='idstr',cols='measid,objectid',where="exposure=='"+base+"'")
            idstr1 = readidstrdb(dbfile,where="exposure=='"+base+"'")
            nidstr1 = len(idstr1)
            if nidstr1>0:
                idstr['measid'][cnt:cnt+nidstr1] = idstr1['measid']
                idstr['objectid'][cnt:cnt+nidstr1] = idstr1['objectid']
                idstr['pix'][cnt:cnt+nidstr1] = upix[i]
                cnt += nidstr1
            rootLogger.info(str(i+1)+' '+str(upix[i])+' '+str(nidstr1))
            #nmatch = 0
            #if nidstr>0:
            #    idstr_measid = np.char.array(idstr['measid']).strip()
            #    idstr_objectid = np.char.array(idstr['objectid']).strip()
            #    #ind1,ind2 = dln.match(idstr_measid,measid)
            #    nmatch = len(ind1)
            #    if nmatch>0:
            #        meas['OBJECTID'][ind2] = idstr_objectid[ind1]
            #        ntotmatch += nmatch
            #rootLogger.info(str(i+1)+' '+str(upix[i])+' '+str(nmatch))

        else:
            rootLogger.info(str(i+1)+' '+dbfile+' NOT FOUND.  Checking for high-resolution database files.')
            # Check if there are high-resolution healpix idstr databases
            hidbfiles = glob(cmbdir+'combine/'+str(int(upix[i])//1000)+'/'+str(upix[i])+'_n*_*_idstr.db')
            nhidbfiles = len(hidbfiles)
            if os.path.exists(fitsfile) & (nhidbfiles>0):
                rootLogger.info('Found high-resolution HEALPix IDSTR files')
                for j in range(nhidbfiles):
                    dbfile1 = hidbfiles[j]
                    dbbase1 = os.path.basename(dbfile1)
                    idstr1 = readidstrdb(dbfile1,where="exposure=='"+base+"'")
                    nidstr1 = len(idstr1)
                    if nidstr1>0:
                        idstr['measid'][cnt:cnt+nidstr1] = idstr1['measid']
                        idstr['objectid'][cnt:cnt+nidstr1] = idstr1['objectid']
                        idstr['pix'][cnt:cnt+nidstr1] = upix[i]
                        cnt += nidstr1
                    rootLogger.info('  '+str(j+1)+' '+dbbase1+' '+str(upix[i])+' '+str(nidstr1))
                    #idstr_measid = np.char.array(idstr['measid']).strip()
                    #idstr_objectid = np.char.array(idstr['objectid']).strip()
                    #ind1,ind2 = dln.match(idstr_measid,measid)
                    #nmatch = len(ind1)
                    #if nmatch>0:
                    #    meas['OBJECTID'][ind2] = idstr_objectid[ind1]
                    #    ntotmatch += nmatch
                    #rootLogger.info('  '+str(j+1)+' '+dbbase1+' '+str(upix[i])+' '+str(nmatch))

    # Trim any leftover elements of IDSTR
    if cnt<nmeas:
        idstr = idstr[0:cnt]

    # Now match them all up
    rootLogger.info('Matching the measurements')
    idstr_measid = np.char.array(idstr['measid']).strip()
    idstr_objectid = np.char.array(idstr['objectid']).strip() 
    ind1,ind2 = dln.match(idstr_measid,measid)
    nmatch = len(ind1)
    if nmatch>0:
        meas['OBJECTID'][ind2] = idstr_objectid[ind1] 


    # Only keep sources with an objectid
    ind,nind = dln.where(np.char.array(meas['OBJECTID']).strip().decode() == '')
    # There can be missing/orphaned measurements at healpix boundaries in crowded
    # regions when the DBSCAN eps is different.  But there should be very few of these.
    # At this point, let's allow this to pass
    if nind>0:
        rootLogger.info('WARNING: '+str(nind)+' measurements are missing OBJECTIDs')
    if ((nmeas>=20000) & (nind>20)) | ((nmeas<20000) & (nind>3)):
        rootLogger.info('More missing OBJECTIDs than currently allowed.')
        raise ValueError('More missing OBJECTIDs than currently allowed.')

    # Output the updated catalogs
    #rootLogger.info('Updating measurement catalogs')
    #for i in range(nchips):
    #    measfile1 = chstr['MEASFILE'][i].strip()
    #    lo = chstr['MEAS_INDEX'][i]
    #    hi = lo+chstr['NMEAS'][i]
    #    meas1 = meas[lo:hi]
    #    meta1 = Table.read(measfile1,2)        # load the meta extensions
    #    # 'KLUDGE!!!  Changing /dl1 filenames to /dl2 filenames')
    #    cols = ['EXPDIR','FILENAME','MEASFILE']
    #    for c in cols:
    #        f = np.char.array(meta1[c]).decode()
    #        f = np.char.array(f).replace('/dl1/users/dnidever/','/dl2/dnidever/')
    #        meta1[c] = f
    #    # Copy as a backup
    #    if os.path.exists(measfile1+'.bak'): os.remove(measfile1+'.bak')
    #    dum = shutil.move(measfile1,measfile1+'.bak')
    #    # Write new catalog
    #    #meas1.write(measfile1,overwrite=True)  # first, measurement table
    #    # append other fits binary tabl
    #    #hdulist = fits.open(measfile1)
    #    rootLogger.info('Writing '+measfile1)
    #    hdulist = fits.HDUList()
    #    hdulist.append(fits.table_to_hdu(meas1))       # first, meas catalog
    #    hdulist.append(fits.table_to_hdu(meta1))       # second, meta
    #    hdulist.writeto(measfile1,overwrite=True)
    #    hdulist.close()
    #    # Create a file saying that the file was successfully updated.
    #    dln.writelines(measfile1+'.updated','')
    #    # Delete backups
    #    if os.path.exists(measfile1+'.bak'): os.remove(measfile1+'.bak')

    measfile = expdir+'/'+base+'_meas.fits'
    meas.write(measfile,overwrite=True)
    if os.path.exists(measfile+'.gz'): os.remove(measfile+'.gz')
    ret = subprocess.call(['gzip',measfile])    # compress final catalog

    # Update the meta file as well, need to the /dl2 filenames
    rootLogger.info('Updating meta file')
    meta.write(metafile,overwrite=True)
    hdulist = fits.open(metafile)
    hdu = fits.table_to_hdu(chstr)
    hdulist.append(hdu)
    hdulist.writeto(metafile,overwrite=True)
    hdulist.close()

    # Create a file saying that the files were updated okay.
    dln.writelines(expdir+'/'+base+'_meas.updated','')

    rootLogger.info('dt = '+str(time.time()-t0)+' sec.')


if __name__ == "__main__":
    parser = ArgumentParser(description='Update NSC exposure measurement catalogs with OBJECTID.')
    parser.add_argument('pix', type=str, nargs=1, help='Exposure directory')
    parser.add_argument('-r','--redo', action='store_true', help='Redo this exposure catalog')
    #parser.add_argument('-v','--verbose', action='store_true', help='Verbose output')
    args = parser.parse_args()

    hostname = socket.gethostname()
    host = hostname.split('.')[0]
    pix = args.pix[0]
    redo = args.redo

    # Check if the exposure has already been updated
    #base = os.path.basename(expdir)
    #if (os.path.exists(expdir+'/'+base+'_meas.updated') & (not redo)):
    #    print(expdir+' has already been updated and REDO not set')
    #    sys.exit()

    measurement_info(pix)
