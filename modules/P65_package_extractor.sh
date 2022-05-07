#!/bin/bash

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2020-2022 Siemens Energy AG
# Copyright 2020-2022 Siemens AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Michael Messner, Pascal Eckmann

# Description:  Identification and extraction of typical package archives like deb, apk, ipk

# Pre-checker threading mode - if set to 1, these modules will run in threaded mode
# This module extracts the firmware and is blocking modules that needs executed before the following modules can run
export PRE_THREAD_ENA=0

P65_package_extractor() {
  module_log_init "${FUNCNAME[0]}"
  module_title "Package extractor"
  pre_module_reporter "${FUNCNAME[0]}"

  DISK_SPACE_CRIT=0
  NEG_LOG=0
  FILES_PRE_PACKAGE=0
  FILES_POST_PACKAGE=0

  if [[ "${#ROOT_PATH[@]}" -gt 0 && "$RTOS" -eq 0 ]]; then
    FILES_PRE_PACKAGE=$(find "$FIRMWARE_PATH_CP" -xdev -type f | wc -l )
    if [[ "$DISK_SPACE_CRIT" -ne 1 ]]; then
      deb_extractor
    else
      print_output "[!] $(date) - Extractor needs too much disk space $DISK_SPACE" "main"
      print_output "[!] $(date) - Ending extraction processes - no deb extraction performed" "main"
      DISK_SPACE_CRIT=1
    fi
    if [[ "$DISK_SPACE_CRIT" -ne 1 ]]; then
      ipk_extractor
    else
      print_output "[!] $(date) - Extractor needs too much disk space $DISK_SPACE" "main"
      print_output "[!] $(date) - Ending extraction processes - no ipk extraction performed" "main"
      DISK_SPACE_CRIT=1
    fi
    if [[ "$DISK_SPACE_CRIT" -ne 1 ]]; then
      apk_extractor
    else
      print_output "[!] $(date) - Extractor needs too much disk space $DISK_SPACE" "main"
      print_output "[!] $(date) - Ending extraction processes - apk extraction performed" "main"
      DISK_SPACE_CRIT=1
    fi

    FILES_POST_PACKAGE=$(find "$FIRMWARE_PATH_CP" -xdev -type f | wc -l )

    if [[ "$FILES_POST_PACKAGE" -gt "$FILES_PRE_PACKAGE" ]]; then
      print_output ""
      print_output "[*] Before package extraction we had $ORANGE$FILES_PRE_PACKAGE$NC files, after package extraction we have now $ORANGE$FILES_POST_PACKAGE$NC files extracted."
      NEG_LOG=1
    fi
  else
    print_output "[*] As there is no root directory detected it is not possible to process package archives"
  fi

  module_end_log "${FUNCNAME[0]}" "$NEG_LOG"
}

apk_extractor() {
  sub_module_title "APK archive extraction mode"
  print_output "[*] Identify apk archives and extracting it to the root directories ..."
  extract_apk_helper &
  WAIT_PIDS+=( "$!" )
  wait_for_extractor
  WAIT_PIDS=( )
  if [[ -f "$TMP_DIR"/apk_db.txt ]] ; then
    APK_ARCHIVES=$(wc -l "$TMP_DIR"/apk_db.txt | awk '{print $1}')
    if [[ "$APK_ARCHIVES" -gt 0 ]]; then
      print_output "[*] Found $ORANGE$APK_ARCHIVES$NC APK archives - extracting them to the root directories ..."
      for R_PATH in "${ROOT_PATH[@]}"; do
        while read -r APK; do
          APK_NAME=$(basename "$APK")
          print_output "[*] Extracting $ORANGE$APK_NAME$NC package to the root directory $ORANGE$R_PATH$NC."
          tar xpf "$APK" --directory "$R_PATH" || true
        done < "$TMP_DIR"/apk_db.txt
      done

      FILES_AFTER_APK=$(find "$FIRMWARE_PATH_CP" -xdev -type f | wc -l )
      echo ""
      print_output "[*] Before apk extraction we had $ORANGE$FILES_EXT$NC files, after deep extraction we have $ORANGE$FILES_AFTER_APK$NC files extracted."
    fi
    check_disk_space
  else
    print_output "[-] No apk packages extracted."
  fi
}

ipk_extractor() {
  sub_module_title "IPK archive extraction mode"
  print_output "[*] Identify ipk archives and extracting it to the root directories ..."
  extract_ipk_helper &
  WAIT_PIDS+=( "$!" )
  wait_for_extractor
  WAIT_PIDS=( )

  if [[ -f "$TMP_DIR"/ipk_db.txt ]] ; then
    IPK_ARCHIVES=$(wc -l "$TMP_DIR"/ipk_db.txt | awk '{print $1}')
    if [[ "$IPK_ARCHIVES" -gt 0 ]]; then
      print_output "[*] Found $ORANGE$IPK_ARCHIVES$NC IPK archives - extracting them to the root directories ..."
      mkdir "$LOG_DIR"/ipk_tmp
      for R_PATH in "${ROOT_PATH[@]}"; do
        while read -r IPK; do
          IPK_NAME=$(basename "$IPK")
          print_output "[*] Extracting $ORANGE$IPK_NAME$NC package to the root directory $ORANGE$R_PATH$NC."
          tar zxpf "$IPK" --directory "$LOG_DIR"/ipk_tmp || true
          tar xzf "$LOG_DIR"/ipk_tmp/data.tar.gz --directory "$R_PATH" || true
          rm -r "$LOG_DIR"/ipk_tmp/* || true
        done < "$TMP_DIR"/ipk_db.txt
      done

      FILES_AFTER_IPK=$(find "$FIRMWARE_PATH_CP" -xdev -type f | wc -l )
      echo ""
      print_output "[*] Before ipk extraction we had $ORANGE$FILES_EXT$NC files, after deep extraction we have $ORANGE$FILES_AFTER_IPK$NC files extracted."
      rm -r "$LOG_DIR"/ipk_tmp
    fi
    check_disk_space
  else
    print_output "[-] No ipk packages extracted."
  fi
}

deb_extractor() {
  sub_module_title "Debian archive extraction mode"
  print_output "[*] Identify debian archives and extracting it to the root directories ..."
  extract_deb_helper &
  WAIT_PIDS+=( "$!" )
  wait_for_extractor
  WAIT_PIDS=( )

  if [[ -f "$TMP_DIR"/deb_db.txt ]] ; then
    DEB_ARCHIVES=$(wc -l "$TMP_DIR"/deb_db.txt | awk '{print $1}')
    if [[ "$DEB_ARCHIVES" -gt 0 ]]; then
      print_output "[*] Found $ORANGE$DEB_ARCHIVES$NC debian archives - extracting them to the root directories ..."
      for R_PATH in "${ROOT_PATH[@]}"; do
        while read -r DEB; do
          if [[ "$THREADED" -eq 1 ]]; then
            extract_deb_extractor_helper &
            WAIT_PIDS_P20+=( "$!" )
          else
            extract_deb_extractor_helper
          fi
        done < "$TMP_DIR"/deb_db.txt
      done

      if [[ "$THREADED" -eq 1 ]]; then
        wait_for_pid "${WAIT_PIDS_P20[@]}"
      fi

      FILES_AFTER_DEB=$(find "$FIRMWARE_PATH_CP" -xdev -type f | wc -l )
      echo ""
      print_output "[*] Before deb extraction we had $ORANGE$FILES_EXT$NC files, after deep extraction we have $ORANGE$FILES_AFTER_DEB$NC files extracted."
    fi
    check_disk_space
  else
    print_output "[-] No deb packages extracted."
  fi
}

extract_ipk_helper() {
  find "$FIRMWARE_PATH_CP" -xdev -type f -name "*.ipk" -exec md5sum {} \; 2>/dev/null | sort -u -k1,1 | cut -d\  -f3 >> "$TMP_DIR"/ipk_db.txt
}

extract_apk_helper() {
  find "$FIRMWARE_PATH_CP" -xdev -type f -name "*.apk" -exec md5sum {} \; 2>/dev/null | sort -u -k1,1 | cut -d\  -f3 >> "$TMP_DIR"/apk_db.txt
}

extract_deb_helper() {
  find "$FIRMWARE_PATH_CP" -xdev -type f \( -name "*.deb" -o -name "*.udeb" \) -exec md5sum {} \; 2>/dev/null | sort -u -k1,1 | cut -d\  -f3 >> "$TMP_DIR"/deb_db.txt
}

extract_deb_extractor_helper(){
  DEB_NAME=$(basename "$DEB")
  print_output "[*] Extracting $ORANGE$DEB_NAME$NC package to the root directory $ORANGE$R_PATH$NC."
  dpkg-deb --extract "$DEB" "$R_PATH" || true
}
