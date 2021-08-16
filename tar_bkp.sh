#!/usr/bin/env bash
# required applications: tar, rclone and openssl
# can be added to exclude changing db tables: db_hash="$(... -type f \( ! -name "access_tokens.ibd" ! -name "users.ibd" \) ...)"
#
while getopts ":bexwqzfgmp:c:d:r:k:a:u:j:i:h" opt; do
    case $opt in
        b) opt_b="true" ;; # create backup
        e) opt_e="true" ;; # extract backup
        x) opt_x="true" ;; # [opt_b] + encrypt
        w) opt_w="true" ;; # [opt_b] + encrypt + split
        q) opt_q="true" ;; # [opt_b] + split
        z) opt_z="true" ;; # [opt_e] + decrypt
        f) opt_f="true" ;; # [opt_e] + decrypt + split
        g) opt_g="true" ;; # [opt_e] + split
        m) opt_m="true" ;; # create database backup
        p) project="${OPTARG}" ;; # <name> project
        c) count_bkp="${OPTARG}" ;; # <count> backup
        d) source="${OPTARG}" ;; # <path> backup
        r) remote="${OPTARG}" ;; # <rclone remote> cloud
        k) crypt_pass="${OPTARG}" ;; # <pass> for crypt or decrypt backup
        a) split_bytes="${OPTARG}" ;; # <bytes>K,M,G for split backup
        u) db_user="${OPTARG}" ;; # <user> dbuser
        j) db_pass="${OPTARG}" ;; # <pass> dbpass
        i) db_name="${OPTARG}" ;; # <name> dbname
        h) echo -e "\nUsage:\n tar_bkp.sh -e -p box or -ez -k pass\n tar_bkp.sh -b -p box -c 5 -d /path/directory/ -r g-disk or -bx -k pass\n\nOptions:\n "-b", create backup\n "-e", extract backup\n "-x", [opt_b] + encrypt\n "-w", [opt_b] + encrypt + split\n "-q", [opt_b] + split\n "-z", [opt_e] + decrypt\n "-f", [opt_e] + decrypt + split\n "-g", [opt_e] + split\n "-m", create database backup\n "-p", <name> project\n "-c", <count> backup\n "-d", <path> backup\n "-r", <rclone remote> cloud or dir\n "-k", <pass> for crypt or decrypt backup\n "-a", <bytes> K,M,G for split backup\n "-u", <user> dbuser\n "-j", <pass> dbpass\n "-i", <name> dbname\n "-h", display this help\n" ;;
        \?) echo " - Invalid option: -${OPTARG}." ; exit 1 ;;
        :) echo " - Option -${OPTARG} requires an argument." ; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
# - #
script_dir="$(dirname "$(readlink -f "$0")")"
dest="${script_dir}/backup/$project"
exclude="${script_dir}/exclude.conf"
drive_dir="${remote}:${project}"
curdate="$(date +%d-%m-%Y-%H-%M-%S)"
# - #

# Setting the logger utility function;
function logger() {
    while [ -z "$project" ]; do echo " - [@logger] Error, requared option "-p"" ; exit 1 ; done
    if [ ! -e "${dest}" ]; then mkdir -p "${dest}" ; fi
    find "${dest}"/../ -maxdepth 1 -name "*.log" -size +10k -exec rm -f {} \;
    echo -e "[$(date "+%H:%M:%S")]: $1" >> "${dest}"/../"${project}.log"
}

# Cleaning old backups;
remove_bkp () {
    while [ -z "$count_bkp" ]; do echo " - [@remove_bkp] Error, requared option "-c"" ; exit 1 ; done
    cur_bkp="$(find "${dest}" -name "*.tar.gz*" 2> /dev/null | wc -l)"
    local size_bkp="$(du -sh "${dest}" | awk '{print $1}')"
    if [ "$cur_bkp" -ge "$count_bkp" ]; then
        if rm -f "${dest}"/*.tar.gz* "${dest}"/../"${project}".snar; then
            logger "[+] [@remove_bkp] Очищено старых резервных копий [$cur_bkp/$count_bkp/$size_bkp]."
        fi
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
        db_hash="$(find /var/lib/mysql/"${db_name}"/*.ibd -type f \( ! -name "access_tokens.ibd" ! -name "users.ibd" \) -print0 | xargs -0 sha1sum | cut -b-40 | sort | sha1sum | awk '{print $1}')"
        bkp_hash="$(cat "${db_bkp}"/"${project}"-*.sql.gz.sha1 2> /dev/null)"
        if [ "$db_hash" != "$bkp_hash" ]; then
            local name_bkp="${project}-${curdate}.sql.gz.sha1"
            rm -f "${db_bkp}"/"${project}"-*.sql.gz*
            mysqldump -u "${db_user}" -p"${db_pass}" "${db_name}" | gzip > "${db_bkp}"/"${name_bkp::-5}" || exit 1 ; status_cdb="$?"
            echo "$db_hash" > "${db_bkp}"/"${name_bkp}"
            local size_bkp="$(du -sh "${db_bkp}"/"${name_bkp::-5}" | awk '{print $1}')"
            if [ "$status_cdb" = "0" ]; then logger "[+] [@create_db_bkp] Резервная копия (${name_bkp::-5}) создана [$size_bkp]." ; fi
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
    # encrypt;
    if [ "$opt_x" = "true" ]; then
        while [ -z "$crypt_pass" ]; do echo " - [@create_bkp] Error, requared option "-k"" ; exit 1 ; done
        local name_bkp="${project}-${curdate}.tar.gz.crypt"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" ./ | openssl enc -e -aes-256-cbc -salt -pbkdf2 -k "${crypt_pass}" -out "${dest}"/"${name_bkp}" ; status_cb="$?"
    # encrypt + split;
    elif [ "$opt_w" = "true" ]; then
        while [[ -z "$crypt_pass" || -z "$split_bytes" ]]; do echo " - [@create_bkp] Error, requared option's "-k, -a"" ; exit 1 ; done
        local split_bkp="true"
        local name_bkp="${project}-${curdate}.tar.gz.crypt"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" ./ | openssl enc -e -aes-256-cbc -salt -pbkdf2 -k "${crypt_pass}" | split -d -b "$split_bytes" - "${dest}"/"${name_bkp}" ; status_cb="$?"
    # split;
    elif [ "$opt_q" = "true" ]; then
        while [ -z "$split_bytes" ]; do echo " - [@create_bkp] Error, requared option "-a"" ; exit 1 ; done
        local split_bkp="true"
        local name_bkp="${project}-${curdate}.tar.gz"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" ./ | split -d -b "$split_bytes" - "${dest}"/"${name_bkp}" ; status_cb="$?"
    # normal;
    else
        local name_bkp="${project}-${curdate}.tar.gz"
        tar -cpz -g "${dest}"/../"${project}".snar -X "$exclude" -f "${dest}"/"${name_bkp}" ./ ; status_cb="$?"
    fi
    if [ "$status_cb" = "0" ]; then
        if [ "$split_bkp" = "true" ]; then
            local size_bkp="$(du -ch "${dest}"/"${name_bkp}"* | tail -1 | cut -f 1)"
            logger "[+] [@create_bkp] Резервная копия (${name_bkp}.split[$split_bytes]) создана [$size_bkp]."
        else
            local size_bkp="$(du -sh "${dest}"/"${name_bkp}" | awk '{print $1}')"
            logger "[+] [@create_bkp] Резервная копия (${name_bkp}) создана [$size_bkp]."
        fi
    fi
}

# Sync backup witch remote storage;
sync_bkp () {
    while [ -z "$remote" ]; do echo " - [@sync_bkp] Error, requared option "-r"" ; exit 1 ; done
    if else_err_sb="$(rclone sync -q "${dest}" "$drive_dir"/ 2>&1)"; then
        logger "[+] [@sync_bkp] Синхронизация с хранилищем ($drive_dir) выполнена."
    else
        logger "[!] [@sync_bkp] Ошибка - ${else_err_sb}.\n"
        exit 1
    fi
}

# Extract incremental backup;
extract_bkp () {
    while [ -z "$project" ]; do echo " - [@extract_bkp] Error, requared option "-p"" ; exit 1 ; done
    local extract="./extract/${project}"
    if [ ! -e "${extract}" ]; then mkdir -p "${extract}" ; fi
    local bkps="$(ls -1 "${dest}" | sort -t'-' -k4 -k3 -k2 -k5 -k6 -k7)" # by time "$(ls -txr ${dest})" ; old "$(ls -1 "${dest}" | sort -t'-' -k3,4 -n)"
    # decrypt;
    if [ "$opt_z" = "true" ]; then
        while [ -z "$crypt_pass" ]; do echo " - [@extract_bkp] Error, requared option "-k"" ; exit 1 ; done
        for bkp in $bkps; do
            if else_err_eb="$(openssl enc -d -aes-256-cbc -pbkdf2 -k "${crypt_pass}" -in "${dest}"/"$bkp" | tar -xpz -g /dev/null -C "${extract}" --numeric-owner 2>&1)"; then
                logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена."
            else
                logger "[!] [@extract_bkp] Ошибка - ($bkp) ${else_err_eb}."
            fi
        done
    # decrypt + split;
    elif [ "$opt_f" = "true" ]; then
        while [ -z "$crypt_pass" ]; do echo " - [@extract_bkp] Error, requared option "-k"" ; exit 1 ; done
        for bkp in $(find "${dest}" -type f -name "*.tar.gz.crypt00" | sort -t'-' -k4 -k3 -k2 -k5 -k6 -k7); do
            if else_err_eb="$(cat ${bkp::-2}* | openssl enc -d -aes-256-cbc -pbkdf2 -k "${crypt_pass}" | tar -xpz -g /dev/null -C "${extract}" --numeric-owner 2>&1)"; then
                logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена."
            else
                logger "[!] [@extract_bkp] Ошибка - ($bkp) ${else_err_eb}."
            fi
        done
    # split;
    elif [ "$opt_g" = "true" ]; then
        for bkp in $(find "${dest}" -type f -name "*.tar.gz00" | sort -t'-' -k4 -k3 -k2 -k5 -k6 -k7); do
            if else_err_eb="$(cat ${bkp::-2}* | tar -xpz -g /dev/null -C "${extract}" --numeric-owner 2>&1)"; then
                logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена."
            else
                logger "[!] [@extract_bkp] Ошибка - ($bkp) ${else_err_eb}."
            fi
        done
    # normal;
    else
        for bkp in $bkps; do
            if else_err_eb="$(tar -xpz -g /dev/null -f "${dest}"/"$bkp" -C "${extract}" --numeric-owner 2>&1)"; then
                logger "[+] [@extract_bkp] Распаковка ($bkp) выполнена."
            else
                logger "[!] [@extract_bkp] Ошибка - ($bkp) ${else_err_eb}."
            fi
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
