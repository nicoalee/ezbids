#!/bin/bash

set -e
set -x

export SHELL=$(type -p bash)

# We want to keep track of whether or not dcm2niix has run, with the addition of PET2BIDs 
# dcm2niix may not be triggered to run at all if only PET images (dicoms/ecat) are uploaded

DCM2NIIX_RUN=false
PET2BIDS_RUN=false

if [ -z $1 ]; then
    echo "please specify root dir"
    exit 1
fi

root=$1
echo "running preprocess.sh on root folder ${root}"

echo "running expand.sh"
./expand.sh $root

echo "replace file path that contains space"
# find $root -depth -name "* *" -execdir rename 's/ /_/g' "{}" \;
find $root -depth -name "*[ ()]*" -execdir rename 's/[ )]/_/g; s/\(//g' "{}" \;

# check to see if uploaded data is a BIDS-compliant dataset
echo "Running bids-validator to check BIDS compliance"

# Check the ezBIDS uploaded directory to see if it's a BIDS-compliant root directory or contains one
# Search a few levels down in case a sub-directory is actually the BIDS root (could happen based on how user stored their data)
substring="dataset_description.json"
maxdepth=1

test_root=($(find $root -maxdepth $maxdepth -type f \( -name $substring \)))

bids="no"

until [[ $maxdepth -gt 5 ]] # go five levels in to check for existence of BIDS-compliant data
do
    if [[ "$test_root" == *"$substring"* ]]; then
        bids="yes"
        break
    else
        ((maxdepth++))
        test_root=($(find $root -maxdepth $maxdepth -type f \( -name $substring \)))
    fi
done

if [[ $bids == "yes" ]]; then
    test_root=${test_root///$substring/}
else
    test_root=$root
fi

if [ -f $test_root/.bidsignore]; then
    touch $test_root/.bidsignore
    echo "*finalized.json" > $test_root/.bidsignore
else
    echo "*finalized.json" >> $test_root/.bidsignore
fi
echo "*template.json" >> $test_root/.bidsignore

echo "*dcm2niix*" >> $test_root/.bidsignore
echo "*preprocess*" >> $test_root/.bidsignore
echo "*pet2bids*" >> $test_root/.bidsignore
echo "*list" >> $test_root/.bidsignore
echo "*nii_files" >> $test_root/.bidsignore
echo "*ezBIDS_core.json" >> $test_root/.bidsignore
echo "*bids_compliant.log" >> $test_root/.bidsignore
echo "*validator.log" >> $test_root/.bidsignore
echo "*.png" >> $test_root/.bidsignore

bids-validator $test_root > $test_root/validator.log || true

if grep -w "ERR" $test_root/validator.log; then
	echo "Uploaded data is not a BIDS-compliant dataset"
    bids_compliant="false"
else
    echo "Uploaded data is a BIDS-compliant dataset"
	bids_compliant="true"
fi

echo $test_root > $root/bids_compliant.log
echo $bids_compliant >> $root/bids_compliant.log

cat $root/bids_compliant.log

if [ $bids_compliant == "true" ]; then
    # Skip certain processing steps, since uploaded data is already BIDS-compliant

    touch $root/dcm2niix_output
    touch $root/dcm2niix_error
    
    #find products
    (cd $root && find . -maxdepth 9 -type f \( -name "*.json" \) > list)

    # remove irrelevant json files (e.g., ezBIDS_core.json, etc) if found
    grep -F -v ezBIDS_core.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list
    # grep -F -v dataset_description.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list
    # grep -F -v participants.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list

    echo "running ezBIDS_core (may take several minutes, depending on size of data)"
    python3 "./ezBIDS_core/ezBIDS_core.py" $root
else

    # If there are .nii files, compress them to .nii.gz
    echo "Making sure all NIfTI files are in .nii.gz format"
    touch $root/nii_files
    find $root -name "*.nii" > $root/nii_files
    [ -s $root/nii_files ] && gzip --force $(cat $root/nii_files)

    echo "processing $root"

    echo "finding dicom directories"
    ./find_dicomdir.py $root > $root/dcm2niix.list
    cat $root/dcm2niix.list

    # There can be overlap between the dicom directories and the pet directories
    # we want to use dcm2niix4pet for the pet directories, and dcm2niix for the dicom directories

    function rundcm2niix4pet {
        #note.. this function runs inside $root (by --wd $root)

        path=$1

        echo "----------------------- $path ------------------------"
        timeout 3600 dcm2niix4pet --silent $path

        #all good
        echo $path >> pet2bids.done
        PET2BIDS_RUN=true
    } 

    export -f rundcm2niix4pet

    # determine which uploaded files/folders are PET directories accept return
    # code value of 1 (no PET directories found) or 0 (PET directories found)
    
    (./find_petdir.py $root > $root/pet2bids.list || touch $root/pet2bids.list)

    # sort $root/pet2bids.list and $root/dcm2niix.list for comm
    sort -o $root/pet2bids.list $root/pet2bids.list
    sort -o $root/dcm2niix.list $root/dcm2niix.list

    cat $root/pet2bids.list
    # remove pet directories from dcm2niix list
    echo "Removing PET directories from dcm2niix list"
    comm -12  ${root}/dcm2niix.list ${root}/pet2bids.list > ${root}/remove_from_dcm2niix_list.list
    for folder in $(cat ${root}/remove_from_dcm2niix_list.list); do
        # use sed to remove any lines that contain the folder name while escaping special characters (slashes and dots mostly)
        sed -i "/${folder//\//\\/}/d" ${root}/dcm2niix.list > ${root}/tmpfile && mv ${root}/tmpfile ${root}/dcm2niix.list
    done
    [ -e ${root}/remove_from_dcm2niix_list.list ] && rm ${root}/remove_from_dcm2niix_list.list
    [ -e ${root}/tmpfile ] && rm ${root}/tmpfile

    # run pet2bids
    true > $root/pet2bids.done

    cat $root/pet2bids.list | parallel --linebuffer --wd $root -j 6 rundcm2niix4pet {} 2>> $root/pet2bids_output


    echo "running dcm2niix"
    echo `dcm2niix --version`
    true > $root/dcm2niix.done
    function d2n {
        #note.. this function runs inside $root (by --wd $root)

        #set -e #we can't set this here because dcm2niix could return code:2
        #which just means there are no DICOM files in that directory
        set -x

        path=$1

        # if path is empty then do nothing
        if [ -z "$path" ]; then
            echo "No path ${path} provided to d2n, skipping"
        else 
            echo "----------------------- $path ------------------------"
            timeout 3600 dcm2niix --progress y -v 1 -ba n -z o -d 9 -f 'time-%t-sn-%s' $path

            #all good
            echo $path >> dcm2niix.done
            DCM2NIIX_RUN=true
        fi
    }

    export -f d2n

    cat $root/dcm2niix.list | parallel --linebuffer --wd $root -j 6 d2n {} 2>> $root/dcm2niix_output

    #find products
    echo "searching for products in $root"
    (cd $root && find . -maxdepth 9 -type f \( -name "*.json" \) > list)

    # remove irrelevant json files (e.g., ezBIDS_core.json, etc) if found
    grep -F -v *ezBIDS_core*.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list
    # grep -F -v dataset_description.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list
    # grep -F -v participants.json $root/list > $root/list_tmp && mv $root/list_tmp $root/list

    if [ ! -s $root/list ]; then
        echo "Could not find any MRI (or PET) DICOM files in upload. Uploaded files likely do not conform to DICOM format, aborting"
        exit 1
    fi

    if [[ $DCM2NIIX_RUN -eq "true" ]]; then
        # pull dcm2niix error information to log file
        { grep -B 1 --group-separator=$'\n\n' Error $root/dcm2niix_output || true; } > $root/dcm2niix_error
        # # remove error message(s) about not finding any DICOMs in folder
        line_nums=$(grep -n 'Error: Unable to find any DICOM images' $root/dcm2niix_error | cut -d: -f1)

        for line_num in ${line_nums[*]}
        do
            sed -i "$((line_num-1)), $((line_num+1))d" $root/dcm2niix_error
        done
    fi

    echo "running ezBIDS_core (may take several minutes, depending on size of data)"
    python3 "./ezBIDS_core/ezBIDS_core.py" $root


    echo "generating thumbnails for 3/4D acquisitions (may take several minutes, depending on size of dataset)"
    cat $root/list | parallel --linebuffer -j 6 --progress python3 "./ezBIDS_core/createThumbnailsMovies.py" $root

    echo "updating ezBIDS_core.json"
    python3 "./ezBIDS_core/update_ezBIDS_core.py" $root

fi

echo "done preprocessing"