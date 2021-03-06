#!/bin/bash
# MOM6-GODAS data assimilation cycle script
set -e


# setup environemnt
if [ -z "${MOAB_SUBMITDIR}" ]; then
    exp_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
else
    exp_dir=$MOAB_SUBMITDIR
fi
source $exp_dir/config/config.DAcycle
cd $exp_dir


# get the date we are about to start from
# note that that forecast could have finished, but the 
# DA might not have, so pick up from the appropriate place
if [[ ! -f "last_date_fcst" ]]; then 
    echo "$date_start" > last_date_fcst 
    echo "$date_start" > last_date_da
fi
last_date_fcst=$(cat last_date_fcst)
last_date_da=$(cat last_date_da)
if [[ $(date -d $last_date_fcst +%s) -gt $(date -d $last_date_da +%s) ]]; then
    date_cur=$last_date_da
else
    date_cur=$last_date_fcst
fi
echo "Resuming experiment from $date_cur"


# if the user is running this from the command line, submit the job to MOAB and quit
function submitJob()
{
    echo "Submitting job to MOAB..."
    echo "  account: $moab_acct"
    echo "  nodes:   $moab_nodes"
    echo "  runtime: $moab_walltime"
    echo "  queue:   $moab_queue"    
    cd $exp_dir
    msub $exp_dir/run_DAcycle.sh -N MOM6_GODAS_DACYCLE -E -A $moab_acct -l partition=c4,nodes=$moab_nodes,walltime=$moab_walltime -q $moab_queue -j oe -o $exp_dir/logs/dacycle_$date_cur.log -d $exp_dir
}
if [[ -z "${MOAB_JOBNAME}" ]]; then
    submitJob
    exit
fi


# determine if leap day is an issue, if so, add a day to the forecast run
fcst_leapadj=${fcst_leapadj:-1}
[ $(date +%d -d "$(date +%Y-02-28 -d "$date_cur") + 1 day" ) -eq 29 ] && isleap=1 || isleap=0
if [[ $fcst_leapadj -gt 0 && $isleap -eq 1 ]]; then
  leapday=$(date +%s -d"$(date +%Y-02-29 -d "$date_cur")")
  if [[ $(date +%s -d "$date_cur") -le $leapday &&\
        $(date +%s -d "$date_cur + $da_interval day") -ge $leapday ]]; then
      da_interval=$((da_interval + 1))
  fi
fi


# otherwise, this is a job running under MOAB, continue with the da cycle
#------------------------------------------------------------

# run the forecast
#------------------------------------------------------------
ts=$(date +%s)
if [[ $(date +%s -d $last_date_fcst) -eq $(date +%s -d $date_cur) ]]; then
    # clear out old background fields first
    rm -f $exp_dir/bkg/*.nc

    fcst_start=$date_cur
    fcst_len=$da_interval
    fcst_diag_daily=1
    fcst_diag_pentad=1
    fcst_diag_dir=$exp_dir/bkg/
    fcst_diag_combine=1
    (. $root_dir/run/subscripts/run_fcst.sh)
    if [ $? -gt 0 ]; then echo "ERROR running forecast."; exit 1; fi

    # move the background files to the correct location
    # TODO, this should really be in one of the subscripts instead
    for f in bkg/*ocean_daily*.nc; do
	f2=$(echo $f | cut -d. -f 2 | cut -d_ -f 3-5 --output-delimiter='').nc
	mv $f bkg/$f2	
    done
    for f in bkg/*pentad*.nc; do
	f2=$(echo $f | cut -d. -f 2 | cut -d_ -f 1-2)
	d=$(date -d "$date_cur + 2 days" "+%Y%m%d")
	mkdir -p output/bkg_pent/${d:0:4}
	mv $f output/bkg_pent/${d:0:4}/$f2.$d.nc
    done
	
fi
timing_fcst=$(( $(date +%s) - $ts ))


# run the DA step
#------------------------------------------------------------
ts=$(date +%s)
t=$(($da_interval-1))
da_date_ana=$(date "+%Y%m%d" -d "$date_cur + $t day")
da_date_ob_end=$da_date_ana
da_date_ob_start=$date_cur
(. $root_dir/run/subscripts/run_da.sh)
if [ $? -gt 0 ]; then echo "ERROR running DA."; exit 1; fi
cp last_date_fcst last_date_da
timing_da=$(( $(date +%s) - $ts ))


echo ""
echo "============================================================"
echo " overall cycle timing (seconds)"
echo "============================================================"
echo " Forecast   : $timing_fcst"
echo " 3DVar      : $timing_da"
echo " "


# submit another job if we aren't done yet
date_cur=$(date "+%Y-%m-%d" -d "$date_cur + $da_interval day")
if [ $(date +%s -d $date_cur) -le $(date +%s -d $date_end) ]; then submitJob; fi

