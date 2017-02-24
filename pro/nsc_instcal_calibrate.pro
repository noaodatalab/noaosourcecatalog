pro nsc_instcal_calibrate,expdir,redo=redo,stp=stp

; Calibrate catalogs for one exposure

NSC_ROOTDIRS,dldir,mssdir,localdir

; Not enough inputs
if n_elements(expdir) eq 0 then begin
  print,'Syntax - nsc_instcal_calibrate,expdir'
  return
endif

; Make sure the directory exists
if file_test(expdir,/directory) eq 0 then begin
  print,expdir,' NOT FOUND'
  return
endif

t00 = systime(1)

base = file_basename(expdir)
logf = expdir+'/'+base+'_calib.log'
outfile = expdir+'/'+base+'_cat.fits'

printlog,logf,'Calibrate catalogs for exposure ',base,' in ',expdir

; Check for output file
if file_test(outfile) eq 1 and not keyword_set(redo) then begin
  printlog,logf,outfile,' already exists and /redo not set.'
  return
endif

; Step 1. Read in the catalogs 
;-----------------------------
printlog,logf,'' & printlog,logf,'Step 1. Read in the catalogs'
printlog,logf,'-----------------------------'
catfiles1 = file_search(expdir+'/'+base+'_[1-9].fits',count=ncatfiles1)
if ncatfiles1 gt 0 then push,catfiles,catfiles1
catfiles2 = file_search(expdir+'/'+base+'_[0-9][0-9].fits',count=ncatfiles2)
if ncatfiles2 gt 0 then push,catfiles,catfiles2
ncatfiles = n_elements(catfiles)
nchips = ncatfiles
printlog,logf,strtrim(ncatfiles,2),' catalogs found'

; Figure out the number of sources
ncat = 0L
for i=0,ncatfiles-1 do begin
  head = headfits(catfiles[i],exten=2)
  ncat += sxpar(head,'NAXIS2')
endfor
printlog,logf,strtrim(ncat,2),' total sources'
; Create structure, exten=1 has header now
cat1 = MRDFITS(catfiles[0],2,/silent)
schema = cat1[0]
STRUCT_ASSIGN,{dum:''},schema   ; blank everything out
add_tag,schema,'CCDNUM',0L,schema
add_tag,schema,'EBV',0.0,schema
add_tag,schema,'RA',0.0d0,schema
add_tag,schema,'DEC',0.0d0,schema
add_tag,schema,'CMAG',99.99,schema
add_tag,schema,'CERR',9.99,schema
cat = REPLICATE(schema,ncat)
; Start the chips summary structure
chstr = replicate({filename:'',ccdnum:0L,nsources:0L,cenra:0.0d0,cendec:0.0d0,$
                   gaianmatch:0L,rarms:0.0,racoef:dblarr(4),decrms:0.0,$
                   deccoef:dblarr(4),zpterm:0.0,zperr:0.0},nchips)
; Load the files
cnt = 0LL
for i=0,ncatfiles-1 do begin
  dum = strsplit(file_basename(catfiles[i],'.fits'),'_',/extract)
  ccdnum = long(first_el(dum,/last))
  cat1 = MRDFITS(catfiles[i],2,/silent)
  ncat1 = n_elements(cat1)
  temp = cat[cnt:cnt+ncat1-1]
  STRUCT_ASSIGN,cat1,temp,/nozero
  temp.ccdnum = ccdnum
  cat[cnt:cnt+ncat1-1] = temp
  cnt += ncat1
  chstr[i].filename = catfiles[i]
  chstr[i].ccdnum = ccdnum
  chstr[i].nsources = ncat1
  cenra = mean(minmax(cat1.alpha_j2000))
  ; Wrapping around RA=0
  if range(cat1.alpha_j2000) gt 100 then begin
    ra = cat1.alpha_j2000
    bdra = where(ra gt 180,nbdra)
    if nbdra gt 0 then ra[bdra]-=360
    cenra = mean(minmax(ra))
    if cenra lt 0 then cenra+=360
  endif
  chstr[i].cenra = cenra
  chstr[i].cendec = mean(minmax(cat1.delta_j2000))
endfor
; Exposure level values
cendec = mean(minmax(chstr.cendec))
decrange = range(chstr.cendec)
cenra = mean(minmax(chstr.cenra))
rarange = range(chstr.cenra)*cos(cendec/!radeg)
; Wrapping around RA=0
if range(minmax(chstr.cenra)) gt 100 then begin
 ra = chstr.cenra
 bdra = where(ra gt 180,nbdra)
 if nbdra gt 0 then ra[bdra]-=360
 cenra = mean(minmax(ra))
 if cenra lt 0 then cenra+=360
 rarange = range(ra)*cos(cendec/!radeg)
endif

; Load the logfile and get absolute flux filename
READLINE,expdir+'/'+base+'.log',loglines
ind = where(stregex(loglines,'Step #2: Copying InstCal images from mass store archive',/boolean) eq 1,nind)
line = loglines[ind[0]+1]
lo = strpos(line,'/net/')
fluxfile = strmid(line,lo)

; Load the meta-data from the original header
;READLINE,expdir+'/'+base+'.head',head
head = headfits(fluxfile,exten=0)
filterlong = sxpar(head,'filter')
if strmid(filterlong,0,2) eq 'VR' then filter='VR' else filter=strmid(filterlong,0,1)
expnum = sxpar(head,'expnum')
exptime = sxpar(head,'exptime')
dateobs = sxpar(head,'date-obs')
airmass = sxpar(head,'airmass')
printlog,logf,'FILTER = ',filter
printlog,logf,'EXPTIME = ',stringize(exptime,ndec=2),' sec.'

; Step 2. Load the reference catalogs
;------------------------------------
printlog,logf,'' & printlog,logf,'Step 2. Load the reference catalogs'
printlog,logf,'------------------------------------'
refcat = ['GAIA/GAIA','2MASS-PSC']  ; always need these two
CASE filter of
; u-band
'u': begin
  ; Use GAIA, 2MASS and GALEX to calibrate
  push,refcat,'II/312/ais'
end
; g-band
'g': begin
  ; Use GAIA, 2MASS and APASS to calibrate
  push,refcat,'APASS'
end
; r-band
'r': begin
  ; Use GAIA, 2MASS and maybe APASS to calibrate
  push,refcat,'APASS'
end
; i-band
'i': begin
  ; Use GAIA and 2MASS to calibrate
end
; z-band
'z': begin
  ; Use GAIA and 2MASS to calibrate  
end
'Y': begin
  ; Use 2MASS to calibrate
end
'VR': begin
  ; Use GAIA G-band to calibrate
end
else: begin
  printlog,logf,filter,' not currently supported'
  return
end
ENDCASE

; Load the necessary catalogs
nrefcat = n_elements(refcat)
printlog,logf,'  ',strtrim(nrefcat,2),' reference catalogs to load'
for i=0,nrefcat-1 do begin
  t0 = systime(1)
  printlog,logf,'  Loading ',refcat[i],' reference catalog'
  varname = refcat[i]
  if varname eq 'II/312/ais' then varname='GALEX'
  if varname eq '2MASS-PSC' then varname='TMASS'
  if varname eq 'GAIA/GAIA' then varname='GAIA'
  refcatfile = expdir+'/'+base+'_'+varname+'.fits'
  ;if file_test(refcatfile) eq 1 and not keyword_set(redo) then begin
  if file_test(refcatfile) eq 1 then begin
    printlog,logf,'  Loading previously-saved file ',refcatfile
    (SCOPE_VARFETCH(varname,/enter)) = MRDFITS(refcatfile,1,/silent)
    ref = SCOPE_VARFETCH(varname)
  endif else begin
    ref = QUERYVIZIER(refcat[i],[cenra,cendec],[rarange*1.1*60,decrange*1.1*60])
    (SCOPE_VARFETCH(varname,/enter)) = ref
    ; Save the file
    MWRFITS,ref,refcatfile,/create
  endelse
  nref = n_elements(ref)
  dt = systime(1)-t0
  printlog,logf,'  ',strtrim(nref,2),' sources   dt=',stringize(dt,ndec=1),' sec.'
endfor

; Step 3. Astrometric calibration
;----------------------------------
; At the chip level, linear fits in RA/DEC
printlog,logf,'' & printlog,logf,'Step 3. Astrometric calibration'
printlog,logf,'--------------------------------'
; CCD loop
For i=0,nchips-1 do begin
  ; Relative to center of chip
  MATCH,chstr[i].ccdnum,cat.ccdnum,chind1,chind2,/sort,count=nchmatch
  cat1 = cat[chind2]
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat1.alpha_j2000,cat1.delta_j2000,0.5,ind1,ind2,/sph,count=ngmatch
  gaia2 = gaia[ind1]
  cat2 = cat1[ind2]
  ROTSPHCEN,gaia2.ra_icrs,gaia2.de_icrs,chstr[i].cenra,chstr[i].cendec,gaialon,gaialat,/gnomic
  ROTSPHCEN,cat2.alpha_j2000,cat2.delta_j2000,chstr[i].cenra,chstr[i].cendec,lon1,lat1,/gnomic
  ; Fit RA as function of RA/DEC
  londiff = gaialon-lon1
  err = gaia2.e_ra_icrs
  npars = 4
  initpars = dblarr(npars)
  initpars[0] = median(londiff)
  parinfo = REPLICATE({limited:[0,0],limits:[0.0,0.0],fixed:0},npars)
  racoef = MPFIT2DFUN('func_poly2d',lon1,lat1,londiff,err,initpars,status=status,dof=dof,$
                  bestnorm=chisq,parinfo=parinfo,perror=perror,yfit=yfit,/quiet)
  rarms = sqrt(mean((londiff-yfit)*3600.)^2)
  ; Fit DEC as function of RA/DEC
  latdiff = gaialat-lat1
  err = gaia2.e_de_icrs
  npars = 4
  initpars = dblarr(npars)
  initpars[0] = median(latdiff)
  parinfo = REPLICATE({limited:[0,0],limits:[0.0,0.0],fixed:0},npars)
  deccoef = MPFIT2DFUN('func_poly2d',lon1,lat1,latdiff,err,initpars,status=status,dof=dof,$
                       bestnorm=chisq,parinfo=parinfo,perror=perror,yfit=yfit,/quiet)
  decrms = sqrt(mean((latdiff-yfit)*3600.)^2)
  printlog,logf,'  CCDNUM=',strtrim(chstr[i].ccdnum,2),'  NSOURCES=',strtrim(nchmatch,2),'  ',strtrim(ngmatch,2),' GAIA matches  RMS(RA)=',$
       stringize(rarms,ndec=3),' RMS(DEC)=',stringize(decrms,ndec=3),' arcsec'
  ; Apply to all sources
  ROTSPHCEN,cat1.alpha_j2000,cat1.delta_j2000,chstr[i].cenra,chstr[i].cendec,lon,lat,/gnomic
  lon2 = lon + FUNC_POLY2D(lon,lat,racoef)
  lat2 = lat + FUNC_POLY2D(lon,lat,deccoef)
  ROTSPHCEN,lon2,lat2,chstr[i].cenra,chstr[i].cendec,ra2,dec2,/reverse,/gnomic
  cat1.ra = ra2
  cat1.dec = dec2
  ; Stuff back into the main structure
  cat[chind2] = cat1
  chstr[i].gaianmatch = ngmatch
  chstr[i].rarms = rarms
  chstr[i].racoef = racoef
  chstr[i].decrms = decrms
  chstr[i].deccoef = deccoef
Endfor

; Measure median seeing FWHM
gdcat = where(cat.mag_auto lt 50 and cat.magerr_auto lt 0.05 and cat.class_star gt 0.8,ngdcat)
medfwhm = median(cat[gdcat].fwhm_world*3600.)
print,'FWHM = ',stringize(medfwhm,ndec=2),' arcsec'

; Get reddening
glactc,cat.ra,cat.dec,2000.0,glon,glat,1,/deg
ebv = dust_getval(glon,glat,/noloop,/interp)
cat.ebv = ebv

; Step 4. Photometric calibration
;--------------------------------
; Do it on the exposure level
printlog,logf,'' & printlog,logf,'Step 4. Photometric calibration'
printlog,logf,'-------------------------------'
expstr = {file:fluxfile,base:base,expnum:long(expnum),ra:0.0d0,dec:0.0d0,dateobs:dateobs,mjd:0.0d,filter:filter,exptime:exptime,$
          airmass:0.0,nsources:long(ncat),fwhm:0.0,nchips:0L,rarms:0.0,decrms:0.0,ebv:0.0,gaianmatch:0L,zpterm:0.0,zptermerr:0.0,$
          zptermsig:0.0,nrefmatch:0L}
expstr.ra = cenra
expstr.dec = cendec
expstr.mjd = photred_getmjd('','CTIO',dateobs=dateobs)
expstr.nchips = nchips
expstr.airmass = airmass
expstr.rarms = median(chstr.rarms)
expstr.decrms = median(chstr.decrms)
expstr.ebv = median(ebv)
expstr.gaianmatch = median(chstr.gaianmatch)

CASE filter of
; ---- u-band ----
'u': begin
  ; Use GAIA, 2MASS and GALEX to calibrate
  index = lonarr(ncat,3)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  SRCMATCH,galex.raj2000,galex.dej2000,cat.ra,cat.dec,0.5,aind1,aind2,/sph,count=namatch
  if namatch gt 0 then index[aind2,2] = aind1
  gd = where(total(index gt -1,2) eq 3,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA, 2MASS and GALEX'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA, 2MASS and GALEX'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  galex1 = galex[index[gd,2]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  ; (G-J)o = G-J-1.12*EBV
  col = gaia._gmag_ - tmass.jmag - 1.12*cat.ebv
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and finite(galex1.nuv) eq 1 and col ge 0.7 and col le 1.1,ngdcat)
  ; could also make cuts on GMAG, JMAG, NUVERR
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  tmass2 = tmass1[gdcat]
  galex2 = galex1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  ; Fit zpterm using color-color relation
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + galex2.e_nuv^2 + gmagerr2^2)
  ;diff = galex2.nuv-mag
  ; see nsc_color_relations_smashuband.pro
  ; u = 0.30874*NUV + 0.6955*G + 0.424*EBV + 0.0930  ; for 0.7<GJ0<1.1
  model_mag = 0.30874*galex2.nuv + 0.6955*gaia2._gmag_ + 0.424*cat2.ebv + 0.0930
  diff = model_mag - mag
  ;col = gaia2._gmag_ - tmass2.jmag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  zpterm = dln_poly_fit(col2[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  ;zpterm = dln_poly_fit(col[gd],diff[gd],1,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
;- --- g-band ----
'g': begin
  ; Use GAIA, 2MASS and APASS to calibrate
  index = lonarr(ncat,3)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  SRCMATCH,apass.raj2000,apass.dej2000,cat.ra,cat.dec,0.5,aind1,aind2,/sph,count=namatch
  if namatch gt 0 then index[aind2,2] = aind1
  gd = where(total(index gt -1,2) eq 3,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA, 2MASS and APASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA, 2MASS and APASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  apass1 = apass[index[gd,2]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and apass1.e_g_mag lt 0.1 and col ge 0.3 and col le 0.7,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  tmass2 = tmass1[gdcat]
  apass2 = apass1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  ; Take a robust mean relative to model GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + apass2.e_g_mag^2)  ; leave off JK error for now
  ; see nsc_color_relations_stripe82_superposition.pro
  ; g = APASS_G - 0.1433*JK0 - 0.05*EBV - 0.0138
  model_mag = apass2.g_mag - 0.1433*col2 - 0.05*cat2.ebv - 0.0138
  diff = model_mag - mag
  ;diff = apass2.g_mag-mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
; ---- r-band ----
'r': begin
  ; Use GAIA, 2MASS and maybe APASS to calibrate
  index = lonarr(ncat,3)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  SRCMATCH,apass.raj2000,apass.dej2000,cat.ra,cat.dec,0.5,aind1,aind2,/sph,count=namatch
  if namatch gt 0 then index[aind2,2] = aind1
  gd = where(total(index gt -1,2) eq 3,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA, 2MASS and APASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA, 2MASS and APASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  apass1 = apass[index[gd,2]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and apass1.e_r_mag lt 0.1,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  tmass2 = tmass1[gdcat]
  apass2 = apass1[gdcat]
  ; Take a robust mean relative to model RMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + apass2.e_r_mag^2)  ; leave off JK error for now
  ; see nsc_color_relations_stripe82_superposition.pro
  ; r = APASS_r + 0.00740*JK0 + 0.0*EBV + 0.000528
  model_mag = apass2.r_mag + 0.00740*col2 + 0.000528
  diff = model_mag - mag
  ;diff = apass2.r_mag-mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
; ---- i-band ----
'i': begin
  ; Use GAIA and 2MASS to calibrate
  index = lonarr(ncat,2)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  gd = where(total(index gt -1,2) eq 2,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA and 2MASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA and 2MASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and col ge 0.3 and col le 0.7,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  tmass2 = tmass1[gdcat]
  ; Take a robust mean relative to model IMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + gmagerr2^2)  ; leave off the JK error for now
  ; see nsc_color_relations_stripe82_superposition.pro
  ; i = G - 0.4587*JK0 - 0.276*EBV + 0.0967721
  model_mag = gaia2._gmag_ - 0.4587*col2 - 0.276*cat2.ebv + 0.0967721
  diff = model_mag - mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
; ---- z-band ----
'z': begin
  ; Use GAIA and 2MASS to calibrate  
  index = lonarr(ncat,2)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  gd = where(total(index gt -1,2) eq 2,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA and 2MASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA and 2MASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and col ge 0.3 and col le 0.7,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  tmass2 = tmass1[gdcat]
  ; Take a robust mean relative to model ZMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + tmass2.jerr^2)
  ; see nsc_color_relations_stripe82_superposition.pro
  ; z = J + 0.765720*JK0 + 0.40*EBV +  0.605658
  model_mag = tmass2.jmag + 0.765720*col2 + 0.40*cat2.ebv +  0.605658
  diff = model_mag - mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
; ---- Y-band ----
'Y': begin
  ; Use 2MASS to calibrate
  index = lonarr(ncat,2)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  gd = where(total(index gt -1,2) eq 2,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA and 2MASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA and 2MASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and col ge 0.3 and col le 0.7,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  tmass2 = tmass1[gdcat]
  ; Take a robust mean relative to model YMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime) ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + tmass2.e_jmag^2)
  ; see nsc_color_relations_stripe82_superposition.pro
  ; Y = J + 0.54482*JK0 + 0.20*EBV + 0.663380
  model_mag = tmass2.jmag + 0.54482*col2 + 0.20*cat2.ebv + 0.663380
  diff = model_mag - mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
; ---- VR-band ----
'VR': begin
  ; Use GAIA G-band to calibrate
  index = lonarr(ncat,2)-1
  SRCMATCH,gaia.ra_icrs,gaia.de_icrs,cat.ra,cat.dec,0.5,gind1,gind2,/sph,count=ngmatch
  if ngmatch gt 0 then index[gind2,0] = gind1
  SRCMATCH,tmass.raj2000,tmass.dej2000,cat.ra,cat.dec,0.5,tind1,tind2,/sph,count=ntmatch
  if ntmatch gt 0 then index[tind2,1] = tind1
  gd = where(total(index gt -1,2) eq 2,ngd)
  printlog,logf,strtrim(ngd,2),' matches to GAIA and 2MASS'
  if ngd eq 0 then begin
    printlog,logf,'No matches to GAIA and 2MASS'
    return
  endif
  ; Matched catalogs
  cat1 = cat[gd]
  gaia1 = gaia[index[gd,0]]
  tmass1 = tmass[index[gd,1]]
  ; Make quality and error cuts
  gmagerr = 2.5*alog10(1.0+gaia1.e__fg_/gaia1._fg_)
  col = tmass1.jmag-tmass1.kmag-0.17*cat1.ebv  ; (J-Ks)o = J-Ks-0.17*EBV
  gdcat = where(cat1.mag_auto lt 50 and cat1.magerr_auto lt 0.05 and cat1.class_star gt 0.8 and $
                cat1.fwhm_world*3600 lt 2*medfwhm and gmagerr lt 0.05 and tmass1.qflg eq 'AAA' and $
                tmass1.e_jmag lt 0.05 and col ge 0.3 and col le 0.7,ngdcat)
  if ngdcat eq 0 then begin
    printlog,logf,'No stars that pass all of the quality/error cuts'
    return
  endif
  cat2 = cat1[gdcat]
  gaia2 = gaia1[gdcat]
  gmagerr2 = gmagerr[gdcat]
  col2 = col[gdcat]
  tmass2 = tmass1[gdcat]
  ; Take a robust mean relative to GAIA GMAG
  mag = cat2.mag_auto + 2.5*alog10(exptime)  ; correct for the exposure time
  err = sqrt(cat2.magerr_auto^2 + gmagerr2^2)
  diff = gaia2._gmag_ - mag
  ; Make a sigma cut
  med = median(diff)
  sig = mad(diff)
  gd = where(abs(diff-med) lt 3*sig,ngd)
  x = fltarr(ngdcat)
  zpterm = dln_poly_fit(x[gd],diff[gd],0,measure_errors=err[gd],sigma=zptermerr,yerror=yerror,status=status,yfit=yfit1,/bootstrap)
  zpterm = zpterm[0] & zptermerr=zptermerr[0]
  ; Save in exposure structure
  expstr.zpterm = zpterm
  expstr.zptermerr = zptermerr
  expstr.zptermsig = sig  
  expstr.nrefmatch = ngdcat
  expstr.fwhm = medfwhm
  ; Apply the zero-point to the full catalogs
  gdcatmag = where(cat.mag_auto lt 50,ngd)
  cat[gdcatmag].cmag = cat[gdcatmag].mag_auto + 2.5*alog10(exptime) + zpterm
  cat[gdcatmag].cerr = sqrt(cat[gdcatmag].magerr_auto^2 + zptermerr^2)  ; add calibration error in quadrature
end
else: begin
  printlog,logf,filter,' not currently supported'
  return
end
ENDCASE
printlog,logf,'ZPTERM = ',stringize(expstr.zpterm,ndec=4),' +/- ',stringize(expstr.zptermerr,ndec=4),'  SIG=',stringize(expstr.zptermsig,ndec=4),' mag'


; Step 5. Write out the final catalogs and metadata
;--------------------------------------------------
printlog,logf,'' & printlog,logf,'Writing final catalog to ',outfile
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
