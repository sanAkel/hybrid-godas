#!/bin/bash
# MOM6-GODAS data assimilation cycle script
set -e

# setup environemnt
if [ -z "${MOAB_SUBMITDIR}" ]; then
    exp_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
else
    exp_dir=$MOAB_SUBMITDIR
fi
source $exp_dir/config/config.freerun
cd $exp_dir


# get the date we are about to start from
# note that that forecast could have finished, but the 
# DA might not have, so pick up from the appropriate place
if [ ! -f "last_date_fcst" ]; then 
    echo "$date_start" > last_date_fcst 
fi
date_cur=$(cat last_date_fcst)


# if the user is running this from the command line, submit the job to MOAB and quit
function submitJob()
{
    echo "Submitting job to MOAB..."
    echo "  account: $moab_acct"
    echo "  nodes:   $moab_nodes"
    echo "  runtime: $moab_walltime"
    echo "  queue:   $moab_queue"    
    cd $exp_dir
    msub $exp_dir/run_freerun.sh -N MOM6_GODAS_FREERUN -E -A $moab_acct -l partition=c4,nodes=$moab_nodes,walltime=$moab_walltime -q $moab_queue -j oe -o $exp_dir/logs/dacycle_$date_cur.log -d $exp_dir
}
if [ -z "${MOAB_JOBNAME}" ]; then
    submitJob
    exit
fi


# otherwise, this is a job running under MOAB, continue with the da cycle
#------------------------------------------------------------

# run the forecast
fcst_start=$date_cur
fcst_diag_daily="${fcst_diag_daily:-0}"
fcst_diag_dir="${fcst_diag_dir:-$exp_dir/output/unprocessed/%Y%m%d}"
#fcst_otherfiles="${fcst_otherfiles:-0}"
#fcst_otherfiles_dir="${fcst_otherfiles_dir:-$exp_dir/output/unprocessed/%Y%m%d}"
fcst_leapadj="${fcst_leapadj:-1}"

# determine if leap day is an issue, if so, add a day to the forecast run
[ $(date +%d -d "$(date +%Y-02-28 -d "$fcst_start") + 1 day" ) -eq 29 ] && isleap=1 || isleap=0
if [[ $fcst_leapadj -gt 0 && $isleap -eq 1 ]]; then
  leapday=$(date +%s -d"$(date +%Y-02-29 -d "$fcst_start")")
  if [[ $(date +%s -d "$fcst_start") -le $leapday &&\
        $(date +%s -d "$fcst_start + $fcst_len day") -ge $leapday ]]; then
      fcst_len=$((fcst_len + 1))
  fi
fi


# run the forecast
# ------------------------------------------------------------
(. $root_dir/run/subscripts/run_fcst.sh)
if [ $? -gt 0 ]; then echo "ERROR running forecast."; exit 1; fi


# submit another job if we aren't done yet
date_cur=$(date "+%Y-%m-%d" -d "$date_cur + $fcst_len day")
if [ $(date +%s -d $date_cur) -le $(date +%s -d $date_end) ]; then submitJob; fi
