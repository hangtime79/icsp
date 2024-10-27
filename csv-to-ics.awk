function run_cmd(cmd) {
  cmd | getline out
  close(cmd)
  return out
}

function get_dt_type(dt) {
  date_part = substr(dt, 1, 8)
  T_part = substr(dt, 9, 1)
  time_part = substr(dt, 10, 6)
  Z_part = substr(dt, 16, 1)
  if (length(dt) == 8 && date_part !~ /[^0-9]/) {
    return "date"
  }
  if (length(dt) == 15 && date_part !~ /[^0-9]/ && T_part == "T" && time_part !~ /[^0-9]/) {
    return "datetime"
  }
  if (length(dt) == 16 && date_part !~ /[^0-9]/ && T_part == "T" && time_part !~ /[^0-9]/ && Z_part == "Z" ) {
    return "utc datetime"
  }
}

function to_iso(dt) {
  dt_type = get_dt_type(dt)
  if (dt_type == "date") {
    Y = substr(dt, 1, 4)
    M = substr(dt, 5, 2)
    D = substr(dt, 7, 2)
    return Y "-" M "-" D
  } else if (dt_type == "datetime") {
    Y = substr(dt, 1, 4)
    M = substr(dt, 5, 2)
    D = substr(dt, 7, 2)
    h = substr(dt, 10, 2)
    m = substr(dt, 12, 2)
    s = substr(dt, 14, 2)
    return Y "-" M "-" D " " h ":" m ":" s
  } else if (dt_type == "utc datetime") {
    Y = substr(dt, 1, 4)
    M = substr(dt, 5, 2)
    D = substr(dt, 7, 2)
    h = substr(dt, 10, 2)
    m = substr(dt, 12, 2)
    s = substr(dt, 14, 2)
    return Y "-" M "-" D " " h ":" m ":" s "Z"
  }
  print "Unrecognized format: " dt
}

function get_iso_format(iso_dt) {
  format = "%Y-%m-%d %H:%M:%SZ"
  if (length(iso_dt) == 19) {
    format = "%Y-%m-%d %H:%M:%S"
  } else if (length(iso_dt) == 10) {
    format = "%Y-%m-%d"
  }
  return format
}

function get_date_cmd_type() {
  check_date_cmd_type = "date --version >/dev/null 2>&1"
  if (system(check_date_cmd_type) == 0) {
    return "gnu"
  } else {
    return "bsd"
  }
}

# Enhanced timezone handling
function dt_format_local(dt, output_format) {
  iso_dt = to_iso(dt)
  dt_type = get_dt_type(dt)
  
  # Build timezone command prefix
  tz_prefix = ""
  if (target_tz != "") {
    tz_prefix = "TZ='" target_tz "' "
  } else if (calendar_tz != "") {
    tz_prefix = "TZ='" calendar_tz "' "
  }
  
  if (date_cmd_type == "gnu") {
    if (dt_type == "utc datetime") {
      # Handle UTC dates with timezone conversion
      date_command = tz_prefix "date -d '" iso_dt "' '" output_format "'"
    } else if (dt_type == "datetime") {
      if (event_tz != "") {
        # Convert from event timezone to target timezone
        date_command = "TZ='" event_tz "' date -d '" iso_dt "' '+%s' | " tz_prefix "date -f - '" output_format "'"
      } else {
        # Use calendar timezone if available, otherwise system timezone
        date_command = tz_prefix "date -d '" iso_dt "' '" output_format "'"
      }
    } else {
      # Date only - no timezone conversion needed
      date_command = "date -d '" iso_dt "' '" output_format "'"
    }
  } else {
    # BSD date handling (macOS)
    if (dt_type == "utc datetime") {
      date_command = tz_prefix "date -jf '%Y-%m-%d %H:%M:%S%z' '" iso_dt " +0000' '" output_format "'"
    } else if (dt_type == "datetime") {
      if (event_tz != "") {
        # Two-step conversion for BSD date with timezone
        date_command = "TZ='" event_tz "' date -jf '" get_iso_format(iso_dt) "' '" iso_dt "' '+%s' | " \
                      tz_prefix "date -j -f '%s' -r - '" output_format "'"
      } else {
        date_command = tz_prefix "date -jf '" get_iso_format(iso_dt) "' '" iso_dt "' '" output_format "'"
      }
    } else {
      # Date only - no timezone conversion needed
      date_command = "date -jf '%Y-%m-%d' '" iso_dt "' '" output_format "'"
    }
  }
  
  return run_cmd(date_command)
}

function get_duration(dtstart, dtend) {
  start = dt_format_local(dtstart, "+%s")
  end = dt_format_local(dtend, "+%s")
  seconds = end - start
  hours = seconds / 3600
  decimal_index = index(hours, ".")
  if (decimal_index == "0") {
    return hours "h"
  }
  decimals = substr(hours, decimal_index + 1, length(hours))
  hour = substr(hours, 0, decimal_index - 1)
  minutes = int(("0." decimals) * 60)
  if (hour == "0") {
    return minutes "m"
  }
  return hour "h" minutes "m"
}

BEGIN {
  FS = "\t" # FS is a tab character because we expect a pre-formatted 
  # ICS stream that uses tab characters as the delimiter for key-value pairs.

  # Initialize variables
  idx = 0            # Current object index
  in_component = 0   # Whether current line is within specified component
  calendar_tz = ""   # Calendar's default timezone
  event_tz = ""     # Current event's timezone
  date_cmd_type = get_date_cmd_type()
  
  # Set default timezone if none provided
  if (target_tz == "") {
    "date +%Z" | getline system_tz
    close("date +%Z")
    calendar_tz = system_tz
  }
}

# Capture calendar timezone
idx == 0 && $1 ~ /^TZID$/ {
  calendar_tz = $2
}

# Capture event timezone from TZID parameter
$0 ~ /^[^;]+;TZID=[^:]+/ {
  split($0, parts, ";")
  split(parts[2], tz_parts, "=")
  event_tz = tz_parts[2]
}

# Handle component start/end
$1 == "BEGIN" {
  if ($2 == component) {
    in_component = 1
  } else {
    in_component = 0
  }
  next
}

$1 == "END" {
  if ($2 == component) {
    in_component = 0
    idx = idx + 1
    event_tz = ""  # Reset event timezone for next event
  } else {
    in_component = 1
  }
  next
}

# Store values when inside target component
in_component == 1 && $1 != "" && $2 != "" {
  found_cols[$1] = found_cols[$1] + 1
  values[idx, $1] = $2
}

END {
  # If no columns specified, create sorted list based on frequency
  if (columns == "") {
    unsorted_columns = ""
    for (col in found_cols) {
      unsorted_columns = unsorted_columns found_cols[col] "\t" col "\n"
    }
    command = "echo '" unsorted_columns "' | sort -rn | cut -d'\t' -f2 | sed '/^$/d'"
    for (i = 0; (command | getline line) > 0; i++) {
      auto_sorted_columns[i] = line
    }
    close(command)
    for (k = 0; k < length(auto_sorted_columns); k++) {
      if (columns == "") {
        columns = auto_sorted_columns[k]
      } else {
        columns = columns "," auto_sorted_columns[k]
      }
    }
  }

  # Print headers
  headers = columns
  gsub(",", OFS, headers)
  print headers

  # Convert columns string to array
  split(columns, cols_array, ",")

  # Process each row
  for (i = 0; i < idx; i++) {
    line_out = "\0"

    # Calculate duration if needed
    if (no_iso == "" && headers ~ /DURATION/ && values[i, "DURATION"] == "" && 
        values[i, "DTSTART"] != "" && values[i, "DTEND"] != "") {
      values[i, "DURATION"] = get_duration(values[i, "DTSTART"], values[i, "DTEND"])
    }

    # Process each column
    for (k = 1; k <= length(cols_array); k++) {
      column = cols_array[k]
      value = values[i, column]

      # Convert dates if needed
      if (no_iso == "" && column ~ /DTSTART|DTEND|DTSTAMP|CREATED|LAST-MOD/) {
        dt_type = get_dt_type(value)
        if (dt_type != "") {
          value = dt_format_local(value, "+%Y-%m-%d %H:%M:%S")
        }
      }

      # Handle delimiters in values
      if (index(value, OFS) != 0) {
        gsub("\"", "\"\"", value)
        value = "\"" value "\""
      }

      # Build output line
      if (line_out == "\0") {
        line_out = value
      } else {
        line_out = line_out OFS value
      }
    }

    # Print row
    if (line_out != "\0") {
      print line_out
    }
  }
}