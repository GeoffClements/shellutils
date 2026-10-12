#!/bin/bash

###################################################################
# naud - Normalize mp3, ogg and flac files
# (c) Copyright - 2026 Geoff Clements
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.
###################################################################

###################################################################
# Two useful web pages about quality settings
# https://sourceforge.net/p/lame/svn/HEAD/tree/trunk/lame/USAGE
# https://xiph.org/vorbis/faq/#quality
###################################################################

###################################################################
# Quality setting when encoding from flacs
# Feel free to change to your liking
###################################################################
LAME_DEF_QUAL="-V 0"
OGG_DEF_QUAL="-q 6"

###################################################################
# Everything from this point should not be changed unless you
# know what you're doing
###################################################################

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "${0##*/}: bash 4.3 or later is required" >&2
  exit 1
fi

shopt -u nullglob

PROG=${0##*/}
TARGET=same                          # same | mp3 | vorbis | flac
TMPBASE=${TMPDIR:-${TMP:-/tmp}}      # where the working area is created
MAXJOBS=                             # parallel jobs, set below
RECURSE=0                            # -r: descend into sub-directories
INNER_PAR=0                          # 1 = fan out inside a directory batch
FAILS=0                              # number of things that went wrong
SESSION=                             # our private temp dir
declare -A NORM_OPTS=()              # options passed through to normalize

#########################################
# Small helpers
#########################################
log ()  { printf '%s\n' "$*"; }
warn () { printf '%s: %s\n' "$PROG" "$*" >&2; }
die ()  { warn "$*"; exit 1; }

usage () {
  local norm=$(basename $(command -v normalize-audio || command -v normalize || "normalize (not found)"))
  cat <<EOF
Usage: $PROG [OPTIONS] FILE|DIR ...

Normalize the volume of mp3, ogg and flac files.  A directory is normalized
as one batch (one gain for the whole album, so relative levels survive);
files named individually are normalized on their own.

Files are re-encoded in place.  Each new file is written to a temporary name
first and only replaces the original once encoding has succeeded.

Options apply to the files and directories that follow them:
  -o TYPE   output type: same (default), mp3, ogg (or vorbis), flac
  -r        recurse into sub-directories, one batch per directory
  -a AMP    \\
  -g ADJ     |
  -T THR     |  passed to ${norm}, see ${norm} --help".
  -n -b -m   |  Add a trailing "-" to cancel an earlier one, e.g. "-g-".
  -v -q     /

Global options:
  -t DIR    directory for temporary files (default: \$TMPDIR, or /tmp)
  -j N      maximum number of parallel jobs (default: number of CPUs)
  -h        show this help

Encoder settings for flac sources are at the top of this script.
EOF
}

#########################################
# Early option scan: -h and -t are global
#########################################
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -h|--help) usage; exit 0 ;;
    -t)
      ((i + 1 < ${#args[@]})) || die "Missing argument to -t"
      TMPBASE=${args[i + 1]}
      ((i++))
      ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }

#########################################
# Find programs which we need
#########################################
SOX=$(command -v sox)  || die "Cannot find sox"
SOXI=$(command -v soxi) || die "Cannot find soxi"
NORM=$(command -v normalize-audio || command -v normalize) \
  || die "Cannot find normalize-audio"
command -v awk >/dev/null || die "Cannot find awk"

# Encoders are only needed if we actually encode to that format, so a
# missing one is reported per file rather than stopping everything.
LAME=$(command -v lame)
OGGENC=$(command -v oggenc)
FLAC=$(command -v flac)

MAXJOBS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

#########################################
# Working area and cleanup
#########################################
[ -d "${TMPBASE}" ] || die "Temporary directory ${TMPBASE} does not exist"
SESSION=$(mktemp -d "${TMPBASE%/}/naud-XXXXXXXXXX") \
  || die "Cannot create a temporary directory in ${TMPBASE}"

cleanup () {
  [[ -n ${SESSION} ]] && rm -rf -- "${SESSION}"
}

on_signal () {
  trap - INT TERM
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null
  wait 2>/dev/null
  exit "$1"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

#########################################
# Parallel job control
#
# Jobs are plain background processes, throttled to MAXJOBS.  This
# replaces the fifo/flock job pool, and also bounds the work done
# inside a directory (the old code started one encoder per file with
# no limit).
#########################################
reap_one () {
  local rc
  wait -n
  rc=$?
  ((rc == 127)) && return 1        # nothing left to wait for
  ((rc != 0)) && FAILS=$((FAILS + 1))
  return 0
}

drain () {
  while reap_one; do :; done
}

throttle () {
  while (($(jobs -rp | wc -l) >= MAXJOBS)); do
    reap_one || break
  done
}

# run_job CMD ARGS... - background when fanning out, inline otherwise
run_job () {
  if ((INNER_PAR)); then
    throttle
    "$@" &
  else
    "$@" || FAILS=$((FAILS + 1))
  fi
}

#########################################
# Audio helpers
#########################################
probe_file () {
  # Identify an audio file.
  # $1 = path to file
  # $2 = file to receive the file's tags, one KEY=VALUE per line
  # Prints three lines: type, bitrate in bits per second (0 if unknown)
  # and number of channels.  Fails if this isn't an mp3, vorbis or flac.
  local type br ch
  type=$("${SOXI}" -t "$1" 2>/dev/null) || return 1
  case ${type} in
    mp3|vorbis|flac) ;;
    *) return 1 ;;
  esac
  br=$("${SOXI}" -B "$1" 2>/dev/null)
  ch=$("${SOXI}" -c "$1" 2>/dev/null) || return 1
  "${SOXI}" -a "$1" >"$2" 2>/dev/null

  printf '%s\n' "${type}"
  # soxi reports e.g. "128k" or "1.02M"
  awk -v v="${br}" 'BEGIN {
    n = v + 0
    if (v ~ /[kK]$/) n *= 1000
    else if (v ~ /[mM]$/) n *= 1000000
    printf "%d\n", n + 0.5
  }'
  printf '%s\n' "${ch}"
}

out_type_for () {
  # $1 = type of the source file
  if [[ ${TARGET} == same ]]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "${TARGET}"
  fi
}

encoder_for () {
  # $1 = output type; prints the path of its encoder (empty if missing)
  case $1 in
    mp3)    printf '%s\n' "${LAME}" ;;
    vorbis) printf '%s\n' "${OGGENC}" ;;
    flac)   printf '%s\n' "${FLAC}" ;;
  esac
}

dest_path () {
  # Work out where the encoded file goes.  Same type: replace the
  # original.  Different type: same name with the new extension.
  # $1 = source path, $2 = source type, $3 = output type
  local dir name ext
  if [[ $2 == "$3" ]]; then
    printf '%s\n' "$1"
    return
  fi
  dir=${1%/*}
  [[ ${dir} == "$1" ]] && dir=.
  name=${1##*/}
  case $3 in
    vorbis) ext=ogg ;;
    *)      ext=$3 ;;
  esac
  printf '%s/%s.%s\n' "${dir}" "${name%.*}" "${ext}"
}

clamp_number () {
  # clamp_number VALUE MIN MAX - print VALUE limited to MIN..MAX
  awk -v v="$1" -v lo="$2" -v hi="$3" \
    'BEGIN { if (v < lo) v = lo; if (v > hi) v = hi; printf "%.2f\n", v }'
}

build_tags () {
  # Turn the saved tags into encoder arguments, filling the caller's
  # "tagargs" array.  All Vorbis comments are carried across for ogg and
  # flac; lame can only take the ones we can map to ID3 frames.
  # Tags that would be wrong after normalizing (ReplayGain) are dropped.
  # $1 = tag file, $2 = output type
  local line key val
  tagargs=()
  [[ -r $1 ]] || return 0
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}                 # keep any further "=" in the value
    [[ -n ${val} ]] || continue
    key=${key^^}
    [[ ${key} =~ ^[A-Z0-9_]+$ ]] || continue
    case ${key} in
      REPLAYGAIN_*|R128_*|ENCODER|WAVEFORMATEXTENSIBLE_CHANNEL_MASK) continue ;;
      METADATA_BLOCK_PICTURE|COVERART*) continue ;;
      YEAR) key=DATE ;;
    esac
    case $2 in
      mp3)
        case ${key} in
          TITLE)       tagargs+=(--tt "${val}") ;;
          ARTIST)      tagargs+=(--ta "${val}") ;;
          ALBUM)       tagargs+=(--tl "${val}") ;;
          DATE)        tagargs+=(--ty "${val}") ;;
          TRACKNUMBER) tagargs+=(--tn "${val}") ;;
          GENRE)       tagargs+=(--tg "${val}") ;;
          COMMENT)     tagargs+=(--tc "${val}") ;;
          ALBUMARTIST) tagargs+=(--tv "TPE2=${val}") ;;
          DISCNUMBER)  tagargs+=(--tv "TPOS=${val}") ;;
          COMPOSER)    tagargs+=(--tv "TCOM=${val}") ;;
        esac
        ;;
      vorbis) tagargs+=(-c "${key}=${val}") ;;
      flac)   tagargs+=(-T "${key}=${val}") ;;
    esac
  done <"$1"
}

#########################################
# Decode / encode one file
#
# These two read the per-file arrays (SRC, TYPE, CH, BR, WAV) and WORK
# from process_group, and always run in a subshell, so the traps they
# set can't leak into the main shell.
#########################################
decode_one () {
  # $1 = index of file
  local i=$1 err
  log "Decoding ${SRC[i]} ..."
  if err=$("${SOX}" "${SRC[i]}" -t wav "${WAV[i]}" 2>&1); then
    : >"${WORK}/${i}.ok"
  else
    warn "Failed to decode ${SRC[i]}: ${err}"
    return 1
  fi
}

encode_one () {
  # $1 = index of file
  local i=$1
  local src=${SRC[i]} in_type=${TYPE[i]} wav=${WAV[i]} br=${BR[i]}
  local out_type dest dir tmp mode err
  local -a quality=() mono=() tagargs=() cmd=()

  out_type=$(out_type_for "${in_type}")
  dest=$(dest_path "${src}" "${in_type}" "${out_type}")
  dir=${dest%/*}
  [[ ${dir} == "${dest}" ]] && dir=.

  # Never write straight over the original: encode to a temporary file
  # next to the destination and rename it into place on success.
  tmp=$(mktemp "${dir}/.naud-XXXXXXXX") || { warn "Cannot write to ${dir}"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -f -- '${tmp}'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  build_tags "${WORK}/${i}.tags" "${out_type}"
  log "Encoding ${src##*/} to ${out_type} ..."

  case ${out_type} in
    mp3)
      ((CH[i] == 1)) && mono=(-m m)
      # Quality: flacs get the default, anything lossy gets a setting that
      # roughly matches its current bitrate.  Magic numbers divined from
      # the web pages shown near the top of this file.
      if [[ ${in_type} == flac ]] || ((br == 0)); then
        read -ra quality <<<"${LAME_DEF_QUAL}"
      elif ((br > 283000)); then
        quality=(-b 320)
      elif ((br < 98000)); then
        if ((CH[i] == 1)); then quality=(--abr 56); else quality=(--abr 80); fi
      else
        quality=(-V "$(clamp_number \
          "$(awk -v b="${br}" 'BEGIN { print (b - 264285.71429) / (-21785.71429 * 1.09) - 1 }')" \
          0 9.999)")
      fi
      cmd=("${LAME}" --quiet "${quality[@]}" "${mono[@]}" --add-id3v2
           "${tagargs[@]}" "${wav}" "${tmp}")
      ;;
    vorbis)
      if [[ ${in_type} == flac ]] || ((br == 0)); then
        read -ra quality <<<"${OGG_DEF_QUAL}"
      else
        # oggenc accepts -1..10; going outside that makes it fail
        # *after* it has already truncated its output file.
        quality=(-q "$(clamp_number \
          "$(awk -v b="${br}" 'BEGIN { print log(b / 53478.12402) * 1.1384 / 0.18859 - 1 }')" \
          -1 10)")
      fi
      cmd=("${OGGENC}" "${quality[@]}" --quiet -o "${tmp}" "${tagargs[@]}" "${wav}")
      ;;
    flac)
      cmd=("${FLAC}" --silent --force --best -o "${tmp}" "${tagargs[@]}" "${wav}")
      ;;
  esac

  if ! err=$("${cmd[@]}" 2>&1) || [[ ! -s ${tmp} ]]; then
    warn "Failed to encode ${src} to ${out_type} - original left untouched. ${err}"
    return 1
  fi

  # Keep the original's permissions if we're replacing it
  if [[ ${dest} == "${src}" ]]; then
    chmod --reference="${src}" -- "${tmp}" 2>/dev/null
    mv -f -- "${tmp}" "${dest}" || return 1
  else
    printf -v mode '%03o' $((0666 & ~$(umask)))
    chmod "${mode}" -- "${tmp}"
    mv -n -- "${tmp}" "${dest}"
    if [[ -e ${tmp} ]]; then
      warn "${dest} already exists - not overwriting"
      return 1
    fi
  fi

  trap - EXIT INT TERM
  log "Completed encoding ${src##*/} to ${out_type}"
}

#########################################
# Normalize a group of files
#########################################
process_group () {
  # Decode, normalize and re-encode a list of files.
  # $1 = name to use in messages
  # $2 = 1 to normalize as a batch (a directory), 0 for a single file
  # remaining args = the files
  local label=$1 batch=$2
  shift 2

  local WORK n=0 skipped=0 f j out info t b c dest out_type
  local -a SRC=() TYPE=() BR=() CH=() WAV=() ok=() wavs=() todo=() nargs=() k_
  local -A before=()

  WORK=$(mktemp -d "${SESSION}/grp-XXXXXX") || { warn "Cannot create work area"; FAILS=$((FAILS + 1)); return 1; }

  # Identify every file and start decoding the valid ones
  for f in "$@"; do
    info=$(probe_file "${f}" "${WORK}/${n}.tags") || continue
    { read -r t; read -r b; read -r c; } <<<"${info}"

    out_type=$(out_type_for "${t}")
    if [[ -z $(encoder_for "${out_type}") ]]; then
      warn "Skipping ${f}: no encoder installed for ${out_type}"
      FAILS=$((FAILS + 1))
      ((skipped++))
      continue
    fi
    dest=$(dest_path "${f}" "${t}" "${out_type}")
    if [[ ${dest} != "${f}" && -e ${dest} ]]; then
      warn "Skipping ${f}: ${dest} already exists"
      ((skipped++))
      continue
    fi

    SRC[n]=${f}; TYPE[n]=${t}; BR[n]=${b}; CH[n]=${c}
    WAV[n]=$(printf '%s/%04d.wav' "${WORK}" "${n}")
    run_job decode_one "${n}"
    ((n++))
  done
  drain

  for ((j = 0; j < n; j++)); do
    if [[ -e ${WORK}/${j}.ok ]]; then
      ok+=("${j}")
      wavs+=("${WAV[j]}")
    fi
  done
  if ((${#ok[@]} == 0)); then
    ((skipped || (RECURSE && batch))) || warn "No supported audio files found in ${label}"
    rm -rf -- "${WORK}"
    return 0
  fi

  # Build the normalize command line from the options given so far
  nargs=(--no-progress)
  [[ -n ${NORM_OPTS[-b]+x} ]] || { ((batch)) && nargs+=(--batch); }
  for k_ in "${!NORM_OPTS[@]}"; do
    nargs+=("${k_}")
    [[ -n ${NORM_OPTS[${k_}]} ]] && nargs+=("${NORM_OPTS[${k_}]}")
  done

  for j in "${ok[@]}"; do before[${j}]=$(cksum <"${WAV[j]}"); done

  if ((batch)); then
    log "Batch normalizing ${label} ..."
  else
    log "Normalizing ${label} ..."
  fi
  if ! out=$("${NORM}" "${nargs[@]}" "${wavs[@]}" 2>&1); then
    warn "normalize failed for ${label}: ${out}"
    FAILS=$((FAILS + 1))
    rm -rf -- "${WORK}"
    return 1
  fi
  if [[ -n ${NORM_OPTS[-v]+x} || -n ${NORM_OPTS[-n]+x} ]]; then
    printf '%s\n' "${out}"
  fi

  # Only re-encode what normalize actually changed (re-encoding a lossy
  # file for nothing just costs quality), plus anything being converted
  # to a different format.
  for j in "${ok[@]}"; do
    out_type=$(out_type_for "${TYPE[j]}")
    if [[ $(cksum <"${WAV[j]}") != "${before[${j}]}" || ${out_type} != "${TYPE[j]}" ]]; then
      todo+=("${j}")
    else
      log "${SRC[j]} is already normalized - not encoding!"
    fi
  done

  for j in "${todo[@]}"; do run_job encode_one "${j}"; done
  drain

  rm -rf -- "${WORK}"
  return 0
}

process_dir () {
  # $1 = directory
  local dir=${1%/} f
  local -a files=()
  [[ -z ${dir} ]] && dir=/
  ((RECURSE)) || log "Batch processing ${dir} ..."
  for f in "${dir%/}"/*; do
    [[ -f ${f} && -r ${f} ]] && files+=("${f}")
  done
  if ((${#files[@]} == 0)); then
    ((RECURSE)) || warn "No files in ${dir}"
    return 0
  fi
  INNER_PAR=1
  process_group "${dir}" 1 "${files[@]}"
  INNER_PAR=0
}

handle_path () {
  # One file or directory from the command line, using the options
  # that have been seen up to this point.
  local p=$1 d
  local -a dirs=()
  [[ ${p} == -* ]] && p=./${p}

  if [[ -d ${p} ]]; then
    drain                          # finish any single files first
    if ((RECURSE)); then
      while IFS= read -r -d '' d; do
        dirs+=("${d}")
      done < <(find "${p}" -type d -print0 | sort -z)
      for d in "${dirs[@]}"; do process_dir "${d}"; done
    else
      process_dir "${p}"
    fi
  elif [[ -f ${p} && -r ${p} ]]; then
    throttle
    (
      INNER_PAR=0
      FAILS=0
      process_group "${p}" 0 "${p}"
      exit $((FAILS > 0))
    ) &
  else
    warn "Skipping ${p}: not a readable file or directory"
    FAILS=$((FAILS + 1))
  fi
}

#########################################
# Command line
#
# Options affect the files and directories that come after them, so
#   naud -o mp3 album1 -o ogg album2
# does what you'd hope.  Options for normalize can be cancelled again
# by adding a "-" (e.g. "-g-").
#########################################
set -- "${args[@]}"
while (($#)); do
  case $1 in
    -t)
      shift 2                      # already handled by the early scan
      ;;
    -o)
      (($# > 1)) || die "Missing argument to -o"
      case $2 in
        same|mp3|flac) TARGET=$2 ;;
        ogg|vorbis)    TARGET=vorbis ;;
        *) die "Unrecognised target file type '$2', should be one of: same mp3 ogg vorbis flac" ;;
      esac
      shift 2
      ;;
    -j)
      (($# > 1)) || die "Missing argument to -j"
      [[ $2 =~ ^[1-9][0-9]*$ ]] || die "-j needs a positive number"
      MAXJOBS=$2
      shift 2
      ;;
    -r)
      RECURSE=1
      shift
      ;;
    -n|-b|-m|-v|-q)
      NORM_OPTS[$1]=""
      shift
      ;;
    -n-|-b-|-m-|-v-|-q-)
      unset "NORM_OPTS[${1%-}]"
      shift
      ;;
    -a|-g|-T)
      (($# > 1)) || die "Missing argument to $1"
      NORM_OPTS[$1]=$2
      shift 2
      ;;
    -a-|-g-|-T-)
      unset "NORM_OPTS[${1%-}]"
      shift
      ;;
    --)
      shift
      for p in "$@"; do handle_path "${p}"; done
      break
      ;;
    -?*)
      die "Unknown option: $1 (try -h)"
      ;;
    *)
      handle_path "$1"
      shift
      ;;
  esac
done

drain

# Phew! - time for a cup of tea
if ((FAILS > 0)); then
  log "naud has finished, but some things went wrong - see the messages above."
  exit 1
fi
log "naud has finished."
exit 0
