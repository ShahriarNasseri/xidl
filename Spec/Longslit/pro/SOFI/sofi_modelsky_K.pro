

;; H+K setup
wvmnx = [1.8d, 2.5d] ;; expand the ragne to get slightly more coverage
dlam = (2.30-2.0)/1024.0d
lam_cen = 2.0 + (2.30-2.0)/2.0d
;; According to manual, assume resolution is actually 2 pixels
resolution = 2200.0 ;; lam_cen/(2.5*dlam)
flgd = 0
linefile = 'SOFI_modelsky_OH_linelist_K.lst'
outfile = 'SOFI_modelsky_OH_linelist_K.fits'
plate_scale = 0.288d
fnslit = 0.6/plate_scale ;; slits are 2x plate scale
pkwdth = 1.3*fnslit
toler = fnslit/2.0d > 2.0d
thin = 1
fweight = 0
nsig = 3.0d
;;T_BB = 273.0
T_BB = 250.0
wave_water = 2.33
nearir_modelsky_linelist, resolution, linefile, outfile $
                          , wvmnx = wvmnx, dlam = dlam, flgd = flgd $
                          , pkwdth = pkwdth, toler = toler, thin = thin $
                          , fweight = fweight, nsig = nsig, T_BB = T_BB $
                          , wave_water = wave_water
END
