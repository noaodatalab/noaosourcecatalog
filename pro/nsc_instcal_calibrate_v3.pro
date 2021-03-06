pro nsc_instcal_calibrate_v3,expdir,inpref,redo=redo,selfcal=selfcal,saveref=saveref,ncpu=ncpu,stp=stp

; Calibrate catalogs for one exposure

NSC_ROOTDIRS,dldir,mssdir,localdir

; Not enough inputs
if n_elements(expdir) eq 0 then begin
  print,'Syntax - nsc_instcal_calibrate,expdir,inpref,redo=redo,selfcal=selfcal,saveref=saveref,ncpu=ncpu,stp=stp'
  return
endif

; Make sure the directory exists
if file_test(expdir,/directory) eq 0 then begin
  print,expdir,' NOT FOUND'
  return
endif

t00 = systime(1)
d2r = !dpi / 180.0d0

; Setting pool thread values
if n_elements(ncpu) eq 0 then ncpu=1
CPU, TPOOL_NTHREADS = ncpu

base = file_basename(expdir)
logf = expdir+'/'+base+'_calib.log'
outfile = expdir+'/'+base+'_cat.fits'

printlog,logf,'Calibrate catalogs for exposure ',base,' in ',expdir

; Check for output file
if file_test(outfile) eq 1 and not keyword_set(redo) then begin
  printlog,logf,outfile,' already exists and /redo not set.'
  return
endif

; What instrument is this?
instrument = 'c4d'  ; by default
if stregex(expdir,'/k4m/',/boolean) eq 1 then instrument='k4m'
if stregex(expdir,'/ksb/',/boolean) eq 1 then instrument='ksb'
printlog,logf,'This is a '+instrument+' exposure'

; Step 1. Read in the catalogs 
;-----------------------------
printlog,logf,'' & printlog,logf,'Step 1. Read in the catalogs'
printlog,logf,'-----------------------------'
catfiles1 = file_search(expdir+'/'+base+'_[1-9].fits',count=ncatfiles1)
if ncatfiles1 gt 0 then push,catfiles,catfiles1
catfiles2 = file_search(expdir+'/'+base+'_[0-9][0-9].fits',count=ncatfiles2)
if ncatfiles2 gt 0 then push,catfiles,catfiles2
ncatfiles = n_elements(catfiles)
if ncatfiles eq 0 then begin
  printlog,logf,'No catalog files found'
  return
endif
nchips = ncatfiles
printlog,logf,strtrim(ncatfiles,2),' catalogs found'

; Check that this isn't a problematic Mosaic3 exposure
if stregex(expdir,'/k4m/',/boolean) eq 1 then begin
  dum = MRDFITS(catfiles[0],1)
  head0 = dum.field_header_card
  pixcnt = sxpar(head0,'PIXCNT*',count=npixcnt)
  if pixcnt gt 0 then begin
    printlog,logf,'This is a Mosaic3 exposure with pixel shift problems'
    return
  endif
  wcscal = sxpar(head0,'WCSCAL',count=nwcscal)
  if nwcscal gt 0 and strtrim(wcscal,2) eq 'Failed' then begin
    printlog,logf,'This is a Mosaic3 exposure with failed WCS calibration'
    return
  endif
endif

; Figure out the number of sources
ncat = 0L
for i=0,ncatfiles-1 do begin
  head = headfits(catfiles[i],exten=2)
  ncat += sxpar(head,'NAXIS2')
endfor
printlog,logf,strtrim(ncat,2),' total sources'
; Create structure, exten=1 has header now
cat1 = MRDFITS(catfiles[0],2,/silent)
if size(cat1,/type) ne 8 then begin
  printlog,logf,'Chip 1 catalog is empty.'
  return
endif
schema = cat1[0]
STRUCT_ASSIGN,{dum:''},schema   ; blank everything out
add_tag,schema,'CCDNUM',0L,schema
add_tag,schema,'EBV',0.0,schema
add_tag,schema,'RA',0.0d0,schema
add_tag,schema,'DEC',0.0d0,schema
add_tag,schema,'RAERR',0.0d0,schema
add_tag,schema,'DECERR',0.0d0,schema
add_tag,schema,'CMAG',99.99,schema
add_tag,schema,'CERR',9.99,schema
add_tag,schema,'SOURCEID','',schema
add_tag,schema,'FILTER','',schema
add_tag,schema,'MJD',0.0d0,schema
cat = REPLICATE(schema,ncat)
; Start the chips summary structure
chstr = replicate({expdir:'',instrument:'',filename:'',ccdnum:0L,nsources:0L,cenra:999999.0d0,cendec:999999.0d0,$
                   ngaiamatch:0L,ngoodgaiamatch:0L,rarms:999999.0,rastderr:999999.0,racoef:dblarr(4),decrms:999999.0,$
                   decstderr:999999.0,deccoef:dblarr(4),vra:dblarr(4),vdec:dblarr(4),zpterm:999999.0,$
                   zptermerr:999999.0,nrefmatch:0L,depth95:99.99,depth10sig:99.99},nchips)
chstr.expdir = expdir
chstr.instrument = instrument
; Load the files
cnt = 0LL
for i=0,ncatfiles-1 do begin
  dum = strsplit(file_basename(catfiles[i],'.fits'),'_',/extract)
  ccdnum = long(first_el(dum,/last))
  hd = headfits(catfiles[i],exten=2)
  cat1 = MRDFITS(catfiles[i],2,/silent)
  ncat1 = sxpar(hd,'naxis2')  ; handles empty catalogs
  ;ncat1 = n_elements(cat1)
  chstr[i].filename = catfiles[i]
  chstr[i].ccdnum = ccdnum
  chstr[i].nsources = ncat1
  ; Get the chip corners
  dum = MRDFITS(catfiles[i],1,/silent)
  hd1 = dum.field_header_card
  nx = sxpar(hd1,'NAXIS1')
  ny = sxpar(hd1,'NAXIS2')
  extast,hd1,ast,noparams  ; check the WCS
  if noparams le 0 then begin
    printlog,logf,'Problem with WCS in header ',catfiles[i]
    goto,BOMB1
  endif
  head_xyad,hd1,[0,nx-1,nx-1,0],[0,0,ny-1,ny-1],vra,vdec,/degree
  chstr[i].vra = vra
  chstr[i].vdec = vdec
  if ncat1 gt 0 then begin
    temp = cat[cnt:cnt+ncat1-1]
    STRUCT_ASSIGN,cat1,temp,/nozero
    temp.ccdnum = ccdnum
    temp.ra = cat1.alpha_j2000  ; add these here in case the astrometric correction fails later on
    temp.dec = cat1.delta_j2000
    ; Add coordinate uncertainties
    ;   sigma = 0.644*FWHM/SNR
    ;   SNR = 1.087/magerr
    snr = 1.087/temp.magerr_auto
    bderr = where(temp.magerr_auto gt 10 and temp.magerr_iso lt 10,nbderr)
    if nbderr gt 0 then snr[bderr]=1.087/temp[bderr].magerr_iso
    bderr = where(temp.magerr_auto gt 10 and temp.magerr_iso gt 10,nbderr)
    if nbderr gt 0 then snr[bderr] = 1
    coorderr = 0.664*(temp.fwhm_world*3600)/snr
    temp.raerr = coorderr
    temp.decerr = coorderr
    ; Stuff into main structure
    cat[cnt:cnt+ncat1-1] = temp
    cnt += ncat1
    cenra = mean(minmax(cat1.alpha_j2000))
    ; Wrapping around RA=0
    if range(cat1.alpha_j2000) gt 100 then begin
      ra = cat1.alpha_j2000
      bdra = where(ra gt 180,nbdra)
      if nbdra gt 0 then ra[bdra]-=360
      bdra2 = where(ra lt -180,nbdra2)
      if nbdra2 gt 0 then ra[bdra2]+=360
      cenra = mean(minmax(ra))
      if cenra lt 0 then cenra+=360
    endif
    chstr[i].cenra = cenra
    chstr[i].cendec = mean(minmax(cat1.delta_j2000))
  endif
  BOMB1:
endfor
; Exposure level values
gdchip = where(chstr.nsources gt 0 and chstr.cenra lt 400,ngdchip)
if ngdchip eq 0 then begin
  printlog,logf,'No good chip catalogs with good WCS.'
  return
endif
; Central coordinates of the entire field
cendec = mean(minmax(chstr[gdchip].cendec))
decrange = range(chstr[gdchip].cendec)
cenra = mean(minmax(chstr[gdchip].cenra))
rarange = range(chstr[gdchip].cenra)*cos(cendec/!radeg)
; Wrapping around RA=0
if range(minmax(chstr[gdchip].cenra)) gt 100 then begin
 ra = chstr[gdchip].cenra
 bdra = where(ra gt 180,nbdra)
 if nbdra gt 0 then ra[bdra]-=360
 bdra2 = where(ra lt -180,nbdra2)
 if nbdra2 gt 0 then ra[bdra2]+=360
 cenra = mean(minmax(ra))
 if cenra lt 0 then cenra+=360
 rarange = range(ra)*cos(cendec/!radeg)
 rawrap = 1
endif else rawrap=0
printlog,logf,'CENRA  = ',stringize(cenra,ndec=5)
printlog,logf,'CENDEC = ',stringize(cendec,ndec=5)
glactc,cenra,cendec,2000.0,glon,glat,1,/deg
printlog,logf,'GLON = ',stringize(glon,ndec=5)
printlog,logf,'GLAT = ',stringize(glat,ndec=5)
; Number of good sources
goodsources = where(cat.imaflags_iso eq 0 and not ((cat.flags and 8) eq 8) and not ((cat.flags and 16) eq 16) and $
                    cat.mag_auto lt 50,ngoodsources)
printlog,logf,'GOOD SRCS = ',strtrim(ngoodsources,2)

; Measure median seeing FWHM
gdcat = where(cat.mag_auto lt 50 and cat.magerr_auto lt 0.05 and cat.class_star gt 0.8,ngdcat)
medfwhm = median(cat[gdcat].fwhm_world*3600.)
printlog,logf,'FWHM = ',stringize(medfwhm,ndec=2),' arcsec'

; Load the logfile and get absolute flux filename
READLINE,expdir+'/'+base+'.log',loglines
ind = where(stregex(loglines,'Step #2: Copying InstCal images from mass store archive',/boolean) eq 1,nind)
fline = loglines[ind[0]+1]
lo = strpos(fline,'/archive')
; make sure the mss1 directory is correct for this server
fluxfile = mssdir+strtrim(strmid(fline,lo+1),2)
wline = loglines[ind[0]+2]
lo = strpos(wline,'/archive')
wtfile = mssdir+strtrim(strmid(wline,lo+1),2)
mline = loglines[ind[0]+3]
lo = strpos(mline,'/archive')
maskfile = mssdir+strtrim(strmid(mline,lo+1),2)

; Load the meta-data from the original header
;READLINE,expdir+'/'+base+'.head',head
head = headfits(fluxfile,exten=0)
filterlong = strtrim(sxpar(head,'filter',count=nfilter),2)
if nfilter eq 0 then begin
  dum = mrdfits(catfiles[0],1,/silent)
  hd1 = dum.field_header_card
  filterlong = strtrim(sxpar(hd1,'filter'),2)
endif
if strmid(filterlong,0,2) eq 'VR' then filter='VR' else filter=strmid(filterlong,0,1)
if filterlong eq 'bokr' then filter='r'
expnum = sxpar(head,'expnum')
if instrument eq 'ksb' then begin  ; Bok doesn't have expnum
  ;DTACQNAM= '/data1/batch/bok/20160102/d7390.0049.fits.fz'   
  dtacqnam = sxpar(head,'DTACQNAM',count=ndtacqnam)
  if ndtacqnam eq 0 then begin
    printlog,logf,'I cannot create an EXPNUM for this Bok exposure'
    return
  endif
  bokbase = file_basename(dtacqnam)
  dum = strsplit(bokbase,'.',/extract)
  boknight = strmid(dum[0],1)
  boknum = dum[1]
  expnum = boknight+boknum  ; concatenate the two numbers
endif
exptime = sxpar(head,'exptime',count=nexptime)
if nexptime eq 0 then begin
  dum = mrdfits(catfiles[0],1,/silent)
  hd1 = dum.field_header_card
  exptime = sxpar(hd1,'exptime')
endif
dateobs = sxpar(head,'date-obs')
airmass = sxpar(head,'airmass')
mjd = date2jd(dateobs,/mjd)
printlog,logf,'FILTER = ',filter
printlog,logf,'EXPTIME = ',stringize(exptime,ndec=2),' sec.'
printlog,logf,'MJD = ',stringize(mjd,ndec=4,/nocomma)

; Set some catalog values
cat.filter = filter
cat.mjd = mjd
cat.sourceid = instrument+'.'+strtrim(expnum,2)+'.'+strtrim(cat.ccdnum,2)+'.'+strtrim(cat.number,2)

; Start the exposure-level structure
expstr = {file:fluxfile,wtfile:wtfile,maskfile:maskfile,instrument:'',base:base,expnum:long(expnum),ra:0.0d0,dec:0.0d0,dateobs:string(dateobs),$
          mjd:0.0d,filter:filter,exptime:float(exptime),airmass:0.0,nsources:long(ncat),ngoodsources:0L,fwhm:0.0,nchips:0L,rarms:0.0,decrms:0.0,ebv:0.0,ngaiamatch:0L,$
          ngoodgaiamatch:0L,zptype:0,zpterm:999999.0,zptermerr:99999.0,zptermsig:999999.0,zpspatialvar_rms:999999.0,zpspatialvar_range:999999.0,$
          zpspatialvar_nccd:0,nrefmatch:0L,ngoodrefmatch:0L,depth95:99.99,depth10sig:99.99}
expstr.instrument = instrument
expstr.ra = cenra
expstr.dec = cendec
expstr.mjd = mjd
;expstr.mjd = photred_getmjd('','CTIO',dateobs=dateobs)
expstr.nchips = nchips
expstr.airmass = airmass
expstr.fwhm = medfwhm
expstr.ngoodsources = ngoodsources

; Step 2. Load the reference catalogs
;------------------------------------
printlog,logf,'' & printlog,logf,'Step 2. Load the reference catalogs'
printlog,logf,'------------------------------------'

; Getting reference catalogs
if n_elements(inpref) eq 0 then begin
  ; Search radius
  radius = 1.1 * sqrt( (0.5*rarange)^2 + (0.5*decrange)^2 ) 
  ref = GETREFDATA_V3(filter,cenra,cendec,radius,count=count)
  if count eq 0 then begin
    printlog,logfi,'No Reference Data'
    return
 endif
; Using input reference catalog
endif else begin
  printlog,logf,'Reference catalogs input'
  if rawrap eq 0 then begin
    gdref = where(inpref.ra ge min(cat.alpha_j2000)-0.01 and inpref.ra le max(cat.alpha_j2000)+0.01 and $
                  inpref.dec ge min(cat.delta_j2000)-0.01 and inpref.dec le max(cat.delta_j2000)+0.01,ngdref)
  endif else begin
    ra = cat.alpha_j2000
    bdra = where(ra gt 180,nbdra)
    if nbdra gt 0 then ra[bdra]-=360
    gdref = where((inpref.ra le max(ra)+0.01 or inpref.ra ge min(ra+360)-0.01) and $
                  inpref.dec ge min(cat.delta_j2000)-0.01 and inpref.dec le max(cat.delta_j2000)+0.01,ngdref)
  endelse
  ref = inpref[gdref]
  printlog,logf,strtrim(ngdref,2),' reference stars in our region'
endelse


; Step 3. Astrometric calibration
;----------------------------------
; At the chip level, linear fits in RA/DEC
printlog,logf,'' & printlog,logf,'Step 3. Astrometric calibration'
printlog,logf,'--------------------------------'
; Get reference catalog with Gaia values
gdgaia = where(ref.source gt 0,ngdgaia)
gaia = ref[gdgaia]
; Match everything to Gaia at once, this is much faster!
SRCMATCH,gaia.ra,gaia.dec,cat.alpha_j2000,cat.delta_j2000,1.0,ind1,ind2,/sph,count=ngmatch
if ngmatch eq 0 then begin
  printlog,logf,'No gaia matches'
  return
endif
allgaiaind = lonarr(ncat)-1
allgaiaind[ind2] = ind1
allgaiadist = fltarr(ncat)+999999.
allgaiadist[ind2] = sphdist(gaia[ind1].ra,gaia[ind1].dec,cat[ind2].alpha_j2000,cat[ind2].delta_j2000,/deg)*3600
; CCD loop
For i=0,nchips-1 do begin
  if chstr[i].nsources eq 0 then goto,BOMB
  ; Get chip sources using CCDNUM
  MATCH,chstr[i].ccdnum,cat.ccdnum,chind1,chind2,/sort,count=nchmatch
  cat1 = cat[chind2]
  ; Gaia matches for this chip
  gaiaind1 = allgaiaind[chind2]
  gaiadist1 = allgaiadist[chind2]
  gmatch = where(gaiaind1 gt -1 and gaiadist1 le 0.5,ngmatch)  ; get sources with Gaia matches
  if ngmatch eq 0 then gmatch = where(gaiaind1 gt -1 and gaiadist1 le 1.0,ngmatch)
  if ngmatch lt 5 then begin
    printlog,logf,'Not enough Gaia matches'
    ; Add threshold to astrometric errors
    cat1.raerr = sqrt(cat1.raerr^2 + 0.100^2)
    cat1.decerr = sqrt(cat1.decerr^2 + 0.100^2)
    cat[chind2] = cat1
    goto,BOMB
  endif
  ;gaia1b = gaia[ind1]
  ;cat1b = cat1[ind2]
  gaia1b = gaia[gaiaind1[gmatch]]
  cat1b = cat1[gmatch]
  ; Apply quality cuts
  ;  no bad CP flags
  ;  no SE truncated or incomplete data flags
  ;  must have good photometry
  qcuts1 = where(cat1b.imaflags_iso eq 0 and not ((cat1b.flags and 8) eq 8) and not ((cat1b.flags and 16) eq 16) and $
                 cat1b.mag_auto lt 50 and finite(gaia1b.pmra) eq 1 and finite(gaia1b.pmdec) eq 1,nqcuts1)
  if nqcuts1 eq 0 then begin
    printlog,logf,'Not enough stars after quality cuts'
    ; Add threshold to astrometric errors
    cat1.raerr = sqrt(cat1.raerr^2 + 0.100^2)
    cat1.decerr = sqrt(cat1.decerr^2 + 0.100^2)
    cat[chind2] = cat1
    goto,BOMB
  endif
  gaia2 = gaia1b[qcuts1]
  cat2 = cat1b[qcuts1]

  ;; Precess the Gaia coordinates to the epoch of the observation
  ;; The reference epoch for Gaia DR2 is J2015.5 (compared to the
  ;; J2015.0 epoch for Gaia DR1).
  gaiamjd = 57206.0d0
  delt = (mjd-gaiamjd)/365.242170d0   ; convert to years
  ;; convert from mas/yr->deg/yr and convert to angle in RA
  gra_epoch = gaia2.ra + delt*gaia2.pmra/3600.0d0/1000.0d0/cos(gaia2.dec*d2r)
  gdec_epoch = gaia2.dec + delt*gaia2.pmdec/3600.0d0/1000.0d0

  ; Rotate to coordinates relative to the center of the field
  ;ROTSPHCEN,gaia2.ra,gaia2.dec,chstr[i].cenra,chstr[i].cendec,gaialon,gaialat,/gnomic
  ROTSPHCEN,gra_epoch,gdec_epoch,chstr[i].cenra,chstr[i].cendec,gaialon,gaialat,/gnomic
  ROTSPHCEN,cat2.alpha_j2000,cat2.delta_j2000,chstr[i].cenra,chstr[i].cendec,lon1,lat1,/gnomic
  ; ---- Fit RA as function of RA/DEC ----
  londiff = gaialon-lon1
  err = sqrt(gaia2.ra_error^2 + cat2.raerr^2)
  lonmed = median([londiff])
  lonsig = mad([londiff]) > 1e-5   ; 0.036"
  gdlon = where(abs(londiff-lonmed) lt 3.0*lonsig,ngdlon)  ; remove outliers
  if ngdlon gt 5 then npars = 4 else npars=1  ; use constant if not enough stars
  initpars = dblarr(npars)
  initpars[0] = median([londiff])
  parinfo = REPLICATE({limited:[0,0],limits:[0.0,0.0],fixed:0},npars)
  racoef = MPFIT2DFUN('func_poly2d',lon1[gdlon],lat1[gdlon],londiff[gdlon],err[gdlon],initpars,status=status,dof=dof,$
                  bestnorm=chisq,parinfo=parinfo,perror=perror,yfit=yfit,/quiet)
  yfitall = FUNC_POLY2D(lon1,lat1,racoef)
  rarms1 = MAD((londiff[gdlon]-yfit)*3600.)
  rastderr = rarms1/sqrt(ngdlon)
  ; Use bright stars to get a better RMS estimate
  gdstars = where(cat2.fwhm_world*3600 lt 2*medfwhm and 1.087/cat2.magerr_auto gt 50,ngdstars)
  if ngdstars lt 20 then gdstars = where(cat2.fwhm_world*3600 lt 2*medfwhm and 1.087/cat2.magerr_auto gt 30,ngdstars)
  if ngdstars gt 5 then begin
    diff = (londiff-yfitall)*3600.
    rarms = MAD(diff[gdstars])
    rastderr = rarms/sqrt(ngdstars)
  endif else rarms=rarms1
  ; ---- Fit DEC as function of RA/DEC -----
  latdiff = gaialat-lat1
  err = sqrt(gaia2.dec_error^2 + cat2.decerr^2)
  latmed = median([latdiff])
  latsig = mad([latdiff]) > 1e-5  ; 0.036"
  gdlat = where(abs(latdiff-latmed) lt 3.0*latsig,ngdlat)  ; remove outliers
  if ngdlat gt 5 then npars = 4 else npars=1  ; use constant if not enough stars
  initpars = dblarr(npars)
  initpars[0] = median([latdiff])
  parinfo = REPLICATE({limited:[0,0],limits:[0.0,0.0],fixed:0},npars)
  deccoef = MPFIT2DFUN('func_poly2d',lon1[gdlat],lat1[gdlat],latdiff[gdlat],err[gdlat],initpars,status=status,dof=dof,$
                       bestnorm=chisq,parinfo=parinfo,perror=perror,yfit=yfit,/quiet)
  yfitall = FUNC_POLY2D(lon1,lat1,deccoef)
  decrms1 = MAD((latdiff[gdlat]-yfit)*3600.)
  decstderr = decrms1/sqrt(ngdlat)
  ; Use bright stars to get a better RMS estimate
  if ngdstars gt 5 then begin
    diff = (latdiff-yfitall)*3600.
    decrms = MAD(diff[gdstars])
    decstderr = decrms/sqrt(ngdstars)
  endif else decrms=decrms1
  printlog,logf,'  CCDNUM=',strtrim(chstr[i].ccdnum,2),'  NSOURCES=',strtrim(nchmatch,2),'  ',strtrim(ngmatch,2),'/',strtrim(nqcuts1,2),$
                ' GAIA matches  RMS(RA/DEC)=',stringize(rarms,ndec=3)+'/'+stringize(decrms,ndec=3),' STDERR(RA/DEC)=',$
                stringize(rastderr,ndec=4)+'/'+stringize(decstderr,ndec=4),' arcsec'
  ; Apply to all sources
  ROTSPHCEN,cat1.alpha_j2000,cat1.delta_j2000,chstr[i].cenra,chstr[i].cendec,lon,lat,/gnomic
  lon2 = lon + FUNC_POLY2D(lon,lat,racoef)
  lat2 = lat + FUNC_POLY2D(lon,lat,deccoef)
  ROTSPHCEN,lon2,lat2,chstr[i].cenra,chstr[i].cendec,ra2,dec2,/reverse,/gnomic
  cat1.ra = ra2
  cat1.dec = dec2
  ; Add to astrometric errors
  cat1.raerr = sqrt(cat1.raerr^2 + rarms^2)
  cat1.decerr = sqrt(cat1.decerr^2 + decrms^2)
  ; Stuff back into the main structure
  cat[chind2] = cat1
  chstr[i].ngaiamatch = ngmatch
  chstr[i].ngoodgaiamatch = nqcuts1
  chstr[i].rarms = rarms
  chstr[i].rastderr = rastderr
  chstr[i].racoef = racoef
  chstr[i].decrms = decrms
  chstr[i].decstderr = decstderr
  chstr[i].deccoef = deccoef
  BOMB:

stop
Endfor

stop

; Get reddening
glactc,cat.ra,cat.dec,2000.0,glon,glat,1,/deg
ebv = dust_getval(glon,glat,/noloop,/interp)
cat.ebv = ebv

; Put in exposure-level information
expstr.rarms = median(chstr.rarms)
expstr.decrms = median(chstr.decrms)
expstr.ebv = median(ebv)
;expstr.gaianmatch = median(chstr.gaianmatch)
expstr.ngaiamatch = total(chstr.ngaiamatch)
expstr.ngoodgaiamatch = total(chstr.ngoodgaiamatch)


; Step 4. Photometric calibration
;--------------------------------
printlog,logf,'' & printlog,logf,'Step 4. Photometric calibration'
printlog,logf,'-------------------------------'
instfilt = instrument+'-'+filter    ; instrument-filter combination

CASE instfilt of
; ---- DECam u-band ----
'c4d-u': begin
  ; Use GAIA, 2MASS and GALEX to calibrate
  printlog,logf,'Calibrating with GAIA, 2MASS and GALEX'
  dcr = 1.0
  SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
  printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
  if nmatch eq 0 then begin
    printlog,logf,'No matches to reference catalog'
    goto,ENDBOMB
  endif
  ; Matched catalogs
  cat1 = cat[ind2]
  ref1 = ref[ind1]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+ref1.e_fg/ref1.fg)
  ; (G-J)o = G-J-1.12*EBV
  col = ref1.gmag - ref1.jmag - 1.12*cat1.ebv
  gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                ref1.e_jmag lt 0.05 and finite(ref1.nuv) eq 1 and ref1.nuv lt 50 and col ge 0.8 and col le 1.1,ngdcat)
  ;  if the seeing is bad then class_star sometimes doens't work well
  if medfwhm gt 1.8 and ngdcat lt 100 then begin
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and finite(ref1.nuv) eq 1 and ref1.nuv lt 50 and col ge 0.8 and col le 1.1,ngdcat)
  endif
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    goto,ENDBOMB
  endif
  cat2 = cat1[gdcat]
  ref2 = ref1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  ; Fit zpterm using color-color relation
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + ref2.e_nuv^2 + gmagerr2^2)
  ;diff = galex2.nuv-mag
  ; see nsc_color_relations_smashuband.pro
  ; u = 0.30874*NUV + 0.6955*G + 0.424*EBV + 0.0930  ; for 0.7<GJ0<1.1
  ;model_mag = 0.30874*galex2.nuv + 0.6955*gaia2.gmag + 0.424*cat2.ebv + 0.0930
  ; ADJUSTED EQUATION
  ; u = 0.2469*NUV + 0.7501*G + 0.5462*GJ0 + 0.6809*EBV + 0.0052  ; for 0.8<GJ0<1.1
  model_mag = 0.2469*ref2.nuv + 0.7501*ref2.gmag + 0.5462*col2 + 0.6809*cat2.ebv + 0.0052
  ; Matched structure
  mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
end
;---- DECam g-band ----
'c4d-g': begin
  ; Use PS1 if we can
  if cendec gt -29 then begin
    printlog,logf,'Calibrating with PS1'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
    ; Don't use CLASS_STAR threshold if not enough sources are selected
    if ngdcat lt 10 then $
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
    ;  if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 2 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    ; Take a robust mean relative to GAIA GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = cat2.magerr_auto
    model_mag = ref2.ps_gmag
    col2 = fltarr(n_elements(mag))
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}

  ; Use 2MASS and APASS to calibrate
  endif else begin
    printlog,logf,'Calibrating with 2MASS and APASS'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and ref1.e_apass_gmag lt 0.1 and col ge 0.3 and col le 0.7,ngdcat)
    ;  if the seeing is bad then class_star sometimes doens't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                    ref1.e_jmag lt 0.05 and ref1.e_apass_gmag lt 0.1 and col ge 0.3 and col le 0.7,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    col2 = col[gdcat]
    ; Take a robust mean relative to model GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = sqrt(cat2.magerr_auto^2 + ref2.e_apass_gmag^2)  ; leave off JK error for now
    ; see nsc_color_relations_stripe82_superposition.pro
    ; g = APASS_G - 0.1433*JK0 - 0.05*EBV - 0.0138
    ;model_mag = apass2.g_mag - 0.1433*col2 - 0.05*cat2.ebv - 0.0138
    ; ADJUSTED EQUATION
    ; g = APASS_G - 0.0421*JK0 - 0.05*EBV - 0.0620
    model_mag = ref2.apass_gmag - 0.0421*col2 - 0.05*cat2.ebv - 0.0620
    ; Matched structure
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
  endelse ; use APASS
end
; ---- DECam r-band ----
'c4d-r': begin
  ; Use PS1 to calibrate
  if cendec gt -29 then begin
    printlog,logf,'Calibrating with PS1'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
    ; Don't use CLASS_STAR threshold if not enough sources are selected
    if ngdcat lt 10 then $
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
    ;  if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    ; Take a robust mean relative to GAIA GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = cat2.magerr_auto
    model_mag = ref2.ps_rmag
    col2 = fltarr(n_elements(mag))
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}

  ; Use 2MASS and APASS to calibrate
  endif else begin
    printlog,logf,'Calibrating with 2MASS and APASS'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and ref1.e_apass_rmag lt 0.1 and col ge 0.3 and col le 0.7,ngdcat)
    ;  if the seeing is bad then class_star sometimes doens't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                    ref1.e_jmag lt 0.05 and ref1.e_apass_rmag lt 0.1 and col ge 0.3 and col le 0.7,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    col2 = col[gdcat]
    ; Take a robust mean relative to model RMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = sqrt(cat2.magerr_auto^2 + ref2.e_apass_rmag^2)  ; leave off JK error for now
    ; see nsc_color_relations_stripe82_superposition.pro
    ; r = APASS_r + 0.00740*JK0 + 0.0*EBV + 0.000528
    ;model_mag = apass2.r_mag + 0.00740*col2 + 0.000528
    ; ADJUSTED EQUATION
    ; r = APASS_r - 0.0861884*JK0 + 0.0*EBV + 0.0548607
    model_mag = ref2.apass_rmag - 0.0861884*col2 + 0.0548607
    ; Matched structure
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
  endelse ; use APASS to calibrate
end
; ---- DECam i-band ----
'c4d-i': begin
  ; Use PS1 if we can
  if cendec gt -29 then begin
    printlog,logf,'Calibrating with PS1'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_imag gt 0 and ref1.ps_imag lt 21.0,ngdcat)
    ; Don't use CLASS_STAR threshold if not enough sources are selected
    if ngdcat lt 10 then $
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_imag gt 0 and ref1.ps_imag lt 21.0,ngdcat)
    ;  if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 2 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_imag gt 0 and ref1.ps_imag lt 21.0,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    ; Take a robust mean relative to GAIA GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = cat2.magerr_auto
    model_mag = ref2.ps_imag
    col2 = fltarr(n_elements(mag))
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}

  ; Use GAIA and 2MASS to calibrate
  endif else begin
    printlog,logf,'Calibrating with GAIA and 2MASS'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gmagerr = 2.5*alog10(1.0+ref1.e_fg/ref1.fg)
    col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and col ge 0.25 and col le 0.65,ngdcat)
    ;  if the seeing is bad then class_star sometimes doens't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                    ref1.e_jmag lt 0.05 and col ge 0.25 and col le 0.65,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    gmagerr2 = gmagerr[gdcat]
    col2 = col[gdcat]
    ; Take a robust mean relative to model IMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = sqrt(cat2.magerr_auto^2 + gmagerr2^2)  ; leave off the JK error for now
    ; see nsc_color_relations_stripe82_superposition.pro
    ; i = G - 0.4587*JK0 - 0.276*EBV + 0.0967721
    model_mag = ref2.gmag - 0.4587*col2 - 0.276*cat2.ebv + 0.0967721
    ; Matched structure
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
  endelse
end
; ---- DECam z-band ----
'c4d-z': begin
  ; Use PS1 if we can
  if cendec gt -29 then begin
    printlog,logf,'Calibrating with PS1'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
    ; Don't use CLASS_STAR threshold if not enough sources are selected
    if ngdcat lt 10 then $
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
    ;  if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 2 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    ; Take a robust mean relative to GAIA GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = cat2.magerr_auto
    model_mag = ref2.ps_zmag
    col2 = fltarr(n_elements(mag))
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}

  ; Use 2MASS to calibrate  
  endif else begin
    printlog,logf,'Calibrating with 2MASS'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and col ge 0.4 and col le 0.65,ngdcat)
    ; if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                    ref1.e_jmag lt 0.05 and col ge 0.4 and col le 0.65,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    col2 = col[gdcat]
    ; Take a robust mean relative to model ZMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = sqrt(cat2.magerr_auto^2 + ref2.e_jmag^2)
    ; see nsc_color_relations_stripe82_superposition.pro
    ; z = J + 0.765720*JK0 + 0.40*EBV +  0.605658
    model_mag = ref2.jmag + 0.765720*col2 + 0.40*cat2.ebv +  0.605658
    ; Matched structure
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
  endelse
end
; ---- DECam Y-band ----
'c4d-Y': begin
  ; Use PS1 if we can
  if cendec gt -29 then begin
    printlog,logf,'Calibrating with PS1'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_ymag gt 0 and ref1.ps_ymag lt 21.0,ngdcat)
    ; Don't use CLASS_STAR threshold if not enough sources are selected
    if ngdcat lt 10 then $
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_ymag gt 0 and ref1.ps_ymag lt 21.0,ngdcat)
    ;  if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 2 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_ymag gt 0 and ref1.ps_ymag lt 21.0,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    ; Take a robust mean relative to GAIA GMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
    err = cat2.magerr_auto
    model_mag = ref2.ps_ymag
    col2 = fltarr(n_elements(mag))
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}

  ; Use 2MASS to calibrate
  endif else begin
    printlog,logf,'Calibrating with 2MASS'
    dcr = 0.5
    SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
    printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
    if nmatch eq 0 then begin
      printlog,logf,'No matches to reference catalog'
      goto,ENDBOMB
    endif
    ; Matched catalogs
    cat1 = cat[ind2]
    ref1 = ref[ind1]
    ; Make quality and error cuts
    col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and col ge 0.4 and col le 0.7,ngdcat)
    ; if the seeing is bad then class_star sometimes doesn't work well
    if medfwhm gt 1.8 and ngdcat lt 100 then begin
      gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                    cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                    cat1.fwhm_world*3600 lt 2*medfwhm and ref1.qflg eq 'AAA' and $
                    ref1.e_jmag lt 0.05 and col ge 0.4 and col le 0.7,ngdcat)
    endif
    if ngdcat eq 0 then begin
      printlog,logf,'No stars that pass all of the quality/error cuts'
      goto,ENDBOMB
    endif
    cat2 = cat1[gdcat]
    ref2 = ref1[gdcat]
    col2 = col[gdcat]
    ; Take a robust mean relative to model YMAG
    mag = cat2.mag_auto + 2.5*alog10(exptime) ; correct for the exposure time
    err = sqrt(cat2.magerr_auto^2 + ref2.e_jmag^2)
    ; see nsc_color_relations_stripe82_superposition.pro
    ; Y = J + 0.54482*JK0 + 0.20*EBV + 0.663380
    model_mag = ref2.jmag + 0.54482*col2 + 0.20*cat2.ebv + 0.663380
    mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
  endelse
end
; ---- DECam VR-band ----
'c4d-VR': begin
  ; Use GAIA G-band to calibrate
  printlog,logf,'Calibrating with GAIA'
  dcr = 0.5
  SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
  printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
  if nmatch eq 0 then begin
    printlog,logf,'No matches to reference catalog'
    goto,ENDBOMB
  endif
  ; Matched catalogs
  cat1 = cat[ind2]
  ref1 = ref[ind1]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+ref1.e_fg/ref1.fg)
  col = ref1.jmag-ref1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                ref1.e_jmag lt 0.05 and col ge 0.2 and col le 0.6,ngdcat)
  ;  if the seeing is bad then class_star sometimes doesn't work well
  if medfwhm gt 2 and ngdcat lt 100 then begin
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and ref1.qflg eq 'AAA' and $
                  ref1.e_jmag lt 0.05 and col ge 0.2 and col le 0.6,ngdcat)
  endif
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    goto,ENDBOMB
  endif
  cat2 = cat1[gdcat]
  ref2 = ref1[gdcat]
  col2 = col[gdcat]
  gmagerr2 = gmagerr[gdcat]
  ; Take a robust mean relative to GAIA GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + gmagerr2^2)
  model_mag = ref2.gmag
  mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
end
; ---- Bok+90Prime g-band ----
'ksb-g': begin
  ; Use PS1 g-band to calibrate
  printlog,logf,'Calibrating with PS1'
  dcr = 0.5
  SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
  printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
  if nmatch eq 0 then begin
    printlog,logf,'No matches to reference catalog'
    goto,ENDBOMB
  endif
  ; Matched catalogs
  cat1 = cat[ind2]
  ref1 = ref[ind1]
  ; Make quality and error cuts
  gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
  ; Don't use CLASS_STAR threshold if not enough sources are selected
  if ngdcat lt 10 then $
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
  ;  if the seeing is bad then class_star sometimes doesn't work well
  if medfwhm gt 2 and ngdcat lt 100 then begin
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_gmag gt 0 and ref1.ps_gmag lt 21.0,ngdcat)
  endif
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    goto,ENDBOMB
  endif
  cat2 = cat1[gdcat]
  ref2 = ref1[gdcat]
  ; Take a robust mean relative to GAIA GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = cat2.magerr_auto
  model_mag = ref2.ps_gmag
  col2 = fltarr(n_elements(mag))
  mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
end
; ---- Bok+90Prime r-band ----
'ksb-r': begin
  ; Use PS1 r-band to calibrate
  printlog,logf,'Calibrating with PS1'
  dcr = 0.5
  SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
  printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
  if nmatch eq 0 then begin
    printlog,logf,'No matches to reference catalog'
    goto,ENDBOMB
  endif
  ; Matched catalogs
  cat1 = cat[ind2]
  ref1 = ref[ind1]
  ; Make quality and error cuts
  gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
  ; Don't use CLASS_STAR threshold if not enough sources are selected
  if ngdcat lt 10 then $
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
  ;  if the seeing is bad then class_star sometimes doesn't work well
  if medfwhm gt 1.8 and ngdcat lt 100 then begin
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_rmag gt 0 and ref1.ps_rmag lt 21.0,ngdcat)
  endif
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    goto,ENDBOMB
  endif
  cat2 = cat1[gdcat]
  ref2 = ref1[gdcat]
  ; Take a robust mean relative to GAIA GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = cat2.magerr_auto
  model_mag = ref2.ps_rmag
  col2 = fltarr(n_elements(mag))
  mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
end
; ---- Mosaic3 z-band ----
'k4m-z': begin
  ; Use PS1 z-band to calibrate
  printlog,logf,'Calibrating with PS1'
  dcr = 0.5
  SRCMATCH,ref.ra,ref.dec,cat.ra,cat.dec,dcr,ind1,ind2,/sph,count=nmatch
  printlog,logf,strtrim(nmatch,2),' matches to reference catalog'
  if nmatch eq 0 then begin
    printlog,logf,'No matches to reference catalog'
    goto,ENDBOMB
  endif
  ; Matched catalogs
  cat1 = cat[ind2]
  ref1 = ref[ind1]
  ; Make quality and error cuts
  gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
  ; Don't use CLASS_STAR threshold if not enough sources are selected
  if ngdcat lt 10 then $
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
  ;  if the seeing is bad then class_star sometimes doesn't work well
  if medfwhm gt 1.8 and ngdcat lt 100 then begin
    gdcat = where(cat1.imaflags_iso eq 0 and not ((cat1.flags and 8) eq 8) and not ((cat1.flags and 16) eq 16) and $
                  cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and $
                  cat1.fwhm_world*3600 lt 2*medfwhm and ref1.ps_zmag gt 0 and ref1.ps_zmag lt 21.0,ngdcat)
  endif
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    goto,ENDBOMB
  endif
  cat2 = cat1[gdcat]
  ref2 = ref1[gdcat]
  ; Take a robust mean relative to GAIA GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = cat2.magerr_auto
  model_mag = ref2.ps_zmag
  col2 = fltarr(n_elements(mag))
  mstr = {col:col2,mag:float(mag),model:float(model_mag),err:float(err),ccdnum:long(cat2.ccdnum)}
end
else: begin
  printlog,logf,filter,' not currently supported'
  return
end
ENDCASE
; Measure the zero-point
NSC_INSTCAL_CALIBRATE_FITZPTERM,mstr,expstr,chstr
expstr.zptype = 1

ENDBOMB:

; Use self-calibration
if expstr.nrefmatch le 5 and keyword_set(selfcal) then begin
  NSC_INSTCAL_CALIBRATE_SELFCALZPTERM,expdir,cat,expstr,chstr
  expstr.zptype = 2
endif
; Apply the zero-point to the full catalogs
gdcatmag = where(cat.mag_auto lt 50,ngd)
cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + expstr.zpterm
cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + expstr.zptermerr^2)  ; add calibration error in quadrature
; Print out the results
printlog,logf,'NPHOTREFMATCH=',strtrim(expstr.nrefmatch,2)
printlog,logf,'ZPTERM=',stringize(expstr.zpterm,ndec=4),'+/-',stringize(expstr.zptermerr,ndec=4),'  SIG=',stringize(expstr.zptermsig,ndec=4),'mag'
printlog,logf,'ZPSPATIALVAR:  RMS=',stringize(expstr.zpspatialvar_rms,ndec=3),' ',$
         'RANGE=',stringize(expstr.zpspatialvar_range,ndec=3),' NCCD=',strtrim(expstr.zpspatialvar_nccd,2)

; Measure the depth
;   need good photometry
gdmag = where(cat.cmag lt 50,ngdmag)
if ngdmag gt 0 then begin
  ; Get 95% percentile depth
  cmag = cat[gdmag].cmag
  si = sort(cmag)
  cmag = cmag[si]
  depth95 = cmag[round(0.95*ngdmag)-1]
  expstr.depth95 = depth95
  chstr.depth95 = depth95
  printlog,logf,'95% percentile depth = '+stringize(depth95,ndec=2)+' mag'
  ; Get 10 sigma depth
  ;  S/N = 1.087/err
  ;  so S/N=5 is for err=1.087/5=0.2174
  ;  S/N=10 is for err=1.087/10=0.1087
  depth10sig = 99.99
  depind = where(cat.cmag lt 50 and cat.cmag gt depth95-3.0 and cat.cerr ge 0.0987 and cat.cerr le 0.1187,ndepind)
  if ndepind lt 5 then depind = where(cat.cmag lt 50 and cat.cmag gt depth95-3.0 and cat.cerr ge 0.0787 and cat.cerr le 0.1387,ndepind)
  if ndepind gt 5 then begin
    depth10sig = median([cat[depind].cmag])
  endif else begin
    depind = where(cat.cmag lt 50,ndepind)
    if ndepind gt 0 then depth10sig=max([cat[depind].cmag])
  endelse
  printlog,logf,'10sigma depth = '+stringize(depth10sig,ndec=2)+' mag'
  expstr.depth10sig = depth10sig
  chstr.depth10sig = depth10sig
endif

; Step 5. Write out the final catalogs and metadata
;--------------------------------------------------
if keyword_set(redo) and keyword_set(selfcal) and expstr.zptype eq 2 then begin
  ; Create backup of original versions
  printlog,logf,'Copying cat and meta files to v1 versions'
  metafile = expdir+'/'+base+'_meta.fits'
  if file_test(metafile) eq 1 then FILE_COPY,metafile,expdir+'/'+base+'_meta.v1.fits',/overwrite
  if file_test(outfile) eq 1 then FILE_COPY,outfile,expdir+'/'+base+'_cat.v1.fits',/overwrite
  if file_test(logf) eq 1 then FILE_COPY,logf,expdir+'/'+base+'_calib.v1.log',/overwrite
endif

printlog,logf,'' & printlog,logf,'Writing final catalog to ',outfile
;;; Create an output catalog for each chip
;nsrc = long64(total(chstr.nsources,/cum))
;lo = [0L,nsrc[0:nchips-2]]
;hi = nsrc-1
;for i=0,nchips-1 do begin
;  outfile = expdir+'/'+base+'_cat'+strtrim(chstr[i].ccdnum,2)+'.fits'
;  MWRFITS,cat[lo[i]:hi[i]],outfile,/create
;  MWRFITS,chstr[i],outfile,/silent   ; add chip stucture for this chip
;endfor
MWRFITS,cat,outfile,/create
;if file_test(outfile+'.gz') eq 1 then file_delete,outfile+'.gz'
;spawn,['gzip',outfile],/noshell  ; makes little difference
metafile = expdir+'/'+base+'_meta.fits'
printlog,logf,'Writing metadata to ',metafile
MWRFITS,expstr,metafile,/create
MWRFITS,chstr,metafile,/silent  ; add chip structure to second extension

dt = systime(1)-t00
printlog,logf,'dt = ',stringize(dt,ndec=2),' sec.'

if keyword_set(stp) then stop

end
