#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2024-2024 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Michael Messner

# Description:  This module is using Ghidra to generate decompiled code from the firmware binaries.
#               This module uses the ghidra script Haruspex.java (https://github.com/0xdea/ghidra-scripts)
#               The generated source code is further analysed with semgrep and the rules provided by 0xdea
#               (https://github.com/0xdea/semgrep-rules)

S16_ghidra_decompile_checks()
{
  module_log_init "${FUNCNAME[0]}"
  module_title "Check decompiled binary source code for vulnerabilities"
  pre_module_reporter "${FUNCNAME[0]}"

  if [[ ${BINARY_EXTENDED} -ne 1 ]] ; then
    print_output "[-] ${FUNCNAME[0]} - missing ghidra_scripts dependencies"
    module_end_log "${FUNCNAME[0]}" 0
    return
  fi

  if ! [[ -d "${EXT_DIR}"/ghidra_scripts ]]; then
    print_output "[-] ${FUNCNAME[0]} - missing ghidra_scripts dependencies"
    module_end_log "${FUNCNAME[0]}" 0
    return
  fi

  local BINARY=""
  local BIN_TO_CHECK=""
  local TMP_PID=""
  local VULN_COUNTER=0
  local WAIT_PIDS_S16=()
  local BIN_TO_CHECK_ARR=()
  local lNAME=""
  local BINS_CHECKED_ARR=()

  module_wait "S13_weak_func_check"
  if [[ -f "${CSV_DIR}"/s13_weak_func_check.csv ]]; then
    local BINARIES=()
    # usually binaries with strcpy or system calls are more interesting for further analysis
    # to keep analysis time low we only check these bins
    mapfile -t BINARIES < <(grep "strcpy\|system" "${CSV_DIR}"/s13_weak_func_check.csv | sort -k 3 -t ';' -n -r | awk '{print $1}')
  fi

  for BINARY in "${BINARIES[@]}"; do
    mapfile -t BIN_TO_CHECK_ARR < <(find "${LOG_DIR}/firmware" -name "$(basename "${BINARY}")" | sort -u || true)
    for BIN_TO_CHECK in "${BIN_TO_CHECK_ARR[@]}"; do
      if [[ -f "${BASE_LINUX_FILES}" && "${FULL_TEST}" -eq 0 ]]; then
        # if we have the base linux config file we only test non known Linux binaries
        # with this we do not waste too much time on open source Linux stuff
        lNAME=$(basename "${BIN_TO_CHECK}" 2> /dev/null)
        if grep -E -q "^${lNAME}$" "${BASE_LINUX_FILES}" 2>/dev/null; then
          continue 2
        fi
      fi

      if ( file "${BIN_TO_CHECK}" | grep -q ELF ) ; then
        # ensure we have not tested this binary entry
        local BIN_MD5=""
        BIN_MD5="$(md5sum "${BIN_TO_CHECK}" | awk '{print $1}')"
        if [[ "${BINS_CHECKED_ARR[*]}" == *"${BIN_MD5}"* ]]; then
          # print_output "[*] ${ORANGE}${BIN_TO_CHECK}${NC} already tested with ghidra/semgrep" "no_log"
          continue
        fi
        # print_output "[*] Testing ${BIN_TO_CHECK} with ghidra/semgrep"
        BINS_CHECKED_ARR+=( "${BIN_MD5}" )
        if [[ "${THREADED}" -eq 1 ]]; then
          ghidra_analyzer "${BIN_TO_CHECK}" &
          TMP_PID="$!"
          store_kill_pids "${TMP_PID}"
          WAIT_PIDS_S16+=( "${TMP_PID}" )
          max_pids_protection "$(("${MAX_MOD_THREADS}"/3))" "${WAIT_PIDS_S16[@]}"
        else
          ghidra_analyzer "${BIN_TO_CHECK}"
        fi

        # we stop checking after the first 20 binaries
        if [[ "${#BINS_CHECKED_ARR[@]}" -gt 20 ]] && [[ "${FULL_TEST}" -ne 1 ]]; then
          print_output "[*] 20 binaries already analysed - ending Ghidra binary analysis now." "no_log"
          print_output "[*] For complete analysis enable FULL_TEST." "no_log"
          break 2
        fi
      fi
    done
  done

  [[ ${THREADED} -eq 1 ]] && wait_for_pid "${WAIT_PIDS_S16[@]}"

  # cleanup - remove the rest without issues now
  rm -r /tmp/haruspex_* 2>/dev/null || true

  if [[ "$(find "${LOG_PATH_MODULE}" -name "semgrep_*.csv" | wc -l)" -gt 0 ]]; then
    # can't use grep -c here as it counts on file base and we need the number of semgrep-rules
    # shellcheck disable=SC2126
    VULN_COUNTER=$(wc -l "${LOG_PATH_MODULE}"/semgrep_*.csv | tail -n1 | awk '{print $1}' || true)
  fi
  if [[ "${VULN_COUNTER}" -gt 0 ]]; then
    print_ln
    sub_module_title "Results - Ghidra decompiled code analysis via Semgrep"
    print_output "[+] Found ""${ORANGE}""${VULN_COUNTER}""${GREEN}"" possible vulnerabilities (${ORANGE}via semgrep on Ghidra decompiled code${GREEN}) in ""${ORANGE}""${#BINS_CHECKED_ARR[@]}""${GREEN}"" tested binaries:""${NC}"
    local VULN_CAT_CNT=0
    local VULN_CATS_ARR=()
    local VULN_CATEGORY=""
    mapfile -t VULN_CATS_ARR < <(grep -h -o "external.semgrep-rules-0xdea.c.raptor-[a-zA-Z0-9_\-]*" "${LOG_PATH_MODULE}"/semgrep_*.csv | sort -u)
    for VULN_CATEGORY in "${VULN_CATS_ARR[@]}"; do
      VULN_CAT_CNT=$(grep -h -o "${VULN_CATEGORY}" "${LOG_PATH_MODULE}"/semgrep_*.csv | wc -l)
      local VULN_CATEGORY_STRIPPED=${VULN_CATEGORY//external.semgrep-rules-0xdea.c.raptor-/}
      print_output "$(indent "${GREEN}${VULN_CATEGORY_STRIPPED}${ORANGE} - ${VULN_CAT_CNT} times.${NC}")"
    done
    print_bar
  fi

  write_log "[*] Statistics:${VULN_COUNTER}:${#BINS_CHECKED_ARR[@]}"
  module_end_log "${FUNCNAME[0]}" "${VULN_COUNTER}"
}

ghidra_analyzer() {
  local lBINARY="${1:-}"
  local lNAME=""
  local GPT_PRIO_=2
  local S16_SEMGREP_ISSUES=0
  local lHARUSPEX_FILE_ARR=()
  local WAIT_PIDS_S16_1=()

  if ! [[ -f "${lBINARY}" ]]; then
    return
  fi

  lNAME=$(basename "${lBINARY}" 2> /dev/null)

  if [[ -d "/tmp/haruspex_${lNAME}" ]]; then
    print_output "[-] WARNING: Temporary directory already exists for binary ${ORANGE}${lNAME}${NC} - skipping analysis" "no_log"
    return
  fi

  print_output "[*] Extracting decompiled code from binary ${ORANGE}${lNAME} / ${lBINARY}${NC} with Ghidra" "no_log"
  local IDENTIFIER="${RANDOM}"

  "${GHIDRA_PATH}"/support/analyzeHeadless "${LOG_PATH_MODULE}" "ghidra_${lNAME}_${IDENTIFIER}" -import "${lBINARY}" -log "${LOG_PATH_MODULE}"/ghidra_"${lNAME}"_"${IDENTIFIER}".txt -scriptPath "${EXT_DIR}"/ghidra_scripts -postScript Haruspex || print_output "[-] Error detected while Ghidra run for ${lNAME}" "no_log"

  # Ghidra cleanup:
  if [[ -d "${LOG_PATH_MODULE}"/"ghidra_${lNAME}_${IDENTIFIER}.rep" ]]; then
    rm -r "${LOG_PATH_MODULE}"/"ghidra_${lNAME}_${IDENTIFIER}.rep" || print_output "[-] Error detected while removing Ghidra log file ghidra_${lNAME}.rep" "no_log"
  fi
  if [[ -f "${LOG_PATH_MODULE}"/"ghidra_${lNAME}_${IDENTIFIER}.gpr" ]]; then
    rm -r "${LOG_PATH_MODULE}"/"ghidra_${lNAME}_${IDENTIFIER}.gpr" || print_output "[-] Error detected while removing Ghidra log file ghidra_${lNAME}.rep" "no_log"
  fi

  # if Ghidra was not able to produce code we can return now:
  if ! [[ -d /tmp/haruspex_"${lNAME}" ]]; then
    print_output "[-] No Ghidra decompiled code for further analysis of binary ${ORANGE}${lNAME}${NC} available ..." "no_log"
    return
  fi

  print_output "[*] Semgrep analysis on decompiled code from binary ${ORANGE}${lNAME}${NC}" "no_log"
  local lSEMGREPLOG="${LOG_PATH_MODULE}"/semgrep_"${lNAME}".json
  local lSEMGREPLOG_CSV="${lSEMGREPLOG/\.json/\.csv}"
  local lSEMGREPLOG_TXT="${lSEMGREPLOG/\.json/\.log}"
  if [[ -f "${lSEMGREPLOG}" ]]; then
    local lSEMGREPLOG="${LOG_PATH_MODULE}"/semgrep_"${lNAME}"_"${RANDOM}".json
  fi

  if [[ -f "${LOG_DIR}"/s12_binary_protection.txt ]]; then
    # we start the log file with the binary protection mechanisms
    # FUNC_LOG is currently global for log_bin_hardening from modules/S13_weak_func_check.sh -> todo as parameter
    export FUNC_LOG="${lSEMGREPLOG_TXT}"
    write_log "\\n" "${lSEMGREPLOG_TXT}"
    log_bin_hardening "${lNAME}"
    write_log "\\n-----------------------------------------------------------------\\n" "${lSEMGREPLOG_TXT}"
  fi

  # cleanup filenames
  local FPATH_ARR=()
  mapfile -t FPATH_ARR < <(find /tmp/haruspex_"${lNAME}" -type f)
  local FNAME=""
  for FPATH in "${FPATH_ARR[@]}"; do
    FNAME=$(basename "${FPATH}")
    if ! [[ -f /tmp/haruspex_"${lNAME}"/"${FNAME//[^A-Za-z0-9._-]/_}" ]]; then
      mv "${FPATH}" /tmp/haruspex_"${lNAME}"/"${FNAME//[^A-Za-z0-9._-]/_}" || true
    fi
  done

  semgrep --disable-version-check --metrics=off --severity ERROR --severity WARNING --json --config "${EXT_DIR}"/semgrep-rules-0xdea /tmp/haruspex_"${lNAME}"/* >> "${lSEMGREPLOG}" || print_output "[-] Semgrep error detected on testing ${lNAME}" "no_log"

  # check if there are more details in our log (not only the header with the binary protections)
  if [[ "$(wc -l "${lSEMGREPLOG}" | awk '{print $1}' 2>/dev/null)" -gt 0 ]]; then
    jq  -rc '.results[] | "\(.path),\(.check_id),\(.end.line),\(.extra.message)"' "${lSEMGREPLOG}" >> "${lSEMGREPLOG_CSV}" || true
    S16_SEMGREP_ISSUES=$(wc -l "${lSEMGREPLOG_CSV}" | awk '{print $1}' || true)

    if [[ "${S16_SEMGREP_ISSUES}" -gt 0 ]]; then
      print_output "[+] Found ""${ORANGE}""${S16_SEMGREP_ISSUES}"" issues""${GREEN}"" in native binary ""${ORANGE}""${lNAME}""${NC}" "" "${lSEMGREPLOG_TXT}"
      # highlight security findings in the main semgrep log:
      # sed -i -r "s/.*external\.semgrep-rules-0xdea.*/\x1b[32m&\x1b[0m/" "${lSEMGREPLOG}"
      GPT_PRIO_=$((GPT_PRIO_+1))
      # Todo: highlight the identified code areas in the decompiled code
    else
      print_output "[-] No C/C++ issues found for binary ${ORANGE}${lNAME}${NC}" "no_log"
      rm "${lSEMGREPLOG}" || print_output "[-] Error detected while removing ${lSEMGREPLOG}" "no_log"
      return
    fi
  else
    rm "${lSEMGREPLOG}" || print_output "[-] Error detected while removing ${lSEMGREPLOG}" "no_log"
    return
  fi

  # write the logs
  if [[ -d /tmp/haruspex_"${lNAME}" ]] && [[ -f "${lSEMGREPLOG}" ]]; then
    mapfile -t lHARUSPEX_FILE_ARR < <(find /tmp/haruspex_"${lNAME}" -type f || true)
    # we only store decompiled code with issues:
    if ! [[ -d "${LOG_PATH_MODULE}"/haruspex_"${lNAME}" ]]; then
      mkdir "${LOG_PATH_MODULE}"/haruspex_"${lNAME}" || print_output "[-] Error detected while creating ${LOG_PATH_MODULE}/haruspex_${lNAME}" "no_log"
    fi
    for lHARUSPEX_FILE in "${lHARUSPEX_FILE_ARR[@]}"; do
      if [[ ${THREADED} -eq 1 ]]; then
        # threading is currently not working because of mangled output
        # we need to rewrite the logging functionality in here to provide threading
        s16_semgrep_logger "${lHARUSPEX_FILE}" "${lNAME}" "${lSEMGREPLOG}" "${GPT_PRIO_}" &
        local TMP_PID="$!"
        WAIT_PIDS_S16_1+=( "${TMP_PID}" )
        max_pids_protection "${MAX_MOD_THREADS}" "${WAIT_PIDS_S16_1[@]}"
      else
        s16_semgrep_logger "${lHARUSPEX_FILE}" "${lNAME}" "${lSEMGREPLOG}" "${GPT_PRIO_}"
      fi
    done

    if [[ ${THREADED} -eq 1 ]]; then
      wait_for_pid "${WAIT_PIDS_S16_1[@]}"
      s16_finish_the_log "${lSEMGREPLOG}" "${lNAME}" &
      local TMP_PID="$!"
      WAIT_PIDS_S16+=( "${TMP_PID}" )
    else
      s16_finish_the_log "${lSEMGREPLOG}" "${lNAME}"
    fi
  fi
}

# function is just for speeding up the process
s16_finish_the_log() {
  local lSEMGREPLOG="${1:-}"
  local lNAME="${2:-}"
  local lSEMGREPLOG_TXT="${lSEMGREPLOG/\.json/\.log}"
  local lTMP_FILE=""

  for lTMP_FILE in "${lSEMGREPLOG/\.json/}"_"${lNAME}"*.tmp; do
    cat "${lTMP_FILE}" >> "${lSEMGREPLOG_TXT}" || print_output "[-] Error in logfile processing - ${lTMP_FILE}" "no_log"
    rm "${lTMP_FILE}" || true
  done
}

s16_semgrep_logger() {
  local lHARUSPEX_FILE="${1:-}"
  local lNAME="${2:-}"
  local lSEMGREPLOG="${3:-}"
  local lGPT_PRIO="${4:-}"

  local lSEMGREPLOG_CSV="${lSEMGREPLOG/\.json/\.csv}"
  local lSEMGREPLOG_TXT="${lSEMGREPLOG/\.json/\.log}"
  local lGPT_ANCHOR=""
  local CODE_LINE=""
  local lLINE_NR=""
  local lHARUSPEX_FILE_NAME=""

  lHARUSPEX_FILE_NAME="$(basename "${lHARUSPEX_FILE}")"
  local lSEMGREPLOG_TMP="${lSEMGREPLOG/\.json/}"_"${lNAME}"_"${lHARUSPEX_FILE_NAME}".tmp

  # we only handle decompiled code files with semgrep issues, otherwise we move to the next function
  # print_output "[*] Testing ${lHARUSPEX_FILE_NAME} against semgrep log ${lSEMGREPLOG}"
  if ! grep -q "${lHARUSPEX_FILE_NAME}" "${lSEMGREPLOG_CSV}"; then
    return
  fi
  if [[ -f "${lHARUSPEX_FILE}" ]]; then
    mv "${lHARUSPEX_FILE}" "${LOG_PATH_MODULE}"/haruspex_"${lNAME}" || print_output "[-] Error storing Ghidra decompiled code for ${lNAME} in log directory" "no_log"
  fi
  # print_output "[*] moved ${lHARUSPEX_FILE} to ${LOG_PATH_MODULE}/haruspex_${lNAME}" "no_log"
  if [[ -f "${lSEMGREPLOG}" ]]; then
    # now we rebuild our logfile
    while IFS="," read -r lPATH lCHECK_ID lLINE_NR lMESSAGE; do
      if [[ "${lPATH}" != *"${lHARUSPEX_FILE_NAME}"* ]]; then
        continue
      fi
      write_log "[+] Identified source function: ${ORANGE}${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}${NC}" "${lSEMGREPLOG_TMP}"
      write_link "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" "${lSEMGREPLOG_TMP}"
      write_log "$(indent "$(indent "Semgrep rule: ${ORANGE}${lCHECK_ID}${NC}")")" "${lSEMGREPLOG_TMP}"
      write_log "$(indent "$(indent "Issue description:\\n${lMESSAGE}")")" "${lSEMGREPLOG_TMP}"
      write_log "" "${lSEMGREPLOG_TMP}"
      if [[ -f "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" ]]; then
        # extract the identified code line from the source code to show it in the overview page
        CODE_LINE="$(strip_color_codes "$(sed -n "${lLINE_NR}"p "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" 2>/dev/null)")"
        shopt -s extglob
        CODE_LINE="${CODE_LINE##+([[:space:]])}"
        CODE_LINE="$(echo "${CODE_LINE}" | tr -d '\0')"
        shopt -u extglob
        # color the identified line in the source file:
        lLINE_NR="$(echo "${lLINE_NR}" | tr -d '\0')"
        sed -i -r "${lLINE_NR}s/.*/\x1b[32m&\x1b[0m/" "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" 2>/dev/null || true
        # this is the output
        write_log "$(indent "$(indent "${GREEN}${lLINE_NR}${NC} - ${ORANGE}${CODE_LINE}${NC}")")" "${lSEMGREPLOG_TMP}"
      fi
      write_log "\\n-----------------------------------------------------------------\\n" "${lSEMGREPLOG_TMP}"
    done < "${lSEMGREPLOG_CSV}"
  fi

  # GPT integration
  lGPT_ANCHOR="$(openssl rand -hex 8)"
  if [[ -f "${BASE_LINUX_FILES}" ]]; then
    # if we have the base linux config file we are checking it:
    if ! grep -E -q "^${lNAME}$" "${BASE_LINUX_FILES}" 2>/dev/null; then
      lGPT_PRIO=$((lGPT_PRIO+1))
    fi
  fi
  write_csv_gpt_tmp "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" "${lGPT_ANCHOR}" "${lGPT_PRIO}" "${GPT_QUESTION}" "${LOG_PATH_MODULE}/haruspex_${lNAME}/${lHARUSPEX_FILE_NAME}" "" ""
  write_anchor_gpt "${lGPT_ANCHOR}" "${LOG_PATH_MODULE}"/haruspex_"${lNAME}"/"${lHARUSPEX_FILE_NAME}"

  cat "${lSEMGREPLOG_TMP}" >> "${lSEMGREPLOG_TXT}"
}
