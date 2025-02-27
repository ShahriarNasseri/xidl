;+
;
; NAME
;      do_extract_dither.pro
;
; PURPOSE
;      Makes iterative calls to extract1d.pro to extract 1d spectra
;      from slit files. The extracted spectra are packaged according
;      to slit number (blue and red portions together) and saved to a
;      .fits file.
;
;
; SYNTAX
;      do_extract, [files=files, _EXTRA=EXTRA]
;
; INPUTS
;      files = an optional parameter giving a vector of slit file
;              names. The procedure calls the extract1d.pro and
;              extracts a 1d spectrum from each of the slit files. 
;
; KEYWORDS
;      
;
; OUTPUTS
;      A .fits file which contains the extracted 1d spectra for a
;      given slit on a given mask. The files are named
;      "spec1d.xxxx.nnn.fits" where xxxx denotes the mask number and
;      nnn gives the slit number. Within the fits file, the blue
;      portion of the spectra is saved as the first extension and the
;      red portion of the spectrum is saved as the second
;      extension. Each is a structure containing flux, wavelength, and
;      inverse variance information. For example:
;           bfoo = mrdfits('spec1d.xxxx.nnn.fits', 1)
;           rfoo = mrdfits('spec1d.xxxx.nnn.fits', 2)
;           bfoo.spec = the flux as a function of wavelength on the
;                       blue end.
;           bfoo.lambda = the wavelength solution for the blue end (in
;                         linear lambda form). 
;           bfoo.ivar = the inverse variance as a function of
;                       wavelength on the blue end.
;
; PROCEDURES CALLED 
;      extract1d.pro
;      mcc_gauss1dfit.pro
;      find_object.pro
;      peakinfo.pro
;      find_objpos.pro
;      fxaddpar
;      headfits
;      mrdfits
;      mwrfits
;
; EXAMPLES
;      None.
;
; COMMENTS
;      The do_extract.pro routine assumes that you are already in the
;      directory which contains the slit files. This is a reasonable
;      assumption since this routine is intended to be called within
;      the domask.pro wrapper which makes the same assumption. Note
;      that the PBS shell script cd's to the proper directory. 
;
;      If the user passes do_extract 100 or more slitfiles, then the
;      routine will determine the seeing difference between the
;      photmetric observations (design fwhm) and the spectroscopy
;      observations (fwhm from spatial profile). This difference will
;      be applied to the design fwhm's and used in the extraction. The
;      position of the object will be chosen according to the significance
;      of the peak in the spatial profile. If a strong peak, then
;      pkcol (from peakinfo) will be used. If not so strong, the
;      design position will be employed.
;      If you feed do_extract less than 100 slitfiles, then it will
;      use the fwhm according to the design specifications (without
;      adjusting for seeing changes between the photometric
;      observations and the present spectroscopy data). The position
;      will be chosen in the same manner according to the significance
;      of the peak in the spatial profile.
;
; HISTORY
;      Created July 22, 2002 by mcc.
;      Revised July 28, 2002 by mcc - routine adjusted to accomodate     
;         changes in the routines find_object, peakinfo, and
;         extract1d. 
;      Revised July 29, 2002 by mcc - routine revised to handle the
;         varying lengths of structures. The structures read-in from
;         the slitfiles are now stored using pointers.
;      Revised August 4, 2002 by mcc - reversed revision from July
;        29th. Saving structures using pointers was too inefficient
;        and so now the routine simply reads the files multiple times.
;      Revised August 26, 2002 by mcc - added /CREATE keyword to call
;         to MWRFITS so that the spec1d.xxxx.nnn.fits files are
;         re-written each time that the pipeline is run. Also added
;         code to account for multiple objects in a single slit..
;      Hacked 21sep02 by MD to simplify object finding.
;      Revised October 21, 2002 by mcc - complete revision of routine!
;      Revised November 4, 2002 by mcc - another complete revision!
;      Revised March 1, 2003 by mcc - routine now extracts spectra
;         according to the /boxsprof and /horne extractions. Tests
;         with a fake data showed that these extractions gave better
;         results in the cases of bad pixel columns. The /boxsprof was
;         far superior to the /boxcar and the /horne was very
;         minimally better than the /optimal.
;-

;Estimate the RA/DEC of a serendipitous source


; a simple procedure to find only the unique solutions in a array. 
pro select_uniq, bstr, rstr, bfin=bfin, rfin=rfin, isdeep=isdeep
  flagval = 0
  sz = n_elements(bstr)
  for i=0,sz-1 do begin
      if bstr[i].objpos eq flagval then flag = 1 else flag = 0 
      dex = where(bstr.objpos eq bstr[i].objpos, dcnt)
      if i eq 0 then subscr = dex[0] $
      else begin
          junk = where(subscr eq dex[0], jcnt)
          if jcnt eq 0 or flag then subscr = [subscr, dex[0]]
      endelse
  endfor
  bfin = bstr[subscr]
  rfin = rstr[subscr]
  num = n_elements(subscr)
  if keyword_set(isdeep) then begin
      alpha = ['b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k']
      lchar = alpha[indgen(num)]
      objno = strmid(bfin[0].objno, 0, 9) + lchar
      bfin.objno = objno
      rfin.objno = objno
  endif else begin
      objnames = 'serendip' + string((indgen(num) + 1), format='(I0.3)')
      bfin.objno = objnames
      rfin.objno = objnames
  endelse
end
;--------------------------------
; a function to determine the name of a serendip object.
function get_objname, inum, objpos, ss, pcat, ra=ra, dec=dec
; initialize the variables ra and dec to be null-strings.
  ra = ''
  dec = ''
; construct a way to convert numbers to letters...this is bad!
  alpha = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', $
           'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r']
; determine the number of catalog objects in the slit.
  catnum = n_elements(ss)
  for i=0,catnum-1 do begin
; determine the distance between the serendip and the known object.
      if ss[i].objpos gt 0. then pixdist = abs(objpos - ss[i].objpos) $
      else pixdist = abs(objpos - ss[i].cat_objpos)
; get the RA and DEC for the catalog object.
      dex = where(pcat.objno eq long(ss[i].objno), cnt)
      if cnt gt 0 then begin
          dec0 = pcat[dex[0]].dec
          ra0 = pcat[dex[0]].ra
; determine the RA and DEC offsets to the serendip.
          slit_xy2radec, pixdist, dec0, pixel_scale=pixscl, $
            slitpa=slitpa, maskpa=maskpa, $
            delta_ra=delta_ra, delta_dec=delta_dec, /degrees
; calculate the RA and DEC of the serendip.
          if keyword_set(dec) then dec = [dec, dec0 + delta_dec] $
            else dec = [dec0 + delta_dec]
          if keyword_set(ra) then ra = [ra, ra0 + delta_ra]
          ra = [ra0 + delta_ra]
      endif
  endfor
; if there are multiple catalog objects then take the average RA and
; DEC values.
  if keyword_set(dec) then dec = mean(dec) 
  if keyword_set(ra) then ra = mean(ra)
; now convert the RA and DEC from decimal degrees to HR:MIN:SEC
; format.
  if ra ne '' and dec ne '' then begin
      radec, ra, dec, hr, mn, sc, deg, min, sec
      ra = strn(hr,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
        strn(mn,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
        strn(sc, padtype=1, padchar='0', format='(F5.2)', length=5)
      if deg lt 0 then sign = '-' else sign = '+'
      dec = sign + $
        strn(deg,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
        strn(min, padtype=1, padchar='0', format='(I2.2)') + ':' + $
        strn(sec, padtype=1, padchar='0', format='(F4.1)', length=4)
  endif else begin
      ra = ''
      dec = ''
  endelse
; lastly construct the name for the serendip object.
  name = 's' + strcompress(string(ss[0].objno), /rem) + alpha[inum]
  return, name
end
;--------------------------------
; a procedure to extract the RA and DEC of an object from the objectcat.
function get_radec, objno, objcat=objcat
  if keyword_set(objcat) then begin
      dex = where(strcompress(objcat.object, /rem) eq objno, cnt)
      if cnt gt 0 then begin
          dec = float(objcat[dex[0]].dec_obj)
          ra = float(objcat[dex[0]].ra_obj)
          radec, ra, dec, hr, mn, sc, deg, min, sec
          ra = strn(hr,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(mn,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(sc, padtype=1, padchar='0', format='(F5.2)')
          if deg lt 0 then sign = '-' else sign = '+'
          dec = sign + $
            strn(deg,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(min, padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(sec, padtype=1, padchar='0', format='(F4.1)')
      endif else begin
          dec = ''
          ra = ''
      endelse
  endif
;  if keyword_set(pcat) then begin
;      dex = where(pcat.objno eq long(objno), cnt)
;      if cnt gt 0 then begin
;          dec = pcat[dex[0]].dec
;          ra = pcat[dex[0]].ra
;      endif else begin
;          dec = ''
;          ra = ''
;      endelse
;  endif
  return, [ra, dec]
end

;--------------------------------
; a procedure to extract the magnitudes (B,R,I) of an object from the
; pcat.
function get_mags, objno, pcat=pcat, objpa=objpa
  dd = where(strcompress(string(pcat.objno), /rem) eq $
             strcompress(objno, /rem), cnt)
  if cnt eq 0 then begin
      objpa = 999.0
      output = [0.0, 0.0, 0.0]
  endif else begin
      output = [pcat[dd[0]].magb, $
                pcat[dd[0]].magr, $
                pcat[dd[0]].magi]
      objpa = pcat[dd[0]].pa
  endelse
  return, output
end

pro do_extract_dither, inputfile,files=files, nonlocal=nonlocal, $
                nsigma_optimal=nsigma_optimal, $
                nsigma_boxcar=nsigma_boxcar, _extra=extra

if n_elements(inputfile) eq 0 then begin
   message, 'You must specify a list of input positions!'
endif


;print,'Capak V3.0 dither'

;manual extraction size, forced, should code as an option at some point
;fwhmB=10 ;manually forced FWHM for extraction
;fwhmR=10
;avgfwhmB=10 ;manually forced boxcar for extraction
;avgfwhmR=10
    

; if no slit files are passed to the routine, then simply find all
; slit files in the current directory.
  if n_elements(files) eq 0 then files = findfile('slit*.fits')

; if no slit files are passed or found, then return error message.
  nfiles = n_elements(files)
  if nfiles eq 0 then message, 'ERROR: no slitfiles supplied by ' + $
    'user or found in current directory!'

; if the nonlocal keyword is set, then extract from the extension
; in the slitfile that contains the non-local-sky-subtracted data.
;  if keyword_set(nonlocal) then goto, jump_nonlocal

;--------------------------------
; step 1: match the pairs of slit files (red and blue pairs) and
; determine objects positions, fwhms, and serendips. tabulate all the
; information in an array of structures.

; define the scale in pixels at which two peaks in the spatial
; profile will be considered to be denoting the same object.
  resolu = 5.
; define the scale over which to smooth the spatial profile when
; searching for serendips.
  smthscl = 3.
; define the threshold level for object detection.
  thresh = 15.
  thresh_serendip = 10.
; define the window and nbuf values passed to the peakinfo routine.
  window = 5.
  nbuf = 2.
; define the template structure to catch the plethora of info
; regarding each object.
  template = {objno:'', slitno:long(0), slitfile:'', $
              objtype:'', color:'', cat_objpos:float(0), $
              cat_fwhm:float(0), objpos:float(0), fwhm:float(0), $
              corr_fwhm:float(0), nrows:float(0), $
              s2n_fwhm:float(0), s2n_window:float(0), $
              ra:'', dec:'', Xmm:float(-1), Ymm:float(-1), $
              magb:999.0, magr:999.0, magi:999.0, objpa:999.0}
; make the inital done array.
  done_arr = [-1]

; loop through the slitfiles...
  for i=0,nfiles-1 do begin
; check if this particular slitfile has already been processed with
; its counterpart.
      ddex = where(done_arr eq i, dcnt)
      if dcnt eq 0 then begin
; now for the ith file in the list of slit files, find all files
; (blue/red) that correspond to the same slit number. that is, find
; the pair (blue and red) files that contain all of the data for the
; slit.
          loc = strpos(files[i], '.fits')
          slitdex = where( strmid(files, 0, loc-1) eq $
                           strmid(files[i], 0, loc-1) and $
                           files ne files[i], slitcnt )
; loop through the slitfiles...
          for j=0,slitcnt do begin
; get the right file.
              if j eq 0 then this_file = files[i] $
              else this_file = files[slitdex[j-1]]
; extract the data from the file.
              slit = mrdfits(this_file, 1, hdr, /silent) 
; get the mask number from the file header. only do this once for the
; set of slitfiles (we can assume that all files are from the same
; mask).
              if i eq 0 then begin
                  mask = strcompress( sxpar(hdr, 'SLMSKNAM'), /rem)
; and if the mask is a DEEP2 mask, then remove the ".E" or ".W" at the
; end of the mask name (only keep the xxxx numbers). to do this we
; must check the bin table file to see if the mask is a DEEP2 mask!
                  bintab = findfile('*.bintabs.fits*', count=bincnt)
                  if bincnt eq 0 then $
                    message, '(do_extract.pro) bintab file not found!' $
                  else begin
                      bintab = bintab[0]
; open bin table file and get the extension names...remember to close
; the opened file!!!
                      fits_open, bintab, fcb
                      extnames = fcb.extname
                      fits_close, fcb
; also extract the ObjectCat table from the bintab file.
                      tabdex = where(extnames eq 'ObjectCat', cnt)
                      if cnt eq 0 then $
                        print, '(do_extract.pro) ObjectCat table ' + $
                        'not found in bintab file!' $
                      else objcat = mrdfits(bintab, tabdex[0], /silent)
; extract the Xmm and Ymm positions from the bintab file. The Xmm and
; Ymm values give the position of the slit (at its center) on the
; DEIMOS detector in units of milimeters.                      
                      bludex = where(extnames eq 'BluSlits', blucnt)
                      desdex = where(extnames eq 'DesiSlits', descnt)
                      if blucnt eq 0 or descnt eq 0 then begin
                          if blucnt eq 0 then $
                            print, '(do_extract.pro) BluSlits table ' + $
                            'not found in bintab file!'
                          if descnt eq 0 then $
                            print, '(do_extract.pro) DesiSlits table ' + $
                            'not found in bintab file!'
                      endif else begin
                          blutab = mrdfits(bintab, bludex[0], /silent)
                          desitab = mrdfits(bintab, desdex[0], /silent)
; sort the BluSlits and DesiSlits tables by dslitid number.
                          blutab = blutab[sort(blutab.dslitid)]
                          desitab = desitab[sort(desitab.dslitid)]
                          nslit = n_elements(blutab)
                          slitinfo = {slitn:lonarr(nslit), $
                                      Xmm:fltarr(nslit), $
                                      Ymm:fltarr(nslit)}
                          slitinfo.Xmm = (blutab.slitx1 + blutab.slitx2 + $
                                          blutab.slitx3 + blutab.slitx4) / 4.0
                          slitinfo.Ymm = (blutab.slity1 + blutab.slity2 + $
                                          blutab.slity3 + blutab.slity4) / 4.0
                          slitinfo.slitn = long(desitab.slitname)
                      endelse
                  endelse
              endif ;if i eq 0 (only for first slitfile in list)
; determine the number of pixels in the slitfile.
              npix_rows = n_elements(slit.flux[0,*])
; get the slit number from the file header and extract the object
; position, fwhm, object number, object type from the mask design
; tables.
              slitnum = long( sxpar(hdr, 'SLITNO') )
              desipos = find_objpos(slitnum, npix_rows, fwhm=cat_width, $
                                    objnum=objnum, objtype=objkind)
              objnum = strcompress( string(objnum), /rem)

; determine if this a blue or red portion of the slit.
             loc = strpos(this_file, '.fits')
             hue = strmid(this_file, loc-1, 1)

; determine how many objects are expected to be in this slit.
              catnum = n_elements(desipos)

; create an array of structures to hold the info about these objects.
              str = replicate(template, catnum)
              for k=0,catnum-1 do begin
                  str[k].slitfile = this_file
                  str[k].slitno = slitnum
                  str[k].objno = objnum[k]
                  str[k].objtype = objkind
                  str[k].cat_objpos = desipos[k]
                  str[k].cat_fwhm = cat_width[k]
                  str[k].nrows = npix_rows
                  str[k].color = hue
                  dd = where(slitinfo.slitn eq slitnum, ddcnt)
                  if ddcnt gt 0 then begin
                      str[k].Xmm = slitinfo.Xmm[dd[0]]
                      str[k].Ymm = slitinfo.Ymm[dd[0]]
                  endif
                  if keyword_set(objcat) then begin
                      radec = get_radec(objnum[k], objcat=objcat)
                      str[k].ra = radec[0]
                      str[k].dec = radec[1]
                  endif else begin
                      str[k].ra = ''
                      str[k].dec = ''
                  endelse
              endfor            ;k-index

; add the information for this slit to the composite structure.
              if i eq 0 and j eq 0 then finstr = str $
              else finstr = [finstr, str]
; lastly before iterating, add these entries in the slit files array
; to the array containing all the entries which have been analyzed.
              if i eq 0 then begin
                  if slitcnt gt 0 then done_arr = [i, slitdex] $
                  else done_arr = [i] 
              endif else begin
                  if slitcnt gt 0 then done_arr = [done_arr, i, slitdex] $
                  else done_arr = [done_arr, i]
              endelse
          endfor ;j-index
      endif
  endfor                        ;i-index

;read in the manual list of poistions                                
readcol,inputfile,slitfiles,posBmanual,posRmanual,fwhmB,fwhmR,format='a,f,f,f,f'
nmanual=n_elements(slitfiles)


;create an array for holding the number of serendips per slit
;assume we will never have more than 400 slits
serendip_cnt=intarr(400)


;read in some of the bintab information to estimage the RA DEC of serendip sources

;define an array which contains the slit poisition corrections
;might as well get the RA/DEC as correct as possible
serendip_poscor=intarr(400)

;read in the mask info file
bintab = findfile('*.bintabs.fits*', count=bincnt)
if bincnt eq 0 then message, '(do_extract.pro) bintab file not found!' $
else bintab = bintab[0]

;extract the slit tables
m1=mrdfits(bintab,1,/silent)      ; info on the central obj in the slit
m3=mrdfits(bintab,3,/silent)      ; info on the slit
m4=mrdfits(bintab,4,/silent)      ; info on the geometry of the slit



for j=0,nmanual-1 do begin
   
   ;get the string number
   file_name_len = strlen(slitfiles(j))
   file_No=strmid(slitfiles(j),file_name_len-3,file_name_len)
   
   ;figure out where to add the information
   blue_obj=where( finstr.slitno eq file_No and finstr.color eq 'B' and finstr.objtype eq 'P',bcnt)
   red_obj=where( finstr.slitno eq file_No and finstr.color eq 'R' and finstr.objtype eq 'P',rcnt)

   ;if no object found this could be an aligbnment box, check for that
   if bcnt EQ 0 then blue_obj=where( finstr.slitno eq file_No and finstr.color eq 'B' and finstr.objtype eq 'A',bcnt)
   if rcnt EQ 0 then red_obj=where( finstr.slitno eq file_No and finstr.color eq 'R' and finstr.objtype eq 'A',rcnt)

   ;get the slit number
   slit_No = finstr(blue_obj).slitno

   ;cludge for 2 objects in a slit, sometimes happens
   if n_elements(slit_No) gt 1 then slit_No=slit_No[0]
  
   ;check if this is the first object we are doing
   if serendip_cnt(slit_No) eq 0 then begin
             
      ;put the information into the structure
      if bcnt GT 0 then begin
         finstr(blue_obj).objpos=posBmanual(j)
         finstr(blue_obj).fwhm=fwhmB(j)
      endif

      if rcnt GT 0 then begin
         finstr(red_obj).objpos=posRmanual(j)
         finstr(red_obj).fwhm=fwhmR(j)
      endif

       
      ;record the correction to the object position so we can estimate the serendip RA/DEC better
      if bcnt GT 0 then serendip_poscor(slit_No) = finstr(blue_obj).cat_objpos - posBmanual(j) $
      else serendip_poscor(slit_No) = finstr(blue_obj).cat_objpos - posRmanual(j) 

      if serendip_poscor(slit_No) GT -9 and serendip_poscor(slit_No) LT 13 then begin 
         ;print,serendip_poscor(slit_No) 
      endif else begin
         sname = strcompress(slit_No);
         print,'Probably miss identified Serendip as primary source in Slit ',sname,' Offset is = ',serendip_poscor(slit_No),' pixels'
         serendip_poscor(slit_No) = 0
      endelse
         


      ;increment the serendip number so we know all following objects are serendips
      serendip_cnt(slit_No) = serendip_cnt(slit_No) + 1

   endif else begin
      
      ;this is a serendip, replicate the information from the main slit  
      
      ;replicate the template structure for the serendip, only one structure if no red or blue side
      if ((bcnt GT 0) AND (rcnt GT 0)) then serendip_str = replicate(template, 2) $
      else serendip_str = replicate(template, 1)

      ;setup a name for the serendip
      serendip_name = 'serendip' + strcompress(string(serendip_cnt(file_No)),/REMOVE_ALL)

      
      ;this determines the RA/DEC of the serendip
      ;read some information from the bintab file on the slit
      slit_ra = m3[slit_No].SLITRA   ; deg 
      slit_dec = m3[slit_No].SLITDEC ;deg
      obj_ra = m1[slit_No].RA_OBJ    ;deg
      obj_dec = m1[slit_No].DEC_OBJ  ;deg
      slit_len = m3[slit_No].SLITLEN ;arcsec
      slit_wid = m3[slit_No].SLITWID ;arcsec
      slit_pa = m3[slit_No].SLITLPA  ;deg
      mask_pa =m3[slit_No].SLITWPA   ;deg
      scale =0.119              ; scale arcsec/pixel 
      
      ;correct the manual position to the expected position based on the primary object
      if bcnt GT 0 then corpos = posBmanual[j] + serendip_poscor(slit_No) $
      else corpos = posRmanual[j] + serendip_poscor(slit_No)
      
      ;determine the object position on the slit in degrees
      y_deg = corpos*scale/3600d

      ;calculate some geometric parameters 
      slit_dec_cos = cos(slit_dec*!DTOR)
      slit_pa_sin  = sin((90-mask_pa)*!DTOR)
      slit_pa_cos  = cos((90-mask_pa)*!DTOR)
      slit_len_arcs = slit_len
      slit_len_dr_arcs = slit_len+(34 *scale)
      half_slit_len = 0.5*(slit_len)/3600d
      tt=obj_dec+(0.5*(slit_len+(34*scale))/3600d)

      ;calcualte the RA and DEC in degrees
      sRAdeg  = obj_ra + ((half_slit_len-y_deg)*cos(mask_pa*!DTOR)*cos(obj_dec*!DTOR))
      sDECdeg = obj_dec - ((half_slit_len-y_deg)*sin(mask_pa*!DTOR))

      ;convert the RA DEC to HH:MM:SS and DD:MM:SS format

      radec, sRAdeg, sDECdeg, hr, mn, sc, deg, min, sec
      ra = strn(hr,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
           strn(mn,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
           strn(sc, padtype=1, padchar='0', format='(F5.2)', length=5)
      if deg lt 0 then sign = '-' else sign = '+'
      dec = sign + $
            strn(deg,  padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(min, padtype=1, padchar='0', format='(I2.2)') + ':' + $
            strn(sec, padtype=1, padchar='0', format='(F4.1)', length=4)


      
      ;put the information for the serendip into the structure
      
      ;check if there is both a blue and red side, set red count to 0 if not, 1 otherwise
      if ((bcnt GT 0) AND (rcnt GT 0)) then rk=1 else rk=0

      ;first the blue side
      if bcnt GT 0 then begin
         serendip_str[0].objno = serendip_name
         serendip_str[0].slitno = finstr[blue_obj].slitno
         serendip_str[0].slitfile = finstr[blue_obj].slitfile
         serendip_str[0].objtype = 'Q'
         serendip_str[0].color = finstr[blue_obj].color
         serendip_str[0].cat_objpos = 0
         serendip_str[0].cat_fwhm = 0
         serendip_str[0].objpos = posBmanual[j]
         serendip_str[0].fwhm = fwhmB[j]
         serendip_str[0].corr_fwhm = finstr[blue_obj].corr_fwhm
         serendip_str[0].nrows = finstr[blue_obj].nrows
         serendip_str[0].s2n_fwhm = finstr[blue_obj].s2n_fwhm
         serendip_str[0].s2n_window = finstr[blue_obj].s2n_window
         serendip_str[0].ra = ra
         serendip_str[0].dec = dec
         serendip_str[0].xmm = 0
         serendip_str[0].ymm = 0
         serendip_str[0].magb = 999.000
         serendip_str[0].magr = 999.000
         serendip_str[0].magi = 999.000
         serendip_str[0].objpa = 999.000
      endif

      ;now the red side
      if rcnt GT 0 then begin
         serendip_str[rk].objno = serendip_name
         serendip_str[rk].slitno = finstr[red_obj].slitno
         serendip_str[rk].slitfile = finstr[red_obj].slitfile
         serendip_str[rk].objtype = 'Q'
         serendip_str[rk].color = finstr[red_obj].color
         serendip_str[rk].cat_objpos = 0
         serendip_str[rk].cat_fwhm = 0
         serendip_str[rk].objpos = posRmanual[j]
         serendip_str[rk].fwhm = fwhmR[j]
         serendip_str[rk].corr_fwhm = finstr[red_obj].corr_fwhm
         serendip_str[rk].nrows = finstr[red_obj].nrows
         serendip_str[rk].s2n_fwhm = finstr[red_obj].s2n_fwhm
         serendip_str[rk].s2n_window = finstr[red_obj].s2n_window
         serendip_str[rk].ra = ra
         serendip_str[rk].dec = dec
         serendip_str[rk].xmm = 0
         serendip_str[rk].ymm = 0
         serendip_str[rk].magb = 999.000
         serendip_str[rk].magr = 999.000
         serendip_str[rk].magi = 999.000
         serendip_str[rk].objpa = 999.000
      endif
      
      ;combine the serendip and main strings
      finstr = [finstr, serendip_str]

      ;increment the serendip number
      serendip_cnt(slit_No) = serendip_cnt(slit_No) + 1

  endelse


endfor


; finally, save and analyze the info that was tabulated in step 1.
; create a file name in which to wrote the object info data.
  objfile = 'obj_info.' + mask + '.fits'
; copy the header from one of the slit files. remove the fields
; referring directly to the particular slit.
  hdr = copy_header(hdr, 'ObjInfo')
  sxdelpar, hdr, 'SLITNO'
  sxdelpar, hdr, 'SLITX0'
  sxdelpar, hdr, 'SLITX1'
  if keyword_set(corrB) then $
    sxaddpar, hdr, 'corrB', corrB[2], 'median seeing correction on Blue side'
  if keyword_set(corrR) then $
    sxaddpar, hdr, 'corrR', corrR[2], 'median seeing correction on Red side'
; add header entries for pcat seeing and for the seeing difference
; (both blue and red). 
  if keyword_set(psee) then $
    sxaddpar, hdr, 'pcat_see', psee, 'pcat seeing (cfht pixels)'
  if keyword_set(bsd) then $
    sxaddpar, hdr, 'SeeDiffB', bsd, 'Seeing Diff (arcsec)'
  if keyword_set(rsd) then $
    sxaddpar, hdr, 'SeeDiffR', rsd, 'Seeing Diff (arcsec)'

; write the object information structure into a fits file.
  mwrfits, finstr, objfile, hdr, /silent, /create


;now lets do the extraction!
  objdone = [-1]
; determine the number of objects which we need to extract.
  nfiles = n_elements(finstr)

  for j=0,nfiles-1 do begin

; get all entries matching the jth object number and slit
; number. really, object number should be enough here!
      objdex = where(finstr.objno eq finstr[j].objno and $
                     finstr.slitno eq finstr[j].slitno, objcnt)
; make sure that this object wasn't extracted already.
      done = where(objdone eq j, done_num)

; if not done previously and 2 entries in finstr are found, then do
; the following...
      if done_num eq 0 and objcnt gt 0 then begin
          if objcnt gt 2 then $
            print, '(do_extract.pro) ERROR: more than 2 objects found ' + $
            'with same object number!'
; figure out which entry is the blue portion of the slit and which is
; the red portion.
          bdex = where(finstr[objdex].color eq 'B', bcnt)
          if bcnt gt 1 then $
            print, '(do_extract.pro) ERROR: multiple objects ' + $
            '(w/ same objno) found in blue portion of slit ' + $
            strcompress(string(finstr[j].slitno), /rem)
          if bcnt GT 0 then bdex = objdex[bdex[0]]
          rdex = where(finstr[objdex].color eq 'R', rcnt)
          if rcnt gt 1 then $
            print, '(do_extract.pro) ERROR: multiple objects ' + $
            '(w/ same objno) found in red portion of slit ' + $
            strcompress(string(finstr[j].slitno), /remove_all)
          if rcnt gt 0 then rdex = objdex[rdex[0]]
      endif else begin
          bcnt = 0
          rcnt = 0
      endelse

      ; get the slit files.
      if bcnt gt 0 then bfile = finstr[bdex].slitfile
      if rcnt gt 0 then rfile = finstr[rdex].slitfile

      ;get the positions
      if bcnt gt 0 then posB = finstr[bdex].objpos
      if rcnt gt 0 then posR = finstr[rdex].objpos

      ;skip to end if no positional information
      if posB eq 0 then begin
          print,'Not in the input file! Probably missing'
          goto, skip_extraction
      endif

       ;get the fwhm for extraction
      if bcnt gt 0 then EfwhmB  = finstr[bdex].fwhm
      if rcnt gt 0 then EfwhmR = finstr[rdex].fwhm

  
sng=0.5
  
; specify the extraction width parameters (nsigma).
      if n_elements(nsigma_optimal) gt 0 then $
        nsig_opt = nsigma_optimal[0] else nsig_opt = 1.5
      if n_elements(nsigma_boxcar) gt 0 then $
        nsig_box = nsigma_boxcar[0] else nsig_box = 1.1 ;/ 2.35482

; extract the blue spectrum via the optimal extraction and via the
; tophat (or boxcar) extraction algorithm.
      if bcnt gt 0 then begin
          if keyword_set(nonlocal) then begin
              blu_opt = extract1d_dither(bfile, posB, EfwhmB, /horne, $
                                  /nonlocal, nsigma=nsig_opt)
              blu_box = extract1d_dither(bfile, posB, EfwhmB, $
                                  /nonlocal, nsigma=nsig_box)
          endif else begin
              blu_opt = extract1d_dither(bfile, posB, EfwhmB, /horne, $
                                  nsigma=nsig_opt)
              blu_box = extract1d_dither(bfile, posB, EfwhmB, $
                                  /boxsprof, nsigma=nsig_box)
          endelse
      endif
; similarly, extract the red spectrum.
      if rcnt gt 0 then begin
          if keyword_set(nonlocal) then begin
              red_opt = extract1d_dither(rfile, posR, EfwhmR, /horne, $
                                  /nonlocal, nsigma=nsig_opt)
              red_box = extract1d_dither(rfile, posR, EfwhmR, /boxsprof, $
                                  /nonlocal, nsigma=nsig_box)
          endif else begin
              red_opt = extract1d_dither(rfile, posR, EfwhmR, /horne, $
                                  nsigma=nsig_opt)
              red_box = extract1d_dither(rfile, posR, EfwhmR, $
                                  /boxsprof, nsigma=nsig_box)
          endelse
      endif
      
; define the name of the 1-d output file name.
      specfile = 'spec1d.' + mask + '.' + $
        string(finstr[j].slitno, format='(I3.3)') + '.' + $
        strcompress(finstr[j].objno, /rem) + '.fits'

; write the 1-d spectra (blue and red / optimal and tophat) to a
; single fits file. first, grab the header from one of the slitfiles
; and carry it over to the 1-d file.
      hdr = headfits(finstr[j].slitfile, ext=1, /silent)
; write the blue portion of the tophat/boxcar extraction.
      if bcnt gt 0 then begin
          if keyword_set(nonlocal) then $
;            hdrB = copy_header(hdr, 'Boxcar-NL') $
            hdrB = copy_header(hdr, 'Bxspf-NL-B') $
;          else hdrB = copy_header(hdr, 'Boxcar')
          else hdrB = copy_header(hdr, 'Bxspf-B')
          sxaddpar, hdrB, 'objno', finstr[bdex].objno, $
            'Object number', after='DATE'
          sxaddpar, hdrB, 'objpos', finstr[bdex].objpos, $
            'Object Position from Spatial Profile', after='objno'
          sxaddpar, hdrB, 'fwhm', finstr[bdex].fwhm, $
            'FWHM from Spatial Profile', after='objpos'
          sxaddpar, hdrB, 'cat_objpos', finstr[bdex].cat_objpos, $
            'Design Object Position', after='fwhm'
          sxaddpar, hdrB, 'cat_fwhm', finstr[bdex].cat_fwhm, $
            'FWHM from PCAT', after='cat_objp'
          sxaddpar, hdrB, 'cor_fwhm', finstr[bdex].corr_fwhm, $
            'FWHM from PCAT corrected for seeing diff', after='cat_fwhm'
          sxaddpar, hdrB, 'ext_fwhm', EfwhmB, $
            'FWHM employed in object extraction', after='cor_fwhm'
; add RA and DEC info is object is a serendip.
          if finstr[bdex].objtype eq 'Q' then begin
              sxaddpar, hdrB, 'RA_obj', finstr[bdex].ra, $
                'estimate of serendip RA', after='ext_fwhm'
              sxaddpar, hdrB, 'DEC_obj', finstr[bdex].dec, $
                'estimate of serendip DEC', after='RA_obj'
          endif else begin
              sxaddpar, hdrB, 'RA_obj', finstr[bdex].ra, $
                'RA of object', after='ext_fwhm'
              sxaddpar, hdrB, 'DEC_obj', finstr[bdex].dec, $
                'DEC of object', after='RA_obj'
          endelse  
          sxaddpar, hdrB, 'Xmm', finstr[bdex].xmm, $
            'X position of slit', after='DEC_obj'
          sxaddpar, hdrB, 'Ymm', finstr[bdex].ymm, $
            'Y position of slit', after='Xmm'
          sxaddpar, hdrB, 'magB', finstr[bdex].magb, $
            'B magnitude', after='Ymm'
          sxaddpar, hdrB, 'magR', finstr[bdex].magr, $
            'R magnitude', after='magB'
          sxaddpar, hdrB, 'magI', finstr[bdex].magi, $
            'I magnitude', after='magR'
          sxaddpar, hdrB, 'OBJPA', finstr[bdex].objpa, $
            'Object PA on sky', before='SLITPA'

          if bcnt gt 0 and size(blu_box, /tname) eq 'STRUCT' then begin
              print, '(do_extract.pro) Writing spec1d file: ' + $
                specfile + ' ......'
              if keyword_set(nonlocal) then $
                mwrfits, blu_box, specfile, hdrB, /silent $
              else mwrfits, blu_box, specfile, hdrB, /silent, /create
          endif
      endif
; write the red portion of tophat/boxcar extraction.
      if rcnt gt 0 then begin
          if keyword_set(nonlocal) then $
;            hdrR = copy_header(hdr, 'Boxcar-NL') $
            hdrR = copy_header(hdr, 'Bxspf-NL-R') $
;          else hdrR = copy_header(hdr, 'Boxcar') 
          else hdrR = copy_header(hdr, 'Bxspf-R')
          sxaddpar, hdrR, 'objno', finstr[rdex].objno, $
            'Object number', after='DATE'
          sxaddpar, hdrR, 'objpos', finstr[rdex].objpos, $
            'Object Position from Spatial Profile', after='objno'
          sxaddpar, hdrR, 'fwhm', finstr[rdex].fwhm, $
            'FWHM from Spatial Profile', after='objpos'
          sxaddpar, hdrR, 'cat_objpos', finstr[rdex].cat_objpos, $
            'Design Object Position', after='fwhm'
          sxaddpar, hdrR, 'cat_fwhm', finstr[rdex].cat_fwhm, $
            'FWHM from PCAT', after='cat_objp'
          sxaddpar, hdrR, 'cor_fwhm', finstr[rdex].corr_fwhm, $
            'FWHM from PCAT corrected for seeing diff', after='cat_fwhm'
          sxaddpar, hdrR, 'ext_fwhm', EfwhmR, $
            'FWHM employed in object extraction', after='cor_fwhm'
; add RA and DEC info is object is a serendip.
          if finstr[rdex].objtype eq 'Q' then begin
              sxaddpar, hdrR, 'RA_obj', finstr[rdex].ra, $
                'estimate of serendip RA', after='ext_fwhm'
              sxaddpar, hdrR, 'DEC_obj', finstr[rdex].dec, $
                'estimate of serendip DEC', after='RA_obj'
          endif else begin
              sxaddpar, hdrR, 'RA_obj', finstr[rdex].ra, $
                'RA of object', after='ext_fwhm'
              sxaddpar, hdrR, 'DEC_obj', finstr[rdex].dec, $
                'DEC of object', after='RA_obj'
          endelse
          sxaddpar, hdrR, 'Xmm', finstr[rdex].xmm, $
            'X position of slit', after='DEC_obj'
          sxaddpar, hdrR, 'Ymm', finstr[rdex].ymm, $
            'Y position of slit', after='Xmm'
          sxaddpar, hdrR, 'magB', finstr[rdex].magb, $
            'B magnitude', after='Ymm'
          sxaddpar, hdrR, 'magR', finstr[rdex].magr, $
            'R magnitude', after='magB'
          sxaddpar, hdrR, 'magI', finstr[rdex].magi, $
            'I magnitude', after='magR'
          sxaddpar, hdrR, 'OBJPA', finstr[rdex].objpa, $
            'Object PA on sky', before='SLITPA'
          if size(red_box, /tname) eq 'STRUCT' then begin
              if bcnt gt 0 then $
                mwrfits, red_box, specfile, hdrR, /silent $
              else begin 
                  print, '(do_extract.pro) Writing spec1d file: ' + $
                    specfile + ' ......'
                  if keyword_set(nonlocal) then $
                    mwrfits, red_box, specfile, hdrR, /silent $
                  else mwrfits, red_box, specfile, hdrR, /silent, /create
              endelse
          endif
      endif
; write the blue portion of the optimal extraction.
      if bcnt gt 0 then begin
          if keyword_set(nonlocal) then $
;            sxaddpar, hdrB, 'EXTNAME', 'Optimal-NL', 'Extension Name' $
            sxaddpar, hdrB, 'EXTNAME', 'Horne-NL-B', 'Extension Name' $
;          else sxaddpar, hdrB, 'EXTNAME', 'Optimal', 'Extension Name'
          else sxaddpar, hdrB, 'EXTNAME', 'Horne-B', 'Extension Name'
          sxaddpar, hdrB, 'ext_fwhm', EfwhmB, $
            'FWHM employed in object extraction'
          if size(blu_opt, /tname) eq 'STRUCT' then $
            mwrfits, blu_opt, specfile, hdrB, /silent
      endif
; write the red spectrum of optimal extraction.
      if rcnt gt 0 then begin
          if keyword_set(nonlocal) then $
;            sxaddpar, hdrR, 'EXTNAME', 'Optimal-NL', 'Extension Name' $
            sxaddpar, hdrR, 'EXTNAME', 'Horne-NL-R', 'Extension Name' $
;          else sxaddpar, hdrR, 'EXTNAME', 'Optimal', 'Extension Name' 
          else sxaddpar, hdrR, 'EXTNAME', 'Horne-R', 'Extension Name'
          sxaddpar, hdrR, 'ext_fwhm', EfwhmR, $
            'FWHM employed in object extraction'
          if size(red_opt, /tname) eq 'STRUCT' then $
            mwrfits, red_opt, specfile, hdrR, /silent
      endif
      
; construct/add to the list of object for which extraction has been
; completed.
      if j eq 0 then begin
          if bcnt gt 0 and rcnt gt 0 then $
            objdone = [bdex, rdex] $
          else begin
              if bcnt gt 0 then objdone = [bdex] 
              if rcnt gt 0 then objdone = [rdex]
          endelse
      endif else begin
          if bcnt gt 0 then objdone = [objdone, bdex]
          if rcnt gt 0 then objdone = [objdone, rdex]
      endelse
      skip_extraction:
  endfor



end
