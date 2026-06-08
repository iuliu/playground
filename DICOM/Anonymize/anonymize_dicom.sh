#!/usr/bin/env bash
# ============================================================================
# anonymize_dicom.sh — Recursively anonymize DICOM files using DCMTK tools.
#
# DICOM Information Model (Patient → Study → Series → Instance):
#   Patient  identified by: Patient ID (0010,0020)
#   Study    identified by: Study Instance UID (0020,000D)  ← PRESERVED
#   Series   identified by: Series Instance UID (0020,000E) ← PRESERVED
#   Instance identified by: SOP Instance UID (0008,0018)    ← PRESERVED
#
# Strategy:
#   - Each directory containing DICOM files = one study.
#   - Within a study, all files share the same anonymized Patient Name/ID.
#   - Patient Name → ANON_NNNN (sequential: 0001, 0002, ...)
#   - Patient ID   → ANON_NNNN (same value)
#   - All other PHI tags → emptied.
#   - UIDs are NEVER modified.
#
# Usage:
#   ./anonymize_dicom.sh <input_dir> <output_dir> <tags_file>
#
# Dependencies: dcmodify, dcmdump (from DCMTK)
# ============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly ANON_PREFIX="ANON_"
readonly PID_PREFIX="PID_"
readonly ACC_PREFIX="ACC_"

# Platform detection:
#   MINGW/MSYS/CYGWIN (Git Bash)  → dcmodify.exe, need path conversion
#   WSL (Linux + .exe available)   → dcmodify.exe, no path conversion needed
#   Native Linux/macOS             → dcmodify, no path conversion needed
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        readonly DCMODIFY="dcmodify.exe"
        readonly DCMDUMP="dcmdump.exe"
        readonly IS_MSYS2=1
        ;;
    Linux*|Darwin*)
        if command -v "dcmodify.exe" &>/dev/null; then
            # WSL: Windows .exe tools via /mnt/c/ — need path conversion like MSYS2
            readonly DCMODIFY="dcmodify.exe"
            readonly DCMDUMP="dcmdump.exe"
            readonly IS_MSYS2=1
        else
            # Native Linux/macOS: bare tool names, no path conversion
            readonly DCMODIFY="dcmodify"
            readonly DCMDUMP="dcmdump"
            readonly IS_MSYS2=0
        fi
        ;;
    *)
        readonly DCMODIFY="dcmodify"
        readonly DCMDUMP="dcmdump"
        readonly IS_MSYS2=0
        ;;
esac

# Convert MSYS2 paths to Windows format for DCMTK native tools
to_win_path() {
    # Pass through unchanged on Linux/macOS — only convert paths under MSYS2
    ((IS_MSYS2)) || { echo "$1"; return; }
    local p="$1"
    if [[ "$p" == /mnt/?/* ]]; then
        local drive="${p:5:1}"
        p="${drive}:${p:6}"
    elif [[ "$p" == /?/* ]]; then
        local drive="${p:1:1}"
        p="${drive}:${p:2}"
    fi
    echo "${p//\//\\}"
}
# ---- UID tags that MUST NOT be modified ----
readonly PROTECTED_UIDS=(
    "0008,0016"  # SOP Class UID
    "0008,0018"  # SOP Instance UID
    "0020,000d"  # Study Instance UID
    "0020,000e"  # Series Instance UID
    "0008,1150"  # Referenced SOP Class UID
    "0008,1155"  # Referenced SOP Instance UID
    "0020,0052"  # Frame of Reference UID
    "0020,0200"  # Synchronization Frame of Reference UID
)

# ---- Tags that receive generated unique values per study ----
readonly NAME_TAGS=(
    "0010,0010"  # Patient's Name
)
readonly PID_TAGS=(
    "0010,0020"  # Patient ID
)
readonly ACC_TAGS=(
    "0008,0050"  # Accession Number
)
# ---- Sequence (SQ) tags — must use -e (empty) instead of -ma "(tag)=" ----
readonly SEQ_TAGS=(
    "0010,0050"  # Patient's Insurance Plan Code Sequence
    "0010,1002"  # Other Patient IDs Sequence
    "0008,1049"  # Physician(s) of Record Identification Sequence
    "0008,1110"  # Referenced Study Sequence
    "0040,0275"  # Request Attributes Sequence
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <input_dir> <output_dir> <tags_file>

Recursively anonymizes DICOM files. Each directory containing DICOM files
is treated as a separate study.

Arguments:
  input_dir    Root directory to scan for DICOM studies.
  output_dir   Directory where anonymized copies are written (mirrors structure).
  tags_file    File listing DICOM tags to anonymize, one (gggg,eeee) per line.

Options:
  -h, --help   Show this help message.

Example:
  $SCRIPT_NAME ./original_scans ./anonymized_scans ./phi_tags.txt
EOF
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
    local missing=()
    for tool in "$DCMODIFY" "$DCMDUMP"; do
        if command -v "$tool" &>/dev/null; then
            continue
        fi
        local found=0
        for prefix in "/usr/bin" "/usr/local/bin" "/opt/dcmtk/bin"; do
            if [[ -x "$prefix/$tool" ]]; then
                export PATH="$prefix:$PATH"
                found=1
                break
            fi
        done
        if ((!found)); then
            missing+=("$tool")
        fi
    done
    if ((${#missing[@]} > 0)); then
        log_error "Missing required DCMTK tools: ${missing[*]}"
        log_error "Install DCMTK: https://dicom.offis.de/dcmtk.php.en"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Tag helpers
# ---------------------------------------------------------------------------

parse_tags_file() {
    local tags_file="$1"
    if [[ ! -f "$tags_file" ]]; then
        log_error "Tags file not found: $tags_file"
        exit 1
    fi
    if [[ ! -r "$tags_file" ]]; then
        log_error "Tags file not readable: $tags_file"
        exit 1
    fi
    grep -v '^[[:space:]]*#' "$tags_file" \
        | grep -oiE '\([0-9a-f]{4},[0-9a-f]{4}\)' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[()]//g' \
        | sort -u
}

is_tag_protected() {
    local tag_lower="$1"
    for protected in "${PROTECTED_UIDS[@]}"; do
        [[ "$tag_lower" == "$protected" ]] && return 0
    done
    return 1
}

is_name_tag() {
    local tag_lower="$1"
    for nt in "${NAME_TAGS[@]}"; do
        [[ "$tag_lower" == "$nt" ]] && return 0
    done
    return 1
}

is_pid_tag() {
    local tag_lower="$1"
    for pt in "${PID_TAGS[@]}"; do
        [[ "$tag_lower" == "$pt" ]] && return 0
    done
    return 1
}

is_acc_tag() {
    local tag_lower="$1"
    for at in "${ACC_TAGS[@]}"; do
        [[ "$tag_lower" == "$at" ]] && return 0
    done
    return 1
}

is_seq_tag() {
    local tag_lower="$1"
    for st in "${SEQ_TAGS[@]}"; do
        [[ "$tag_lower" == "$st" ]] && return 0
    done
    return 1
}

is_dicom_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    "$DCMDUMP" -q "$(to_win_path "$file")" &>/dev/null
}

# ---------------------------------------------------------------------------
# SOP Instance UID extraction — used in error messages
# ---------------------------------------------------------------------------

get_sop_instance_uid() {
    local file="$1"
    local raw
    raw="$("$DCMDUMP" -q +P "0008,0018" "$(to_win_path "$file")" 2>/dev/null)" || true
    # Extract value between brackets:  [VALUE]  or "(no value available)"
    if [[ "$raw" == *"["*"]"* ]]; then
        local val="${raw#*[}"
        echo "${val%%]*}"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Study discovery
# ---------------------------------------------------------------------------

find_study_dirs() {
    local root="$1"
    # Use recursive function instead of find (broken with /mnt/c/ paths on MSYS2)
    _scan_dirs() {
        local d f found=0
        # Check THIS directory for DICOM files
        for f in "$1"/*; do
            [[ -f "$f" ]] || continue
            if is_dicom_file "$f"; then found=1; break; fi
        done
        if ((found)); then echo "${1%/}"; fi
        # Recurse into subdirectories
        for d in "$1"/*/; do
            [[ -d "$d" ]] || continue
            _scan_dirs "$d"
        done
    }
    _scan_dirs "$root" | sort
}

# ---------------------------------------------------------------------------
# Anonymization core
# ---------------------------------------------------------------------------

anonymize_file() {
    local file="$1"
    local anon_name="$2"    # PatientName value (e.g. ANON_0001)
    local anon_pid="$3"     # PatientID value  (e.g. PID_0001)
    local anon_acc="$4"     # AccessionNumber value (e.g. ACC_0001)
    local -n _tags="$5"
    local orig_file="${6:-}"

    [[ -f "$file" ]] || { log_warn "Skipping: file not found: $file"; return 1; }
    is_dicom_file "$file" || { log_warn "Skipping: not a valid DICOM file: $file"; return 1; }

    local sop_uid
    sop_uid="$(get_sop_instance_uid "$file")"
    local wnpath
    wnpath="$(to_win_path "$file")"
    local bname
    bname="$(basename "$file")"

    # ---- Resolve value for each tag ----
    _get_tag_value() {
        local tag="$1"
        if is_name_tag "$tag"; then
            echo "$anon_name"
        elif is_pid_tag "$tag"; then
            echo "$anon_pid"
        elif is_acc_tag "$tag"; then
            echo "$anon_acc"
        elif is_seq_tag "$tag"; then
            echo ""   # sequences use -e flag, not value
        else
            echo ""   # emptied tags
        fi
    }

    # ---- Build the full batch of modifications ----
    local dcmodify_args=("-nb" "-ie" "-imt")
    local skipped_uids=()
    for tag in "${_tags[@]}"; do
        if is_tag_protected "$tag"; then
            skipped_uids+=("$tag")
            continue
        fi
        if is_seq_tag "$tag"; then
            dcmodify_args+=("-e" "($tag)")
        else
            local val
            val="$(_get_tag_value "$tag")"
            dcmodify_args+=("-ma" "($tag)=$val")
        fi
    done

    if ((${#skipped_uids[@]} > 0)); then
        log_info "  Skipped protected UID tags: ${skipped_uids[*]}"
    fi

    # ---- Fast path: single dcmodify call with all tags ----
    local batch_err
    batch_err="$("$DCMODIFY" "${dcmodify_args[@]}" "$wnpath" 2>&1)" && return 0

    # ---- Slow path: batch failed, retry tag by tag ----
    log_warn "  $bname: batch modification failed — retrying tag by tag"
    log_info "  Batch error was:"
    local batch_line
    while IFS= read -r batch_line; do
        log_info "    $batch_line"
    done <<< "$batch_err"

    if [[ -n "$orig_file" ]] && [[ -f "$orig_file" ]]; then
        cp "$orig_file" "$file"
    fi

    local failures=0
    local -a failed_tags=()

    for tag in "${_tags[@]}"; do
        if is_tag_protected "$tag"; then
            continue
        fi

        local flag modify_arg
        if is_seq_tag "$tag"; then
            flag="-e"
            modify_arg="($tag)"
        else
            flag="-ma"
            local val
            val="$(_get_tag_value "$tag")"
            modify_arg="($tag)=$val"
        fi

        local dcmtk_err
        dcmtk_err="$("$DCMODIFY" -nb -ie -imt "$flag" "$modify_arg" "$wnpath" 2>&1)" || {
            log_error "Anonymization failed"
            log_error "  File:           $bname"
            log_error "  SOPInstanceUID: ${sop_uid:-unknown}"
            log_error "  Tag:            ($tag)"
            local err_line
            err_line="$(echo "$dcmtk_err" | grep -E '^[EW]:' | head -1)"
            [[ -z "$err_line" ]] && err_line="$(echo "$dcmtk_err" | head -1)"
            log_error "  DCMTK error:    ${err_line:-$dcmtk_err}"
            ((failures++)) || true
            failed_tags+=("$tag")
        }
    done

    if ((failures > 0)); then
        log_warn "  $bname: ${#failed_tags[@]} tag(s) could not be anonymized: ${failed_tags[*]}"
    fi
    return "$failures"
}

anonymize_study() {
    local study_dir="$1"
    local anon_index="$2"
    local output_root="$3"
    local input_root="$4"
    local -n tags_ref="$5"

    local anon_name
    local anon_pid
    local anon_acc
    anon_name="$(printf "%s%04d" "$ANON_PREFIX" "$anon_index")"
    anon_pid="$(printf "%s%04d" "$PID_PREFIX" "$anon_index")"
    anon_acc="$(printf "%s%04d" "$ACC_PREFIX" "$anon_index")"
    log_info "Study #$anon_index: $study_dir  →  $anon_name (PID=$anon_pid, ACC=$anon_acc)"

    local dcm_files=()
    local f
    for f in "$study_dir"/*; do
        [[ -f "$f" ]] || continue
        is_dicom_file "$f" && dcm_files+=("$f")
    done

    if ((${#dcm_files[@]} == 0)); then
        log_warn "No DICOM files found in: $study_dir"
        return 0
    fi

    log_info "  Found ${#dcm_files[@]} DICOM file(s)"

    local rel_path="${study_dir#$input_root}"
    rel_path="${rel_path#/}"
    local output_dir="$output_root/$rel_path"
    [[ -z "$rel_path" ]] && output_dir="$output_root"
    mkdir -p "$output_dir"

    local failures=0
    for f in "${dcm_files[@]}"; do
        local dest="$output_dir/$(basename "$f")"
        cp "$f" "$dest"
        if anonymize_file "$dest" "$anon_name" "$anon_pid" "$anon_acc" tags_ref "$f"; then
            log_info "  ✓ $(basename "$f")"
        else
            log_warn "  ✗ $(basename "$f") (failed, original copied)"
            ((failures++)) || true
        fi
    done

    if ((failures > 0)); then
        log_warn "  $failures file(s) had errors in study $anon_name"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    if (($# < 3)); then
        log_error "Missing arguments. Expected 3, got $#."
        usage >&2
        exit 1
    fi

    local input_dir
    local output_dir
    local tags_file
    input_dir="$(realpath "$1")"
    output_dir="$(realpath -m "$2")"
    tags_file="$3"

    if [[ ! -d "$input_dir" ]]; then
        log_error "Input directory not found: $input_dir"
        exit 1
    fi

    log_info "============================================"
    log_info "DICOM Anonymization"
    log_info "============================================"
    log_info "Input:       $input_dir"
    log_info "Output:      $output_dir"
    log_info "Tags file:   $tags_file"
    log_info "--------------------------------------------"

    check_prerequisites

    log_info "Parsing tags file..."
    local all_tags=()
    local tag
    while IFS= read -r tag; do
        all_tags+=("$tag")
    done < <(parse_tags_file "$tags_file")

    if ((${#all_tags[@]} == 0)); then
        log_error "No valid tags found in: $tags_file"
        exit 1
    fi
    log_info "  ${#all_tags[@]} tag(s) loaded"

    log_info "Discovering study directories..."
    local study_dirs=()
    local dir
    while IFS= read -r dir; do
        study_dirs+=("$dir")
    done < <(find_study_dirs "$input_dir")

    if ((${#study_dirs[@]} == 0)); then
        log_error "No directories containing DICOM files found under: $input_dir"
        exit 1
    fi
    log_info "  ${#study_dirs[@]} study directories found"

    mkdir -p "$output_dir"

    local study_count=0
    local total_files=0
    local failed_studies=0

    for study_dir in "${study_dirs[@]}"; do
        ((study_count++)) || true

        local file_count=0
        local f
        while IFS= read -r -d '' f; do
            is_dicom_file "$f" && ((file_count++)) || true
        done < <(find "$study_dir" -maxdepth 1 -type f -print0 2>/dev/null || true)

        anonymize_study "$study_dir" "$study_count" "$output_dir" "$input_dir" all_tags || ((failed_studies++)) || true
        ((total_files += file_count)) || true
    done

    log_info "============================================"
    log_info "Anonymization complete"
    log_info "  Studies processed:  $study_count"
    log_info "  Studies failed:     $failed_studies"
    log_info "  Total DICOM files:  $total_files"
    log_info "  Output directory:   $output_dir"
    log_info "============================================"

    if ((failed_studies > 0)); then
        exit 1
    fi
}

if [[ -z "${ANON_SOURCED:-}" ]]; then
    main "$@"
fi
