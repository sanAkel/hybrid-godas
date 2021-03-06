#!/bin/bash
set -e
shopt -s nullglob

echo "running on $(hostname)"

# Hybrid-GODAS data assimilation step scripts

timing_start=$(date +%s)

#================================================================================
#================================================================================
# Set the required environment variables, along with any default values.
# Any variable that doesn't have a default value will be checked by this script
# to make sure it has been defined
v=""

v="$V PBS_NP"      # number of processors given by job scheduler
v="$v PBS_NUM_PPN" # number of cores per node
v="$v da_nproc"    # number of processors we actually want to use
v="$v da_threads"  # number of thread to use for the non-mpi openmp jobs
v="$v da_skip"     # If = 1, skip the 3DVar code (but still do obsop for O-F stats)

# directory paths
#------------------------------
v="$v root_dir"    # Path to the top level directory for the hybrid-godas code.
v="$v work_dir"    # A temporary working directory to use when running the forecast
                   # the location needs to be accessible from all computational nodes.
v="$v exp_dir"     # Top level directory of the experiment


# Dates (all dates in YYYYMMDD format)
#------------------------------
v="$v da_date_ana"       # The date on which the analysis is centered.
v="$v da_date_ob_start"  # The start date of observation window
v="$v da_date_ob_end"    # The end date of observation window


# Observation types
#------------------------------
v="$v da_sst_use"     # If = 1, use SST observations
v="$v da_sst_dir"     # Directory to AVHRR SST observation

v="$v da_prof_use"    # If = 1, use profile observations
v="$v da_prof_dir"    # Directory to T/S profile observations
v="$v da_prof_legacy" # If = 1 , use "dave's obs" from legacy GODAS

da_prof_legacy=${da_prof_legacy:-0}

#------------------------------

envvars="$v"


#================================================================================
#================================================================================

echo ""
echo "============================================================"
echo "   Running Data assimilation"
echo "============================================================"


# check the required environment variables
for v in ${envvars}; do
    if [ -z "${!v}" ]; then echo "ERROR: env var $v not set."; exit 1; fi
    echo "  $v = ${!v}"
done
echo ""

# setup the environment
. $root_dir/config/env

# setup the working directory
work_dir=$work_dir/3dvar
rm -rf $work_dir
mkdir -p $work_dir
cd $work_dir
ln -s $root_dir/build/* .
cp $exp_dir/config/3dvar/* .

mkdir INPUT
cd INPUT
ln -s $root_dir/DATA/grid/ocean_geometry.nc grid.nc
ln -s $root_dir/DATA/grid/Vertical_coordinate.nc vgrid.nc
ln -s $root_dir/DATA/grid/coast_dist.nc .
ln -s $exp_dir/bkg/${da_date_ana}.nc bkg.nc
cd ..

# make sure that unless otherwise specified, all programs are single threaded
export OMP_NUM_THREADS=1

#------------------------------------------------------------
#------------------------------------------------------------
echo ""
echo "============================================================"
echo "Vertical Localization distance"
echo ""
ts=$(date +%s)
OMP_NUM_THREADS=$PBS_NUM_PPN aprun -cc depth -n 1 -d $PBS_NUM_PPN time  ./vtloc
timing_vtloc=$(( $(date +%s) - $ts ))



#------------------------------------------------------------
#------------------------------------------------------------
echo ""
echo "============================================================"
echo "background variance"
echo ""
ts=$(date +%s)
OMP_NUM_THREADS=$PBS_NUM_PPN aprun -cc depth -n 1 -d $PBS_NUM_PPN time ./bgvar
timing_bgvar=$(( $(date +%s) - $ts ))



#------------------------------------------------------------
# Observation prep
#------------------------------------------------------------
echo ""
echo "============================================================"
echo "Observation processing"
echo ""
echo "Preparing Observations (SST/insitu)"



#run the obs prep programs
#------------------------------------------------------------
ts=$(date +%s)
fdate=$da_date_ob_end
while [ $(date -d $fdate +%s) -ge $(date -d $da_date_ob_start +%s) ]
do
    # make directory
    d=$work_dir/obsop_$fdate
    mkdir -p $d
    cd $d
    export fdate

    # link required files    
    ln -s ../INPUT .
    ln -sf $exp_dir/bkg/$fdate.nc obsop_bkg.nc
    ln -s $root_dir/build/gsw_data_v3_0.nc .
    ln -s ../obsprep.nml .

    # conventional obs
    obfile=$da_prof_dir/$(date "+%Y/%Y%m%d" -d $fdate)
    if [[ ("$da_prof_use" -eq 1) && (-f $obfile.T.nc || -f $obfile.S.nc) ]]; then
	if [[ "$da_prof_legacy" -eq 1 ]]; then
	    # are we using the legacy GODAS profiles, or new ones
	    obsprep_exec=obsprep_insitu_legacy
	else
	    obsprep_exec=obsprep_insitu
	fi
	echo "  obsprep_insitu $fdate"	
	aprun -n 1 time ../$obsprep_exec $obfile obsprep.insitu.nc > obsprep_insitu.log &
    fi    

    # SST obs
    obfile=$da_sst_dir/$(date "+%Y/%Y%m/%Y%m%d" -d $fdate).nc    
    if [[ ("$da_sst_use" -eq 1) &&  (-f $obfile) ]]; then
	echo "  obsprep_sst    $fdate"
#    	aprun -n 1 ../obsprep_sst > obsprep_sst.log &
	ln -s $obfile obsprep.sst.nc
    fi

    fdate=$(date "+%Y%m%d" -d "$fdate - 1 day")    
done
echo "Waiting for completetion..."
wait

cd $work_dir
for f in obsop_????????/obsprep*.log; do cat $f; done 

timing_obsprep=$(( $(date +%s) - $ts ))


# Obseration operators
#------------------------------------------------------------
ts=$(date +%s)
echo ""
echo "============================================================"
echo "Daily observation operator"
fdate=$da_date_ob_end
while [ $(date -d $fdate +%s) -ge $(date -d $da_date_ob_start +%s) ]
do
    d=$work_dir/obsop_$fdate
    d2=$(date -d "$fdate" "+%Y,%m,%d,0,0,0")
    cd $d
    echo "  concatenating $fdate..."
    aprun -n 1 time ../obsprep_combine -basedate $d2  obsprep.*.nc obsprep.nc > obsprep_combine.log &
    fdate=$(date "+%Y%m%d" -d "$fdate - 1 day")    
done
wait

fdate=$da_date_ob_end
while [ $(date -d $fdate +%s) -ge $(date -d $da_date_ob_start +%s) ]
do
    d=$work_dir/obsop_$fdate
    cd $d
    echo "  obsop for $fdate..."
    aprun -n 1 time ../obsop obsprep.nc obsop.nc > obsop.log &
    fdate=$(date "+%Y%m%d" -d "$fdate - 1 day")    
done
echo "waiting for completion..."
wait
cd $work_dir
cat obsop_????????/obsop.log
timing_obsop=$(( $(date +%s) - $ts ))


# combine all obs
ts=$(date +%s)
cd $work_dir
echo ""
echo "============================================================"
echo "Combining all obs into single file..."
d2=$(date -d "$da_date_ana" "+%Y,%m,%d,12,0,0")
aprun -n 1 time ./obsprep_combine -basedate $d2 obsop_????????/obsop.nc INPUT/obs.nc
timing_obscmb=$(( $(date +%s) - $ts ))


#------------------------------------------------------------
# 3dvar
#------------------------------------------------------------
if [ $da_skip -eq 0 ]; then
    ts=$(date +%s)
    echo ""
    echo "============================================================"
    echo "Running 3DVar..."
    echo "============================================================"
    aprun -n $da_nproc time ./3dvar
    timing_3dvar=$(( $(date +%s) - $ts ))

     # update the restart
     ts=$(date +%s)
     echo ""
     echo "Updating the restart files..."
     ln -s $exp_dir/RESTART .
     aprun -n $PBS_NUM_PPN ./update_restart
     timing_restart=$(( $(date +%s) - $ts ))

     ts=$(date +%s)
     # move da output
     echo "Moving AI file..."
     d=$exp_dir/output/ana_inc/$date_dir/${da_date_ana:0:4}
     mkdir -p $d
     mv ana_inc.nc $d/${da_date_ana}.nc

     d=$exp_dir/diag/misc/$date_dir/${da_date_ana:0:4}
     mkdir -p $d
     mv ana_diag.nc $d/${da_date_ana}.nc
    
     # vtloc file
     d=$exp_dir/diag/vtloc/$date_dir/${da_date_ana:0:4}
     mkdir -p $d
     mv vtloc.nc $d/${da_date_ana}.nc

     #bgvar file
     d=$exp_dir/diag/bgvar/$date_dir/${da_date_ana:0:4}
     mkdir -p $d
     mv bgvar.nc $d/${da_date_ana}.nc

     # # background files
     # d=$exp_dir/output/bkg_inst/$date_dir/${da_date_ana:0:4}
     # mkdir -p $d
     # mv $exp_dir/bkg/${da_date_ana}.nc $d/${da_date_ana}.nc

#     # # delete background files    
#     # echo "Deleting background..."
#     # rm $exp_dir/bkg/* 

     timing_mvfiles=$(( $(date +%s) - $ts ))
fi




# #------------------------------------------------------------
# # post processing
# #------------------------------------------------------------

# O-B
echo ""
echo "Creating observation space statistics..."
date_dir=${da_date_ana:0:4}
d=$exp_dir/output/bkg_omf/$date_dir
mkdir -p $d
mv $work_dir/INPUT/obs.nc  $d/${da_date_ana}.nc
mv $work_dir/obs.varqc.nc  $d/${da_date_ana}.varqc.nc


# clean up
rm -rf $work_dir

timing_final=$(( $(date +%s) - $timing_start ))



#Print out timing statistics summary
echo ""
echo "============================================================"
echo "Data assimilation Timing (seconds)"
echo "============================================================"
echo " vertical localization distance (vtloc): $timing_vtloc"
echo " Background error variance (bgvar)     : $timing_bgvar"
echo " observation preparation (obsprep)     : $timing_obsprep"
echo " observation operator (obsop)          : $timing_obsop"
echo " observation file combination          : $timing_obscmb"
echo " 3dvar solver (3dvar)                  : $timing_3dvar"
echo " update restart file                   : $timing_restart"
echo " move output files                     : $timing_mvfiles"
echo "                               Total   : $timing_final"
