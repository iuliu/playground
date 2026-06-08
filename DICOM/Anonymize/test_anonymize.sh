#!/usr/bin/env bash
# ============================================================================
# test_anonymize.sh — End-to-end test for DICOM anonymization system.
#
# Creates synthetic DICOM files with PHI, runs anonymization, validates results.
#
# Test structure:
#   test_input/
#     study_001/          → ANON_0001
#       image_001.dcm     Series A (same series as image_002)
#       image_002.dcm     Series A
#       image_003.dcm     Series B (different series, same study)
#     study_002/          → ANON_0002
#       scan_001.dcm      Series C (same series as scan_002)
#       scan_002.dcm      Series C
# ============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly TEST_DIR="$SCRIPT_DIR/test_workspace"
readonly INPUT_DIR="$TEST_DIR/input"
readonly OUTPUT_DIR="$TEST_DIR/output"
readonly ANON_SCRIPT="$SCRIPT_DIR/anonymize_dicom.sh"
readonly VALIDATE_SCRIPT="$SCRIPT_DIR/validate_anonymized.sh"
readonly TAGS_FILE="$SCRIPT_DIR/phi_tags.txt"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        readonly DCMDUMP="dcmdump.exe"
        readonly DUMP2DCM="dump2dcm.exe"
        readonly IS_MSYS2=1
        ;;
    Linux*|Darwin*)
        if command -v "dcmdump.exe" &>/dev/null; then
            readonly DCMDUMP="dcmdump.exe"
            readonly DUMP2DCM="dump2dcm.exe"
            readonly IS_MSYS2=1
        else
            readonly DCMDUMP="dcmdump"
            readonly DUMP2DCM="dump2dcm"
            readonly IS_MSYS2=0
        fi
        ;;
    *)
        readonly DCMDUMP="dcmdump"
        readonly DUMP2DCM="dump2dcm"
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
# Unique UIDs for test files
readonly STUDY1_UID="1.2.840.999.1.1.100.1"
readonly STUDY2_UID="1.2.840.999.1.1.200.1"
readonly SERIES1A_UID="1.2.840.999.1.1.100.1.1"
readonly SERIES1B_UID="1.2.840.999.1.1.100.1.2"
readonly SERIES2C_UID="1.2.840.999.1.1.200.1.1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_section() { echo ""; echo "========== $* =========="; }
log_info()    { echo "[TEST]   $*"; }
log_pass()    { echo "[PASS]   $*"; }
log_fail()    { echo "[FAIL]   $*"; }
log_detail()  { echo "         $*"; }

cleanup() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        log_info "Cleaned up test workspace."
    fi
}

# ---------------------------------------------------------------------------
# DICOM file generation (uses printf — heredocs broken on MSYS2)
# ---------------------------------------------------------------------------

generate_dicom() {
    local output_file=""
    local sop_uid=""
    local study_uid=""
    local series_uid=""

    while (($# > 0)); do
        case "$1" in
            --output)    output_file="$2"; shift 2 ;;
            --sop-uid)   sop_uid="$2"; shift 2 ;;
            --study-uid) study_uid="$2"; shift 2 ;;
            --series-uid) series_uid="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$output_file" || -z "$sop_uid" || -z "$study_uid" || -z "$series_uid" ]]; then
        log_fail "generate_dicom: missing required arguments"
        return 1
    fi

    mkdir -p "$(dirname "$output_file")"
    local dump_file="${output_file}.dump"

    # Write dump using printf (heredocs/here-strings broken on Windows MSYS2)
    {
        printf '%s\n' \
            '(0008,0005) CS [ISO_IR 100]                             # SpecificCharacterSet' \
            '(0008,0008) CS [ORIGINAL\PRIMARY]                     # ImageType' \
            '(0008,0016) UI [1.2.840.10008.5.1.4.1.1.2]              # SOPClassUID' \
            "(0008,0018) UI [${sop_uid}]                             # SOPInstanceUID" \
            '(0008,0020) DA [20230601]                               # StudyDate' \
            '(0008,0030) TM [120000]                                 # StudyTime' \
            '(0008,0050) SH [ACC-12345]                              # AccessionNumber' \
            '(0008,0070) LO [ACME Medical]                           # Manufacturer' \
            '(0008,0080) LO [General Hospital]                       # InstitutionName' \
            '(0008,0090) PN [WILLIAMS^HENRY]                        # ReferringPhysicianName' \
            '(0008,1030) LO [BRAIN MRI]                              # StudyDescription' \
            '(0008,103E) LO [AXIAL T1]                               # SeriesDescription' \
            '(0008,1070) PN [TECHNOLOGIST^SUSAN]                     # OperatorsName' \
            '(0008,1090) LO [Somatom Plus]                           # ManufacturersModelName' \
            "(0010,0010) PN [${PATIENT_NAME}]                       # PatientName" \
            "(0010,0020) LO [${PATIENT_ID}]                         # PatientID" \
            '(0010,0030) DA [19800101]                               # PatientBirthDate' \
            '(0010,0040) CS [M]                                      # PatientSex' \
            '(0010,1010) AS [044Y]                                   # PatientAge' \
            '(0010,1020) DS [180.0]                                  # PatientSize' \
            '(0010,1030) DS [80.5]                                   # PatientWeight' \
            '(0010,1040) LO [123 Main St^^Anytown^CA^90210]          # PatientAddress' \
            '(0010,2110) LO [Penicillin]                             # Allergies' \
            '(0010,2154) SH [555-1234]                               # PatientTelephoneNumbers' \
            '(0010,4000) LT [Patient reports chronic headaches]      # PatientComments' \
            '(0018,1000) LO [SN-987654321]                           # DeviceSerialNumber' \
            '(0018,1020) LO [v4.2.1]                                 # SoftwareVersions' \
            "(0020,000D) UI [${study_uid}]                           # StudyInstanceUID" \
            "(0020,000E) UI [${series_uid}]                          # SeriesInstanceUID" \
            '(0020,0010) SH [STUDY-001]                              # StudyID' \
            '(0020,0011) IS [1]                                      # SeriesNumber' \
            "(0020,0013) IS [${INSTANCE_NUMBER}]                     # InstanceNumber" \
            '(0020,4000) LT [Image comment with PHI]                  # ImageComments' \
            '(0028,0004) CS [MONOCHROME2]                            # PhotometricInterpretation' \
            '(0028,0010) US [64]                                     # Rows' \
            '(0028,0011) US [64]                                     # Columns' \
            '(0032,1032) PN [DOE^JOHN]                               # RequestingPhysician' \
            '(0032,1033) LO [NEUROLOGY]                              # RequestingService'
    } > "$dump_file"

    if ! "$DUMP2DCM" +te "$(to_win_path "$dump_file")" "$(to_win_path "$output_file")" 2>/dev/null; then
        log_fail "dump2dcm failed for $output_file"
        log_detail "Dump file: $dump_file"
        return 1
    fi
    rm -f "$dump_file"
    return 0
}

# ---------------------------------------------------------------------------
# Test setup
# ---------------------------------------------------------------------------

setup_test_data() {
    log_section "Setting up test data"

    cleanup
    mkdir -p "$INPUT_DIR/study_001" "$INPUT_DIR/study_002"

    # --- Study 001: Patient John Doe ---
    export PATIENT_NAME="DOE^JOHN"
    export PATIENT_ID="PAT-001"

    log_info "Creating study_001 ..."

    export INSTANCE_NUMBER="1"
    generate_dicom \
        --output "$INPUT_DIR/study_001/image_001.dcm" \
        --sop-uid "1.2.840.999.1.1.100.1.100.1" \
        --study-uid "$STUDY1_UID" \
        --series-uid "$SERIES1A_UID"
    log_info "  image_001.dcm (Series A)"

    export INSTANCE_NUMBER="2"
    generate_dicom \
        --output "$INPUT_DIR/study_001/image_002.dcm" \
        --sop-uid "1.2.840.999.1.1.100.1.100.2" \
        --study-uid "$STUDY1_UID" \
        --series-uid "$SERIES1A_UID"
    log_info "  image_002.dcm (Series A — same series)"

    export INSTANCE_NUMBER="3"
    generate_dicom \
        --output "$INPUT_DIR/study_001/image_003.dcm" \
        --sop-uid "1.2.840.999.1.1.100.1.100.3" \
        --study-uid "$STUDY1_UID" \
        --series-uid "$SERIES1B_UID"
    log_info "  image_003.dcm (Series B — different series, same study)"

    # --- Study 002: Patient Jane Smith ---
    export PATIENT_NAME="SMITH^JANE"
    export PATIENT_ID="PAT-002"

    log_info "Creating study_002 ..."

    export INSTANCE_NUMBER="1"
    generate_dicom \
        --output "$INPUT_DIR/study_002/scan_001.dcm" \
        --sop-uid "1.2.840.999.1.1.200.1.200.1" \
        --study-uid "$STUDY2_UID" \
        --series-uid "$SERIES2C_UID"
    log_info "  scan_001.dcm (Series C)"

    export INSTANCE_NUMBER="2"
    generate_dicom \
        --output "$INPUT_DIR/study_002/scan_002.dcm" \
        --sop-uid "1.2.840.999.1.1.200.1.200.2" \
        --study-uid "$STUDY2_UID" \
        --series-uid "$SERIES2C_UID"
    log_info "  scan_002.dcm (Series C — same series)"

    log_pass "Test data created (5 DICOM files, 2 studies)"
}

# ---------------------------------------------------------------------------
# Verify original files contain PHI
# ---------------------------------------------------------------------------

verify_original_has_phi() {
    log_section "Verifying original files contain PHI"
    local failures=0

    local val
    val="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    if [[ "$val" == *"[DOE^JOHN]"* ]]; then
        log_pass "Original PatientName: DOE^JOHN ✓"
    else
        log_fail "Original PatientName missing or wrong: $val"
        ((failures++)) || true
    fi

    val="$("$DCMDUMP" -q +P "0008,0050" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    if [[ "$val" == *"[ACC-12345]"* ]]; then
        log_pass "Original AccessionNumber: ACC-12345 ✓"
    else
        log_fail "Original AccessionNumber missing: $val"
        ((failures++)) || true
    fi

    val="$("$DCMDUMP" -q +P "0020,000d" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    if [[ "$val" == *"[$STUDY1_UID]"* ]]; then
        log_pass "Original StudyInstanceUID present ✓"
    else
        log_fail "Original StudyInstanceUID missing: $val"
        ((failures++)) || true
    fi

    return "$failures"
}

# ---------------------------------------------------------------------------
# Run anonymization
# ---------------------------------------------------------------------------

run_anonymization() {
    log_section "Running anonymization"
    if ! bash "$ANON_SCRIPT" "$INPUT_DIR" "$OUTPUT_DIR" "$TAGS_FILE"; then
        log_fail "Anonymization script failed"
        return 1
    fi
    log_pass "Anonymization completed successfully"
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Value extraction helper
# ---------------------------------------------------------------------------

extract_dcm_val() {
    local raw="$1"
    if [[ "$raw" == *"["*"]"* ]]; then
        local v="${raw#*[}"
        echo "${v%%]*}"
    else
        echo "$raw"
    fi
}

# ---------------------------------------------------------------------------
# Manual verification checks
# ---------------------------------------------------------------------------
verify_anonymized() {
    log_section "Verifying anonymized output"
    local failures=0

    # Check 1: Sequential naming
    log_info "Check 1: Sequential naming (ANON_0001, ANON_0002)"
    local name1 name2 id1 id2 acc1 acc2
    name1="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    id1="$("$DCMDUMP" -q +P "0010,0020" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    acc1="$("$DCMDUMP" -q +P "0008,0050" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    name2="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$OUTPUT_DIR/study_002/scan_001.dcm")" 2>/dev/null)"
    id2="$("$DCMDUMP" -q +P "0010,0020" "$(to_win_path "$OUTPUT_DIR/study_002/scan_001.dcm")" 2>/dev/null)"
    acc2="$("$DCMDUMP" -q +P "0008,0050" "$(to_win_path "$OUTPUT_DIR/study_002/scan_001.dcm")" 2>/dev/null)"

    [[ "$name1" == *"[ANON_0001]"* ]] && log_pass "Study 1 PatientName = ANON_0001 ✓" || { log_fail "Study 1 PatientName: got $name1"; ((failures++)) || true; }
    [[ "$id1"   == *"[PID_0001]"*  ]] && log_pass "Study 1 PatientID = PID_0001 ✓"   || { log_fail "Study 1 PatientID: got $id1"; ((failures++)) || true; }
    [[ "$acc1"  == *"[ACC_0001]"*  ]] && log_pass "Study 1 AccessionNumber = ACC_0001 ✓" || { log_fail "Study 1 AccessionNumber: got $acc1"; ((failures++)) || true; }
    [[ "$name2" == *"[ANON_0002]"* ]] && log_pass "Study 2 PatientName = ANON_0002 ✓" || { log_fail "Study 2 PatientName: got $name2"; ((failures++)) || true; }
    [[ "$id2"   == *"[PID_0002]"*  ]] && log_pass "Study 2 PatientID = PID_0002 ✓"   || { log_fail "Study 2 PatientID: got $id2"; ((failures++)) || true; }
    [[ "$acc2"  == *"[ACC_0002]"*  ]] && log_pass "Study 2 AccessionNumber = ACC_0002 ✓" || { log_fail "Study 2 AccessionNumber: got $acc2"; ((failures++)) || true; }

    # Check 2: PHI removal
    log_info "Check 2: PHI tags emptied"
    local val

    val="$("$DCMDUMP" -q +P "0008,1030" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$val" == *"(no value available)"* || -z "$val" ]] && log_pass "StudyDescription emptied ✓" || { log_fail "StudyDescription not emptied: $val"; ((failures++)) || true; }

    val="$("$DCMDUMP" -q +P "0010,0030" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$val" == *"(no value available)"* || -z "$val" ]] && log_pass "PatientBirthDate emptied ✓" || { log_fail "PatientBirthDate not emptied: $val"; ((failures++)) || true; }

    val="$("$DCMDUMP" -q +P "0010,4000" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$val" == *"(no value available)"* || -z "$val" ]] && log_pass "PatientComments emptied ✓" || { log_fail "PatientComments not emptied: $val"; ((failures++)) || true; }

    # Check 3: UID preservation
    log_info "Check 3: UID preservation"
    local orig_uid anon_uid
    orig_uid="$("$DCMDUMP" -q +P "0020,000d" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    anon_uid="$("$DCMDUMP" -q +P "0020,000d" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$orig_uid" == "$anon_uid" ]] && log_pass "StudyInstanceUID preserved ✓" || { log_fail "StudyInstanceUID changed!"; ((failures++)) || true; }

    orig_uid="$("$DCMDUMP" -q +P "0020,000e" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    anon_uid="$("$DCMDUMP" -q +P "0020,000e" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$orig_uid" == "$anon_uid" ]] && log_pass "SeriesInstanceUID preserved ✓" || { log_fail "SeriesInstanceUID changed!"; ((failures++)) || true; }

    orig_uid="$("$DCMDUMP" -q +P "0008,0018" "$(to_win_path "$INPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    anon_uid="$("$DCMDUMP" -q +P "0008,0018" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    [[ "$orig_uid" == "$anon_uid" ]] && log_pass "SOPInstanceUID preserved ✓" || { log_fail "SOPInstanceUID changed!"; ((failures++)) || true; }

    # Check 4: Study-level consistency
    log_info "Check 4: Study-level consistency"
    local n1 n2 n3 i1 i2 i3
    n1="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    n2="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$OUTPUT_DIR/study_001/image_002.dcm")" 2>/dev/null)"
    n3="$("$DCMDUMP" -q +P "0010,0010" "$(to_win_path "$OUTPUT_DIR/study_001/image_003.dcm")" 2>/dev/null)"
    [[ "$n1" == "$n2" && "$n2" == "$n3" && -n "$n1" ]] && log_pass "PatientName consistent across study_001 ✓" || { log_fail "PatientName inconsistent: [$n1] [$n2] [$n3]"; ((failures++)) || true; }

    i1="$("$DCMDUMP" -q +P "0010,0020" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    i2="$("$DCMDUMP" -q +P "0010,0020" "$(to_win_path "$OUTPUT_DIR/study_001/image_002.dcm")" 2>/dev/null)"
    i3="$("$DCMDUMP" -q +P "0010,0020" "$(to_win_path "$OUTPUT_DIR/study_001/image_003.dcm")" 2>/dev/null)"
    [[ "$i1" == "$i2" && "$i2" == "$i3" && -n "$i1" ]] && log_pass "PatientID consistent across study_001 ✓" || { log_fail "PatientID inconsistent: [$i1] [$i2] [$i3]"; ((failures++)) || true; }

    # Check 5: Series-level consistency
    log_info "Check 5: Series-level consistency"
    local sd1 sd2
    sd1="$("$DCMDUMP" -q +P "0008,103e" "$(to_win_path "$OUTPUT_DIR/study_001/image_001.dcm")" 2>/dev/null)"
    sd2="$("$DCMDUMP" -q +P "0008,103e" "$(to_win_path "$OUTPUT_DIR/study_001/image_002.dcm")" 2>/dev/null)"
    [[ "$sd1" == "$sd2" ]] && log_pass "SeriesDescription consistent within Series A ✓" || { log_fail "SeriesDescription inconsistent: [$sd1] [$sd2]"; ((failures++)) || true; }


    return "$failures"
}

# ---------------------------------------------------------------------------
# Run validation script
# ---------------------------------------------------------------------------

run_validation_script() {
    log_section "Running validation script"
    local exit_code=0
    bash "$VALIDATE_SCRIPT" "$INPUT_DIR" "$OUTPUT_DIR" "$TAGS_FILE" || exit_code=$?
    if ((exit_code == 0)); then
        log_pass "Validation script PASSED"
    else
        log_fail "Validation script FAILED (exit code: $exit_code)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Edge case: empty directory
# ---------------------------------------------------------------------------

test_empty_dir_skipped() {
    log_section "Edge case: empty directories skipped"
    local td_in="$TEST_DIR/empty_input"
    local td_out="$TEST_DIR/empty_output"
    rm -rf "$td_in" "$td_out"
    mkdir -p "$td_in/empty_dir"
    if bash "$ANON_SCRIPT" "$td_in" "$td_out" "$TAGS_FILE" 2>&1; then
        log_fail "Should have failed: no DICOM files found"
        return 1
    else
        log_pass "Correctly detected no DICOM files ✓"
    fi
    rm -rf "$td_in" "$td_out"
    return 0
}

# ---------------------------------------------------------------------------
# Edge case: non-DICOM files ignored
# ---------------------------------------------------------------------------

test_non_dicom_ignored() {
    log_section "Edge case: non-DICOM files ignored"
    local td_in="$TEST_DIR/mixed_input"
    local td_out="$TEST_DIR/mixed_output"
    rm -rf "$td_in" "$td_out"
    mkdir -p "$td_in"
    echo "This is not a DICOM file" > "$td_in/readme.txt"

    export PATIENT_NAME="TEST^CASE" PATIENT_ID="PAT-JUNK" INSTANCE_NUMBER="1"
    generate_dicom \
        --output "$td_in/valid.dcm" \
        --sop-uid "1.2.840.999.1.1.999.1.999.1" \
        --study-uid "1.2.840.999.1.1.999.1" \
        --series-uid "1.2.840.999.1.1.999.1.1"

    if bash "$ANON_SCRIPT" "$td_in" "$td_out" "$TAGS_FILE" 2>&1; then
        if [[ -f "$td_out/valid.dcm" ]] && [[ ! -f "$td_out/readme.txt" ]]; then
            log_pass "Non-DICOM file correctly ignored ✓"
        else
            log_fail "Unexpected files in output"
            return 1
        fi
    else
        log_fail "Anonymization failed for mixed directory"
        return 1
    fi
    rm -rf "$td_in" "$td_out"
    return 0
}

# ---------------------------------------------------------------------------
# Test: detailed error messages on dcmodify failure
# ---------------------------------------------------------------------------

test_detailed_error_messages() {
    log_section "Test: detailed error messages on dcmodify failure"
    local td="$TEST_DIR/error_detail"
    rm -rf "$td"
    mkdir -p "$td"

    # Create a valid DICOM file with known SOPInstanceUID
    export PATIENT_NAME="ERROR^TEST" PATIENT_ID="PAT-ERR" INSTANCE_NUMBER="1"
    if ! generate_dicom \
        --output "$td/test_001.dcm" \
        --sop-uid "1.2.840.999.ERROR.1" \
        --study-uid "1.2.840.999.ERROR" \
        --series-uid "1.2.840.999.ERROR.1"; then
        log_fail "Failed to create test DICOM file"
        rm -rf "$td"
        return 1
    fi

    if [[ ! -f "$td/test_001.dcm" ]]; then
        log_fail "Test DICOM file not created"
        rm -rf "$td"
        return 1
    fi

    # Create a custom tags file
    local tags_file="$td/custom_tags.txt"
    printf '(0010,0010)\n(0010,0020)\n(0008,0090)\n' > "$tags_file"

    # Make the file read-only so dcmodify fails when trying to write back.
    # Use attrib.exe (Windows native) because chmod -w is unreliable on WSL /mnt/ mounts.
    attrib.exe +R "$(to_win_path "$td/test_001.dcm")" 2>/dev/null || chmod -w "$td/test_001.dcm"

    # Source the anonymize script (with main overridden) and call anonymize_file.
    # Pass paths via environment so a quoted heredoc keeps $tag literal for inner bash.
    export TD_PATH="$td"
    export TAGS_PATH="$tags_file"
    export ANON_PATH="$ANON_SCRIPT"
    local captured
    captured=$(bash 2>&1 <<'INNER'
export ANON_SOURCED=1
source "$ANON_PATH"
_run_test() {
local tags=()
local tag
while IFS= read -r tag; do tags+=("$tag"); done < <(parse_tags_file "$TAGS_PATH")
anonymize_file "$TD_PATH/test_001.dcm" "ANON_ERROR_TEST" "PID_ERROR_TEST" "ACC_ERROR_TEST" tags
}
_run_test
INNER
)

    local failures=0

    # Check SOPInstanceUID appears in output
    if echo "$captured" | grep -qF '1.2.840.999.ERROR.1'; then
        log_pass "Error contains SOPInstanceUID ✓"
    else
        log_fail "Error missing SOPInstanceUID"
        log_detail "Expected: 1.2.840.999.ERROR.1"
        log_detail "Output:"
        echo "$captured"
        ((failures++)) || true
    fi

    # Check file name appears in output
    if echo "$captured" | grep -qF 'test_001.dcm'; then
        log_pass "Error contains file name ✓"
    else
        log_fail "Error missing file name"
        log_detail "Output:"
        echo "$captured"
        ((failures++)) || true
    fi

    # Check DICOM tag appears in output (the tag that failed)
    if echo "$captured" | grep -qE '\(0010,0010\)|\(0010,0020\)|\(0008,0090\)'; then
        log_pass "Error contains DICOM tag ✓"
    else
        log_fail "Error missing DICOM tag reference"
        log_detail "Output:"
        echo "$captured"
        ((failures++)) || true
    fi

    # Check DCMTK error message appears
    if echo "$captured" | grep -qiE '(error|unable|cannot|denied|fail)'; then
        log_pass "Error contains DCMTK error message ✓"
    else
        log_fail "Error missing DCMTK error message"
        log_detail "Output:"
        echo "$captured"
        ((failures++)) || true
    fi

    # Check the overall file summary warning (N tag(s) could not be anonymized)
    if echo "$captured" | grep -qE 'tag\(s\) could not be anonymized'; then
        log_pass "Error contains tag failure summary ✓"
    else
        log_fail "Error missing tag failure summary"
        log_detail "Output:"
        echo "$captured"
        ((failures++)) || true
    fi

    rm -rf "$td"
    return "$failures"
}

# ---------------------------------------------------------------------------
# Main test runner
# ---------------------------------------------------------------------------

main() {
    log_section "DICOM Anonymization — Test Suite"
    local total_failures=0

    setup_test_data || { log_fail "Setup failed"; exit 1; }
    verify_original_has_phi || ((total_failures++)) || true
    run_anonymization || ((total_failures++)) || true
    verify_anonymized || ((total_failures++)) || true
    run_validation_script || ((total_failures++)) || true
    test_empty_dir_skipped || ((total_failures++)) || true
    test_non_dicom_ignored || ((total_failures++)) || true
    test_detailed_error_messages || ((total_failures++)) || true

    log_section "Test Results"
    if ((total_failures == 0)); then
        log_pass "ALL CHECKS PASSED"
        cleanup
        exit 0
    else
        log_fail "$total_failures check(s) FAILED"
        log_info "Test workspace preserved at: $TEST_DIR"
        exit 1
    fi
}

main "$@"
