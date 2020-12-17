#!/bin/bash

# Copyright (C) 2020  Feignint <feignint@gmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later

# Utilises codespell https://github.com/codespell-project/codespell
# sudo apt-get install codespell

set -e

main()
{
  codepell_version

  until (( ${#} == 0 )); do
    case "${1#--}" in
      all|staged|dirty)
        files="${1//-}"
      ;;
      binary)
        binary="$2"
        shift 2
      ;;
      base-git-ref)
        >&2 printf "%s " "looking for git ref $2 .."
        >&2 git describe "$2" ||
            {
              #local return_code=$?
              >&2 printf "did you type %s correcty?\n" "$2"
              #exit $return_code
              >&2 printf "let me have a go at guessing\n"
              auto_parent="$(
                grep -m1 -Po "(?<=^commit \w{40}\s\()([^HEAD][\w/-]+)" \
                    < <( git log --decorate )
              )"
              >&2 printf "found %s\n" "${auto_parent}"
            }
        #>&2 printf "\n"
        files="git-ref $( 2>/dev/null git describe "${auto_parent:-$2}" )"
        shift 2
      ;;
    esac
    shift 1 || :
  done

  get_file_list
  load_ignore_regex
  check_binary
  _github_PR
}

codepell_version()
{
  >/dev/null type -p codespell ||
    {
      >&2 printf "%s\n" "codespell command not found"
      exit 127 # same as bash: command not found
    }
  >&2 printf "codespell version: %s\n" "$( codespell --version )"
}

get_file_list()
{
  if [[ $GITHUB_ACTOR && $files != all ]]; then
    get_github_api_file_list
    readarray -t -O ${#check_files[@]} check_files < <(
      jq -r 'select(.filename|startswith("contrib/translations")|not)
              |.filename
            ' <<<"$patch_hunks_json"
    )
  else
    # Since translation files are not English, they will make a lot of noise.
    # CODESPELL(1) has "-S|--skip", however this does not work if codespell is
    # given a list of files, so exclude here
    exclude_files=( ':!contrib/translations/' )

    case ${files:=dirty} in
      all)
        readarray -t -O ${#check_files[@]} check_files < <(
          git ls-files -- "${exclude_files[@]}"
        )
        return
      ;;
      dirty)
        git_diff_opts=( --name-only )
      ;;
      staged)
        git_diff_opts=( --name-only --staged )
      ;;
      git-ref*)
        git_diff_opts=( --name-only "${files#* }" HEAD )
      ;;
    esac

    readarray -t -O ${#check_files[@]} check_files < <(
      git diff "${git_diff_opts[@]}" -- "${exclude_files[@]}"
    )
  fi

  if (( ${#check_files[@]} == 0 )); then
    >&2 printf "%s --%s\n" "No files found with option" "${files}"
  fi
}

get_github_api_file_list()
{
  # "." vs "/" . I've been using refs_pull_nnn_merge.json
  # locally for testing ;)
  [[ ${GITHUB_REF} =~ refs.pull.[0-9]+.merge ]] ||
    {
      >&2 printf "%s " "${0}:" "${GITHUB_REF}" "not a PR, skipped"
      >&2 printf "\n"
      exit 0
    }

  PULL_NUMBER="${GITHUB_REF//[^0-9]}"

  local PULLS="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/pulls/"

  [[ -z $PULL_NUMBER ]] && return ||
    PR_FILES_JSON="$(
      if [[ -f "$GITHUB_REF" ]]
      then
        # craft your own json, to test stuff
        cat "$GITHUB_REF"
      else
        # easier to get details of the PR from github's API than messing about
        # with git, which I'm guessing will be a shallow checkout.
        curl -s -H "Accept: application/vnd.github.v3+json" \
                   "${PULLS}${PULL_NUMBER}/files"
        # FIXME do something if curl fails
      fi
    )"

  patch_hunks_json="$(
    # splits the patch string into patch_hunks array
    # i.e. each array element is a hunk
    jq '.[]|select(.patch != null)
        | {
            "filename"    : .filename,
            "patch_hunks" : [ .patch | split("\n@@")|.[] | sub("^ -";"@@ -") ]
          }
       ' <<<"${PR_FILES_JSON}"
  )"
}

hunk_ranges()
{
  # When checking all files, simply output ${LN},0
  [[ ${files} == all ]] &&
    printf "%s,0\n" "${LN}" && return

  if [[ $GITHUB_ACTOR ]]; then
    jq -r 'select(.filename == "'"${FN}"'")
             |.patch_hunks[]|match("\\+[0-9]+,[0-9]+")
             |.string|sub("\\+";"")
          ' <<<"${patch_hunks_json}"
  else
    sed -n -E 's/^@@ -[0-9]+,[0-9]+ \+([0-9]+,[0-9]+) @@.*/\1/p
              ' < <( git diff "${git_diff_opts[@]:1}" -- "${FN}" )
  fi
}

_github_PR()
{
  (( ${#check_files[@]} != 0 )) || return 0
  while IFS=":" read -r FN LN TYPO_FIX; do
    # NOTE: TYPO_FIX has a leading space.
    while IFS="," read -r S R; do
      (( LN >= S && LN <= S + R )) || continue &&
        ( # subshell for easy reset of errlevel
          [[ "${TYPO_FIX# }" =~ ^(${bin_filter})$ ]] && (( errlevel ++ ))
          # TODO different output format for when not github CI
          printf "::%s file=%s,line=%d::%s:%s\n" \
                 "${errlevels[$errlevel]}" "$FN" "$LN" "$FN" "$TYPO_FIX"
        )
    done < <( hunk_ranges )
  done < <( codespell --ignore-regex "(${ignore_regex})" "${check_files[@]}" )
}

load_ignore_regex()
{
  local -a MAPFILE
  readarray -t < <( grep -v -E "^(#|$)" .codespell_ignore )
  printf -v ignore_regex "%q|" "${MAPFILE[@]}"
  ignore_regex="${ignore_regex%|}"
}

check_binary()
{
  [[ -e "${binary:=src/dosbox}" ]] ||
    {
      >&2 printf '"%s" does not exist.. skipped\n' "${binary}"
      return 0
    }

  while read -r; do
    if [[ "${REPLY%%:*}" =~ [0-9]+ ]]; then
      CONTEXT=( "${REPLY#*:}" )
    else
      CONTEXT+=( "${REPLY# +}" )
    fi

    [[ ${#CONTEXT[@]} == 2 ]] || continue
      ALL_BINARY_TYPOS+=( "${CONTEXT[@]}" )
      typo_in_binary+=( "${CONTEXT[1]##[[:space:]]}" )
  done < <( codespell --ignore-regex "(${ignore_regex})"  \
                      - < <( strings -n 9 -w "${binary}" ) )

  printf -v bin_filter "%s|" "${typo_in_binary[@]}"
  bin_filter="${bin_filter%|}"
}

# Annotations
errlevels=( debug warning error )
errlevel=1 # default, warning

main "${@}"

(( ${#ALL_BINARY_TYPOS[@]} == 0 )) ||
  {
    >&2 printf "%s\n" " Typos found in binary:" "${ALL_BINARY_TYPOS[@]/#/>>>}"
    # This is just a dumb report for the sake of verbosity
    # Anything introduced by commit(s) would be flagged by the main script
    # TODO filter this, should any typos not be related to commit(s) remain do
    # a git grep to find suspect filename & line_no.
  }
