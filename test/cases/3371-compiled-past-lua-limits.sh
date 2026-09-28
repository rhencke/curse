# Ordinary scripts whose compiled form passes LuaJIT's per-function limits: 210 variables
# lifted into registers (200 locals), a function touching 61 of them (60 upvalues), 199
# functions called from one loop, `case` nested 199 deep, 199 nested function definitions
# (65536 constants), `[[ ! ! … ]]` 100 deep (200 syntax levels). The compiled tier failed to
# load them ("function at line N has more than 200 local variables", …): compiled mode
# ended with a Lua traceback, tiered silently ran the interpreter (stress-attack S11). Now
# the coldest variables spill into one int64 array, long lists into one table, huge blocks
# and alternations into functions of their own, and a giant frame into segment functions.
# Each runs hot (150+ rounds); the biggest ones are generated and run by a child shell.
v0=0; v1=0; v2=0; v3=0; v4=0; v5=0; v6=0; v7=0; v8=0; v9=0; v10=0; v11=0; v12=0; v13=0; v14=0; v15=0; v16=0; v17=0; v18=0; v19=0; v20=0; v21=0; v22=0; v23=0; v24=0; v25=0; v26=0; v27=0; v28=0; v29=0; v30=0; v31=0; v32=0; v33=0; v34=0; v35=0; v36=0; v37=0; v38=0; v39=0; v40=0; v41=0; v42=0; v43=0; v44=0; v45=0; v46=0; v47=0; v48=0; v49=0; v50=0; v51=0; v52=0; v53=0; v54=0; v55=0; v56=0; v57=0; v58=0; v59=0; v60=0; v61=0; v62=0; v63=0; v64=0; v65=0; v66=0; v67=0; v68=0; v69=0; v70=0; v71=0; v72=0; v73=0; v74=0; v75=0; v76=0; v77=0; v78=0; v79=0; v80=0; v81=0; v82=0; v83=0; v84=0; v85=0; v86=0; v87=0; v88=0; v89=0; v90=0; v91=0; v92=0; v93=0; v94=0; v95=0; v96=0; v97=0; v98=0; v99=0; v100=0; v101=0; v102=0; v103=0; v104=0; v105=0; v106=0; v107=0; v108=0; v109=0; v110=0; v111=0; v112=0; v113=0; v114=0; v115=0; v116=0; v117=0; v118=0; v119=0; v120=0; v121=0; v122=0; v123=0; v124=0; v125=0; v126=0; v127=0; v128=0; v129=0; v130=0; v131=0; v132=0; v133=0; v134=0; v135=0; v136=0; v137=0; v138=0; v139=0; v140=0; v141=0; v142=0; v143=0; v144=0; v145=0; v146=0; v147=0; v148=0; v149=0; v150=0; v151=0; v152=0; v153=0; v154=0; v155=0; v156=0; v157=0; v158=0; v159=0; v160=0; v161=0; v162=0; v163=0; v164=0; v165=0; v166=0; v167=0; v168=0; v169=0; v170=0; v171=0; v172=0; v173=0; v174=0; v175=0; v176=0; v177=0; v178=0; v179=0; v180=0; v181=0; v182=0; v183=0; v184=0; v185=0; v186=0; v187=0; v188=0; v189=0; v190=0; v191=0; v192=0; v193=0; v194=0; v195=0; v196=0; v197=0; v198=0; v199=0; v200=0; v201=0; v202=0; v203=0; v204=0; v205=0; v206=0; v207=0; v208=0; v209=0; 
for ((i = 0; i < 150; i++)); do
  v0=$((v0 + i)); v1=$((v1 + 1)); v2=$((v2 ^ i))
  v3=$((v3 + i)); v4=$((v4 + 1)); v5=$((v5 ^ i))
  v6=$((v6 + i)); v7=$((v7 + 1)); v8=$((v8 ^ i))
  v9=$((v9 + i)); v10=$((v10 + 1)); v11=$((v11 ^ i))
  v12=$((v12 + i)); v13=$((v13 + 1)); v14=$((v14 ^ i))
  v15=$((v15 + i)); v16=$((v16 + 1)); v17=$((v17 ^ i))
  v18=$((v18 + i)); v19=$((v19 + 1)); v20=$((v20 ^ i))
  v21=$((v21 + i)); v22=$((v22 + 1)); v23=$((v23 ^ i))
  v24=$((v24 + i)); v25=$((v25 + 1)); v26=$((v26 ^ i))
  v27=$((v27 + i)); v28=$((v28 + 1)); v29=$((v29 ^ i))
  v30=$((v30 + i)); v31=$((v31 + 1)); v32=$((v32 ^ i))
  v33=$((v33 + i)); v34=$((v34 + 1)); v35=$((v35 ^ i))
  v36=$((v36 + i)); v37=$((v37 + 1)); v38=$((v38 ^ i))
  v39=$((v39 + i)); v40=$((v40 + 1)); v41=$((v41 ^ i))
  v42=$((v42 + i)); v43=$((v43 + 1)); v44=$((v44 ^ i))
  v45=$((v45 + i)); v46=$((v46 + 1)); v47=$((v47 ^ i))
  v48=$((v48 + i)); v49=$((v49 + 1)); v50=$((v50 ^ i))
  v51=$((v51 + i)); v52=$((v52 + 1)); v53=$((v53 ^ i))
  v54=$((v54 + i)); v55=$((v55 + 1)); v56=$((v56 ^ i))
  v57=$((v57 + i)); v58=$((v58 + 1)); v59=$((v59 ^ i))
  v60=$((v60 + i)); v61=$((v61 + 1)); v62=$((v62 ^ i))
  v63=$((v63 + i)); v64=$((v64 + 1)); v65=$((v65 ^ i))
  v66=$((v66 + i)); v67=$((v67 + 1)); v68=$((v68 ^ i))
  v69=$((v69 + i)); v70=$((v70 + 1)); v71=$((v71 ^ i))
  v72=$((v72 + i)); v73=$((v73 + 1)); v74=$((v74 ^ i))
  v75=$((v75 + i)); v76=$((v76 + 1)); v77=$((v77 ^ i))
  v78=$((v78 + i)); v79=$((v79 + 1)); v80=$((v80 ^ i))
  v81=$((v81 + i)); v82=$((v82 + 1)); v83=$((v83 ^ i))
  v84=$((v84 + i)); v85=$((v85 + 1)); v86=$((v86 ^ i))
  v87=$((v87 + i)); v88=$((v88 + 1)); v89=$((v89 ^ i))
  v90=$((v90 + i)); v91=$((v91 + 1)); v92=$((v92 ^ i))
  v93=$((v93 + i)); v94=$((v94 + 1)); v95=$((v95 ^ i))
  v96=$((v96 + i)); v97=$((v97 + 1)); v98=$((v98 ^ i))
  v99=$((v99 + i)); v100=$((v100 + 1)); v101=$((v101 ^ i))
  v102=$((v102 + i)); v103=$((v103 + 1)); v104=$((v104 ^ i))
  v105=$((v105 + i)); v106=$((v106 + 1)); v107=$((v107 ^ i))
  v108=$((v108 + i)); v109=$((v109 + 1)); v110=$((v110 ^ i))
  v111=$((v111 + i)); v112=$((v112 + 1)); v113=$((v113 ^ i))
  v114=$((v114 + i)); v115=$((v115 + 1)); v116=$((v116 ^ i))
  v117=$((v117 + i)); v118=$((v118 + 1)); v119=$((v119 ^ i))
  v120=$((v120 + i)); v121=$((v121 + 1)); v122=$((v122 ^ i))
  v123=$((v123 + i)); v124=$((v124 + 1)); v125=$((v125 ^ i))
  v126=$((v126 + i)); v127=$((v127 + 1)); v128=$((v128 ^ i))
  v129=$((v129 + i)); v130=$((v130 + 1)); v131=$((v131 ^ i))
  v132=$((v132 + i)); v133=$((v133 + 1)); v134=$((v134 ^ i))
  v135=$((v135 + i)); v136=$((v136 + 1)); v137=$((v137 ^ i))
  v138=$((v138 + i)); v139=$((v139 + 1)); v140=$((v140 ^ i))
  v141=$((v141 + i)); v142=$((v142 + 1)); v143=$((v143 ^ i))
  v144=$((v144 + i)); v145=$((v145 + 1)); v146=$((v146 ^ i))
  v147=$((v147 + i)); v148=$((v148 + 1)); v149=$((v149 ^ i))
  v150=$((v150 + i)); v151=$((v151 + 1)); v152=$((v152 ^ i))
  v153=$((v153 + i)); v154=$((v154 + 1)); v155=$((v155 ^ i))
  v156=$((v156 + i)); v157=$((v157 + 1)); v158=$((v158 ^ i))
  v159=$((v159 + i)); v160=$((v160 + 1)); v161=$((v161 ^ i))
  v162=$((v162 + i)); v163=$((v163 + 1)); v164=$((v164 ^ i))
  v165=$((v165 + i)); v166=$((v166 + 1)); v167=$((v167 ^ i))
  v168=$((v168 + i)); v169=$((v169 + 1)); v170=$((v170 ^ i))
  v171=$((v171 + i)); v172=$((v172 + 1)); v173=$((v173 ^ i))
  v174=$((v174 + i)); v175=$((v175 + 1)); v176=$((v176 ^ i))
  v177=$((v177 + i)); v178=$((v178 + 1)); v179=$((v179 ^ i))
  v180=$((v180 + i)); v181=$((v181 + 1)); v182=$((v182 ^ i))
  v183=$((v183 + i)); v184=$((v184 + 1)); v185=$((v185 ^ i))
  v186=$((v186 + i)); v187=$((v187 + 1)); v188=$((v188 ^ i))
  v189=$((v189 + i)); v190=$((v190 + 1)); v191=$((v191 ^ i))
  v192=$((v192 + i)); v193=$((v193 + 1)); v194=$((v194 ^ i))
  v195=$((v195 + i)); v196=$((v196 + 1)); v197=$((v197 ^ i))
  v198=$((v198 + i)); v199=$((v199 + 1)); v200=$((v200 ^ i))
  v201=$((v201 + i)); v202=$((v202 + 1)); v203=$((v203 ^ i))
  v204=$((v204 + i)); v205=$((v205 + 1)); v206=$((v206 ^ i))
  v207=$((v207 + i)); v208=$((v208 + 1)); v209=$((v209 ^ i))
done
x="v209 + v7 * 2"; echo "lifted: $v0 $v1 $v2 $v100 $v209 $((x))"
u0=1; u1=1; u2=1; u3=1; u4=1; u5=1; u6=1; u7=1; u8=1; u9=1; u10=1; u11=1; u12=1; u13=1; u14=1; u15=1; u16=1; u17=1; u18=1; u19=1; u20=1; u21=1; u22=1; u23=1; u24=1; u25=1; u26=1; u27=1; u28=1; u29=1; u30=1; u31=1; u32=1; u33=1; u34=1; u35=1; u36=1; u37=1; u38=1; u39=1; u40=1; u41=1; u42=1; u43=1; u44=1; u45=1; u46=1; u47=1; u48=1; u49=1; u50=1; u51=1; u52=1; u53=1; u54=1; u55=1; u56=1; u57=1; u58=1; u59=1; u60=1; 
fu() { local k; for ((k = 0; k < 200; k++)); do
  ((u0 += k))
  ((u1 += k))
  ((u2 += k))
  ((u3 += k))
  ((u4 += k))
  ((u5 += k))
  ((u6 += k))
  ((u7 += k))
  ((u8 += k))
  ((u9 += k))
  ((u10 += k))
  ((u11 += k))
  ((u12 += k))
  ((u13 += k))
  ((u14 += k))
  ((u15 += k))
  ((u16 += k))
  ((u17 += k))
  ((u18 += k))
  ((u19 += k))
  ((u20 += k))
  ((u21 += k))
  ((u22 += k))
  ((u23 += k))
  ((u24 += k))
  ((u25 += k))
  ((u26 += k))
  ((u27 += k))
  ((u28 += k))
  ((u29 += k))
  ((u30 += k))
  ((u31 += k))
  ((u32 += k))
  ((u33 += k))
  ((u34 += k))
  ((u35 += k))
  ((u36 += k))
  ((u37 += k))
  ((u38 += k))
  ((u39 += k))
  ((u40 += k))
  ((u41 += k))
  ((u42 += k))
  ((u43 += k))
  ((u44 += k))
  ((u45 += k))
  ((u46 += k))
  ((u47 += k))
  ((u48 += k))
  ((u49 += k))
  ((u50 += k))
  ((u51 += k))
  ((u52 += k))
  ((u53 += k))
  ((u54 += k))
  ((u55 += k))
  ((u56 += k))
  ((u57 += k))
  ((u58 += k))
  ((u59 += k))
  ((u60 += k))
done; }
for ((j = 0; j < 3; j++)); do fu; done; echo "upvalues: $u0 $u30 $u60"
f0() { fx=$((fx + 0)); }
f1() { fx=$((fx + 1)); }
f2() { fx=$((fx + 2)); }
f3() { fx=$((fx + 3)); }
f4() { fx=$((fx + 4)); }
f5() { fx=$((fx + 5)); }
f6() { fx=$((fx + 6)); }
f7() { fx=$((fx + 7)); }
f8() { fx=$((fx + 8)); }
f9() { fx=$((fx + 9)); }
f10() { fx=$((fx + 10)); }
f11() { fx=$((fx + 11)); }
f12() { fx=$((fx + 12)); }
f13() { fx=$((fx + 13)); }
f14() { fx=$((fx + 14)); }
f15() { fx=$((fx + 15)); }
f16() { fx=$((fx + 16)); }
f17() { fx=$((fx + 17)); }
f18() { fx=$((fx + 18)); }
f19() { fx=$((fx + 19)); }
f20() { fx=$((fx + 20)); }
f21() { fx=$((fx + 21)); }
f22() { fx=$((fx + 22)); }
f23() { fx=$((fx + 23)); }
f24() { fx=$((fx + 24)); }
f25() { fx=$((fx + 25)); }
f26() { fx=$((fx + 26)); }
f27() { fx=$((fx + 27)); }
f28() { fx=$((fx + 28)); }
f29() { fx=$((fx + 29)); }
f30() { fx=$((fx + 30)); }
f31() { fx=$((fx + 31)); }
f32() { fx=$((fx + 32)); }
f33() { fx=$((fx + 33)); }
f34() { fx=$((fx + 34)); }
f35() { fx=$((fx + 35)); }
f36() { fx=$((fx + 36)); }
f37() { fx=$((fx + 37)); }
f38() { fx=$((fx + 38)); }
f39() { fx=$((fx + 39)); }
f40() { fx=$((fx + 40)); }
f41() { fx=$((fx + 41)); }
f42() { fx=$((fx + 42)); }
f43() { fx=$((fx + 43)); }
f44() { fx=$((fx + 44)); }
f45() { fx=$((fx + 45)); }
f46() { fx=$((fx + 46)); }
f47() { fx=$((fx + 47)); }
f48() { fx=$((fx + 48)); }
f49() { fx=$((fx + 49)); }
f50() { fx=$((fx + 50)); }
f51() { fx=$((fx + 51)); }
f52() { fx=$((fx + 52)); }
f53() { fx=$((fx + 53)); }
f54() { fx=$((fx + 54)); }
f55() { fx=$((fx + 55)); }
f56() { fx=$((fx + 56)); }
f57() { fx=$((fx + 57)); }
f58() { fx=$((fx + 58)); }
f59() { fx=$((fx + 59)); }
f60() { fx=$((fx + 60)); }
f61() { fx=$((fx + 61)); }
f62() { fx=$((fx + 62)); }
f63() { fx=$((fx + 63)); }
f64() { fx=$((fx + 64)); }
f65() { fx=$((fx + 65)); }
f66() { fx=$((fx + 66)); }
f67() { fx=$((fx + 67)); }
f68() { fx=$((fx + 68)); }
f69() { fx=$((fx + 69)); }
f70() { fx=$((fx + 70)); }
f71() { fx=$((fx + 71)); }
f72() { fx=$((fx + 72)); }
f73() { fx=$((fx + 73)); }
f74() { fx=$((fx + 74)); }
f75() { fx=$((fx + 75)); }
f76() { fx=$((fx + 76)); }
f77() { fx=$((fx + 77)); }
f78() { fx=$((fx + 78)); }
f79() { fx=$((fx + 79)); }
f80() { fx=$((fx + 80)); }
f81() { fx=$((fx + 81)); }
f82() { fx=$((fx + 82)); }
f83() { fx=$((fx + 83)); }
f84() { fx=$((fx + 84)); }
f85() { fx=$((fx + 85)); }
f86() { fx=$((fx + 86)); }
f87() { fx=$((fx + 87)); }
f88() { fx=$((fx + 88)); }
f89() { fx=$((fx + 89)); }
f90() { fx=$((fx + 90)); }
f91() { fx=$((fx + 91)); }
f92() { fx=$((fx + 92)); }
f93() { fx=$((fx + 93)); }
f94() { fx=$((fx + 94)); }
f95() { fx=$((fx + 95)); }
f96() { fx=$((fx + 96)); }
f97() { fx=$((fx + 97)); }
f98() { fx=$((fx + 98)); }
f99() { fx=$((fx + 99)); }
f100() { fx=$((fx + 100)); }
f101() { fx=$((fx + 101)); }
f102() { fx=$((fx + 102)); }
f103() { fx=$((fx + 103)); }
f104() { fx=$((fx + 104)); }
f105() { fx=$((fx + 105)); }
f106() { fx=$((fx + 106)); }
f107() { fx=$((fx + 107)); }
f108() { fx=$((fx + 108)); }
f109() { fx=$((fx + 109)); }
f110() { fx=$((fx + 110)); }
f111() { fx=$((fx + 111)); }
f112() { fx=$((fx + 112)); }
f113() { fx=$((fx + 113)); }
f114() { fx=$((fx + 114)); }
f115() { fx=$((fx + 115)); }
f116() { fx=$((fx + 116)); }
f117() { fx=$((fx + 117)); }
f118() { fx=$((fx + 118)); }
f119() { fx=$((fx + 119)); }
f120() { fx=$((fx + 120)); }
f121() { fx=$((fx + 121)); }
f122() { fx=$((fx + 122)); }
f123() { fx=$((fx + 123)); }
f124() { fx=$((fx + 124)); }
f125() { fx=$((fx + 125)); }
f126() { fx=$((fx + 126)); }
f127() { fx=$((fx + 127)); }
f128() { fx=$((fx + 128)); }
f129() { fx=$((fx + 129)); }
f130() { fx=$((fx + 130)); }
f131() { fx=$((fx + 131)); }
f132() { fx=$((fx + 132)); }
f133() { fx=$((fx + 133)); }
f134() { fx=$((fx + 134)); }
f135() { fx=$((fx + 135)); }
f136() { fx=$((fx + 136)); }
f137() { fx=$((fx + 137)); }
f138() { fx=$((fx + 138)); }
f139() { fx=$((fx + 139)); }
f140() { fx=$((fx + 140)); }
f141() { fx=$((fx + 141)); }
f142() { fx=$((fx + 142)); }
f143() { fx=$((fx + 143)); }
f144() { fx=$((fx + 144)); }
f145() { fx=$((fx + 145)); }
f146() { fx=$((fx + 146)); }
f147() { fx=$((fx + 147)); }
f148() { fx=$((fx + 148)); }
f149() { fx=$((fx + 149)); }
f150() { fx=$((fx + 150)); }
f151() { fx=$((fx + 151)); }
f152() { fx=$((fx + 152)); }
f153() { fx=$((fx + 153)); }
f154() { fx=$((fx + 154)); }
f155() { fx=$((fx + 155)); }
f156() { fx=$((fx + 156)); }
f157() { fx=$((fx + 157)); }
f158() { fx=$((fx + 158)); }
f159() { fx=$((fx + 159)); }
f160() { fx=$((fx + 160)); }
f161() { fx=$((fx + 161)); }
f162() { fx=$((fx + 162)); }
f163() { fx=$((fx + 163)); }
f164() { fx=$((fx + 164)); }
f165() { fx=$((fx + 165)); }
f166() { fx=$((fx + 166)); }
f167() { fx=$((fx + 167)); }
f168() { fx=$((fx + 168)); }
f169() { fx=$((fx + 169)); }
f170() { fx=$((fx + 170)); }
f171() { fx=$((fx + 171)); }
f172() { fx=$((fx + 172)); }
f173() { fx=$((fx + 173)); }
f174() { fx=$((fx + 174)); }
f175() { fx=$((fx + 175)); }
f176() { fx=$((fx + 176)); }
f177() { fx=$((fx + 177)); }
f178() { fx=$((fx + 178)); }
f179() { fx=$((fx + 179)); }
f180() { fx=$((fx + 180)); }
f181() { fx=$((fx + 181)); }
f182() { fx=$((fx + 182)); }
f183() { fx=$((fx + 183)); }
f184() { fx=$((fx + 184)); }
f185() { fx=$((fx + 185)); }
f186() { fx=$((fx + 186)); }
f187() { fx=$((fx + 187)); }
f188() { fx=$((fx + 188)); }
f189() { fx=$((fx + 189)); }
f190() { fx=$((fx + 190)); }
f191() { fx=$((fx + 191)); }
f192() { fx=$((fx + 192)); }
f193() { fx=$((fx + 193)); }
f194() { fx=$((fx + 194)); }
f195() { fx=$((fx + 195)); }
f196() { fx=$((fx + 196)); }
f197() { fx=$((fx + 197)); }
f198() { fx=$((fx + 198)); }
fx=0; for ((r = 0; r < 5; r++)); do
  f0; f1; f2; f3; f4; f5; f6; f7; f8; f9; 
  f10; f11; f12; f13; f14; f15; f16; f17; f18; f19; 
  f20; f21; f22; f23; f24; f25; f26; f27; f28; f29; 
  f30; f31; f32; f33; f34; f35; f36; f37; f38; f39; 
  f40; f41; f42; f43; f44; f45; f46; f47; f48; f49; 
  f50; f51; f52; f53; f54; f55; f56; f57; f58; f59; 
  f60; f61; f62; f63; f64; f65; f66; f67; f68; f69; 
  f70; f71; f72; f73; f74; f75; f76; f77; f78; f79; 
  f80; f81; f82; f83; f84; f85; f86; f87; f88; f89; 
  f90; f91; f92; f93; f94; f95; f96; f97; f98; f99; 
  f100; f101; f102; f103; f104; f105; f106; f107; f108; f109; 
  f110; f111; f112; f113; f114; f115; f116; f117; f118; f119; 
  f120; f121; f122; f123; f124; f125; f126; f127; f128; f129; 
  f130; f131; f132; f133; f134; f135; f136; f137; f138; f139; 
  f140; f141; f142; f143; f144; f145; f146; f147; f148; f149; 
  f150; f151; f152; f153; f154; f155; f156; f157; f158; f159; 
  f160; f161; f162; f163; f164; f165; f166; f167; f168; f169; 
  f170; f171; f172; f173; f174; f175; f176; f177; f178; f179; 
  f180; f181; f182; f183; f184; f185; f186; f187; f188; f189; 
  f190; f191; f192; f193; f194; f195; f196; f197; f198; 
done; echo "functions: $fx"
cx=0; for ((r = 0; r < 150; r++)); do case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) case a in a) cx=$((cx + 1));; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac;; esac; done; echo "nested case: $cx"
g0() { g1() { g2() { g3() { g4() { g5() { g6() { g7() { g8() { g9() { g10() { g11() { g12() { g13() { g14() { g15() { g16() { g17() { g18() { g19() { g20() { g21() { g22() { g23() { g24() { g25() { g26() { g27() { g28() { g29() { g30() { g31() { g32() { g33() { g34() { g35() { g36() { g37() { g38() { g39() { g40() { g41() { g42() { g43() { g44() { g45() { g46() { g47() { g48() { g49() { g50() { g51() { g52() { g53() { g54() { g55() { g56() { g57() { g58() { g59() { g60() { g61() { g62() { g63() { g64() { g65() { g66() { g67() { g68() { g69() { g70() { g71() { g72() { g73() { g74() { g75() { g76() { g77() { g78() { g79() { g80() { g81() { g82() { g83() { g84() { g85() { g86() { g87() { g88() { g89() { g90() { g91() { g92() { g93() { g94() { g95() { g96() { g97() { g98() { g99() { g100() { g101() { g102() { g103() { g104() { g105() { g106() { g107() { g108() { g109() { g110() { g111() { g112() { g113() { g114() { g115() { g116() { g117() { g118() { g119() { g120() { g121() { g122() { g123() { g124() { g125() { g126() { g127() { g128() { g129() { g130() { g131() { g132() { g133() { g134() { g135() { g136() { g137() { g138() { g139() { g140() { g141() { g142() { g143() { g144() { g145() { g146() { g147() { g148() { g149() { g150() { g151() { g152() { g153() { g154() { g155() { g156() { g157() { g158() { g159() { g160() { g161() { g162() { g163() { g164() { g165() { g166() { g167() { g168() { g169() { g170() { g171() { g172() { g173() { g174() { g175() { g176() { g177() { g178() { g179() { g180() { g181() { g182() { g183() { g184() { g185() { g186() { g187() { g188() { g189() { g190() { g191() { g192() { g193() { g194() { g195() { g196() { g197() { g198() { echo "nested definitions: in"; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }; }
for ((k = 0; k < 199; k++)); do "g$k"; done
nx=0; for ((r = 0; r < 150; r++)); do [[ ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! a ]] && nx=$((nx + 1)); [[ ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! a ]] || nx=$((nx + 2)); done; echo "not x100: $nx"
px=0; for ((r = 0; r < 150; r++)); do [[ ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( ( a ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ) ]] && px=$((px + 1)); done; echo "parens: $px"
# generated: an 8000-alternative pattern, a 5000-part word, a 3000-element array literal,
# a 2000-arm case, 20000 statements (each past a jump range, the constants or the locals)
d=${TMPDIR:-/tmp}/s11.$$; mkdir -p "$d"
{ printf 'for ((r = 0; r < 150; r++)); do case zzz in p0'; for ((i = 1; i < 8000; i++)); do printf '|p%d' $i; done
  printf '|zz?) m=$((m + 1));; esac; done; echo "alternatives: $m"\n'; } > "$d/alt.sh"
{ printf 'for ((r = 0; r < 150; r++)); do y='; for ((i = 0; i < 5000; i++)); do printf 'a${r}'; done
  printf '; w=$((w + ${#y})); done; echo "word: $w"\n'; } > "$d/word.sh"
{ printf 'for ((r = 0; r < 150; r++)); do ar=('; for ((i = 0; i < 3000; i++)); do printf '[%d]=$r ' $i; done
  printf '); s=$((s + ${#ar[@]} + ar[2999])); done; echo "array: $s"\n'; } > "$d/arr.sh"
{ printf 'c=0; for ((i = 0; i < 300; i++)); do case $((i * 7 %% 2000)) in\n'
  for ((i = 0; i < 2000; i++)); do printf '%d) c=$((c + %d));;\n' $i $i; done; printf 'esac; done; echo "arms: $c"\n'; } > "$d/arms.sh"
{ for ((i = 0; i < 20000; i++)); do echo "t$((i % 40))=$i"; done; echo 'for ((i = 0; i < 150; i++)); do t0=$((t0 + t39)); done; echo "statements: $t0 $t39"'; } > "$d/stmts.sh"
for f in alt word arr arms stmts; do "$THIS_SH" "$d/$f.sh"; done
rm -rf "$d"
