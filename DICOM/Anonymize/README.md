# DICOM Anonymization Toolkit

Recursively anonymize DICOM files using DCMTK command-line tools. Each directory containing DICOM files is treated as a separate study, maintaining STUDY-level and SERIES-level consistency while stripping all Protected Health Information (PHI).

## Project Structure

```
DICOM/Anonymize/
├── anonymize_dicom.sh      # Main anonymization script
├── validate_anonymized.sh  # Post-anonymization validation script
├── phi_tags.txt            # PHI-containing DICOM tags (Safe Harbor profile)
├── test_anonymize.sh       # End-to-end test harness
└── README.md               # This file
```

## DICOM Information Model

The scripts respect the DICOM Patient → Study → Series → Instance hierarchy:

| Level | Identified by | Tag | Modified? |
|-------|--------------|-----|-----------|
| Patient | Patient ID | (0010,0020) | Yes → `ANON_NNNN` |
| Study | Study Instance UID | (0020,000D) | **Never** |
| Series | Series Instance UID | (0020,000E) | **Never** |
| Instance | SOP Instance UID | (0008,0018) | **Never** |

## Anonymization Strategy

- **Patient Name** → `ANON_NNNN` (sequential per study: 0001, 0002, ...)
- **Patient ID** → `PID_NNNN` (unique per study, distinct from Patient Name)
- **Accession Number** → `ACC_NNNN` (unique per study, distinct from Patient Name/ID)
- **Dates** → emptied
- **All other PHI tags** → emptied
- **Sequence (SQ) tags** → emptied with `-e` flag (containers of nested tags, not modifiable via value assignment)
- **UIDs** → preserved (never modified)
- **Study consistency**: all files in a study directory share the same anonymous Patient Name and ID
- **Series consistency**: files with the same Series Instance UID share consistent series-level attributes
- **Output**: copies anonymized files to an output directory, mirroring the input structure (originals untouched)

## Prerequisites

- [DCMTK](https://dicom.offis.de/dcmtk.php.en) (`dcmodify`, `dcmdump`)
- Bash ≥ 4.0

### Installation by platform

| Platform | Install | Path conversion |
|----------|---------|----------------|
| Linux/macOS | `apt install dcmtk` / `dnf install dcmtk` / `brew install dcmtk` | None — native binaries |
| WSL | Same as Linux distro above, or use Windows DCMTK via `/mnt/c/` | Auto-detected — converted when needed |
| Windows (Git Bash) | `choco install dcmtk` | Auto-detected — MSYS2 paths converted |

The scripts auto-detect the environment (MSYS2, WSL, or native Linux/macOS) and select the correct tool names and path format.

## Usage

### Anonymize

```bash
./anonymize_dicom.sh <input_dir> <output_dir> <tags_file>
```

**Example:**
```bash
./anonymize_dicom.sh ./original_scans ./anonymized_scans ./phi_tags.txt
```

### Validate

```bash
./validate_anonymized.sh <input_dir> <output_dir> <tags_file>
```

**Example:**
```bash
./validate_anonymized.sh ./original_scans ./anonymized_scans ./phi_tags.txt
```

The validation script checks:
1. All PHI tags are emptied or replaced with anonymous values
2. Study, Series, and SOP Instance UIDs are preserved
3. Study-level attributes are consistent within each study directory
4. Series-level attributes are consistent within each series (same Series UID)

**Exit codes:** `0` = all passed, `1` = validation errors, `2` = usage/prerequisite error.

### Tags File Format

One tag per line in `(gggg,eeee)` format. Comments start with `#`.

```txt
(0010,0010)  # Patient's Name
(0010,0020)  # Patient ID
(0010,0030)  # Patient's Birth Date
(0008,0050)  # Accession Number
...
```

The included `phi_tags.txt` contains 74 PHI tags based on the DICOM PS3.15 Table E.1-1 Safe Harbor de-identification profile.

### Adding Custom Tags

Edit `phi_tags.txt` or create your own tags file. Tags listed there that match the protected UID list are automatically skipped during anonymization.

## Testing

```bash
./test_anonymize.sh
```

The test harness:
1. Creates synthetic DICOM files with PHI in a 2-study, 5-file structure
2. Verifies original files contain expected PHI
3. Runs the anonymization script
4. Checks sequential naming (`ANON_0001`, `ANON_0002`)
5. Checks PHI removal, UID preservation, study/series consistency
6. Runs the validation script for automated verification
7. Tests edge cases (empty directories, non-DICOM files)
8. Validates detailed error messages when `dcmodify` fails (SOPInstanceUID, file, tag, DCMTK error)
Test workspace is created under `test_workspace/` and cleaned up on success.
## Notes

- Empty directories and non-DICOM files are silently skipped.
- UID tags are protected regardless of tags file content.
- Platform detection selects correct tool names (`.exe` on Windows/WSL, bare names on Linux/macOS).
- Paths are converted to Windows format only when running Windows-native DCMTK binaries.
- If a file fails anonymization, the script retries tag-by-tag and reports the **SOPInstanceUID, file name, failing tag, and DCMTK error** for each failure.
- The 5 Sequence (SQ) tags in `phi_tags.txt` (`0010,0050`, `0010,1002`, `0008,1049`, `0008,1110`, `0040,0275`) use `dcmodify -e` to remove their nested items. They are not modifiable with `-ma "(tag)="` in real DICOM files.
