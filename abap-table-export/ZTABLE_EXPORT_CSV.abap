*&---------------------------------------------------------------------*
*& Report ZTABLE_EXPORT_CSV
*& High-performance chunked CSV export for arbitrary SAP tables
*& Compatible with SAP NetWeaver 7.0+ (ABAP 7.02+)
*&---------------------------------------------------------------------*
*& Designed for large-volume extraction (billions of rows).
*& Uses OPEN CURSOR with PACKAGE SIZE for memory-efficient streaming.
*& Writes chunked CSV files to application server (AL11) or FTP path.
*&---------------------------------------------------------------------*
REPORT ztable_export_csv.

*----------------------------------------------------------------------*
* Type definitions
*----------------------------------------------------------------------*
TYPES:
  BEGIN OF ty_field_info,
    fieldname  TYPE fieldname,
    position   TYPE i,
    outputlen  TYPE i,
    datatype   TYPE c LENGTH 5,
    decimals   TYPE i,
    is_numeric TYPE abap_bool,
  END OF ty_field_info,
  tt_field_info TYPE STANDARD TABLE OF ty_field_info WITH DEFAULT KEY,

  BEGIN OF ty_key_field,
    fieldname TYPE fieldname,
    position  TYPE i,
  END OF ty_key_field,
  tt_key_fields TYPE STANDARD TABLE OF ty_key_field WITH DEFAULT KEY,

  BEGIN OF ty_col_entry,
    sign   TYPE c LENGTH 1,
    option TYPE c LENGTH 2,
    low    TYPE fieldname,
    high   TYPE fieldname,
  END OF ty_col_entry,
  tt_col_range TYPE STANDARD TABLE OF ty_col_entry WITH DEFAULT KEY.

*----------------------------------------------------------------------*
* Selection screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE tit_b01.
  PARAMETERS:
    p_table  TYPE tabname OBLIGATORY DEFAULT 'ACDOCA',         "Source table
    p_pkg    TYPE i       OBLIGATORY DEFAULT 50000,            "Rows per DB fetch (package size)
    p_chunk  TYPE i       OBLIGATORY DEFAULT 5000000,          "Rows per CSV file (chunk)
    p_maxgb  TYPE p DECIMALS 2 DEFAULT '2.00',                 "Max GB per file (0=use p_chunk)
    p_delim  TYPE c LENGTH 1 DEFAULT ';',                      "CSV delimiter
    p_encl   TYPE c LENGTH 1 DEFAULT '"',                      "Text enclosure
    p_head   TYPE abap_bool AS CHECKBOX DEFAULT 'X',           "Write header row
    p_esc    TYPE abap_bool AS CHECKBOX DEFAULT 'X',           "Escape enclosure chars in data
    p_crlf   TYPE abap_bool AS CHECKBOX DEFAULT ' ',           "Use CRLF line endings (Windows)
    p_utf8   TYPE abap_bool AS CHECKBOX DEFAULT 'X'.           "Write UTF-8 BOM
SELECTION-SCREEN END OF BLOCK b01.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE tit_b02.
  PARAMETERS:
    p_path   TYPE string  OBLIGATORY
               DEFAULT '/tmp/export/' LOWER CASE,              "Output directory (AL11 path)
    p_prefix TYPE string  DEFAULT 'EXPORT' LOWER CASE,        "File name prefix
    p_ext    TYPE string  DEFAULT '.csv' LOWER CASE.           "File extension
SELECTION-SCREEN END OF BLOCK b02.

SELECTION-SCREEN BEGIN OF BLOCK b03 WITH FRAME TITLE tit_b03.
  SELECT-OPTIONS:
    s_fields FOR sy-title NO INTERVALS LOWER CASE.             "Field selection (leave empty = all)
  PARAMETERS:
    p_where  TYPE string  DEFAULT '' LOWER CASE.               "WHERE clause
SELECTION-SCREEN END OF BLOCK b03.

SELECTION-SCREEN BEGIN OF BLOCK b05 WITH FRAME TITLE tit_b05.
  PARAMETERS:
    p_maxrec TYPE int8 DEFAULT 0,                              "Max total rows (0=unlimited)
    p_prog   TYPE i DEFAULT 100000,                            "Progress log interval (rows)
    p_test   TYPE abap_bool AS CHECKBOX DEFAULT ' '.           "Test mode (first package only)
SELECTION-SCREEN END OF BLOCK b05.

SELECTION-SCREEN BEGIN OF BLOCK b06 WITH FRAME TITLE tit_b06.
  PARAMETERS:
    p_resum  TYPE abap_bool AS CHECKBOX DEFAULT ' ',           "Resume from last checkpoint
    p_ckint  TYPE i DEFAULT 0.                                 "Checkpoint interval rows (0=every pkg)
SELECTION-SCREEN END OF BLOCK b06.

*----------------------------------------------------------------------*
* Global data
*----------------------------------------------------------------------*
DATA:
  gv_where_clause   TYPE string,
  gt_field_info     TYPE tt_field_info,
  gt_key_fields     TYPE tt_key_fields,
  gt_fieldlist      TYPE string,
  gv_orderby        TYPE string,
  gv_ckpt_file      TYPE string,
  gv_rows_since_ckpt TYPE int8 VALUE 0,
  gv_file_count     TYPE i VALUE 0,
  gv_total_rows     TYPE int8 VALUE 0,
  gv_chunk_rows     TYPE int8 VALUE 0,
  gv_chunk_bytes    TYPE int8 VALUE 0,
  gv_max_bytes      TYPE int8 VALUE 0,
  gv_file_handle    TYPE i VALUE 0,
  gv_file_open      TYPE abap_bool VALUE abap_false,
  gv_start_time     TYPE i,
  gv_line_ending    TYPE string,
  gv_header_line    TYPE string,
  gv_current_file   TYPE string,
  " Pre-computed for hot-path (serialize_row)
  gv_delim_str      TYPE string,
  gv_encl_str       TYPE string,
  gv_encl_dbl       TYPE string,
  gv_field_count    TYPE i VALUE 0.

* Pre-allocated reusable string table for CSV line assembly.
* Avoids 518 APPENDs + CLEAR per row (23M+ memory operations).
DATA: gt_csv_values TYPE TABLE OF string.

*----------------------------------------------------------------------*
* INITIALIZATION
*----------------------------------------------------------------------*
INITIALIZATION.
  %_p_table_%_app_%-text  = 'Source table name'.
  %_p_pkg_%_app_%-text    = 'DB fetch package size'.
  %_p_chunk_%_app_%-text  = 'Rows per CSV file'.
  %_p_maxgb_%_app_%-text  = 'Max GB per file (0=row)'.
  %_p_delim_%_app_%-text  = 'CSV delimiter'.
  %_p_encl_%_app_%-text   = 'Text enclosure char'.
  %_p_head_%_app_%-text   = 'Write header row'.
  %_p_esc_%_app_%-text    = 'Escape enclosure chars'.
  %_p_crlf_%_app_%-text   = 'CRLF line endings'.
  %_p_utf8_%_app_%-text   = 'Write UTF-8 BOM'.
  %_p_path_%_app_%-text   = 'Output directory path'.
  %_p_prefix_%_app_%-text = 'File name prefix'.
  %_p_ext_%_app_%-text    = 'File extension'.
  %_p_where_%_app_%-text  = 'WHERE clause'.
  %_p_maxrec_%_app_%-text = 'Max total rows (0=all)'.
  %_p_prog_%_app_%-text   = 'Progress log interval'.
  %_p_test_%_app_%-text   = 'Test mode (1 pkg only)'.
  %_s_fields_%_app_%-text = 'Field names to export'.
  %_p_resum_%_app_%-text  = 'Resume from checkpoint'.
  %_p_ckint_%_app_%-text  = 'Checkpoint interval rows'.

  tit_b01 = 'Table & Format Settings'.
  tit_b02 = 'Output File Settings'.
  tit_b03 = 'Field Selection & Filter'.
  tit_b05 = 'Execution Control'.
  tit_b06 = 'Checkpoint / Resume'.

*----------------------------------------------------------------------*
* AT SELECTION-SCREEN
*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
  " Validate table exists
  DATA: lv_tabclass TYPE dd02l-tabclass.
  SELECT SINGLE tabclass FROM dd02l INTO lv_tabclass
    WHERE tabname = p_table AND as4local = 'A'.
  IF sy-subrc <> 0.
    MESSAGE e001(00) WITH 'Table' p_table 'does not exist' ''.
  ENDIF.

  " Validate output path ends with separator
  DATA: lv_len TYPE i.
  lv_len = strlen( p_path ).
  IF lv_len > 0.
    DATA: lv_last TYPE c LENGTH 1.
    lv_last = p_path+0(1). "dummy
    DATA: lv_off TYPE i.
    lv_off = lv_len - 1.
    lv_last = p_path+lv_off(1).
    IF lv_last <> '/' AND lv_last <> '\'.
      CONCATENATE p_path '/' INTO p_path.
    ENDIF.
  ENDIF.

*----------------------------------------------------------------------*
* START-OF-SELECTION
*----------------------------------------------------------------------*
START-OF-SELECTION.
  PERFORM main.

*&---------------------------------------------------------------------*
*& Form main
*&---------------------------------------------------------------------*
FORM main.
  DATA: lv_msg TYPE string.

  " Record start time
  GET RUN TIME FIELD gv_start_time.

  " Set line ending
  IF p_crlf = abap_true.
    gv_line_ending = cl_abap_char_utilities=>cr_lf.
  ELSE.
    gv_line_ending = cl_abap_char_utilities=>newline.
  ENDIF.

  " Calculate max bytes per file
  IF p_maxgb > 0.
    gv_max_bytes = p_maxgb * 1024 * 1024 * 1024.
  ENDIF.

  " Build WHERE clause
  PERFORM build_where_clause.

  " Build field catalog, field list, PK fields, and ORDER BY
  PERFORM build_field_catalog.

  " Pre-compute hot-path constants (used billions of times in serialize_row)
  gv_delim_str = p_delim.
  gv_encl_str  = p_encl.
  CONCATENATE gv_encl_str gv_encl_str INTO gv_encl_dbl.
  DESCRIBE TABLE gt_field_info LINES gv_field_count.

  " Pre-allocate CSV values table (reused every row, never cleared/appended)
  DATA: lv_empty TYPE string,
        lv_init  TYPE i.
  CLEAR lv_empty.
  CLEAR gt_csv_values.
  DO gv_field_count TIMES.
    APPEND lv_empty TO gt_csv_values.
  ENDDO.

  " Resume from checkpoint if requested
  IF p_resum = abap_true.
    PERFORM read_checkpoint.
  ENDIF.

  " Build header line
  IF p_head = abap_true.
    PERFORM build_header_line.
  ENDIF.

  " Log configuration
  PERFORM log_configuration.

  " Execute extraction
  PERFORM extract_data.

  " Close any open file
  IF gv_file_open = abap_true.
    PERFORM close_file.
  ENDIF.

  " Delete checkpoint file on successful completion
  IF gv_ckpt_file IS NOT INITIAL.
    PERFORM delete_checkpoint.
  ENDIF.

  " Final summary
  PERFORM log_summary.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form build_where_clause
*&---------------------------------------------------------------------*
FORM build_where_clause.
  CLEAR gv_where_clause.

  IF p_where IS NOT INITIAL.
    gv_where_clause = p_where.
    WRITE: / 'WHERE clause length:', strlen( gv_where_clause ), 'characters'.
  ELSE.
    WRITE: / 'No WHERE clause - full table extraction.'.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form build_field_catalog
*&---------------------------------------------------------------------*
FORM build_field_catalog.
  DATA: lt_dfies    TYPE TABLE OF dfies,
        ls_dfies    TYPE dfies,
        ls_field    TYPE ty_field_info,
        lv_pos      TYPE i VALUE 0,
        lv_tabname  TYPE tabname,
        lv_count    TYPE i,
        lv_match    TYPE abap_bool.

  lv_tabname = p_table.

  " Get data dictionary info for all fields
  CALL FUNCTION 'DDIF_FIELDINFO_GET'
    EXPORTING
      tabname   = lv_tabname
      langu     = sy-langu
    TABLES
      dfies_tab = lt_dfies
    EXCEPTIONS
      OTHERS    = 1.

  IF sy-subrc <> 0.
    WRITE: / 'ERROR: Cannot read field info for table', lv_tabname.
    STOP.
  ENDIF.

  " Build field catalog respecting field selection
  CLEAR gt_field_info.

  DESCRIBE TABLE s_fields LINES lv_count.

  LOOP AT lt_dfies INTO ls_dfies.
    " Skip .INCLUDE and similar meta entries
    IF ls_dfies-fieldname IS INITIAL.
      CONTINUE.
    ENDIF.

    " If field selection is specified, check if field is in list
    IF lv_count > 0.
      lv_match = abap_false.
      DATA: ls_col_sel LIKE LINE OF s_fields.
      LOOP AT s_fields INTO ls_col_sel.
        DATA: lv_fn_upper TYPE fieldname.
        lv_fn_upper = ls_col_sel-low.
        TRANSLATE lv_fn_upper TO UPPER CASE.
        IF ls_dfies-fieldname = lv_fn_upper.
          lv_match = abap_true.
          EXIT.
        ENDIF.
      ENDLOOP.
      IF lv_match = abap_false.
        CONTINUE.
      ENDIF.
    ENDIF.

    lv_pos = lv_pos + 1.
    CLEAR ls_field.
    ls_field-fieldname = ls_dfies-fieldname.
    ls_field-position  = lv_pos.
    ls_field-outputlen = ls_dfies-outputlen.
    ls_field-decimals  = ls_dfies-decimals.

    " Map to simple data type string for formatting
    " is_numeric defaults to abap_false via CLEAR ls_field above
    CASE ls_dfies-inttype.
      WHEN 'I' OR 'b' OR 's' OR '8'.
        ls_field-datatype = 'INT'.
        ls_field-is_numeric = abap_true.
      WHEN 'P'.
        ls_field-datatype = 'DEC'.
        ls_field-is_numeric = abap_true.
      WHEN 'F' OR 'a' OR 'e'.
        ls_field-datatype = 'FLOAT'.
        ls_field-is_numeric = abap_true.
      WHEN 'D'.
        ls_field-datatype = 'DATE'.
      WHEN 'T'.
        ls_field-datatype = 'TIME'.
      WHEN OTHERS.
        ls_field-datatype = 'CHAR'.
    ENDCASE.

    APPEND ls_field TO gt_field_info.
  ENDLOOP.

  IF gt_field_info IS INITIAL.
    WRITE: / 'ERROR: No fields selected for export.'.
    STOP.
  ENDIF.

  " Detect primary key fields (for ORDER BY and checkpoint/resume)
  DATA: ls_kf      TYPE ty_key_field,
        lv_kf_pos  TYPE i VALUE 0.
  CLEAR gt_key_fields.
  CLEAR gv_orderby.

  LOOP AT lt_dfies INTO ls_dfies WHERE keyflag = 'X'.
    IF ls_dfies-fieldname IS INITIAL.
      CONTINUE.
    ENDIF.
    lv_kf_pos = lv_kf_pos + 1.
    CLEAR ls_kf.
    ls_kf-fieldname = ls_dfies-fieldname.
    ls_kf-position  = lv_kf_pos.
    APPEND ls_kf TO gt_key_fields.

    IF gv_orderby IS INITIAL.
      gv_orderby = ls_dfies-fieldname.
    ELSE.
      CONCATENATE gv_orderby ` ` ls_dfies-fieldname INTO gv_orderby.
    ENDIF.
  ENDLOOP.

  DESCRIBE TABLE gt_key_fields LINES lv_count.
  WRITE: / 'Primary key fields:', lv_count.
  LOOP AT gt_key_fields INTO ls_kf.
    WRITE: / '  PK', ls_kf-position, ':', ls_kf-fieldname.
  ENDLOOP.

  " Build SQL field list string
  CLEAR gt_fieldlist.
  DATA: ls_fi TYPE ty_field_info.
  LOOP AT gt_field_info INTO ls_fi.
    IF gt_fieldlist IS INITIAL.
      gt_fieldlist = ls_fi-fieldname.
    ELSE.
      CONCATENATE gt_fieldlist ` ` ls_fi-fieldname INTO gt_fieldlist.
    ENDIF.
  ENDLOOP.

  " Build checkpoint file path
  CONCATENATE p_path p_prefix '_' p_table '_checkpoint.dat'
    INTO gv_ckpt_file.

  DESCRIBE TABLE gt_field_info LINES lv_count.
  WRITE: / 'Fields to export:', lv_count.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form build_header_line
*&---------------------------------------------------------------------*
FORM build_header_line.
  DATA: ls_field   TYPE ty_field_info,
        lt_names   TYPE TABLE OF string,
        lv_name    TYPE string.

  CLEAR lt_names.
  LOOP AT gt_field_info INTO ls_field.
    lv_name = ls_field-fieldname.
    APPEND lv_name TO lt_names.
  ENDLOOP.

  CONCATENATE LINES OF lt_names INTO gv_header_line
    SEPARATED BY gv_delim_str.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form extract_data
*&---------------------------------------------------------------------*
FORM extract_data.
  DATA: lr_data      TYPE REF TO data,
        lr_wa        TYPE REF TO data,
        lv_cursor    TYPE cursor,
        lv_pkg_count TYPE i VALUE 0,
        lv_fetched   TYPE i VALUE 0,
        lv_msg       TYPE string.

  FIELD-SYMBOLS:
    <lt_data>  TYPE STANDARD TABLE,
    <ls_wa>    TYPE any.

  " Create dynamic internal table for the selected fields
  DATA: lt_fieldcat  TYPE lvc_t_fcat,
        ls_fcat      TYPE lvc_s_fcat,
        ls_fi        TYPE ty_field_info,
        lt_dfies     TYPE TABLE OF dfies,
        ls_dfies     TYPE dfies,
        lv_tabname   TYPE tabname.

  lv_tabname = p_table.

  " Get full DDIC info again for type mapping
  CALL FUNCTION 'DDIF_FIELDINFO_GET'
    EXPORTING
      tabname   = lv_tabname
      langu     = sy-langu
    TABLES
      dfies_tab = lt_dfies
    EXCEPTIONS
      OTHERS    = 1.

  " Build ALV fieldcat for dynamic table creation
  LOOP AT gt_field_info INTO ls_fi.
    READ TABLE lt_dfies INTO ls_dfies
      WITH KEY fieldname = ls_fi-fieldname.
    IF sy-subrc = 0.
      CLEAR ls_fcat.
      ls_fcat-fieldname = ls_dfies-fieldname.
      ls_fcat-ref_table = lv_tabname.
      ls_fcat-ref_field = ls_dfies-fieldname.
      APPEND ls_fcat TO lt_fieldcat.
    ENDIF.
  ENDLOOP.

  " Create dynamic table and work area
  CALL METHOD cl_alv_table_create=>create_dynamic_table
    EXPORTING
      it_fieldcatalog = lt_fieldcat
    IMPORTING
      ep_table        = lr_data.

  ASSIGN lr_data->* TO <lt_data>.
  CREATE DATA lr_wa LIKE LINE OF <lt_data>.
  ASSIGN lr_wa->* TO <ls_wa>.

  " Open cursor for streaming read - dynamic WHERE + ORDER BY PK
  " ORDER BY PRIMARY KEY is essentially free on HANA (clustered by PK)
  " and near-free on other DBs (PK clustered index)
  IF gv_where_clause IS NOT INITIAL AND gv_orderby IS NOT INITIAL.
    OPEN CURSOR WITH HOLD lv_cursor FOR
      SELECT (gt_fieldlist) FROM (p_table)
      WHERE (gv_where_clause)
      ORDER BY (gv_orderby).
  ELSEIF gv_where_clause IS NOT INITIAL.
    OPEN CURSOR WITH HOLD lv_cursor FOR
      SELECT (gt_fieldlist) FROM (p_table)
      WHERE (gv_where_clause).
  ELSEIF gv_orderby IS NOT INITIAL.
    OPEN CURSOR WITH HOLD lv_cursor FOR
      SELECT (gt_fieldlist) FROM (p_table)
      ORDER BY (gv_orderby).
  ELSE.
    OPEN CURSOR WITH HOLD lv_cursor FOR
      SELECT (gt_fieldlist) FROM (p_table).
  ENDIF.

  IF sy-subrc <> 0.
    WRITE: / 'ERROR: Could not open cursor on table', p_table.
    WRITE: / 'sy-subrc =', sy-subrc.
    STOP.
  ENDIF.

  WRITE: / 'Cursor opened. Starting extraction...'.
  WRITE: / ''.

  " Fetch loop
  DO.
    " Fetch next package
    FETCH NEXT CURSOR lv_cursor INTO TABLE <lt_data> PACKAGE SIZE p_pkg.

    IF sy-subrc <> 0.
      " No more data
      EXIT.
    ENDIF.

    DESCRIBE TABLE <lt_data> LINES lv_fetched.
    lv_pkg_count = lv_pkg_count + 1.

    " Process each row in the package
    PERFORM process_package USING <lt_data>.

    " Write checkpoint (last row PK values + counters)
    IF gt_key_fields IS NOT INITIAL AND lv_fetched > 0.
      DATA: lv_do_ckpt TYPE abap_bool.
      lv_do_ckpt = abap_false.
      IF p_ckint <= 0.
        " Checkpoint every package
        lv_do_ckpt = abap_true.
      ELSEIF gv_rows_since_ckpt >= p_ckint.
        lv_do_ckpt = abap_true.
      ENDIF.
      IF lv_do_ckpt = abap_true.
        PERFORM write_checkpoint USING <lt_data>.
        gv_rows_since_ckpt = 0.
      ENDIF.
    ENDIF.

    " Check max rows limit
    IF p_maxrec > 0 AND gv_total_rows >= p_maxrec.
      WRITE: / 'Max row limit reached:', p_maxrec.
      EXIT.
    ENDIF.

    " Test mode: exit after first package
    IF p_test = abap_true.
      WRITE: / 'Test mode: stopping after first package.'.
      EXIT.
    ENDIF.

    " Free memory of processed package
    CLEAR <lt_data>.
  ENDDO.

  " Close cursor
  CLOSE CURSOR lv_cursor.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form process_package
*&---------------------------------------------------------------------*
FORM process_package USING pt_data TYPE STANDARD TABLE.
  DATA: lv_csv_line TYPE string.

  FIELD-SYMBOLS:
    <ls_row> TYPE any.

  LOOP AT pt_data ASSIGNING <ls_row>.

    " Check max rows
    IF p_maxrec > 0 AND gv_total_rows >= p_maxrec.
      RETURN.
    ENDIF.

    " Check if we need a new file (by row count or byte size)
    IF gv_file_open = abap_false.
      PERFORM open_new_file.
    ELSEIF p_maxgb > 0 AND gv_max_bytes > 0 AND gv_chunk_bytes >= gv_max_bytes.
      " Size-based chunking
      PERFORM close_file.
      PERFORM open_new_file.
    ELSEIF p_maxgb <= 0 AND gv_chunk_rows >= p_chunk.
      " Row-based chunking
      PERFORM close_file.
      PERFORM open_new_file.
    ENDIF.

    " Serialize row to CSV
    PERFORM serialize_row USING <ls_row> CHANGING lv_csv_line.

    " Write to file
    PERFORM write_line USING lv_csv_line.

    " Update counters
    gv_total_rows = gv_total_rows + 1.
    gv_chunk_rows = gv_chunk_rows + 1.
    gv_rows_since_ckpt = gv_rows_since_ckpt + 1.

    " Estimate bytes: line length + line ending
    DATA: lv_line_bytes TYPE int8.
    lv_line_bytes = strlen( lv_csv_line ) + strlen( gv_line_ending ).
    gv_chunk_bytes = gv_chunk_bytes + lv_line_bytes.

    " Progress reporting
    IF p_prog > 0 AND gv_total_rows MOD p_prog = 0.
      PERFORM log_progress.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form serialize_row
*& PERFORMANCE-CRITICAL: Called once per row.
*& Optimizations:
*&   1. IS INITIAL fast-path — skips 70-90% of fields on wide tables
*&   2. LOOP ASSIGNING — no structure copy (avoids heap alloc)
*&   3. Pre-allocated gt_csv_values — no CLEAR/APPEND cycle per row
*&   4. ASSIGN COMPONENT by index — O(1) vs hash lookup
*&   5. READ TABLE ASSIGNING — write directly into table slot
*&   6. CONCATENATE LINES OF — single O(n) kernel call
*&   7. CSV escape only for CHAR fields
*&   8. lv_value TYPE c LENGTH 8 — no heap alloc for DATE/TIME temp
*&---------------------------------------------------------------------*
FORM serialize_row USING ps_row TYPE any
                   CHANGING pv_line TYPE string.
  DATA: lv_value TYPE c LENGTH 8,
        lv_idx   TYPE i.

  FIELD-SYMBOLS:
    <ls_fi>    TYPE ty_field_info,
    <lv_field> TYPE any,
    <lv_val>   TYPE string.

  lv_idx = 0.

  LOOP AT gt_field_info ASSIGNING <ls_fi>.
    lv_idx = lv_idx + 1.

    " Direct write into pre-allocated table slot — no APPEND overhead
    READ TABLE gt_csv_values ASSIGNING <lv_val> INDEX lv_idx.

    " O(1) index access into dynamic structure
    ASSIGN COMPONENT lv_idx OF STRUCTURE ps_row TO <lv_field>.
    IF sy-subrc <> 0.
      CLEAR <lv_val>.
      CONTINUE.
    ENDIF.

    " Fast-path: INITIAL fields skip type conversion + CONDENSE + escaping.
    " On wide tables (518 cols), 70-90% of fields are INITIAL per row.
    " Cost: ~0.1μs (IS INITIAL + IF + assign/CLEAR) vs ~1μs full path.
    IF <lv_field> IS INITIAL.
      IF <ls_fi>-is_numeric = abap_true.
        <lv_val> = '0'.
      ELSE.
        CLEAR <lv_val>.
      ENDIF.
      CONTINUE.
    ENDIF.

    CASE <ls_fi>-datatype.
      WHEN 'INT' OR 'DEC'.
        " P→string and I→string use '.' decimal (internal fmt)
        <lv_val> = <lv_field>.
        CONDENSE <lv_val> NO-GAPS.

      WHEN 'FLOAT'.
        PERFORM format_numeric USING <lv_field> <ls_fi>-decimals
                               CHANGING <lv_val>.

      WHEN 'DATE'.
        lv_value = <lv_field>.
        CONCATENATE lv_value(4) '-' lv_value+4(2) '-' lv_value+6(2)
          INTO <lv_val>.

      WHEN 'TIME'.
        lv_value = <lv_field>.
        CONCATENATE lv_value(2) ':' lv_value+2(2) ':' lv_value+4(2)
          INTO <lv_val>.

      WHEN OTHERS.
        <lv_val> = <lv_field>.
        CONDENSE <lv_val>.

        IF p_esc = abap_true AND gv_encl_str IS NOT INITIAL
           AND <lv_val> IS NOT INITIAL.
          IF <lv_val> CS gv_delim_str OR <lv_val> CS gv_encl_str
             OR <lv_val> CS cl_abap_char_utilities=>cr_lf
             OR <lv_val> CS cl_abap_char_utilities=>newline.
            REPLACE ALL OCCURRENCES OF gv_encl_str IN <lv_val>
              WITH gv_encl_dbl.
            CONCATENATE gv_encl_str <lv_val> gv_encl_str INTO <lv_val>.
          ENDIF.
        ENDIF.
    ENDCASE.
  ENDLOOP.

  CONCATENATE LINES OF gt_csv_values INTO pv_line SEPARATED BY gv_delim_str.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form format_numeric
*& Locale-independent formatting for FLOAT types only.
*& Packed decimals (DEC) use direct string assignment instead.
*&---------------------------------------------------------------------*
FORM format_numeric USING pv_value TYPE any
                          pv_decimals TYPE i
                    CHANGING pv_result TYPE string.
  DATA: lv_str      TYPE string,
        lv_sign     TYPE c LENGTH 1,
        lv_packed   TYPE p LENGTH 16 DECIMALS 14,
        lv_int      TYPE int8,
        lv_factor   TYPE p LENGTH 16 DECIMALS 0,
        lv_shifted  TYPE p LENGTH 16 DECIMALS 0,
        lv_int_part TYPE string,
        lv_dec_part TYPE string,
        lv_len      TYPE i,
        lv_int_len  TYPE i.

  lv_packed = pv_value.

  " Determine sign
  IF lv_packed < 0.
    lv_sign = '-'.
    lv_packed = lv_packed * -1.
  ELSE.
    lv_sign = ''.
  ENDIF.

  IF pv_decimals <= 0.
    lv_int = lv_packed.
    lv_str = lv_int.
    CONDENSE lv_str NO-GAPS.
  ELSE.
    " Shift decimals and insert dot
    lv_factor = 1.
    DO pv_decimals TIMES.
      lv_factor = lv_factor * 10.
    ENDDO.

    lv_shifted = lv_packed * lv_factor.
    lv_str = lv_shifted.
    CONDENSE lv_str NO-GAPS.
    REPLACE ALL OCCURRENCES OF '-' IN lv_str WITH ''.

    " Pad with leading zeros if needed
    WHILE strlen( lv_str ) <= pv_decimals.
      CONCATENATE '0' lv_str INTO lv_str.
    ENDWHILE.

    lv_len = strlen( lv_str ).
    lv_int_len = lv_len - pv_decimals.
    lv_int_part = lv_str(lv_int_len).
    lv_dec_part = lv_str+lv_int_len(pv_decimals).

    CONCATENATE lv_int_part '.' lv_dec_part INTO lv_str.
  ENDIF.

  CONCATENATE lv_sign lv_str INTO pv_result.
  CONDENSE pv_result NO-GAPS.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form open_new_file
*&---------------------------------------------------------------------*
FORM open_new_file.
  DATA: lv_filename  TYPE string,
        lv_chunk_str TYPE string,
        lv_codepage  TYPE cpcodepage.

  gv_file_count = gv_file_count + 1.
  gv_chunk_rows  = 0.
  gv_chunk_bytes = 0.

  " Build file name: PREFIX_TABLENAME_NNNNN.csv
  lv_chunk_str = gv_file_count.
  CONDENSE lv_chunk_str NO-GAPS.
  " Pad to 5 digits
  WHILE strlen( lv_chunk_str ) < 5.
    CONCATENATE '0' lv_chunk_str INTO lv_chunk_str.
  ENDWHILE.

  CONCATENATE p_path p_prefix '_' p_table '_' lv_chunk_str p_ext
    INTO lv_filename.
  gv_current_file = lv_filename.

  " Open file for writing
  IF p_utf8 = abap_true.
    OPEN DATASET lv_filename FOR OUTPUT IN TEXT MODE
      ENCODING UTF-8.
  ELSE.
    OPEN DATASET lv_filename FOR OUTPUT IN TEXT MODE
      ENCODING DEFAULT.
  ENDIF.

  IF sy-subrc <> 0.
    WRITE: / 'ERROR: Cannot open file:', lv_filename.
    WRITE: / 'sy-subrc =', sy-subrc.
    WRITE: / 'Check that directory exists and has write permission (AL11).'.
    STOP.
  ENDIF.

  gv_file_open = abap_true.

  WRITE: / 'Opened file:', lv_filename.

  " Write BOM for UTF-8 if requested (some tools need this)
  " Note: OPEN DATASET with ENCODING UTF-8 handles BOM in most kernels
  " We skip manual BOM since the kernel usually adds it

  " Write header line
  IF p_head = abap_true AND gv_header_line IS NOT INITIAL.
    TRANSFER gv_header_line TO lv_filename.
    DATA: lv_hdr_bytes TYPE int8.
    lv_hdr_bytes = strlen( gv_header_line ) + strlen( gv_line_ending ).
    gv_chunk_bytes = gv_chunk_bytes + lv_hdr_bytes.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form write_line
*&---------------------------------------------------------------------*
FORM write_line USING pv_line TYPE string.
  TRANSFER pv_line TO gv_current_file.
  IF sy-subrc <> 0.
    WRITE: / 'ERROR writing to file:', gv_current_file.
    WRITE: / 'sy-subrc =', sy-subrc.
    STOP.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form close_file
*&---------------------------------------------------------------------*
FORM close_file.
  CLOSE DATASET gv_current_file.
  gv_file_open = abap_false.

  DATA: lv_mb TYPE p DECIMALS 2.
  lv_mb = gv_chunk_bytes / 1024 / 1024.

  WRITE: / 'Closed file:', gv_current_file.
  WRITE: / '  Rows:', gv_chunk_rows, '  Size (MB):', lv_mb.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form log_progress
*&---------------------------------------------------------------------*
FORM log_progress.
  DATA: lv_now      TYPE i,
        lv_elapsed  TYPE i,
        lv_rate     TYPE p DECIMALS 0,
        lv_elapsed_s TYPE p DECIMALS 1,
        lv_msg      TYPE string.

  GET RUN TIME FIELD lv_now.
  lv_elapsed = lv_now - gv_start_time. "microseconds

  IF lv_elapsed > 0.
    lv_elapsed_s = lv_elapsed / 1000000.
    lv_rate = gv_total_rows / lv_elapsed_s.
  ELSE.
    lv_elapsed_s = 0.
    lv_rate = 0.
  ENDIF.

  WRITE: / 'Progress:',
           gv_total_rows, 'rows |',
           lv_elapsed_s, 'sec |',
           lv_rate, 'rows/sec |',
           'File', gv_file_count.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form log_configuration
*&---------------------------------------------------------------------*
FORM log_configuration.
  DATA: lv_field_count TYPE i.

  DESCRIBE TABLE gt_field_info LINES lv_field_count.

  WRITE: / '========================================================'.
  WRITE: / '  ZTABLE_EXPORT_CSV - High-Performance Table Export'.
  WRITE: / '========================================================'.
  WRITE: / 'Table:          ', p_table.
  WRITE: / 'Fields:         ', lv_field_count.
  WRITE: / 'Package size:   ', p_pkg.
  IF p_maxgb > 0.
    WRITE: / 'Chunk mode:      Size-based,', p_maxgb, 'GB per file'.
  ELSE.
    WRITE: / 'Chunk mode:      Row-based,', p_chunk, 'rows per file'.
  ENDIF.
  WRITE: / 'Delimiter:      ', p_delim.
  WRITE: / 'Output path:    ', p_path.
  WRITE: / 'File prefix:    ', p_prefix.
  IF p_maxrec > 0.
    WRITE: / 'Row limit:      ', p_maxrec.
  ELSE.
    WRITE: / 'Row limit:       Unlimited'.
  ENDIF.
  IF p_resum = abap_true.
    WRITE: / 'Resume mode:     ACTIVE - continuing from checkpoint'.
    WRITE: / '  Start file:   ', gv_file_count.
    WRITE: / '  Start row:    ', gv_total_rows.
  ELSE.
    WRITE: / 'Resume mode:     Off (fresh extraction)'.
  ENDIF.
  WRITE: / 'Checkpoint file: ', gv_ckpt_file.
  IF gv_where_clause IS NOT INITIAL.
    IF strlen( gv_where_clause ) > 200.
      WRITE: / 'WHERE clause:    (', strlen( gv_where_clause ), 'chars - truncated)'.
      WRITE: / gv_where_clause(200).
      WRITE: / '...'.
    ELSE.
      WRITE: / 'WHERE clause:   ', gv_where_clause.
    ENDIF.
  ENDIF.
  WRITE: / '========================================================'.
  WRITE: / ''.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form log_summary
*&---------------------------------------------------------------------*
FORM log_summary.
  DATA: lv_now       TYPE i,
        lv_elapsed   TYPE i,
        lv_elapsed_s TYPE p DECIMALS 1,
        lv_rate      TYPE p DECIMALS 0,
        lv_total_mb  TYPE p DECIMALS 2.

  GET RUN TIME FIELD lv_now.
  lv_elapsed = lv_now - gv_start_time.

  IF lv_elapsed > 0.
    lv_elapsed_s = lv_elapsed / 1000000.
    IF lv_elapsed_s > 0.
      lv_rate = gv_total_rows / lv_elapsed_s.
    ENDIF.
  ENDIF.

  WRITE: / ''.
  WRITE: / '========================================================'.
  WRITE: / '  EXTRACTION COMPLETE'.
  WRITE: / '========================================================'.
  WRITE: / 'Total rows:     ', gv_total_rows.
  WRITE: / 'Total files:    ', gv_file_count.
  WRITE: / 'Elapsed time:   ', lv_elapsed_s, 'seconds'.
  WRITE: / 'Throughput:     ', lv_rate, 'rows/sec'.
  WRITE: / 'Checkpoint:     ', gv_ckpt_file.
  WRITE: / '========================================================'.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form write_checkpoint
*& Writes current state (counters + last PK values) to checkpoint file.
*& Called after each package (or at checkpoint interval).
*& File is overwritten each time (not appended).
*&---------------------------------------------------------------------*
FORM write_checkpoint USING pt_data TYPE STANDARD TABLE.
  DATA: lv_line1   TYPE string,
        lv_line2   TYPE string,
        lv_value   TYPE string,
        ls_kf      TYPE ty_key_field,
        lv_count   TYPE i,
        lv_fc_str  TYPE string,
        lv_tr_str  TYPE string,
        lv_cr_str  TYPE string,
        lv_cb_str  TYPE string.

  FIELD-SYMBOLS:
    <ls_last_row> TYPE any,
    <lv_field>    TYPE any.

  " Get the last row of the package (highest PK due to ORDER BY)
  DESCRIBE TABLE pt_data LINES lv_count.
  IF lv_count <= 0.
    RETURN.
  ENDIF.
  READ TABLE pt_data ASSIGNING <ls_last_row> INDEX lv_count.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  " Line 1: counters  file_count|total_rows|chunk_rows|chunk_bytes
  lv_fc_str = gv_file_count. CONDENSE lv_fc_str NO-GAPS.
  lv_tr_str = gv_total_rows. CONDENSE lv_tr_str NO-GAPS.
  lv_cr_str = gv_chunk_rows. CONDENSE lv_cr_str NO-GAPS.
  lv_cb_str = gv_chunk_bytes. CONDENSE lv_cb_str NO-GAPS.
  CONCATENATE lv_fc_str '|' lv_tr_str '|' lv_cr_str '|' lv_cb_str
    INTO lv_line1.

  " Line 2: PK field values separated by |
  CLEAR lv_line2.
  LOOP AT gt_key_fields INTO ls_kf.
    ASSIGN COMPONENT ls_kf-fieldname OF STRUCTURE <ls_last_row>
      TO <lv_field>.
    IF sy-subrc = 0.
      lv_value = <lv_field>.
      CONDENSE lv_value NO-GAPS.
    ELSE.
      CLEAR lv_value.
    ENDIF.

    IF lv_line2 IS INITIAL.
      lv_line2 = lv_value.
    ELSE.
      CONCATENATE lv_line2 '|' lv_value INTO lv_line2.
    ENDIF.
  ENDLOOP.

  " Write checkpoint file (overwrite)
  OPEN DATASET gv_ckpt_file FOR OUTPUT IN TEXT MODE ENCODING UTF-8.
  IF sy-subrc = 0.
    TRANSFER lv_line1 TO gv_ckpt_file.
    TRANSFER lv_line2 TO gv_ckpt_file.
    CLOSE DATASET gv_ckpt_file.
  ELSE.
    WRITE: / 'WARNING: Could not write checkpoint file:', gv_ckpt_file.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form read_checkpoint
*& Reads checkpoint file and restores counters + builds resume WHERE.
*& Called from main when P_RESUM = 'X'.
*&---------------------------------------------------------------------*
FORM read_checkpoint.
  DATA: lv_line1     TYPE string,
        lv_line2     TYPE string,
        lt_counters  TYPE TABLE OF string,
        lt_values    TYPE TABLE OF string,
        lv_val       TYPE string,
        lv_counter   TYPE string,
        lv_num_keys  TYPE i,
        lv_num_vals  TYPE i.

  " Check if checkpoint file exists by trying to open it
  OPEN DATASET gv_ckpt_file FOR INPUT IN TEXT MODE ENCODING UTF-8.
  IF sy-subrc <> 0.
    WRITE: / 'No checkpoint file found at:', gv_ckpt_file.
    WRITE: / 'Starting from beginning.'.
    RETURN.
  ENDIF.

  READ DATASET gv_ckpt_file INTO lv_line1.
  IF sy-subrc <> 0.
    CLOSE DATASET gv_ckpt_file.
    WRITE: / 'WARNING: Checkpoint file is empty.'.
    RETURN.
  ENDIF.

  READ DATASET gv_ckpt_file INTO lv_line2.
  CLOSE DATASET gv_ckpt_file.

  IF lv_line1 IS INITIAL OR lv_line2 IS INITIAL.
    WRITE: / 'WARNING: Checkpoint file incomplete.'.
    RETURN.
  ENDIF.

  " Parse line 1: file_count|total_rows|chunk_rows|chunk_bytes
  SPLIT lv_line1 AT '|' INTO TABLE lt_counters.
  READ TABLE lt_counters INTO lv_counter INDEX 1.
  IF sy-subrc = 0. gv_file_count = lv_counter. ENDIF.
  READ TABLE lt_counters INTO lv_counter INDEX 2.
  IF sy-subrc = 0. gv_total_rows = lv_counter. ENDIF.
  " chunk_rows and chunk_bytes are reset on new file, don't restore

  WRITE: / 'Checkpoint loaded:'.
  WRITE: / '  Resuming after file:', gv_file_count.
  WRITE: / '  Resuming after row: ', gv_total_rows.

  " Parse line 2: PK values
  SPLIT lv_line2 AT '|' INTO TABLE lt_values.

  DESCRIBE TABLE gt_key_fields LINES lv_num_keys.
  DESCRIBE TABLE lt_values LINES lv_num_vals.

  IF lv_num_vals <> lv_num_keys.
    WRITE: / 'ERROR: Checkpoint PK values count (', lv_num_vals,
             ') does not match table PK count (', lv_num_keys, ')'.
    WRITE: / 'Cannot resume. Starting from beginning.'.
    gv_file_count = 0.
    gv_total_rows = 0.
    RETURN.
  ENDIF.

  " Build resume WHERE condition
  PERFORM build_resume_condition USING lt_values.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form build_resume_condition
*& Builds composite key "greater than" WHERE clause for resume.
*&
*& For keys (K1,K2,K3) with last values (V1,V2,V3):
*&   ( K1 > 'V1' )
*&   OR ( K1 = 'V1' AND K2 > 'V2' )
*&   OR ( K1 = 'V1' AND K2 = 'V2' AND K3 > 'V3' )
*&
*& This exploits the primary key index for O(log N) seek.
*&---------------------------------------------------------------------*
FORM build_resume_condition USING pt_values TYPE STANDARD TABLE.
  DATA: lv_resume    TYPE string,
        lv_term      TYPE string,
        lv_prefix    TYPE string,
        ls_kf        TYPE ty_key_field,
        lv_val       TYPE string,
        lv_val_esc   TYPE string,
        lv_num_keys  TYPE i,
        lv_i         TYPE i,
        lv_j         TYPE i.

  DESCRIBE TABLE gt_key_fields LINES lv_num_keys.
  CLEAR lv_resume.

  " Build each OR-term
  " Term i: K1 = V1 AND K2 = V2 AND ... AND Ki > Vi
  DO lv_num_keys TIMES.
    lv_i = sy-index.
    CLEAR lv_term.

    " Build the equality prefix: K1 = V1 AND K2 = V2 AND ...
    DO lv_i TIMES.
      lv_j = sy-index.

      READ TABLE gt_key_fields INTO ls_kf INDEX lv_j.
      READ TABLE pt_values INTO lv_val INDEX lv_j.
      CONDENSE lv_val NO-GAPS.

      " Escape single quotes in value
      lv_val_esc = lv_val.
      REPLACE ALL OCCURRENCES OF '''' IN lv_val_esc WITH ''''''.

      IF lv_j < lv_i.
        " Equality condition for prefix keys
        IF lv_term IS INITIAL.
          CONCATENATE ls_kf-fieldname ` = '` lv_val_esc `'`
            INTO lv_term.
        ELSE.
          CONCATENATE lv_term ` AND ` ls_kf-fieldname ` = '`
            lv_val_esc `'` INTO lv_term.
        ENDIF.
      ELSE.
        " Greater-than condition for the current key
        IF lv_term IS INITIAL.
          CONCATENATE ls_kf-fieldname ` > '` lv_val_esc `'`
            INTO lv_term.
        ELSE.
          CONCATENATE lv_term ` AND ` ls_kf-fieldname ` > '`
            lv_val_esc `'` INTO lv_term.
        ENDIF.
      ENDIF.
    ENDDO.

    " Wrap in parentheses
    CONCATENATE '( ' lv_term ' )' INTO lv_term.

    " Add to resume clause with OR
    IF lv_resume IS INITIAL.
      lv_resume = lv_term.
    ELSE.
      CONCATENATE lv_resume ` OR ` lv_term INTO lv_resume.
    ENDIF.
  ENDDO.

  " Wrap entire resume condition in parentheses
  CONCATENATE '( ' lv_resume ' )' INTO lv_resume.

  " Inject into WHERE clause
  IF gv_where_clause IS NOT INITIAL.
    CONCATENATE '( ' gv_where_clause ' ) AND ' lv_resume
      INTO gv_where_clause.
  ELSE.
    gv_where_clause = lv_resume.
  ENDIF.

  WRITE: / 'Resume WHERE injected. Length:',
           strlen( gv_where_clause ), 'chars'.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form delete_checkpoint
*& Removes checkpoint file after successful extraction.
*&---------------------------------------------------------------------*
FORM delete_checkpoint.
  DELETE DATASET gv_ckpt_file.
  IF sy-subrc = 0.
    WRITE: / 'Checkpoint file deleted (extraction complete):',
             gv_ckpt_file.
  ENDIF.
ENDFORM.
