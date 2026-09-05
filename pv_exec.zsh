#!/usr/bin/env zsh
#
# Amor et potentia oppressis.
#

########################################
# Avoid using tput since each call spawns a process. Echoti (or sending raw escape codes)
# is orders of magnitude faster.
pv_get_term_width()  {
    local out_cols=$1   # after zsh 5.10+ use: local -n out_cols=$1
    if [[ -n "${COLUMNS:-}" ]]; then
        # after zsh 5.10+ use: out_cols="$COLUMNS"
        : ${(P)out_cols::="$COLUMNS"}
    else
        __cols=$(echoti cols 2>/dev/null) || __cols=80
        # after zsh 5.10+ use: out_cols="$__cols"
        : ${(P)out_cols::="$__cols"}
    fi
    return 0
}
pv_get_term_height() {
    local out_lines=$1   # after zsh 5.10+ use: local -n out_lines=$1
    if [[ -n "${LINES:-}" ]]; then
        # after zsh 5.10+ use: out_lines="$LINES"
        : ${(P)out_lines::="$LINES"}
    else
        __lines=$(echoti lines 2>/dev/null) || __lines=50
        # after zsh 5.10+ use: out_lines="$__lines"
        : ${(P)out_lines::="$__lines"}
    fi
    return 0
}

pv_start_buffered_update() { print -nr -- $'\033[?2026h'; }  # start buffered update mode
pv_end_buffered_update()   { print -nr -- $'\033[?2026l'; }  # end buffered updated mode (flushes output)

pv_tput_clear() { echoti clear; }       # clear screen
pv_tput_smcup() { echoti smcup; }       # start alternate screen (screen+cursor saved, clear, no scroll back)
pv_tput_rmcup() { echoti rmcup; }       # exit alternate screen (screen+cursor restored)

pv_tput_rmam()  { echoti rmam; }        # disable auto-wrapping of lines (no automatic margins)
pv_tput_smam()  { echoti smam; }        # enable auto-wrapping of lines (automatic margins)

pv_tput_civis() { echoti civis; }       # hide cursor
pv_tput_cnorm() { echoti cnorm; }       # show cursor

pv_tput_cuf()   { echoti cuf $1; }      # cursor forward (relative: move-right)
pv_tput_cup()   { echoti cup $1 $2; }   # cursor position (absolute: y, x)
pv_tput_sc()    { echoti sc; }          # cursor save
pv_tput_rc()    { echoti rc; }          # cursor restore

pv_tput_el()    { echoti el; }          # erase from cursor to end-of-line

pv_tput_csr()   { echoti csr $1 $2; }   # set vertical scroll region (top, bottom)
pv_tput_rcsr()  {
    # reset vertical scroll region to entire term
    local -i height=0
    pv_get_term_height height
    echoti csr 0 $((height - 1));
}

pv_get_cursor_row() {
    emulate -L zsh
    local out_row=$1   # after zsh 5.10+ use: local -n out_row=$1

    local fd  # open controlling terminal for r+w
    exec {fd}<>/dev/tty || return 1

    # Save TTY and switch to no echo and no waiting
    local old=$(stty -g <&$fd)
    stty -echo -icanon min 1 time 1 <&$fd

    # Request report cursor position (CPR), preferring echoti over escape code.
    if ! echoti u7 >&$fd 2>/dev/null; then
        printf '\033[6n' >&$fd
    fi

    # Read reply: ESC [ row ; col R (1-based)
    local resp
    IFS= read -r -d R -u $fd resp
    local read_ok=$?

    # Immediately restore TTY
    stty "$old" <&$fd
    exec {fd}>&-

    # And then parse the result
    if ((read_ok == 0)); then
        resp=${resp#*$'\033['}        # Strip leading ESC[
        local row=${resp%%;*}
        if [[ $row == <-> ]]; then
            ((row--)) # 0-based to match 'tput cup'
            # after zsh 5.10+ use: out_row="${row}"
            : ${(P)out_row::="${row}"}
            return 0
        fi
    fi
    return 1
}

# Detect an available PTY-allocation tool so we can access input from interactive
# commands that read/write via /dev/tty inside the popview.
#   returns: 0 none, 1 script(linux version), 2 script(BSD/macOS version)
pv_get_pty_kind() {
    local out_pty_kind=$1       # after zsh 5.10+ use: local -n out_pty_kind=$1

    if program_exists script; then
        if script --version 2>/dev/null | grep -qi 'util-linux'; then
            : ${(P)out_pty_kind::="1"}  # use linux `script` arg syntax
        else
            : ${(P)out_pty_kind::="2"}  # else BSD/macOS `script` arg syntax
        fi
    else
        : ${(P)out_pty_kind::="0"}      # `script` not found
    fi
    return 0
}

########################################
# Similar to sleep(), but doesn't start a new process.
pv_sleep() {
    local duration=$1
    local -i zsel_duration=$((100 * duration))
    zselect -t $zsel_duration
    return 0
}

########################################
program_exists() {
    command -v "$1" &>/dev/null
    return $?
}

########################################
_pv_record_signal() {
    PV_SIGNAL=$1
    return 0
}

_pv_save_and_config_tty() {
    if [[ -t 0 ]]; then
        PV_SAVED_TTY=$(stty -g 2>/dev/null)
        if [[ -n "$PV_SAVED_TTY" ]]; then
            stty -echo -icanon min 1 time 0 2>/dev/null
        fi
    fi
    return 0
}

_pv_restore_tty() {
    if [[ -n "$PV_SAVED_TTY" ]]; then
        stty "$PV_SAVED_TTY" 2>/dev/null
        PV_SAVED_TTY=""
    fi
    return 0
}

_pv_exit_cleanup() {
    if [[ -n "$PV_PID" ]]; then
        kill -TERM "$PV_PID" 2>/dev/null
    fi
    ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr
    pv_tput_cnorm
    _pv_restore_tty
    print
}

########################################
# Width of a single character in terminal columns (1 or 2). Handles common cases but not all.
char_width() {
    local ch=$1
    local out_width=$2      # after zsh 5.10+ use: local -n out_width=$2
    local -i codepoint=$((#ch))
    local -i width=1
    if   (( codepoint >= 0x1F000 && codepoint <= 0x1F9FF )); then width=2  # Emoji
    elif (( codepoint >= 0x2600  && codepoint <= 0x27BF  )); then width=2  # Misc Symbols/Dingbats
    elif (( codepoint >= 0x4E00  && codepoint <= 0x9FFF  )); then width=2  # CJK Unified
    elif (( codepoint >= 0x3000  && codepoint <= 0x303F  )); then width=2  # CJK Symbols/Punct
    elif (( codepoint >= 0xAC00  && codepoint <= 0xD7AF  )); then width=2  # Hangul Syllables
    elif (( codepoint >= 0xFF01  && codepoint <= 0xFF60  )); then width=2  # Fullwidth Forms
    fi
    # after zsh 5.10+ use: out_width="$width"
    : ${(P)out_width::="$width"}
    return 0
}

# Remove escape sequences (used to set color, style, cursor pos, etc.) using zsh parameter expansion.
strip_control_chars() {
    setopt localoptions extendedglob
    local input=$1
    local output=$2 # after zsh 5.10+ use: local -n output=$2

    local cleaned=${input//*$'\x0D'/}                  # Remove everything up to and including CR

    cleaned=${cleaned//$'\033['[0-9;]#[a-zA-Z]/}       # Most CSI sequences
    cleaned=${cleaned//$'\033'[a-zA-Z]/}               # Simple ESC sequences
    cleaned=${cleaned//$'\033'[0-9]/}                  # ESC + single digit
    cleaned=${cleaned//$'\033Y'??/}                    # VT52 cursor positioning

    cleaned=${cleaned//$'\x9B'[0-9;]#[a-zA-Z]/}        # 8-bit CSI sequences
    cleaned=${cleaned//[$'\x80'-$'\x8F'$'\x91'-$'\x98'$'\x9A'$'\x9E'-$'\x9F']/} # Single-byte C1
    cleaned=${cleaned//$'\007'/}                       # Bell character (BEL)
    cleaned=${cleaned//$'\b'/}                         # Unsupported cursor-left control (BS)

    # Note using parameter expansion (above) is orders of magnitude faster than using sed
    # or anything that spawns a new process.

    # after zsh 5.10+ use: output="$cleaned"
    : ${(P)output::="$cleaned"}
    return 0
}

stripped_len() {
    local handle_widechars=$1
    local stripped=""
    strip_control_chars "$2" stripped
    local outlen=$3     # after zsh 5.10+ use: local -n outlen=$3
    local -i width=0
    if [[ $handle_widechars == "true" ]]; then
        # Optimization: only handle widechars if caller requests it.
        local -i i=1
        local -i len=${#stripped}
        while (( i <= len )); do
            local -i cw=0
            char_width "${stripped[i]}" cw
            ((width += cw))
            ((i++))
        done
    else
        width=${#stripped}
    fi
    # after zsh 5.10+ use: outlen="$width"
    : ${(P)outlen::="$width"}
    return 0
}

text_trunc() {
    local -i width=$1
    local handle_widechars=$2
    local text_str=$3
    local out_text=$4   # after zsh 5.10+ use: local -n out_text=$4

    # Strip colors to get just the visible text (otherwise padding calculation are off)
    local -i text_len=0;  stripped_len $handle_widechars "$text_str" text_len
    if (( text_len > width )); then
        local -i keep_width=$width
        local suffix=""
        if (( width > 3 )); then
            keep_width=$((width - 3))
            suffix="..."
        fi

        # Build the prefix by visible column width so wide characters are not split
        # and so truncation does not rely on negative zsh substring lengths.
        local stripped="" prefix=""
        strip_control_chars "$text_str" stripped
        local -i used_width=0 pos=1 stripped_chars=${#stripped} char_cols=0
        while (( pos <= stripped_chars )); do
            char_width "${stripped[pos]}" char_cols
            (( used_width + char_cols > keep_width )) && break
            prefix+="${stripped[pos]}"
            ((used_width += char_cols))
            ((pos++))
        done
        text_str="$prefix$suffix"
    fi
    # after zsh 5.10+ use: out_text="$text_str"
    : ${(P)out_text::="$text_str"}
    return 0
}

# Wrap a single logical line into an array of lines based on `width`. Wide characters
# (emoji/CJK) count as 2 cols and are never split across a boundary.
text_wrap() {
    local -i width=$1
    local handle_widechars=$2
    local text_str=$3
    local out_arr=$4    # after zsh 5.10+ use: local -n out_arr=$4

    # Strip escapes so measurement reflects visible columns only.
    local stripped=""
    strip_control_chars "$text_str" stripped

    local -a pieces=()
    if (( width < 1 )); then
        pieces=( "$stripped" )
        set -A "$out_arr" "${pieces[@]}"
        return 0
    fi

    if [[ $handle_widechars != "true" ]]; then
        # Fast path: every char is 1 column, so slice by character count.
        local -i len=${#stripped} pos=1
        if (( len == 0 )); then
            pieces=( "" )
        else
            while (( pos <= len )); do
                pieces+=( "${stripped[pos,pos+width-1]}" )
                (( pos += width ))
            done
        fi
        set -A "$out_arr" "${pieces[@]}"
        return 0
    fi

    # Wide-char-aware path: accumulate visible columns, breaking before a char
    # would overflow `width`.
    local -i len=${#stripped} i=1
    local cur=""
    local -i cur_cols=0 cw=0
    if (( len == 0 )); then
        pieces=( "" )
    else
        while (( i <= len )); do
            local ch="${stripped[i]}"
            char_width "$ch" cw
            if (( cur_cols + cw > width )) && [[ -n "$cur" ]]; then
                pieces+=( "$cur" )
                cur=""; cur_cols=0
            fi
            cur+="$ch"
            ((cur_cols += cw))
            ((i++))
        done
        [[ -n "$cur" ]] && pieces+=( "$cur" )
    fi
    set -A "$out_arr" "${pieces[@]}"
    return 0
}

########################################
# This encodes a file name or file path it into an absoluste file:// URL.
url_encode_file() {
    setopt localoptions extendedglob
    local filepath="${1:A}"     # :A normalizes filename/path to an absolute path
    local out_url=$2            # after zsh 5.10+ use: local -n out_url=$2
    local encoded_url="file://"

    local -i pos filepath_len=${#filepath}
    for (( pos=1; pos<=filepath_len; pos++ )); do
        local ch=${filepath[pos]}
        if [[ "$ch" == [a-zA-Z0-9._~/-] ]]; then
            encoded_url+="$ch"
        else
            local -i codepoint=$((#ch))
            local -i byte1=0 byte2=0 byte3=0 byte4=0
            local hex=""
            if (( codepoint < 0x80 )); then
                print -v hex -f "%02X" "$codepoint"
                encoded_url+="%$hex"
            elif (( codepoint < 0x800 )); then
                byte1=$((0xC0 | (codepoint >> 6)))
                byte2=$((0x80 | (codepoint & 0x3F)))
                print -v hex -f "%02X" "$byte1"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte2"; encoded_url+="%$hex"
            elif (( codepoint < 0x10000 )); then
                byte1=$((0xE0 | (codepoint >> 12)))
                byte2=$((0x80 | ((codepoint >> 6) & 0x3F)))
                byte3=$((0x80 | (codepoint & 0x3F)))
                print -v hex -f "%02X" "$byte1"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte2"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte3"; encoded_url+="%$hex"
            else
                byte1=$((0xF0 | (codepoint >> 18)))
                byte2=$((0x80 | ((codepoint >> 12) & 0x3F)))
                byte3=$((0x80 | ((codepoint >> 6) & 0x3F)))
                byte4=$((0x80 | (codepoint & 0x3F)))
                print -v hex -f "%02X" "$byte1"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte2"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte3"; encoded_url+="%$hex"
                print -v hex -f "%02X" "$byte4"; encoded_url+="%$hex"
            fi
        fi
    done
    # after zsh 5.10+ use: out_url="encoded_url"
    : ${(P)out_url::="$encoded_url"}
    return 0
}

# This extracts a UI label to show for the URL, which is the filename
# with spaces (%20) decoded. If the URL isn't pointing to a filename
# then the entire encoded URL is just returned.
url_extract_ui_label() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_label=$2       # after zsh 5.10+ use: local -n out_label=$2

    # Strip trailing slashes
    in_url="${in_url%/}"

    # Extract everything after the last slash
    local filename="${in_url##*/}"

    # If filename part exists (not empty or just query params)
    if [[ -n "$filename" && "$filename" != \?* ]]; then
        filename="${filename%%\?*}"  # Strip ?query
        filename="${filename%%\#*}"  # Strip #fragment

        # Test for filename extensions.
        if [[ "$filename" == *.* && "$filename" != .* ]]; then
            # Test against common extensions
            local extension="${filename##*.}"
            if [[ "${extension:l}" == (txt|out|html|htm|pdf|doc|docx|zip|tar|gz|json|xml|csv|md|js|css|py|sh|zsh|conf|toml|yaml|yml|log) ]]; then
                filename=${filename//\%20/ }  # for display labels convert encoded spaces back to space chars.
                # after zsh 5.10+ use: out_label="filename"
                : ${(P)out_label::="$filename"}
                return 0
            fi
            # # Or just assume if extension < 6 characters it is likely a file?
            # if (( ${#extension} <= 5 )); then
            #     filename=${filename//%20/ }  # for display labels convert encoded spaces back to space chars.
            #     # after zsh 5.10+ use: out_label="filename"
            #     : ${(P)out_label::="$filename"}
            #     return 0
            # fi
        fi
    fi

    # Default to returning the full URL if we aren't confident we can extract a filename.
    # after zsh 5.10+ use: out_label="in_url"
    : ${(P)out_label::="$in_url"}
    return 0
}

# This escape encodes the URL arg (file://, http://, etc.) into an OSC 8 hyperlink
# sequence. Terminals that do not support OSC 8 use the plain-text fallback below.
url_term_render() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_text=$2       # after zsh 5.10+ use: local -n out_text=$2
    local url_text=""

    local label=""
    url_extract_ui_label "$in_url" label

    local url_glyph="🔗"
    if [[ "$in_url" == file://* ]]; then
        local url_glyph="🧾"
    fi

    # These terminal identifiers are commonly used by OSC 8-capable terminals.
    # Multiplexers are intentionally omitted because OSC 8 passthrough depends on
    # their version and configuration.
    local -i render_blue=0
    if [[ "${TERM_PROGRAM:l}" == (iterm.app|apple_terminal|wezterm|kitty|ghostty|vscode|alacritty|hyper|windows_terminal|konsole|gnome|foot|contour|mintty|rio|warp|warpterminal|tabby|tilix) ]]; then
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s \033]8;;%s\007%s\033]8;;\007${PV_RESET}" "$url_glyph" "$in_url" "$label"
        else
            print -v url_text -f "%s \033]8;;%s\007%s\033]8;;\007" "$url_glyph" "$in_url" "$label"
        fi
    else
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s %s${PV_RESET}" "$url_glyph" "$label"
        else
            print -v url_text -f "%s %s" "$url_glyph" "$label"
        fi
    fi
    # after zsh 5.10+ use: out_text="$url_text"
    : ${(P)out_text::="$url_text"}
    return 0
}

########################################
typeset -i _TERM_BG_ISDARK_RTN_VAL=-1
term_bg_isdark() {
    if ((_TERM_BG_ISDARK_RTN_VAL != -1)); then
        return $_TERM_BG_ISDARK_RTN_VAL
    fi

    local -i is_dark=1   # Default to dark (1) if all queries below fail.
    if [[ -n "$COLORFGBG" ]]; then
        local bg_color_index="${COLORFGBG##*;}"
        if (( bg_color_index < 8 )); then
            is_dark=1   # Dark background
        else
            is_dark=0   # Light background
        fi
    else
        # $COLORFGBG not defined (caller probably using SSH), so query terminal directly.
        if program_exists "stty"; then
            local saved_settings=$(stty -g 2>/dev/null)
            if [[ -n "$saved_settings" ]]; then
                {
                    stty raw -echo min 0 time 3 2>/dev/null
                    printf '\033]11;?\a' > /dev/tty  # Make sure query goes to terminal
                    local response=""
                    local char
                    while read -t 2 -k 1 char 2>/dev/null; do
                        response+="$char"
                        [[ "$char" == $'\a' || "$response" == *$'\033\\' ]] && break
                    done
                    stty "$saved_settings" 2>/dev/null

                    if [[ "$response" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
                        local r=$((16#${match[1]:0:2}))  # zsh arithmetic with hex
                        local g=$((16#${match[2]:0:2}))
                        local b=$((16#${match[3]:0:2}))
                        local luminance=$(((r * 299 + g * 587 + b * 114) / 1000))
                        # echo "DEBUG: RGB L=$r $g $b   $luminance" > /dev/tty; sleep 5
                        if (( luminance < 128 )); then
                            is_dark=1
                        else
                            is_dark=0
                        fi
                    fi
                } 2>/dev/null
            fi
        fi
    fi
    if ((is_dark)); then
        _TERM_BG_ISDARK_RTN_VAL=0
    else
        _TERM_BG_ISDARK_RTN_VAL=1
    fi
    return $_TERM_BG_ISDARK_RTN_VAL
}

if term_bg_isdark; then
    # Dark terminal background - use bright foreground colors
    LOG_TEXT_COLOR='\033[37m'           # Light gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[96m'    # Bright cyan for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[96m'      # Bright cyan for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[92m'   # Bright green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[93m'   # Bright yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[91m'   # Bright red for failure text messages
else
    # Light terminal background - use dark foreground colors
    LOG_TEXT_COLOR='\033[90m'           # Dark gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[34m'    # Dark blue for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[34m'      # Dark blue for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[32m'   # Dark green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[33m'   # Dark yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[31m'   # Dark red for failure text messages
fi

########################################
_yield_for_term_resizing() {
    # Before calling pv_get_term_width/height, we must force zsh to hit its execution
    # boundary which will update $COLUMNS and $LINES (which our pv_get_term_*
    # funcs use). If we don't do this then we never detect window resizing. I tried
    # using local trap on WINCH and the global TRAPWINCH() function, but those will not
    # work either without the execution boundary processing. The local trap on WINCH is only
    # processed when execution boundary is hit. The global TRAPWINCH() function is called
    # immediately (via signal) BUT any variables it updates (like RESIZE_NEEDED=1) will
    # not be reflected in our loop here until the execution boundary. The only solution
    # would be to write to a temp FD inside TRAPWINCH() that we then add to our zselect,
    # but even with that we would then (here) still need to force the execution boundary
    # (using /usr/bin/true, sleep 0.01, etc.) to have $COLUMNS and $LINES updates, so
    # the only gain is that we would process the resize more quickly. Given our zselect
    # delay here is very short (PV_SPINNER_UPDATE_INTERVAL), we will handle the resize
    # quickly enough without all that extra overhead/code.
    /usr/bin/true
    # Here are a couple of alternative techniques for forcing execution boundary that
    # are slower. I tried to find a way to trip it without having to call/spawn a
    # new process but couldn't find any that worked.
    #   : | :
    #   sleep 0.001
    return 0
}

_render_label_processing() {
    local label=$1
    pv_tput_rmam  # disable auto-wrapping of lines
    printf "  ${PROCESSING_TEXT_COLOR}%s${PV_RESET}" "$label"
    pv_tput_el
    pv_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_done() {
    local label=$1
    local label_color=$2
    local outfile=$3

    pv_tput_rmam  # disable auto-wrapping of lines
    local outfile_term_rendered=""
    if [[ -n "$outfile" ]]; then
        local outfile_url=""
        url_encode_file "$outfile" outfile_url
        url_term_render "$outfile_url" outfile_term_rendered

        local -i label_width=${#label}
        local -i log_to_padding=$((PV_LOG_TO_PADDING - label_width))
        ((log_to_padding < 1)) && log_to_padding=1
        printf "${label_color}%s${PV_RESET}%*s logged to: %s" "$label" "$log_to_padding" "" "$outfile_term_rendered"
    else
        printf "${label_color}%s${PV_RESET}" "$label"
    fi
    pv_tput_el
    pv_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_success() {
    local label=$1
    local outfile=$2

    print -v label -f "✓ %s success" "$label"
    _render_label_done "$label" "$PROCESSING_TEXT_COLOR" "$outfile"
    return 0
}

_render_label_failure() {
    local label=$1
    local outfile=$2
    local rc=$3

    print -v label -f "✗ %s failed with rc %d" "$label" "$rc"
    _render_label_done "$label" "$MSG_FAILURE_TEXT_COLOR" "$outfile"
    return 0
}

_append_log_timestamp() {
    local outfile="$1"
    local msg="${@:2}"  # Capture args 2+ directly

    if [[ -z "$outfile" ]]; then
        return 0
    fi
    local parent_dir="$(dirname "$outfile")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir" 2>/dev/null
    fi

    if [[ -f "$outfile" && -s "$outfile" ]]; then
        local border_str=${(l:86::━:):""}
        printf "\n\n%s\n" "$border_str" >> "$outfile"
    fi
    print "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$outfile"
    return 0
}

_start_popview() {
    local label=$1
    local pending_frag="$PV_PENDING_FRAG"
    pv_get_term_width PV_WIN_ORIG_WIDTH; pv_get_term_height PV_WIN_ORIG_HEIGHT

    print                               # Placeholder for label (will be filled in below)
    local -i placeholder_lines_needed="$PV_MAX_HEIGHT"
    if ((PV_BORDER_SHOW)); then
        local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
        local border_str=${(l:$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 2))::─:):""}
        print -v PV_TOP_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╭%s╮${PV_RESET}" "$padleft_str" "$border_str"
        print -v PV_BOT_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╰%s╯${PV_RESET}" "$padleft_str" "$border_str"
        print                           # Placeholder for top border
        ((placeholder_lines_needed++))  # Additional placeholder line needed for bottom border
    fi
    local -i count
    for (( count = 1; count < placeholder_lines_needed; count++ )); do
        print                           # Placeholders for scroll view output region
    done

    # Render the task label above the scroll view.
    pv_get_cursor_row PV_TOP_ANCHOR
    PV_TOP_ANCHOR=$((PV_TOP_ANCHOR - PV_MAX_HEIGHT))
    ((PV_BORDER_SHOW)) && ((PV_TOP_ANCHOR-=2))
    ((PV_TOP_ANCHOR < 0)) && PV_TOP_ANCHOR=0
    pv_tput_cup $PV_TOP_ANCHOR 0
    _render_label_processing "$label"

    # Define scroll region to PV_MAX_HEIGHT rows (enabled later when first output line arrives).
    PV_TOP_SCROLLREGION=$((PV_TOP_ANCHOR + 1))
    ((PV_BORDER_SHOW)) && ((PV_TOP_SCROLLREGION++))
    PV_BOT_SCROLLREGION=$((PV_TOP_SCROLLREGION + PV_MAX_HEIGHT - 1))
    pv_tput_cup "$PV_TOP_SCROLLREGION" 0   # move cursor to top-left of scroll region
    PV_CUR_HEIGHT=0
    PV_SCROLL_ON_NEXT_LN=0
    PV_ROW_PAINTED=0
    if [[ -n "$pending_frag" ]]; then
        local -i pending_width=$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 4))
        _paint_row "$pending_frag" "$pending_width"
    fi
    return 0
}

_end_popview_leave_open() {
    local label=$1
    local outfile=$2
    local rc=$3
    local -i display_height=$PV_CUR_HEIGHT
    (( PV_CUR_HEIGHT < PV_MAX_HEIGHT && PV_ROW_PAINTED )) && ((display_height++))

    pv_tput_cup $PV_TOP_ANCHOR 0
    if (( rc == 0 )); then
        _render_label_success "$label" "$outfile"
    else
        _render_label_failure "$label" "$outfile" "$rc"
        if ((PV_BORDER_SHOW && display_height > 0)); then
            # Re-render the border in red (leaving text inside view untouched).
            pv_get_term_width PV_WIN_ORIG_WIDTH; pv_get_term_height PV_WIN_ORIG_HEIGHT

            local -i rt_border_xpos=$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_RIGHT - 1))
            local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}
            local border_str=${(l:$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 2))::─:):""}
            print -v PV_TOP_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╭%s╮${PV_RESET}" "$padleft_str" "$border_str"
            print -v PV_BOT_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╰%s╯${PV_RESET}" "$padleft_str" "$border_str"

            print "$PV_TOP_BORDER_STR"
            local -i index=0    ypos=$PV_TOP_SCROLLREGION
            for (( index = 0; index < display_height; index++, ypos++ )); do
                pv_tput_cup "$ypos" 0;                  printf "%s${MSG_FAILURE_TEXT_COLOR}│" "$padleft_str"
                pv_tput_cup "$ypos" "$rt_border_xpos";  print "│${PV_RESET}"
            done
            print "$PV_BOT_BORDER_STR"
            return 0
        fi
    fi
    if ((display_height > 0)); then
        local -i ypos=$((PV_TOP_SCROLLREGION + display_height - 1))
        ((PV_BORDER_SHOW)) && ((ypos++))
        pv_tput_cup "$ypos" 0
        print
    fi
    return 0
}

_end_popview_with_close() {
    local label=$1
    local outfile=$2

    pv_tput_cup $PV_TOP_ANCHOR 0
    _render_label_success "$label" "$outfile"
    if ((PV_CUR_HEIGHT == 0)); then
        return 0  # Nothing was ever rendered, so no cleanup needed.
    fi

    pv_sleep $PV_CLOSE_PAUSE_DELAY
    local -i unused_width=0 unused_height=0
    if _process_win_resize unused_width unused_height; then
        _render_label_success "$label" "$outfile"
        return 0
    fi

    if ((PV_BORDER_SHOW && PV_BORDER_ANIMATE_CLOSE)); then
        # PV_CUR_HEIGHT counts committed rows. Before the frame is full, _paint_row()
        # also leaves an uncommitted current row on screen after output ending in LF;
        # include that row so the bottom border remains inside the closing scroll
        # region. Once full, the current row is already the last row of the region.
        local -i close_height=$PV_CUR_HEIGHT
        (( PV_CUR_HEIGHT < PV_MAX_HEIGHT && PV_ROW_PAINTED )) && ((close_height++))
        PV_BOT_SCROLLREGION=$((PV_TOP_SCROLLREGION + close_height))
        pv_tput_csr "$PV_TOP_SCROLLREGION" "$PV_BOT_SCROLLREGION"; PV_INSIDE_TPUTCSR=1
        pv_tput_cup "$((PV_TOP_SCROLLREGION + close_height))" 0
        local -i index
        for (( index = 0; index < close_height; index++ )); do
            print
            pv_sleep $PV_CLOSE_FRAME_DELAY
            if _process_win_resize unused_width unused_height; then
                _render_label_success "$label" "$outfile"
                return 0
            fi
        done
        ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
        pv_tput_cup "$((PV_TOP_ANCHOR + 2))" 0;     pv_tput_el
        pv_tput_cup "$((PV_TOP_ANCHOR + 1))" 0;     pv_tput_el
    else
        local -i top=$((PV_TOP_ANCHOR + 1))
        local -i bottom=$((PV_BOT_SCROLLREGION))
        if ((PV_BORDER_SHOW)); then
            ((bottom++))
        fi
        local -i row
        for (( row = bottom; row >= top; row-- )); do
            pv_tput_cup $row 0;     pv_tput_el
            if ((PV_BORDER_ANIMATE_CLOSE)); then
                pv_sleep $PV_CLOSE_FRAME_DELAY
            fi
        done
    fi
    return 0
}

_render_progress_spinner() {
    if (( EPOCHREALTIME - PV_SPINNER_LAST_UPDATE < PV_SPINNER_UPDATE_INTERVAL )); then
        return 0
    fi
    PV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
    pv_tput_cup $PV_TOP_ANCHOR 0
    printf "%s" "${PV_SPINNER_CHARS[PV_SPINNER_IDX]}"
    ((PV_SPINNER_IDX++ && PV_SPINNER_IDX > PV_SPINNER_LEN)) && PV_SPINNER_IDX=1
    return 0
}

# Compute the row (0-based terminal row) of the current "bottom" content line.
# While the frame is still growing this is the PV_CUR_HEIGHT-th row; once the frame
# is full (scroll region locked) the current row is always the last region row.
_pv_current_row() {
    local out_row=$1
    local -i row
    if (( PV_CUR_HEIGHT < PV_MAX_HEIGHT )); then
        row=$(( PV_TOP_SCROLLREGION + PV_CUR_HEIGHT ))
    else
        row=$(( PV_TOP_SCROLLREGION + PV_MAX_HEIGHT - 1 ))
    fi
    : ${(P)out_row::="$row"}
    return 0
}

# Draw text on the CURRENT bottom row, in place. Only advances the scroll region
# if PV_SCROLL_ON_NEXT_LN==1 (meaning _commit_row() was called). Otherwise, it
# doesn't scroll and will paint over the existing current line. Used identically
# for: a still-growing prompt fragment, the user's typed input echo, and a
# finalized (newline-terminated) line. Caller is responsible for calling
# _commit_row() when there is a line ending to advance/scroll to a new line.
_paint_row() {
    local text=$1
    local width=$2

    local noesc_text=""
    strip_control_chars "$text" noesc_text
    ((${#noesc_text} > width)) && noesc_text="${noesc_text[1,$width]}"

    pv_tput_rmam   # disable auto-wrapping of lines
    pv_start_buffered_update

    # Ensure the top border exists before the very first row is drawn.
    if ((PV_BORDER_SHOW && PV_CUR_HEIGHT == 0)); then
        pv_tput_cup "$((PV_TOP_SCROLLREGION - 1))" 0
        print "$PV_TOP_BORDER_STR"
    # If a previous full-height commit owes a scroll, do it now (via `print`) to
    # open a fresh bottom row (to be rendered to below).
    elif (( PV_SCROLL_ON_NEXT_LN )); then
        PV_SCROLL_ON_NEXT_LN=0
        pv_tput_cup "$((PV_TOP_SCROLLREGION + PV_MAX_HEIGHT - 1))" 0
        print
    fi

    local -i ypos=0; _pv_current_row ypos
    local padleft_str=${(l:$PV_BORDER_MARGIN_LEFT:: :):""}

    if ((PV_BORDER_SHOW)); then
        # Double-width safe right border trick (preserved): print left border + text
        # with %-*s (may overshoot on wide chars), then force the cursor to the exact
        # right-border column, draw it, and clear to end-of-line.
        pv_tput_cup "$ypos" 0
        printf "%s${PROCESSING_TEXT_COLOR}│ ${LOG_TEXT_COLOR}%-*s " "$padleft_str" "$width" "$noesc_text"
        pv_tput_cup "$ypos" "$((PV_WIN_ORIG_WIDTH - PV_BORDER_MARGIN_RIGHT - 1))"
        print -n "${PROCESSING_TEXT_COLOR}│${PV_RESET}";    pv_tput_el
        # While growing, keep the bottom border painted one row below the current row.
        if ((PV_CUR_HEIGHT < PV_MAX_HEIGHT)); then
            pv_tput_cup "$((ypos + 1))" 0
            print -n "$PV_BOT_BORDER_STR";    pv_tput_el
        fi
    else
        pv_tput_cup "$ypos" 0
        printf "%s  ${LOG_TEXT_COLOR}%-*s${PV_RESET}  " "$padleft_str" "$width" "$noesc_text";    pv_tput_el
    fi

    pv_end_buffered_update
    pv_tput_smam   # re-enable auto-wrapping of lines
    PV_ROW_PAINTED=1
    return 0
}

# Flag (via PV_SCROLL_ON_NEXT_LN) that the current row is complete and the next row
# (when _paint_row() is called) should advance/scroll to the next line. When the
# maximum height of the scroll view is reached the scroll region is locked in so
# that the vertical line scrolling region is correct.
_commit_row() {
    PV_ROW_PAINTED=0
    if (( PV_CUR_HEIGHT < PV_MAX_HEIGHT )); then
        ((PV_CUR_HEIGHT++))
        if (( PV_CUR_HEIGHT == PV_MAX_HEIGHT )); then
            # Frame just filled: lock the scroll region so subsequent _paint_row() scrolls.
            pv_tput_csr "$PV_TOP_SCROLLREGION" "$PV_BOT_SCROLLREGION"; PV_INSIDE_TPUTCSR=1
            PV_SCROLL_ON_NEXT_LN=1
        fi
    else
        # Frame is full: lock the scroll region so subsequent _paint_row() scrolls.
        PV_SCROLL_ON_NEXT_LN=1
    fi
    return 0
}

_relay_keyboard_stdin() {
    local -i width=$1

    # Pull all immediately-available keyboard input (we already know fd 0 is readable).
    local keys="" ch=""
    IFS= read -r -k 1 -u 0 ch && keys+="$ch"
    while IFS= read -r -t 0 -k 1 -u 0 ch; do
        keys+="$ch"
    done
    [[ -z "$keys" ]] && return 0

    # Forward the raw bytes to the running command's stdin (PV_FD_IN).
    #
    # If there is a PTY active (PV_PTY_ACTIVE), then a terminal echo will occur
    # (along with line editing handling) and the keys pressed will be relayed to
    # PV_FD_OUT and handled inside _process_popview().
    print -rn -- "$keys" >&$PV_FD_IN

    # If there not a PTY active, then the input was relayed to the command via
    # the `print` call above (same as PTY active case) but it will not be echoed
    # or relayed to PV_FD_OUT.
    if (( ! PV_PTY_ACTIVE )); then
        # A plain pipe (no PTY) will have no terminal echo or line editing handling.
        # Just display each byte as it was forwarded instead of pretending that line
        # edit are actually beind performed. LF/CR commits the displayed row; other
        # controls show caret notation because rendering them literally would make
        # the display terminal perform the formatting.
        local kc=""
        local -i k=0 kc_code=0 caret_code=0 previous_was_cr=0
        for (( k = 1; k <= ${#keys}; k++ )); do
            kc="${keys[k]}"
            kc_code=$((#kc))
            if (( kc_code == 10 || kc_code == 13 )); then
                # Treat CRLF as one Return if both bytes arrive in the same batch.
                if (( kc_code == 10 && previous_was_cr )); then
                    previous_was_cr=0
                    continue
                fi
                _paint_row "$PV_PENDING_FRAG" "$width"
                _commit_row
                PV_PENDING_FRAG=""
                previous_was_cr=$((kc_code == 13))
            elif (( kc_code == 127 )); then
                previous_was_cr=0
                PV_PENDING_FRAG+="^?"
            elif (( kc_code < 32 )); then
                previous_was_cr=0
                caret_code=$((kc_code + 64))
                PV_PENDING_FRAG+="^${(#)caret_code}"
            else
                previous_was_cr=0
                PV_PENDING_FRAG+="$kc"
            fi
        done
        _paint_row "$PV_PENDING_FRAG" "$width"
    fi

    if [[ "$keys" == *$'\r'* || "$keys" == *$'\n'* ]]; then
        # <LF> or <CR> indicates that the input might be complete. Reset prompt state to
        # command busy (0) to hide the cursor until the command emits another candidate.
        PV_INPUT_ACTIVE=0
        PV_PROMPT_STATE=0
        PV_PROMPT_CANDIDATE_SINCE=0
    else
        # Once the user types, keep the cursor visible until submission. This is just
        # a heuristic and won't be 100% accurate.
        PV_INPUT_ACTIVE=1
        PV_PROMPT_STATE=2
    fi
    return 0
}

# Place the cursor at the end of the current prompt fragment and reveal it.
# Best-effort (positions within the box).
_show_prompt_cursor() {
    local -i width=$1
    local -i ypos=0; _pv_current_row ypos

    # Visible columns used by the prompt text (escape/wide-char aware), clamped to box.
    local -i cols=0
    stripped_len "true" "$PV_PENDING_FRAG" cols
    (( cols > width )) && cols=width

    local -i xpos=$(( PV_BORDER_MARGIN_LEFT + 2 + cols ))
    pv_tput_cup "$ypos" "$xpos"
    pv_tput_cnorm
    return 0
}

_process_win_resize() {
    local out_width=$1 out_height=$2    # after zsh 5.10+ use: local -n out_width=$1 out_height=$2

    # must call yield before pv_get_term_width / pv_get_term_height
    _yield_for_term_resizing
    local -i width=0 height=0
    pv_get_term_width width; pv_get_term_height height
    # after zsh 5.10+ use: out_width="$width" and out_height="$height"
    : ${(P)out_width::="$width"}
    : ${(P)out_height::="$height"}

    if ((width != PV_WIN_ORIG_WIDTH || height != PV_WIN_ORIG_HEIGHT)); then
        # Window resize detected. There isn't a graceful way to re-render everything
        # already shown, so we clear the screen, and have ther caller reprint the
        # label.
        PV_WIN_TOO_SMALL=$((width < PV_MIN_WIN_WIDTH || height < PV_MIN_WIN_HEIGHT))
        ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
        pv_tput_clear
        return 0
    fi
    return 1
}

_process_popview() {
    local label=$1
    local -i allow_interactive=${2:-$PV_ALLOW_INTERACTIVE}
    if [[ -z $PV_PID || -z $PV_FD_OUT ]]; then
        return 0   # No pending async process, bail out.
    fi

    local -i select_timeout=$((100 * PV_SPINNER_UPDATE_INTERVAL))
    while true; do
        (( PV_SIGNAL )) && break
        local -i coprocess_stdout_readable=0
        local -i keyboard_stdin_readable=0
        if ((allow_interactive)); then
            # Watch for both the coproc output AND our stdin so we can relay keystrokes.
            local -a ready_fds=()
            if zselect -a ready_fds -t $select_timeout -r $PV_FD_OUT -r 0; then
                (( ${ready_fds[(Ie)$PV_FD_OUT]} )) && coprocess_stdout_readable=1
                (( ${ready_fds[(Ie)0]} ))          && keyboard_stdin_readable=1
            fi
        else
            zselect -t $select_timeout -r $PV_FD_OUT && coprocess_stdout_readable=1
        fi

        local -i cur_width=0 unused_height=0
        if _process_win_resize cur_width unused_height; then
            if ((PV_WIN_TOO_SMALL)); then
                # Window shrank to be too small for useful rendering. Just
                # Re-render the processing label and bail out from trying.
                ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
                _render_label_processing "$label"
                return 0
            else
                # Window resized but is still large enough. Reset and restart
                # the scroll view and continue rendering loop.
                _start_popview $label
            fi
        fi
        (( PV_SIGNAL )) && break
        local -i width=$((cur_width - PV_BORDER_MARGIN_LEFT - PV_BORDER_MARGIN_RIGHT - 4))

        if (( keyboard_stdin_readable )) && [[ -n "$PV_FD_IN" ]]; then
            # Relay any pending keystrokes into the running command's stdin.
            _relay_keyboard_stdin "$width"
        fi
        (( PV_SIGNAL )) && break

        if (( coprocess_stdout_readable )); then
            # Drain everything currently available from the coprocess output without
            # blocking on a trailing newline. Complete lines render normally; a trailing
            # fragment (a prompt with no newline) is stashed and rendered on the next
            # idle tick.
            local first_char=""
            if ! IFS= read -r -k 1 -u $PV_FD_OUT first_char; then
                # EOF: finalize any trailing partial as a committed line, then bail out.
                if [[ -n "$PV_PENDING_FRAG" ]]; then
                    _paint_row "$PV_PENDING_FRAG" "$width"
                    _commit_row
                    PV_PENDING_FRAG=""
                fi
                PV_INPUT_ACTIVE=0
                PV_PROMPT_STATE=0
                PV_PROMPT_CANDIDATE_SINCE=0
                break
            fi
            PV_PENDING_FRAG+="$first_char"

            local next_char=""
            while IFS= read -r -t 0 -k 1 -u $PV_FD_OUT next_char; do
                PV_PENDING_FRAG+="$next_char"
            done

            # Narrow PTY-editing support: recognize only the conventional cooked-mode
            # rub-out echo "\b \b" (likely delete key). Apply it to the combined pending
            # data so preceding characters from this same chunk are removed correctly
            # and a sequence split across two reads is recognized. Bare backspaces, ANSI
            # cursor editing, etc., are deliberately not handled to keep implementation
            # simple.
            if (( PV_PTY_ACTIVE )); then
                local rubout=$'\b \b'
                while [[ "$PV_PENDING_FRAG" == *${rubout}* ]]; do
                    local before_rubout="${PV_PENDING_FRAG%%${rubout}*}"
                    local after_rubout="${PV_PENDING_FRAG#*${rubout}}"
                    PV_PENDING_FRAG="${before_rubout%?}${after_rubout}"
                done
            fi

            # Normalize all line endings to LF. Under a PTY the terminator can be
            # '\r\n' or a bare '\r'; on a plain pipe it is '\n'. Progress-bar style
            # bare-CR redraws on a plain pipe are handled by treating them as line
            # ends here too, which is fine for our row-at-a-time model.
            local nl=$'\n' cr=$'\r'
            PV_PENDING_FRAG="${PV_PENDING_FRAG//${cr}${nl}/${nl}}"
            PV_PENDING_FRAG="${PV_PENDING_FRAG//${cr}/${nl}}"

            # Paint and commit each completed (LF-terminated) line. One scroll per LF.
            local -i completed_line=0
            while [[ "$PV_PENDING_FRAG" == *${nl}* ]]; do
                local oneline="${PV_PENDING_FRAG%%${nl}*}"
                PV_PENDING_FRAG="${PV_PENDING_FRAG#*${nl}}"
                completed_line=1
                if (( PV_WRAP_LINES )); then
                    # Wide-char-aware wrap: split the logical line into rows of at
                    # most `width` visible columns, painting/committing each piece.
                    local -a _wrapped=()
                    text_wrap "$width" "true" "$oneline" _wrapped
                    local _piece=""
                    for _piece in "${_wrapped[@]}"; do
                        _paint_row "$_piece" "$width"
                        _commit_row
                    done
                else
                    _paint_row "$oneline" "$width"
                    _commit_row
                fi
            done

            # A trailing partial is a prompt candidate, not proof of a prompt. Paint it
            # in place, but keep the cursor hidden until it remains unchanged for
            # PV_PROMPT_SETTLE_INTERVAL. Resetting the timestamp on every output chunk
            # prevents a temporarily split normal line from flashing the input cursor.
            # User typing (PV_INPUT_ACTIVE == 1) is stronger prompt state evidence and
            # keeps prompting (input cursor) active (PV_PROMPT_STATE == 2).
            if [[ -n "$PV_PENDING_FRAG" ]]; then
                if (( PV_INPUT_ACTIVE )); then
                    PV_PROMPT_STATE=2
                else
                    PV_PROMPT_STATE=1
                    PV_PROMPT_CANDIDATE_SINCE=$EPOCHREALTIME
                fi
                _paint_row "$PV_PENDING_FRAG" "$width"
            else
                # A completed output line always opens a fresh visual row and hides
                # the input cursor. The command script might still be expecting another
                # line of input, but there is no way we can determine that so the cursor
                # just remains hidden until the user starts to type. Best we can do.
                PV_INPUT_ACTIVE=0
                PV_PROMPT_STATE=0
                PV_PROMPT_CANDIDATE_SINCE=0
                (( completed_line )) && _paint_row "" "$width"
            fi
        else
            # Idle case: command is either busy or waiting for input. We promote to
            # showing the input cursor only after a partial frag output and after
            # PV_PROMPT_SETTLE_INTERVAL time has passed.
            if (( PV_PROMPT_STATE == 1 )) &&
               (( EPOCHREALTIME - PV_PROMPT_CANDIDATE_SINCE >= PV_PROMPT_SETTLE_INTERVAL )); then
                PV_PROMPT_STATE=2
            fi
        fi

        # The spinner means only that the child cmd is still running, so it is always
        # rendered. Prompt detection independently controls cursor visibility. Paint
        # the spinner first because it moves the terminal cursor to the label row.
        _render_progress_spinner
        if (( PV_PROMPT_STATE == 2 )); then
            _show_prompt_cursor "$width"
        else
            pv_tput_civis
        fi
    done
    # reset scroll region to full screen
    ((PV_INSIDE_TPUTCSR)) && pv_tput_rcsr; PV_INSIDE_TPUTCSR=0
    return 0
}

_show_usage() {
    local cmd_name=$1
    print -u2 "usage: $cmd_name [-l label] [-o outfile] cmd [args...]"
    return 0
}

typeset -g PV_INIT=0
pv_init() {
    (( PV_INIT )) && return
    PV_INIT=1

    zmodload -F zsh/terminfo    # for echoti() func
    zmodload zsh/datetime       # for $EPOCHREALTIME var
    zmodload zsh/zselect        # for zselect() func

    typeset -gi PV_ENABLE=1                    # 0 to disable dynamic scrolling popview on task execution
    typeset -gi PV_WRAP_LINES=1                # 0 to truncate lines instead of wrapping
    typeset -gi PV_BORDER_SHOW=1
    typeset -gi PV_BORDER_ANIMATE_CLOSE=1
    typeset -gi PV_MAX_HEIGHT=13
    typeset -gi PV_BORDER_MARGIN_LEFT=2        # 2 character margin on left border
    typeset -gi PV_BORDER_MARGIN_RIGHT=2       # 2 character margin on right border
    typeset -gi PV_LOG_TO_PADDING=50           # 50 character padding before rendering label "logged to: "

    typeset -gi PV_DEBUG_SKIP_CLOSE=0          # if enabled scroll view is not closed (even if successful)
    typeset -gF PV_CLOSE_PAUSE_DELAY=1.75      # short pause before erasing and closing views
    typeset -gF PV_CLOSE_FRAME_DELAY=0.035     # delay between animation frames during view closing

    typeset -gi PV_MIN_WIN_WIDTH=$((PV_BORDER_MARGIN_LEFT + PV_BORDER_MARGIN_RIGHT + 12))
    typeset -gi PV_MIN_WIN_HEIGHT=$((PV_MAX_HEIGHT + 8))
    typeset -gi PV_WIN_TOO_SMALL=0

    typeset -gi PV_ALLOW_INTERACTIVE=1          # 1 to relay keystrokes into the running command
    typeset -g PV_PID=""   PV_FD_OUT=""   PV_FD_IN=""
    typeset -gi PV_SIGNAL=0
    typeset -g PV_SAVED_TTY=""
    typeset -g PV_PENDING_FRAG=""               # trailing bytes with no newline yet (likley a prompt)
    typeset -gi PV_SCROLL_ON_NEXT_LN=0          # 1 when the next _paint_row() should scroll before next line
    typeset -gi PV_ROW_PAINTED=0                # 1 when the current row is painted but not yet committed
    typeset -gi PV_PTY_ACTIVE=0                 # 1 when child command runs under a PTY
    typeset -gi PV_PROMPT_STATE=0               # 0: command busy, 1: possible prompt (non-empty input frag), 2: active prompting
    typeset -gi PV_INPUT_ACTIVE=0               # user has typed but has not submitted the line
    typeset -gF PV_PROMPT_CANDIDATE_SINCE=0
    typeset -gF PV_PROMPT_SETTLE_INTERVAL=0.25  # unchanged non-empty input frag duration required before showing cursor

    typeset -g PV_TOP_BORDER_STR=""      PV_BOT_BORDER_STR=""
    typeset -gi PV_WIN_ORIG_WIDTH=0      PV_WIN_ORIG_HEIGHT=0
    typeset -gi PV_TOP_ANCHOR=0
    typeset -gi PV_TOP_SCROLLREGION=0    PV_BOT_SCROLLREGION=0
    typeset -gi PV_CUR_HEIGHT=0
    typeset -gi PV_INSIDE_TPUTCSR=0

    typeset -gF PV_SPINNER_UPDATE_INTERVAL=0.15
    typeset -gF PV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
    typeset -ga PV_SPINNER_CHARS=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )
                  # alternative: ( "⠁" "⠈" "⠐" "⠠" "⢀" "⡀" "⠄" "⠂" )
    typeset -gi PV_SPINNER_LEN=${#PV_SPINNER_CHARS[@]}
    typeset -gi PV_SPINNER_IDX=1

    typeset -g PV_BOLD='\033[1m'         PV_UNBOLD='\033[22m'
    typeset -g PV_RESET='\033[0m'
}

pv_exec() {
    emulate -L zsh
    setopt localtraps
    pv_init

    local label outfile
    local -i allow_interactive=0
    while (( $# )); do
        case $1 in
        -l)
            if (( $# < 2 )); then
                print -u2 "Error: option '-l' requires a label"
                _show_usage "${0:t}"
                return 2
            fi
            label=$2;         shift 2 ;;
        -o)
            if (( $# < 2 )); then
                print -u2 "Error: option '-o' requires an outfile"
                _show_usage "${0:t}"
                return 2
            fi
            outfile=$2;       shift 2 ;;
        -l*) label=${1#-l};   shift   ;;
        -o*) outfile=${1#-o}; shift   ;;
        --)                   shift; break ;;
        -*)  print -u2 "Error: unknown option '$1'"; _show_usage "${0:t}"; return 2 ;;
        *)                    break ;;   # first non-option => command+args starts
        esac
    done
    (( $# )) || { print -u2 "Error: missing cmd"; _show_usage "${0:t}"; return 2; }

    if [[ -z "$label" ]]; then  # If no label specified use the cmd and escaped args as label
        label="${(j: :)${(q)@}}"
    fi
    # truncate label and add "..." to leave room for "logged to: " text added later.
    label_max_len=$((PV_LOG_TO_PADDING - 12))
    text_trunc "$label_max_len" "true" "$label" label
    [[ $label == *... ]] || label+="..."

    local -i width=0 height=0
    pv_get_term_width width; pv_get_term_height height
    if ((PV_ENABLE == 0 || width < PV_MIN_WIN_WIDTH || height < PV_MIN_WIN_HEIGHT)); then
        _render_label_processing "$label"
        # Note in this case interactive (keyboard) input is not handled. No plans to change
        # the handling of this edge case given complexity involved.
        if [[ -n "$outfile" ]]; then
            # Scrolling popview not enabled (or window to narrow); only capture output to file.
            _append_log_timestamp "$outfile" "$@"
            command -- "$@" 1>> "$outfile" 2>&1
        else
            # No output file specified; output is not captured and only process error code is checked.
            command -- "$@" &>/dev/null
        fi
        local rc=$?
        if (( rc == 0 )); then
            _render_label_success "$label" "$outfile"
        else
            _render_label_failure "$label" "$outfile" "$rc"
        fi
        return rc
    fi
    PV_WIN_TOO_SMALL=0

    # Else scrolling popview is enabled, so we'll capture the output as it comes and
    # temporarily display it until process is finished.
    if [[ -n $PV_PID ]]; then
        # Cannot call coproc again, so don't allow recursion.
        ERR_STR="Error: pv_exec cannot be called recursively or asynchronously"
        printf "${MSG_FAILURE_TEXT_COLOR}${PV_BOLD}%s${PV_RESET}\n" "$ERR_STR"
        return 2
    fi

    PV_PID=""; PV_FD_OUT=""; PV_FD_IN=""
    PV_PENDING_FRAG=""
    PV_PROMPT_STATE=0
    PV_INPUT_ACTIVE=0
    PV_PROMPT_CANDIDATE_SINCE=0
    PV_SIGNAL=0
    PV_SAVED_TTY=""

    # Interactive keyboard handling requires terminal (not pipe) input.
    allow_interactive=$PV_ALLOW_INTERACTIVE
    if (( allow_interactive )) && [[ ! -t 0 ]]; then
        allow_interactive=0
    fi

    # Decide whether to run the child under a PTY. A PTY is what makes /dev/tty-based
    # prompts (and color/interactive behavior) work inside the popview. We only use it
    # when interactive input is allowed and a PTY tool exists; otherwise fall back to the plain
    # pipe so the no-dependency guarantee still holds for non-interactive commands.
    PV_PTY_ACTIVE=0
    local -i pty_kind=0
    if ((allow_interactive)); then
        pv_get_pty_kind pty_kind
        (( pty_kind > 0 )) && PV_PTY_ACTIVE=1
    fi

    # The command + args, safely re-quoted for the 'script -c' wrapper.
    local cmd_quoted="${(j: :)${(q+)@}}"

    if [[ -n "$outfile" ]]; then
        _append_log_timestamp "$outfile" "$@"
        setopt localoptions nomonitor
        case $pty_kind in
        0) coproc {     # `script` not found, interactive cmds won't work well
            setopt pipefail
            command -- "$@" 2>&1 | tee -a "$outfile"
           } ;;
        1) coproc {     # linux version of `script`
            setopt pipefail
            script -qef -c "$cmd_quoted" /dev/null 2>&1 | tee -a "$outfile"
           } ;;
        2) coproc {     # BSD/macOS version of `script`
            setopt pipefail
            script -q /dev/null /bin/sh -c "exec \"\$@\"" sh "$@" 2>&1 | tee -a "$outfile"
           } ;;
        esac
    else
        setopt localoptions nomonitor
        case $pty_kind in
        0) coproc {     # `script` not found, interactive cmds won't work well
            command -- "$@" 2>&1
           } ;;
        1) coproc {     # linux version of `script`
            script -qef -c "$cmd_quoted" /dev/null 2>&1
           } ;;
        2) coproc {     # BSD/macOS version of `script`
            script -q /dev/null /bin/sh -c "exec \"\$@\"" sh "$@" 2>&1
           } ;;
        esac
    fi
    PV_PID=$!
    exec {PV_FD_OUT}<&p
    ((allow_interactive)) && exec {PV_FD_IN}>&p

    trap '_pv_exit_cleanup' EXIT
    trap '_pv_record_signal 2' INT
    trap '_pv_record_signal 15' TERM
    trap '_pv_record_signal 1' HUP
    trap '_pv_record_signal 3' QUIT
    pv_tput_civis

    # In interactive mode, put main TTY into char-at-a-time, no-echo mode so we can
    # relay each keystroke into the child and control our own echo. Save/restore it.
    _pv_save_and_config_tty

    if (( PV_SIGNAL )); then
        _pv_restore_tty
        trap - INT TERM HUP QUIT EXIT
        return $((128 + PV_SIGNAL))
    fi

    PV_INSIDE_TPUTCSR=0
    _start_popview $label
    _process_popview "$label" "$allow_interactive"

    # First, restore TTY mode.
    local -i signal_no=$PV_SIGNAL
    if (( signal_no )); then
        if [[ -n "$PV_FD_IN" ]]; then
            exec {PV_FD_IN}>&-;                 PV_FD_IN=""
        fi
        kill -"$signal_no" "$PV_PID" 2>/dev/null
    fi
    _pv_restore_tty
    # Clean up the FDs, and wait (process is dead, so will be instant) to retrieve return code.
    if [[ -n "$PV_FD_IN" ]]; then
        exec {PV_FD_IN}>&-;                 PV_FD_IN=""
    fi
    if [[ -n "$PV_FD_OUT" ]]; then
        exec {PV_FD_OUT}<&-;                PV_FD_OUT=""
    fi
    local -i rc
    wait $PV_PID;       rc=$?
    (( signal_no )) && rc=$((128 + signal_no))
    PV_PID=""
    if (( rc != 0 || PV_DEBUG_SKIP_CLOSE )); then
        # failure: leave scroll view visible since it hopefully has the failure details
        _end_popview_leave_open "$label" "$outfile" "$rc"
        pv_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
        return rc
    else
        # success: wipe the scroll view rows, show a single success line, cleanup
        _end_popview_with_close "$label" "$outfile"
        pv_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
    fi
    return 0
}

# If executed (not sourced), run as a command.
if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
    pv_exec "$@"
fi
