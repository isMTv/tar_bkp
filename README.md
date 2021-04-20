## Overview:
* Simmple tar incremental backup script for linux server's using rclone. It is possible to backup MySQL database.
* Before the backup database, the script will check the hash-sum (sha-1), and if there have been changes, it will make a new backup and synchronize it with the remote storage.
* Interaction with the script occurs only through passing flags and arguments; you do not need to edit the variables in the script body.
* It is possible to encrypt the backup before sending it to the remote storage using openssl aes-256-cbc.

## How-to:
### Without encryption:
```
# ./tar_bkp.sh -b -p box -c 5 -d /home/box/www/website/box/ -r g-disk
```
### Unpack:
```
# /tar_bkp.sh -e -p box
```
### With encryption:
```
# ./tar_bkp.sh -b -p box -c 5 -d /home/box/www/website/box/ -r g-disk -x -k pass
# ./tar_bkp.sh -bx -k pass -p box -c 5 -d /home/box/www/website/box/ -r g-disk
```
### Unpack:
```
# /tar_bkp.sh -ez -k pass -p box 
```
