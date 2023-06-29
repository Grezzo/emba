#!/bin/bash -p

# EMBA - EMBEDDED LINUX ANALYZER
#
# Copyright 2021-2022 Siemens Energy AG
#
# EMBA comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# EMBA is licensed under GPLv3
#
# Author(s): Benedikt Kuehne

# Description:  Resolves all dependancies and links between Q- and S-Modules

F05_qs_resolver(){
  module_log_init "${FUNCNAME[0]}"
  module_title "QS-Resolver"
  if [[ ${GPT_OPTION} -gt 0 ]]; then
    # wait for Q02 to end
    while ! grep -q "Q02_openai_question finished" "${LOG_DIR}"/"${MAIN_LOG_FILE}"; do
      sleep 1
    done
    local _GPT_INPUT_FILE_=""
    local GPT_ANCHOR_=""
    local _GPT_PRIO_=3
    local GPT_QUESTION_=""
    local GPT_RESPONSE_=""
    local GPT_TOKENS_=0
    local GPT_OUTPUT_FILE_=""

    if [[ -f "${CSV_DIR}/q02_openai_question.csv" ]]; then
      while IFS=";" read -r COL1_ COL2_ COL3_ COL4_ COL5_ COL6_ COL7_; do
        _GPT_INPUT_FILE_="${COL1_}"
        GPT_ANCHOR_="${COL2_}"
        _GPT_PRIO_="${COL3_//GPT-Prio-/}"
        GPT_QUESTION_="${COL4_}"
        GPT_RESPONSE_="${COL5_//\'/}"
        GPT_TOKENS_="${COL6_//cost\=/}"
        GPT_OUTPUT_FILE_="${COL7_}"

        if [[ ${GPT_TOKENS_} -ne 0 ]]; then
          GPT_OUTPUT_FILE_="$(find "${LOG_DIR}" -iname "$(basename "${GPT_OUTPUT_FILE_}")" 2>/dev/null)"
          if ! [ -f "${GPT_OUTPUT_FILE_}" ]; then
            print_output "[-] Something went wrong with the Output file ${GPT_OUTPUT_FILE_}"
            if [[ -z ${GPT_OUTPUT_FILE_} ]]; then
              print_output "    there is no file name for anchor: ${GPT_ANCHOR_}"
            fi
          else
            sed -i "s/${GPT_ANCHOR_}/Q\: ${GPT_QUESTION_}\nA\: /1" "${GPT_OUTPUT_FILE_}"
            printf '%s\n' "${GPT_RESPONSE_}" >> "${GPT_OUTPUT_FILE_}"
          fi
        fi
      done < "${CSV_DIR}/q02_openai_question.csv"
    fi
  fi
  module_end_log "${FUNCNAME[0]}" 1
}
