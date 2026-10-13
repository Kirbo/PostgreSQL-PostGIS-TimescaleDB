# output.sh — sourced by the scripts for their own output.
#
# Colours: "==>" section headers stand out from the docker/psql noise around them,
# ok/FAIL/ERROR/WARNING are coloured by outcome. On in a terminal and in CI (GitLab's job log
# renders ANSI colours); NO_COLOR (https://no-color.org) turns it off. Every C_* variable is
# empty when it is off.
#
# Sections: `section TITLE` prints the "==> TITLE" header. In GitLab CI it also opens a
# collapsible section of the job log (with its duration) that runs until the next `section`
# or `section_close`; SECTION_COLLAPSED=true makes them start folded. Anything that must stay
# visible on a failure (the FAIL line, container logs) is printed after `section_close`.
# shellcheck shell=sh disable=SC2034
if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ -n "${CI:-}" ]; }; then
  C_HEAD="$(printf '\033[1;36m')"   # bold cyan: section headers
  C_PASS="$(printf '\033[1;32m')"   # bold green: a whole script passed
  C_OK="$(printf '\033[32m')"       # green: one assertion
  C_WARN="$(printf '\033[1;33m')"   # bold yellow
  C_FAIL="$(printf '\033[1;31m')"   # bold red
  C_OFF="$(printf '\033[0m')"
else
  C_HEAD='' C_PASS='' C_OK='' C_WARN='' C_FAIL='' C_OFF=''
fi

SECTION_OPEN=''
SECTION_SEQ=0

section() { # section TITLE
  section_close
  if [ -n "${GITLAB_CI:-}" ]; then
    SECTION_SEQ=$((SECTION_SEQ + 1))
    SECTION_OPEN="ppt_$$_${SECTION_SEQ}"
    printf '\033[0Ksection_start:%s:%s[collapsed=%s]\r\033[0K%s==> %s%s\n' \
      "$(date +%s)" "$SECTION_OPEN" "${SECTION_COLLAPSED:-false}" "$C_HEAD" "$*" "$C_OFF"
  else
    printf '%s==> %s%s\n' "$C_HEAD" "$*" "$C_OFF"
  fi
}

section_close() {
  [ -n "$SECTION_OPEN" ] || return 0
  printf '\033[0Ksection_end:%s:%s\r\033[0K\n' "$(date +%s)" "$SECTION_OPEN"
  SECTION_OPEN=''
}
