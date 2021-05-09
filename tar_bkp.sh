#!/usr/bin/env bash
# required applications: tar, rclone and openssl
# db_hash="$(... -type f \( ! -name "access_tokens.ibd" ! -name "users.ibd" \) ...)" can be added to exclude changing tables
#
while getopts ":bexzmp:c:d:r:k:u:j:i:h" opt; do
    case $opt in
        b) opt_b="true" ;; # create backup
        e) opt_e="true" ;; # extract backup
        x) opt_x="true" ;; # crypt backup
        z) opt_z="true" ;; # decrypt backup
        m) opt_m="true" ;; # create database backup
        p) project="${OPTARG}" ;; # <name> project
        c) count_bkp="${OPTARG}" ;; # <count> backup
        d) source="${OPTARG}" ;; # <path> backup
        r) remote="${OPTARG}" ;; # <rclone remote>
        k) crypt_pass="${OPTARG}" ;; # <pass> for crypt or decrypt backup
        u) db_user="${OPTARG}" ;; # <user> dbuser
        j) db_pass="${OPTARG}" ;; # <pass> dbpass
        i) db_name="${OPTARG}" ;; # <name> dbname
        h) echo -e "\nUsage:\n tar_bkp.sh -e -p box or -ez -k pass\n tar_bkp.sh -b -p box -c 5 -d /path/directory/ -r g-disk or -bx -k pass\n\nOptions:\n "-b", create backup\n "-e", extract backup\n "-x", encrypt backup\n "-z", decrypt backup\n "-m", create database backup\n "-p", <argument> project name\n "-c", <argument> count backup\n "-d", <argument> source dir to backup\n "-r", <argument> remote rclone cloud or dir\n "-k", <argument> pass for crypt or decrypt backup\n "-u", <argument> dbuser\n "-j", <argument> dbpass\n "-i", <argument> dbname\n "-h", display this help\n" ;;
        \?) echo " - Invalid option: -${OPTARG}." ; exit 1 ;;
        :) echo " - Option -${OPTARG} requires an argument." ; exit 2 ;;
    esac
done
shift $(($OPTIND - 1))
# - #
script_dir="$(dirname "$(readlink -f "$0")")"
dest="${script_dir}/backup/$project"
exclude="${script_dir}/exclude.conf"
drive_dir="${remote}:${project}"
curdate="$(date +%d-%m-%Y)"
# - #

# Setting the logger utility function;
function logger() {
    while [ -z "$project" ]; do echo " - [@logger] Error, requared option "-p"" ; exit 1 ; done
    if [ ! -e "${dest}" ]; then mkdir -p "${dest}" ; fi
    find "${dest}"/../ -maxdepth 1 -name "*.log" -size +10k -exec rm -f {} \;
    echo -e "["`date "+%H:%M:%S"`"]: $1" >> "${dest}"/../"${project}.log"
}

# Cleaning old backups;
remove_bkp () {
    while [ -z "$count_bkp" ]; do echo " - [@remove_bkp] Error, requared option "-c"" ; exit 1 ; done
    cur_bkp="$(find "${dest}" -name "*.tar.gz*" 2> /dev/null | wc -l)"
    local size_bkp="$(du -sh "${dest}" | awk '{print $1}')"
    if [ "$cur_bkp" -ge "$count_bkp" ]; then
        rm -f "${dest}"/*.tar.gz* "${dest}"/../"${project}".snar
        if [ "$?" = "0" ] ; then logger "[+] [@remove_bkp] Очищено старых резервных копий [$cur_bkp/$count_bkp/$size_bkp]." ; fi
    else
        logger "[-] [@remove_bkp] Не обнаружено резервных копий требующих очистки [$cur_bkp/$count_bkp/$size_bkp]."
    fi
}

# Creating database backup;
create_db_bkp () {
    while [ "$opt_m" = "true" ]; do
        while [[ -z "$db_user" || -z "$db_pass" || -z "$db_name" ]]; do echo " - [@create_db_bkp] Error, requared option's "-u, -j, -i"" ; exit 1 ; done
        cd "${source}" || exit 1
        db_bkp="db_bkp" ; if [ ! -e "$db_bkp" ]; then mkdir -p "$db_bkp" ; chmod u=rw,go= "$db_bkp" ; fi
        db_hash="$(find /var/lib/mysql/"${db_name}"/ -type f -print0 | xargs -0 sha1sum | cut -b-40 | sort | sha1sum | awk '{print $1}')"
        bkp_hash="$(cat "${db_bkp}"/"${project}"-*.sql.gz.sha1 2> /dev/null)"
        if [ "$db_hash" != "$bkp_hash" ]; then
            local name_bkp="${project}-${curdate}.sql.gz.sha1"
            rm -f "${db_bkp}"/"${project}"-*.sql.gz*
            mysqldump -u "${db_user}" -p"${db_pass}" "${db_name}" | gzip > "${db_bkp}"/"${name_bkp::-5}" || exit 1 ; status_cdb="$?"
            echo "$db_hash" > "${db_bkp}"/"${name_bkp}"
            local size_bkp="$(du -sh "${db_bkp}"/"${name_bkp::-5}" | awk '{print $1}')"
            if [ "$status_cdb" = "0" ] ; then logger "[+] [@create_db_bkp] Резервная копия (${name_bkp::-5}) создана [$size_bkp]." ; fi
            break
        else
            local name_bkp="$(find "${db_bkp}"/ -maxdepth 1 -name "${project}"-*.sql.gz | sed 's,'${db_bkp}'/,,')"
            local size_bkp="$(du -sh "${db_bkp}"/"${project}"-*.sql.gz | awk '{print $1}')"
            logger "[-] [@create_db_bkp] В резервной копии (${name_bkp}) изменений не обнаружено [$size_bkp]."
            break
        fi
    done
}

# Creating incremental backup;
create_bkp () {
    while [ -z "$source" ]; do echo " - [@create_bkp] Error, requared option "-d"" ; exit 1 ; done
    if [ ! -f "$exclude" ]; then touch "$exclude" ; fi
    if [ ! -e "${dest}" ]; then mkdir -p "${dest}" ; fi
    cd "${source}" || exit 1
    if [ "$opt_x" = "true" ]; then
        while [ -z "$crypt_pass" ]; do echo " - [@create_bkp] Error, requared option "-k"" ; exit 1 ; done
        local name_bkp="${project}-${curdate}.tar.gz.crypt"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" ./ | openssl enc -e -aes-256-cbc -salt -pbkdf2 -k "${crypt_pass}" -out "${dest}"/"${name_bkp}" ; status_cb="$?"
    else
        local name_bkp="${project}-${curdate}.tar.gz"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" -f "${dest}"/"${name_bkp}" ./ ; status_cb="$?"
    fi
    local size_bkp="$(du -sh "${dest}"/"${name_bkp}" | awk '{print $1}')"
    if [ "$status_cb" = "0" ] ; then logger "[+] [@create_bkp] Резервная копия (${name_bkp}) создана [$size_bkp]." ; fi
}

# Sync backup witch remote storage;
sync_bkp () {
    while [ -z "$remote" ]; do echo " - [@sync_bkp] Error, requared option "-r"" ; exit 1 ; done
    else_err_sb="$(rclone sync -q "${dest}" "$drive_dir"/ 2>&1)"
    if [ "$?" = "0" ]; then
        logger "[+] [@sync_bkp] Синхронизация с хранилищем ($drive_dir) выполнена."
    else
        logger "[-] [@sync_bkp] Ошибка - ${else_err_sb}.\n"
        exit 1
    fi
}

# Extract incremental backup;
extract_bkp () {
    while [ -z "$project" ]; do echo " - [@extract_bkp] Error, requared option "-p"" ; exit 1 ; done
    local extract="./extract/${project}"
    if [ ! -e "${extract}" ]; then mkdir -p "${extract}" ; fi
    local bkps="$(ls -1 "${dest}" | sort -t'-' -k3,4 -n)" # by time "ls -txr ${dest}"
    if [ "$opt_z" = "true" ]; then
        while [ -z "$crypt_pass" ]; do echo " - [@extract_bkp] Error, requared option "-k"" ; exit 1 ; done
        for bkp in $bkps; do
            openssl enc -d -aes-256-cbc -pbkdf2 -k "${crypt_pass}" -in "${dest}"/"$bkp" | tar -xpz -g /dev/null -C "${extract}" --numeric-owner
            if [ "$?" = "0" ] ; then logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена." ; fi
        done
    else
        for bkp in $bkps; do
            tar -xpz -g /dev/null -f "${dest}"/"$bkp" -C "${extract}" --numeric-owner
            if [ "$?" = "0" ] ; then logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена." ; fi
        done
    fi
}

# Check options -b and -e;
if [ "$opt_b" = "true" ]; then
    state_bkp="Create-Backup"
    logger "--- $curdate - START $state_bkp: ${project} ---"
    remove_bkp && create_db_bkp && create_bkp && sync_bkp
elif [ "$opt_e" = "true" ]; then
    state_bkp="Extract-Backup"
    logger "--- $curdate - START $state_bkp: ${project} ---"
    extract_bkp
else
    exit 1
fi

logger "--- $curdate - END $state_bkp: ${project} ---\n"
