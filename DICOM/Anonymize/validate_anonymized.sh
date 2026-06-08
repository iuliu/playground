#!/usr/bin/env bash
# ============================================================================
# validate_anonymized.sh — Validate anonymized DICOM studies using DCMTK.
#
# Validates that:
#   1. PHI tags are properly emptied or replaced with anonymous values.
#   2. UID identifiers (Study, Series, SOP Instance) are preserved.
#   3. Study-level attributes are consistent within each study directory.
#   4. Series-level attributes are consistent within each series (same Series UID).
#
# DICOM Information Model:
#   Patient → Study (0020,000D) → Series (0020,000E) → Instance (0008,0018)
#
# Usage:
#   ./validate_anonymized.sh <input_dir> <output_dir> <tags_file>
#
# Dependencies: dcmdump (from DCMTK)
# ============================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        readonly DCMDUMP="dcmdump.exe"
        readonly IS_MSYS2=1
        ;;
    Linux*|Darwin*)
        if command -v "dcmdump.exe" &>/dev/null; then
            readonly DCMDUMP="dcmdump.exe"
            readonly IS_MSYS2=1
        else
            readonly DCMDUMP="dcmdump"
            readonly IS_MSYS2=0
        fi
        ;;
    *)
        readonly DCMDUMP="dcmdump"
        readonly IS_MSYS2=0
        ;;
esac

# Convert MSYS2 paths to Windows format for DCMTK native tools
to_win_path() {
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
# UID tags that identify the DICOM hierarchy — must be preserved
readonly STUDY_UID_TAG="0020,000d"
readonly SERIES_UID_TAG="0020,000e"
readonly SOP_UID_TAG="0008,0018"

# Tags whose values must be consistent across all files in a study
readonly STUDY_CONSISTENCY_TAGS=(
    "0010,0010"  # Patient's Name
    "0010,0020"  # Patient ID
    "0010,0030"  # Patient's Birth Date
    "0010,0040"  # Patient's Sex
    "0008,0020"  # Study Date
    "0008,0030"  # Study Time
    "0008,0050"  # Accession Number
    "0008,1030"  # Study Description
    "0020,0010"  # Study ID
)

# Tags whose values must be consistent across all files in the same series
readonly SERIES_CONSISTENCY_TAGS=(
    "0008,0021"  # Series Date
    "0008,0031"  # Series Time
    "0008,103e"  # Series Description
    "0020,0011"  # Series Number
)

# Tags that should have generated values (not empty)
readonly VALUE_TAGS=(
    "0010,0010"  # Patient's Name     → ANON_NNNN
    "0010,0020"  # Patient ID         → PID_NNNN
    "0008,0050"  # Accession Number   → ACC_NNNN
)

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <input_dir> <output_dir> <tags_file>

Validates that DICOM files under <output_dir> have been properly anonymized
compared to originals under <input_dir>.

Arguments:
  input_dir    Original (pre-anonymization) DICOM directory.
  output_dir   Anonymized DICOM directory (mirrors input_dir structure).
  tags_file    File listing PHI tags that should be anonymized.

Exit codes:
  0  All validations passed.
  1  Validation errors found.
  2  Usage or prerequisite error.

Example:
  $SCRIPT_NAME ./original_scans ./anonymized_scans ./phi_tags.txt
EOF
}

log_info()   { echo "[INFO]    $*"; }
log_pass()   { echo "[PASS]    $*"; }
log_fail()   { echo "[FAIL]    $*"; }
log_detail() { echo "          $*"; }
log_header() { echo ""; echo "====== $* ======"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

check_prerequisites() {
    if command -v "$DCMDUMP" &>/dev/null; then
        return 0
    fi
    for prefix in "/usr/bin" "/usr/local/bin" "/opt/dcmtk/bin"; do
        if [[ -x "$prefix/$DCMDUMP" ]]; then
            export PATH="$prefix:$PATH"
            return 0
        fi
    done
    log_fail "$DCMDUMP not found. Install DCMTK."
    exit 2
}

# ---------------------------------------------------------------------------
# Tag value extraction
# ---------------------------------------------------------------------------

get_tag_value() {
    local file="$1"
    local tag="$2"       # hex format: "gggg,eeee" (no parens)

    local raw
    raw="$("$DCMDUMP" -q +P "$tag" "$(to_win_path "$file")" 2>/dev/null)" || true

    if [[ -z "$raw" ]]; then
        echo ""
        return
    fi
    if [[ "$raw" == *"(no value available)"* ]]; then
        echo "EMPTY"
        return
    fi

    local val="${raw#*[}"
    val="${val%%]*}"
    echo "$val"
}

# ---------------------------------------------------------------------------
# DICOM file discovery
# ---------------------------------------------------------------------------

is_dicom_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    "$DCMDUMP" -q "$(to_win_path "$file")" &>/dev/null
}

find_dicom_files() {
    local dir="$1"
    local files=()
    local f
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        is_dicom_file "$f" && files+=("$f")
    done
    printf '%s\n' "${files[@]}"
}

# ---------------------------------------------------------------------------
# Validation: PHI tag removal
# ---------------------------------------------------------------------------

check_tags_anonymized() {
    local file="$1"
    local -n _tags="$2"
    local basename
    basename="$(basename "$file")"
    local failures=0

    for tag in "${_tags[@]}"; do
        local val
        val="$(get_tag_value "$file" "$tag")"
        local is_anon_tag=0
        for at in "${VALUE_TAGS[@]}"; do
            [[ "${tag,,}" == "${at,,}" ]] && is_anon_tag=1 && break
        done

        if ((is_anon_tag)); then
            if [[ -z "$val" ]]; then
                log_fail "$basename: tag ($tag) is missing (should be anonymized)"
                ((failures++)) || true
            elif [[ "$val" == "EMPTY" ]]; then
                log_fail "$basename: tag ($tag) is empty (should have anonymous value)"
                ((failures++)) || true
            fi
        else
            if [[ -n "$val" && "$val" != "EMPTY" ]]; then
                log_fail "$basename: tag ($tag) still contains value: [$val]"
                ((failures++)) || true
            fi
        fi
    done

    return "$failures"
}

# ---------------------------------------------------------------------------
# Validation: UID preservation
# ---------------------------------------------------------------------------

check_uids_preserved() {
    local orig="$1"
    local anon="$2"
    local basename
    basename="$(basename "$anon")"
    local failures=0

    local uid_tags=("$STUDY_UID_TAG" "$SERIES_UID_TAG" "$SOP_UID_TAG")
    local uid_names=("StudyInstanceUID" "SeriesInstanceUID" "SOPInstanceUID")

    local i
    for ((i = 0; i < ${#uid_tags[@]}; i++)); do
        local tag="${uid_tags[$i]}"
        local name="${uid_names[$i]}"
        local orig_val anon_val
        orig_val="$(get_tag_value "$orig" "$tag")"
        anon_val="$(get_tag_value "$anon" "$tag")"

        if [[ "$orig_val" != "$anon_val" ]]; then
            log_fail "$basename: $name changed!"
            log_detail "  Original:    $orig_val"
            log_detail "  Anonymized:  $anon_val"
            ((failures++)) || true
        fi
    done

    return "$failures"
}

# ---------------------------------------------------------------------------
# Validation: Study-level consistency
# ---------------------------------------------------------------------------

check_study_consistency() {
    local study_dir="$1"
    local dir_name
    dir_name="$(basename "$study_dir")"
    local failures=0

    local dcm_files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && dcm_files+=("$f")
    done < <(find_dicom_files "$study_dir")

    if ((${#dcm_files[@]} < 2)); then
        return 0
    fi

    for tag in "${STUDY_CONSISTENCY_TAGS[@]}"; do
        local first_val=""
        local first_file=""
        for f in "${dcm_files[@]}"; do
            local val
            val="$(get_tag_value "$f" "$tag")"
            if [[ -z "$first_val" ]]; then
                first_val="$val"
                first_file="$(basename "$f")"
            elif [[ "$val" != "$first_val" ]]; then
                log_fail "$dir_name: STUDY inconsistency for tag ($tag)"
                log_detail "  $first_file: [$first_val]"
                log_detail "  $(basename "$f"): [$val]"
                ((failures++)) || true
                break
            fi
        done
    done

    return "$failures"
}

# ---------------------------------------------------------------------------
# Validation: Series-level consistency
# ---------------------------------------------------------------------------

check_series_consistency() {
    local study_dir="$1"
    local dir_name
    dir_name="$(basename "$study_dir")"
    local failures=0

    local dcm_files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && dcm_files+=("$f")
    done < <(find_dicom_files "$study_dir")

    if ((${#dcm_files[@]} < 2)); then
        return 0
    fi

    declare -A series_groups
    for f in "${dcm_files[@]}"; do
        local ser_uid
        ser_uid="$(get_tag_value "$f" "$SERIES_UID_TAG")"
        if [[ -n "$ser_uid" && "$ser_uid" != "EMPTY" ]]; then
            if [[ -z "${series_groups[$ser_uid]:-}" ]]; then
                series_groups[$ser_uid]="$f"
            else
                series_groups[$ser_uid]="${series_groups[$ser_uid]}"$'\n'"$f"
            fi
        fi
    done

    for ser_uid in "${!series_groups[@]}"; do
        local group_files=()
        while IFS= read -r gf; do
            [[ -n "$gf" ]] && group_files+=("$gf")
        done <<< "${series_groups[$ser_uid]}"

        if ((${#group_files[@]} < 2)); then
            continue
        fi

        for tag in "${SERIES_CONSISTENCY_TAGS[@]}"; do
            local first_val=""
            local first_file=""
            for gf in "${group_files[@]}"; do
                local val
                val="$(get_tag_value "$gf" "$tag")"
                if [[ -z "$first_val" ]]; then
                    first_val="$val"
                    first_file="$(basename "$gf")"
                elif [[ "$val" != "$first_val" ]]; then
                    log_fail "$dir_name: SERIES inconsistency for tag ($tag) in series $ser_uid"
                    log_detail "  $first_file: [$first_val]"
                    log_detail "  $(basename "$gf"): [$val]"
                    ((failures++)) || true
                    break
                fi
            done
        done
    done

    return "$failures"
}

# ---------------------------------------------------------------------------
# Per-study validation
# ---------------------------------------------------------------------------

validate_study() {
    local study_dir="$1"
    local orig_study_dir="$2"
    local -n tags_ref="$3"

    local dir_name
    dir_name="$(basename "$study_dir")"
    local study_failures=0

    local dcm_files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && dcm_files+=("$f")
    done < <(find_dicom_files "$study_dir")

    if ((${#dcm_files[@]} == 0)); then
        return 0
    fi

    log_info "Study: $dir_name (${#dcm_files[@]} file(s))"

    local phi_failures=0
    for f in "${dcm_files[@]}"; do
        check_tags_anonymized "$f" tags_ref || ((phi_failures++)) || true
    done
    if ((phi_failures > 0)); then
        log_fail "  PHI tag check: $phi_failures file(s) with residual PHI"
        ((study_failures += phi_failures)) || true
    else
        log_pass "  PHI tag check: all clean"
    fi

    local uid_failures=0
    for f in "${dcm_files[@]}"; do
        local basename
        basename="$(basename "$f")"
        local orig="$orig_study_dir/$basename"
        if [[ -f "$orig" ]]; then
            check_uids_preserved "$orig" "$f" || ((uid_failures++)) || true
        fi
    done
    if ((uid_failures > 0)); then
        log_fail "  UID preservation: $uid_failures file(s) with changed UIDs"
        ((study_failures += uid_failures)) || true
    else
        log_pass "  UID preservation: all preserved"
    fi

    if check_study_consistency "$study_dir"; then
        log_pass "  Study consistency: consistent"
    else
        ((study_failures++)) || true
    fi

    if check_series_consistency "$study_dir"; then
        log_pass "  Series consistency: consistent"
    else
        ((study_failures++)) || true
    fi

    return "$study_failures"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac

    if (($# < 3)); then
        log_fail "Missing arguments. Expected 3, got $#."
        usage >&2
        exit 2
    fi

    local input_dir="$1"
    local output_dir="$2"
    local tags_file="$3"

    input_dir="$(realpath "$input_dir")"
    output_dir="$(realpath "$output_dir")"

    if [[ ! -d "$input_dir" ]]; then
        log_fail "Input directory not found: $input_dir"
        exit 2
    fi
    if [[ ! -d "$output_dir" ]]; then
        log_fail "Output directory not found: $output_dir"
        exit 2
    fi
    if [[ ! -f "$tags_file" ]]; then
        log_fail "Tags file not found: $tags_file"
        exit 2
    fi

    check_prerequisites

    log_header "DICOM Anonymization Validation"
    log_info "Original:    $input_dir"
    log_info "Anonymized:  $output_dir"
    log_info "Tags file:   $tags_file"

    local all_tags=()
    local tag
    while IFS= read -r tag; do
        all_tags+=("$tag")
    done < <(grep -v '^[[:space:]]*#' "$tags_file" \
        | grep -oiE '\([0-9a-f]{4},[0-9a-f]{4}\)' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[()]//g' \
        | sort -u)

    if ((${#all_tags[@]} == 0)); then
        log_fail "No valid tags found in: $tags_file"
        exit 2
    fi
    log_info "PHI tags to verify: ${#all_tags[@]}"

    log_header "Validating Studies"

    local study_dirs=()
    # Discover study directories recursively (avoid find — broken on MSYS2)
    _scan_for_studies() {
        local d f has_dcm=0
        # Check THIS directory for DICOM files
        for f in "$1"/*; do
            [[ -f "$f" ]] || continue
            if is_dicom_file "$f"; then has_dcm=1; break; fi
        done
        if ((has_dcm)); then study_dirs+=("${1%/}"); fi
        # Recurse into subdirectories
        for d in "$1"/*/; do
            [[ -d "$d" ]] || continue
            _scan_for_studies "$d"
        done
    }
    _scan_for_studies "$output_dir"

    local sorted_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && sorted_dirs+=("$dir")
    done < <(printf '%s\n' "${study_dirs[@]}" | sort)

    if ((${#sorted_dirs[@]} == 0)); then
        log_fail "No directories with DICOM files found in: $output_dir"
        exit 1
    fi

    local total_studies=0
    local failed_studies=0

    for study_dir in "${sorted_dirs[@]}"; do
        ((total_studies++)) || true

        local rel_path="${study_dir#$output_dir}"
        rel_path="${rel_path#/}"
        local orig_study_dir="$input_dir/$rel_path"

        validate_study "$study_dir" "$orig_study_dir" all_tags || ((failed_studies++)) || true
        echo ""
    done

    log_header "Summary"
    log_info "Studies checked:   $total_studies"
    if ((failed_studies > 0)); then
        log_fail "Studies with issues: $failed_studies"
        log_fail "VALIDATION FAILED"
        exit 1
    else
        log_pass "Studies with issues: 0"
        log_pass "VALIDATION PASSED"
        exit 0
    fi
}

main "$@"
